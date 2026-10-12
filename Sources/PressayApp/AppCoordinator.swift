import AppKit
import Combine
import SwiftUI
import Foundation
import PressayCore
import PressayTranscription
import OSLog

@MainActor
final class AppCoordinator: ObservableObject, HoldHotkeyDelegate {
    static let shared = AppCoordinator()

    @Published private(set) var modelStatus = "Not loaded"
    @Published private(set) var modelReady = false
    @Published private(set) var modelPreparing = false
    /// 0…1, or `nil` when idle or the size is unknown.
    @Published private(set) var modelDownloadProgress: Double?
    @Published private(set) var lastError: String?

    let settings = AppSettings()
    let permissions = PermissionController()
    let history: HistoryStore
    let tunerRunner = VocabularyTunerRunner()

    private let recorder = AudioRecorder()
    private let hotkey = HotkeyMonitor()
    private let accessibility = AccessibilityBridge()
    private let overlay = OverlayPanelController()
    private let sounds = DictationSoundPlayer()
    private var transcriber: any SpeechTranscriber
    private let logger = Logger(subsystem: "dev.localflow.app", category: "pipeline")
    private var stateMachine = DictationStateMachine()
    private var target: CapturedTarget?
    private var processingTask: Task<Void, Never>?
    /// Only this monitor's release/cancel may end the session.
    private var activeMonitor: HotkeyMonitor?
    /// Captured at key press so a mid-session model swap can't hand the clip to an unprepared engine.
    private var sessionEngine: (any SpeechTranscriber)?
    /// Invalidates stale prepare completions after a model swap.
    private var prepareGeneration = 0
    private var coolDownTask: Task<Void, Never>?
    /// Backstop for the readiness cue when a device never reports live audio.
    private var armingTimeoutTask: Task<Void, Never>?
    private var lastDictationEnded: Date?
    private var outputActivity: OutputActivityObserver?
    /// Parks warming after a failed open so a broken device can't spin.
    private var warmUpFailed = false
    private var keyPressedAt = Date.distantPast
    private let cleaner = ClaudeCleaner()
    private let chatGPTCleaner = ChatGPTCleaner()
    private let editWatcher = EditWatcher()
    let chatGPT = ChatGPTAccount()
    let notes = NotesStore()
    @Published private(set) var liveSession: LiveSession?
    @Published var recordingError: String?
    private var chatGPTForward: AnyCancellable?
    /// Cached so the CGEventTap callback never makes a keychain IPC.
    @Published private(set) var claudeAPIKey: String?
    private lazy var onboardingWindow = OnboardingWindowController(coordinator: self)
    private lazy var settingsWindow = SettingsWindowController(coordinator: self)
    private lazy var notesWindow = NotesWindowController(coordinator: self)

    private init() {
        // Before the history store opens: its retention pass must see audio at its final location.
        Self.migrateApplicationSupportDirectory()
        do {
            history = try HistoryStore()
        } catch {
            history = try! HistoryStore(inMemory: true)
            lastError = "History will not persist: \(error.localizedDescription)"
        }
        transcriber = Self.makeTranscriber(for: settings.asrModel, language: settings.language)
        hotkey.delegate = self
        recorder.onLevel = { [weak self] frame in
            Task { @MainActor in self?.overlay.state.levels = frame.bars }
        }
        recorder.onCaptureFailed = { [weak self] message in
            Task { @MainActor in self?.captureFailedMidDictation(message) }
        }
        recorder.onFirstAudio = { [weak self] in
            Task { @MainActor in self?.captureBecameLive() }
        }
        permissions.onStatusChange = { [weak self] in
            // Fresh run-loop turn: restarting a monitor from its own press callback resets isPressed,
            // so the release would never arrive and recording would never stop.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if permissions.inputMonitoringGranted {
                    restartHotkey()
                } else {
                    hotkey.stop()
                }
            }
        }
    }

    func start() {
        chatGPTForward = chatGPT.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        if chatGPT.isSignedIn { Task { await chatGPT.loadModels() } }
        try? history.rewriteAudioPaths(from: "/LocalFlow/", to: "/Pressay/")
        permissions.startMonitoring()
        settings.refreshLaunchAtLogin()
        applyTranscriptionLanguage()
        applyMicWarmth()
        // Pause video, dictate, resume is common, so react to playback starting inside the warm window.
        let observer = OutputActivityObserver { [weak self] _ in
            self?.applyMicWarmth()
        }
        observer.start()
        outputActivity = observer
        try? history.applyRetention()
        reloadClaudeKey()
        // Independent of TCC onboarding.
        Task { await prepareModel() }
        Task { @MainActor in tunerRunner.scheduleIfNeeded(history: history, settings: settings) }
        if !settings.onboardingComplete {
            showOnboarding()
        }
        #if DEBUG
        runDesignDemo()
        #endif
    }

    /// Design review hook: `open --env PRESSAY_DEMO=<mode>`.
    private var designDemoWindow: NSWindow?

    private func runDesignDemo() {
        switch ProcessInfo.processInfo.environment["PRESSAY_DEMO"] {
        case "onboarding":
            showOnboarding()
        case "menu":
            let panel = NSPanel(
                contentRect: NSRect(x: 400, y: 400, width: 320, height: 420),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            let host = NSHostingView(rootView: MenuContentView(coordinator: self)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous)))
            panel.contentView = host
            panel.setContentSize(host.fittingSize)
            panel.center()
            panel.orderFrontRegardless()
            designDemoWindow = panel
        case "key":
            claudeAPIKey = "sk-ant-demo-000000000000000000001234"
            showSettings()
        case "notes":
            showNotes()
        case "settings":
            showSettings()
        case let mode? where mode.hasPrefix("record-"):
            // e.g. "record-meeting-40": meeting, stops after 40 s.
            let parts = mode.split(separator: "-")
            let kind: Note.Kind = parts.count > 1 && parts[1] == "meeting" ? .meeting : .voice
            let seconds = parts.count > 2 ? Double(parts[2]) ?? 30 : 30
            showNotes()
            Task { @MainActor in
                while !self.modelReady { try? await Task.sleep(for: .milliseconds(200)) }
                self.startRecording(kind)
                try? await Task.sleep(for: .seconds(seconds))
                self.stopRecording()
            }
        case "overlay":
            Task { @MainActor in
                let overlay = self.overlay
                while true {
                    overlay.showArming()
                    try? await Task.sleep(for: .seconds(1.5))
                    overlay.showRecording()
                    for i in 0..<40 {
                        let t = Float(i) * 0.35
                        overlay.state.levels = (0..<4).map { 0.25 + 0.35 * abs(sin(t + Float($0))) }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    overlay.showProcessing()
                    try? await Task.sleep(for: .seconds(2))
                    overlay.showPolishing()
                    try? await Task.sleep(for: .seconds(2))
                    overlay.showSuccess()
                    try? await Task.sleep(for: .seconds(3))
                    overlay.showError("Microphone unavailable")
                    try? await Task.sleep(for: .seconds(4))
                    overlay.showLearnedToast("Learned “Kimi”")
                    try? await Task.sleep(for: .seconds(4))
                }
            }
        case let mode? where mode.hasPrefix("overlay-"):
            Task { @MainActor in
                let overlay = self.overlay
                let show: () -> Void
                switch mode.dropFirst("overlay-".count) {
                case "arming": show = { overlay.showArming() }
                case "recording": show = { overlay.showRecording() }
                case "processing": show = { overlay.showProcessing() }
                case "polishing": show = { overlay.showProcessing(); overlay.showPolishing() }
                case "success": show = { overlay.showSuccess() }
                case "error": show = { overlay.showError("Microphone unavailable") }
                default: show = { overlay.showLearnedToast("Learned “Kimi”") }
                }
                show()
                var t: Float = 0
                while true {
                    t += 0.35
                    overlay.state.levels = (0..<4).map { 0.25 + 0.35 * abs(sin(t + Float($0))) }
                    try? await Task.sleep(for: .milliseconds(100))
                    if !overlay.state.visible { show() }
                }
            }
        default:
            break
        }
    }

    func reloadClaudeKey() {
        // Dev rebuilds change the code hash, so a keychain read would re-prompt for the login password.
        guard ProcessInfo.processInfo.environment["PRESSAY_NO_KEYCHAIN"] != "1" else { return }
        claudeAPIKey = ClaudeAPIKeyStore.read()
    }

    var cleanupConfigured: Bool {
        switch settings.cleanupProvider {
        case .claude: claudeAPIKey != nil
        case .chatgpt: chatGPT.isSignedIn
        }
    }

    private var cleanupActive: Bool {
        settings.claudeCleanup && cleanupConfigured
    }

    private func runCleanup(
        _ raw: String,
        targetBundleID: String?,
        vocabulary: [VocabularyParser.Entry],
        timeout: TimeInterval
    ) async throws -> String {
        switch settings.cleanupProvider {
        case .claude:
            guard let apiKey = claudeAPIKey else { throw CancellationError() }
            return try await cleaner.clean(
                raw,
                targetBundleID: targetBundleID,
                vocabulary: vocabulary,
                model: settings.claudeCleanupModel,
                apiKey: apiKey,
                timeout: timeout
            )
        case .chatgpt:
            let token = try await chatGPT.accessToken()
            return try await chatGPTCleaner.clean(
                raw,
                targetBundleID: targetBundleID,
                vocabulary: vocabulary,
                model: settings.chatGPTModel,
                effort: ChatGPTCleanupModel.effort(for: settings.chatGPTModel),
                accessToken: token,
                timeout: timeout
            )
        }
    }

    private func warmCleanupConnection() {
        guard cleanupActive else { return }
        switch settings.cleanupProvider {
        case .claude:
            guard let key = claudeAPIKey else { return }
            let cleaner = cleaner
            Task.detached(priority: .utility) { _ = try? await cleaner.warmUp(apiKey: key) }
        case .chatgpt:
            // Also refreshes a nearly expired token before the user lets go.
            Task { _ = try? await chatGPT.accessToken() }
        }
    }

    /// Stored audio paths are rewritten separately in start().
    private static func migrateApplicationSupportDirectory() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appending(path: "LocalFlow", directoryHint: .isDirectory)
        let new = base.appending(path: "Pressay", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: old.path),
              !FileManager.default.fileExists(atPath: new.path) else { return }
        try? FileManager.default.moveItem(at: old, to: new)
    }

    func suspendHotkeys() {
        hotkey.stop()
    }

    /// Single wiring point: a capture site that skips it lets rebinding the hold key start a dictation.
    func keyCaptureActive(_ active: Bool) {
        active ? suspendHotkeys() : restartHotkey()
    }

    func restartHotkey() {
        guard permissions.inputMonitoringGranted else {
            hotkey.stop()
            return
        }
        do {
            try hotkey.start(holdKey: settings.holdKey)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func applyTranscriptionLanguage() {
        let code = settings.language.whisperCode
        Task { [transcriber] in await transcriber.setLanguage(code) }
    }

    private static func makeTranscriber(
        for model: ASRModel,
        language: TranscriptionLanguage
    ) -> any SpeechTranscriber {
        GGMLTranscriber(model: model, language: language.whisperCode)
    }

    /// An in-flight dictation keeps the engine captured at its key press.
    func applyASRModel() {
        let model = settings.asrModel
        if !model.supportedLanguages.contains(settings.language) {
            settings.language = model.defaultLanguage
        }
        transcriber = Self.makeTranscriber(for: model, language: settings.language)
        modelReady = false
        // A prepare for the old engine may still be running; its completion must not mark this one ready.
        prepareGeneration += 1
        Task { await prepareModel(force: true) }
    }

    func prepareModel(force: Bool = false) async {
        guard force || (!modelReady && !modelPreparing) else { return }
        let generation = prepareGeneration
        modelPreparing = true
        modelReady = false
        let preparing = transcriber
        let name = await preparing.engineName
        guard generation == prepareGeneration else { return }
        modelStatus = "Preparing \(name)…"
        defer {
            if generation == prepareGeneration { modelPreparing = false }
        }
        await preparing.setStatusHandler { [weak self] status in
            Task { @MainActor in
                guard let self, generation == self.prepareGeneration else { return }
                self.modelStatus = status
            }
        }
        await preparing.setProgressHandler { [weak self] progress in
            Task { @MainActor in
                guard let self, generation == self.prepareGeneration else { return }
                self.modelDownloadProgress = progress
            }
        }
        do {
            try await preparing.prepare()
            guard generation == prepareGeneration else { return }
            modelReady = true
            modelStatus = "\(name) ready · local"
            modelDownloadProgress = nil
            logger.info("Local transcription model is ready")
        } catch {
            guard generation == prepareGeneration else { return }
            modelStatus = "Model unavailable"
            modelDownloadProgress = nil
            lastError = error.localizedDescription
            logger.error("Model preparation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func showOnboarding() {
        onboardingWindow.present()
    }

    func showSettings() {
        settingsWindow.present()
    }

    func showNotes() {
        notesWindow.present()
    }

    func completeOnboarding() {
        permissions.refresh()
        guard permissions.allGranted, modelReady else { return }
        settings.onboardingComplete = true
        restartHotkey()
        onboardingWindow.dismiss()
    }

    func holdKeyPressed(_ monitor: HotkeyMonitor) {
        // No synchronous TCC refresh inside the CGEventTap callback; startMonitoring() keeps these current.
        guard permissions.microphoneGranted, permissions.accessibilityGranted else {
            overlay.showError("Finish setup in Pressay")
            return
        }
        guard modelReady else {
            overlay.showError("Wait for the local model to finish preparing")
            return
        }
        guard liveSession == nil else {
            overlay.showError("Stop the recording in Notes to dictate")
            return
        }
        guard stateMachine.arm() else {
            if stateMachine.phase == .processing {
                overlay.showError("Still processing the previous dictation")
            }
            return
        }
        activeMonitor = monitor
        sessionEngine = transcriber
        keyPressedAt = Date()
        coolDownTask?.cancel()
        do {
            // Cue waits for real audio: a cold Bluetooth link gives 550 ms+ of silence, and beeping
            // through it trains people to talk into a dead mic.
            overlay.showArming()
            try recorder.start()
            target = accessibility.capture(vocabulary: settings.vocabularyTerms)
            settings.hasUsedDictation = true
            startArmingTimeout()
            warmCleanupConnection()
        } catch {
            stateMachine.fail(error.localizedDescription)
            overlay.showError(error.localizedDescription)
            stateMachine.reset()
        }
    }

    private func captureBecameLive() {
        guard stateMachine.phase == .arming else { return }
        armingTimeoutTask?.cancel()
        armingTimeoutTask = nil
        stateMachine.begin()
        sounds.play(.begin)
        recorder.markEarcon(duration: sounds.beginCaptureDelay)
        overlay.showRecording(style: .dictation)
    }

    private func startArmingTimeout() {
        armingTimeoutTask?.cancel()
        armingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_200))
            guard !Task.isCancelled, let self, stateMachine.phase == .arming else { return }
            logger.warning("mic never reported live audio; cueing on timeout")
            captureBecameLive()
        }
    }

    func holdKeyReleased(_ monitor: HotkeyMonitor) {
        guard monitor === activeMonitor else { return }
        guard stateMachine.stop() else { return }
        armingTimeoutTask?.cancel()
        armingTimeoutTask = nil
        do {
            let raw = try recorder.stop()
            // After stop(): coolDown() refuses to cut a live dictation.
            scheduleMicCoolDown()
            // Held-key duration, not clip duration: pre-roll seeds every warm capture with up to 0.5 s.
            let held = Date().timeIntervalSince(keyPressedAt)
            guard held >= DictationProcessingPolicy.minimumClipDuration else {
                resetAfterNonResult()
                return
            }
            sounds.play(.release)
            recorder.mutePreRoll(for: sounds.beginCaptureDelay)
            overlay.showProcessing()
            let captured = target ?? accessibility.capture(vocabulary: settings.vocabularyTerms)
            let target = accessibility.refreshInsertionTarget(captured)
            let engine = sessionEngine ?? transcriber
            processingTask = Task { [weak self] in
                await self?.process(raw, target: target, engine: engine)
            }
        } catch PressayError.recordingTooShort {
            resetAfterNonResult()
        } catch {
            fail(error)
        }
    }

    func holdKeyCancelled(_ monitor: HotkeyMonitor) {
        guard monitor === activeMonitor else { return }
        guard stateMachine.phase == .recording || stateMachine.phase == .arming else { return }
        armingTimeoutTask?.cancel()
        armingTimeoutTask = nil
        recorder.cancel()
        processingTask?.cancel()
        stateMachine.cancel()
        target = nil
        overlay.hide()
        sounds.play(.cancel)
            recorder.mutePreRoll(for: sounds.beginCaptureDelay)
        scheduleMicCoolDown()
    }

    // MARK: - Warm microphone

    /// Re-entrant: each dictation restarts the clock.
    private func scheduleMicCoolDown() {
        lastDictationEnded = Date()
        warmUpFailed = false
        applyMicWarmth()
    }

    /// Single place that reconciles the recorder's stream with the policy.
    func applyMicWarmth() {
        guard stateMachine.phase != .recording, stateMachine.phase != .arming else { return }
        guard liveSession == nil else {
            recorder.coolDown()
            return
        }
        // A warm stream is bound to its device; it must close before a new choice takes effect.
        if recorder.preferredInputUID != settings.inputDeviceUID {
            recorder.preferredInputUID = settings.inputDeviceUID
            recorder.coolDown()
        }
        let conditions = warmConditions(at: Date())
        let shouldWarm = MicWarmPolicy.shouldStayWarm(conditions, now: Date())
        logger.debug(
            """
            warmth: enabled=\(conditions.enabled, privacy: .public) \
            bluetooth=\(conditions.isBluetooth, privacy: .public) \
            otherAppPlaying=\(conditions.outputDeviceInUse, privacy: .public) \
            everDictated=\(conditions.lastDictationEnded != nil, privacy: .public) \
            warm=\(self.recorder.isWarm, privacy: .public) → \
            \(shouldWarm ? "warm" : "cool", privacy: .public)
            """
        )
        // A device that refuses to open should not be retried on every audio
        // event; one failure parks warming until the next real dictation.
        guard shouldWarm, !warmUpFailed else {
            coolDownTask?.cancel()
            coolDownTask = nil
            recorder.coolDown()
            return
        }
        do {
            try recorder.warmUp()
        } catch {
            warmUpFailed = true
            coolDownTask?.cancel()
            coolDownTask = nil
            logger.info("could not keep the mic warm: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Whoever warms the stream owns closing it.
        scheduleCoolDown(for: conditions)
    }

    /// Uses the policy's expiry, not a bare sleep, so a wall-clock change can't leave the mic open.
    private func scheduleCoolDown(for conditions: MicWarmPolicy.Conditions) {
        coolDownTask?.cancel()
        guard let expiry = MicWarmPolicy.expiry(conditions, now: Date()) else {
            coolDownTask = nil
            return
        }
        coolDownTask = Task { [weak self] in
            let remaining = max(0, expiry.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                // A dictation may have pushed the deadline out while sleeping.
                if MicWarmPolicy.shouldStayWarm(self.warmConditions(at: Date()), now: Date()) {
                    self.applyMicWarmth()
                } else {
                    self.coolDownTask = nil
                    self.recorder.coolDown()
                }
            }
        }
    }

    private func warmConditions(at now: Date) -> MicWarmPolicy.Conditions {
        MicWarmPolicy.Conditions(
            enabled: settings.keepMicWarm,
            isBluetooth: AudioDeviceMonitor.defaultInputIsBluetooth,
            outputDeviceInUse: AudioDeviceMonitor.otherProcessIsPlaying,
            lastDictationEnded: lastDictationEnded
        )
    }

    /// Resuming into a half-torn-down Bluetooth link wedges the input into silence.
    func releaseMicForSystemEvent() {
        coolDownTask?.cancel()
        coolDownTask = nil
        armingTimeoutTask?.cancel()
        armingTimeoutTask = nil
        lastDictationEnded = nil
        // forceClose: coolDown() declines while recording.
        recorder.forceClose()
        if stateMachine.phase == .recording || stateMachine.phase == .arming {
            stateMachine.cancel()
            target = nil
            overlay.hide()
        }
    }

    func copy(_ record: DictationRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.referenceText, forType: .string)
    }

    func retry(_ record: DictationRecord) {
        guard let target = accessibility.runningTarget(
            bundleID: record.targetBundleID,
            vocabulary: settings.vocabularyTerms
        ) else {
            copy(record)
            overlay.showError("Copied — target app is closed")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let insertion = await accessibility.insert(
                record.referenceText,
                into: target,
                reactivateTarget: true
            )
            showInsertionOutcome(insertion)
        }
    }

    private func process(
        _ raw: AudioRecorder.RawCapture,
        target: CapturedTarget,
        engine: any SpeechTranscriber
    ) async {
        let releasedAt = Date()
        let recordID = UUID()
        var audioURL: URL?
        do {
            // ~5 ms per second of audio.
            let clip = try await Task.detached(priority: .userInitiated) {
                let converted = try raw.segments.flatMap {
                    try AudioResampler.convert($0.samples, from: $0.sampleRate)
                }
                // Resampling preserves duration, so the cue window maps straight onto the 16 kHz clip.
                let earconGuard = raw.earconWindow.map {
                    Int($0.lowerBound * 16_000)..<Int($0.upperBound * 16_000)
                }
                return AudioClip(
                    samples: try AudioTrimmer.trim(converted, earconGuard: earconGuard)
                )
            }.value
            // Save before inference so failures stay diagnosable; unreferenced files expire after 7 days.
            audioURL = try? AudioFileStore.save(clip, id: recordID)
            let asrTimeout = DictationProcessingPolicy.asrTimeout(duration: clip.duration)
            logger.info("Transcribing \(clip.duration, privacy: .public)s clip with \(asrTimeout, privacy: .public)s budget")
            let engineName = await engine.engineName
            let transcript = try await Timeout.run(for: .seconds(asrTimeout)) {
                try await engine.transcribe(clip)
            }
            guard !Task.isCancelled else {
                cleanUpCancelledProcessing()
                return
            }

            let learnedRules = tunerRunner.learnImmediately(from: transcript.text, settings: settings)

            // Shell commands are case-sensitive; never auto-capitalize into a terminal.
            let isTerminal = target.bundleID.map {
                DeterministicPromptCleaner.terminalBundleIDs.contains($0)
            } ?? false
            let deterministic = DeterministicPromptCleaner.clean(
                transcript.text,
                vocabulary: settings.vocabularyEntries,
                capitalizeFirstWord: !isTerminal,
                // Fuzzy rewrites would break case-sensitive paths and branches.
                phoneticFallback: !isTerminal
            )
            var finalText = deterministic
            var structureLatency: TimeInterval = 0
            var usedLanguageModel = false
            let structureStarted = Date()
            if cleanupActive,
               ClaudeCleanupPolicy.shouldClean(transcript.text, isTerminal: isTerminal) {
                // Raw transcript: the rules' phonetic rewrites would only hand Claude errors to undo.
                let raw = transcript.text
                let vocabulary = settings.vocabularyEntries
                let timeout = ClaudeCleanupPolicy.timeout(for: raw)
                overlay.showPolishing()
                do {
                    finalText = try await Timeout.run(for: .seconds(timeout)) { [self] in
                        try await runCleanup(raw, targetBundleID: target.bundleID, vocabulary: vocabulary, timeout: timeout)
                    }
                    usedLanguageModel = true
                } catch ChatGPTCleaner.CleanupError.usageLimit {
                    logger.notice("ChatGPT usage limit reached; inserted the on-device result")
                    chatGPT.lastError = "You've reached your ChatGPT usage limit. Dictations use on-device cleanup until it resets."
                } catch {
                    // Never block a dictation on the network.
                    logger.error("AI cleanup fell back to rules: \(error.localizedDescription, privacy: .public)")
                }
            }
            if !usedLanguageModel, settings.structuredDictation, !isTerminal {
                finalText = TranscriptStructurer.structure(deterministic)
            }
            structureLatency = Date().timeIntervalSince(structureStarted)

            guard !Task.isCancelled else {
                cleanUpCancelledProcessing()
                return
            }
            let insertion = await accessibility.insert(finalText, into: target)
            let insertionLatency = Date().timeIntervalSince(releasedAt)
            let record = DictationRecord(
                id: recordID,
                duration: clip.duration,
                targetBundleID: target.bundleID,
                engine: engineName,
                rawTranscript: transcript.text,
                polishedText: finalText,
                asrLatency: transcript.processingTime,
                polishLatency: structureLatency,
                totalLatency: insertionLatency,
                audioPath: audioURL?.path,
                usedLanguageModel: usedLanguageModel
            )
            do {
                try history.add(record)
            } catch {
                lastError = "Prompt inserted, but history could not be saved: \(error.localizedDescription)"
                logger.error("History save failed after insertion: \(error.localizedDescription, privacy: .public)")
            }
            stateMachine.succeed()
            showInsertionOutcome(insertion)
            if settings.learnFromEdits, !isTerminal, insertion != .copied {
                editWatcher.watch(pid: target.pid, inserted: finalText) { [weak self] corrections in
                    self?.learnFromEdits(corrections)
                }
            }
            // The overlay's success beat yields if a new press arrives.
            stateMachine.reset()
            self.target = nil
            celebrateLearnedRules(learnedRules)
            tunerRunner.scheduleIfNeeded(history: history, settings: settings)
        } catch PressayError.recordingTooShort {
            resetAfterNonResult()
        } catch PressayError.silence {
            resetAfterNonResult()
        } catch {
            if let audioURL {
                logger.error("Failed dictation audio retained locally at \(audioURL.lastPathComponent, privacy: .public)")
            }
            fail(error)
        }
    }

    /// Fails visibly while the key is still held; the eventual key release is
    /// a no-op because the state machine has left the recording phase.
    private func captureFailedMidDictation(_ message: String) {
        guard stateMachine.phase == .recording || stateMachine.phase == .arming else { return }
        armingTimeoutTask?.cancel()
        armingTimeoutTask = nil
        fail(PressayError.microphoneUnavailable, message: message)
    }

    private func resetAfterNonResult() {
        stateMachine.reset()
        target = nil
        overlay.hide()
    }

    /// Nothing else resets a cancelled process() stuck in .processing.
    private func cleanUpCancelledProcessing() {
        guard stateMachine.phase == .processing else { return }
        resetAfterNonResult()
    }

    private func fail(_ error: Error, message: String? = nil) {
        lastError = error.localizedDescription
        logger.error("Dictation failed: \(error.localizedDescription, privacy: .public)")
        stateMachine.fail(error.localizedDescription)
        overlay.showError(message ?? error.localizedDescription)
        sounds.play(.error)
        recorder.mutePreRoll(for: sounds.beginCaptureDelay)
        target = nil
        // Allow an immediate retry while the error is still showing.
        stateMachine.reset()
    }

    // MARK: - Notes

    func startRecording(_ kind: Note.Kind, continuing id: UUID? = nil) {
        guard liveSession == nil else { return }
        guard permissions.microphoneGranted else {
            recordingError = "Pressay needs microphone access to record. Allow it in System Settings › Privacy & Security › Microphone."
            return
        }
        guard modelReady else {
            recordingError = "Wait for the local model to finish preparing."
            return
        }
        guard stateMachine.phase == .idle else { return }

        let existing = id.flatMap(notes.note)
        let noteID = existing?.id ?? UUID()
        coolDownTask?.cancel()
        coolDownTask = nil
        recorder.forceClose()
        do {
            let session = try LiveSession(
                noteID: noteID,
                kind: existing?.kind ?? kind,
                offset: existing?.duration ?? 0,
                transcriber: transcriber,
                vocabulary: settings.vocabularyEntries,
                inputUID: settings.inputDeviceUID,
                captureSystemAudio: settings.meetingSystemAudio
            )
            session.onLine = { [weak self] line in
                self?.notes.modify(noteID) { $0.lines.append(line) }
            }
            session.createdNote = existing == nil
            if existing == nil {
                notes.add(Note(id: noteID, kind: kind, title: kind == .meeting ? "Meeting" : "Voice note", body: "", transcripts: [], duration: 0))
            }
            liveSession = session
            sounds.play(.begin)
            logger.info("Recording a \(kind.rawValue, privacy: .public) note")
        } catch {
            logger.error("Recording failed to start: \(error.localizedDescription, privacy: .public)")
            recordingError = "Couldn’t start recording: \(error.localizedDescription)"
            applyMicWarmth()
        }
    }

    func finishRecordingForQuit() async {
        guard let session = liveSession, session.phase == .recording else { return }
        let duration = session.elapsed
        _ = await session.finish()
        liveSession = nil
        notes.modify(session.noteID) { note in
            note.duration += duration
            note.lines.sort { $0.start < $1.start }
        }
    }

    func stopRecording() {
        guard let session = liveSession, session.phase == .recording else { return }
        sounds.play(.release)
        let duration = session.elapsed
        Task { [weak self] in
            let lines = await session.finish()
            guard let self else { return }
            liveSession = nil
            applyMicWarmth()
            finishNote(session.noteID, kind: session.kind, newLines: lines, duration: duration)
        }
    }

    func discardRecording() {
        guard let session = liveSession else { return }
        session.discard()
        liveSession = nil
        sounds.play(.cancel)
        if session.createdNote {
            notes.delete(session.noteID)
        } else {
            notes.modify(session.noteID) { $0.lines.removeAll { $0.start >= session.offset } }
        }
        applyMicWarmth()
    }

    private func finishNote(_ id: UUID, kind: Note.Kind, newLines: [TranscriptLine], duration: TimeInterval) {
        guard let note = notes.note(id) else { return }
        let text = newLines.map(\.text).joined(separator: " ")
        guard !text.isEmpty else {
            // Drop a note that only this recording created.
            if note.lines.isEmpty, note.body.isEmpty { notes.delete(id) }
            recordingError = "Nothing was heard. Check your microphone in Settings › General."
            return
        }
        notes.modify(id) { note in
            note.duration += duration
            note.lines.sort { $0.start < $1.start }
            if kind == .voice {
                note.transcripts.append(text)
                note.body += (note.body.isEmpty ? "" : "\n\n") + text
                if note.transcripts.count == 1 { note.title = NotePrompt.fallbackTitle(for: text) }
            } else if note.title == "Meeting" {
                note.title = "Meeting on \(note.createdAt.formatted(.dateTime.month(.wide).day()))"
            }
        }
        writeUpNote(id)
    }

    /// Hand-edited notes are left alone; their new recordings were appended as-is.
    func writeUpNote(_ id: UUID) {
        guard settings.notesUseAI, cleanupConfigured,
              let note = notes.note(id), !note.edited else { return }
        let system: String
        let user: String
        switch note.kind {
        case .voice:
            guard !note.transcripts.isEmpty else { return }
            system = NotePrompt.system(style: settings.noteStyle, vocabulary: settings.vocabularyEntries)
            user = NotePrompt.user(transcript: note.transcripts.joined(separator: "\n\n"))
        case .meeting:
            guard !note.lines.isEmpty else { return }
            let hasNotes = !note.myNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            system = MeetingPrompt.system(vocabulary: settings.vocabularyEntries, hasUserNotes: hasNotes)
            user = MeetingPrompt.user(lines: note.lines, userNotes: note.myNotes)
        }
        // About a minute per hour of meeting on top of the base budget.
        let timeout = 90 + note.duration / 60
        notes.modify(id, persist: false) { $0.formatting = true }
        Task { [weak self] in
            guard let self else { return }
            defer { notes.modify(id, persist: false) { $0.formatting = false } }
            do {
                let reply = try await completeNote(system: system, user: user, timeout: timeout)
                guard let parsed = NotePrompt.parse(reply) else { return }
                guard notes.note(id)?.edited == false else { return }
                notes.modify(id) {
                    $0.title = parsed.title
                    $0.body = parsed.body
                }
            } catch {
                logger.error("Note write-up failed, kept the on-device text: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func completeNote(system: String, user: String, timeout: TimeInterval) async throws -> String {
        switch settings.cleanupProvider {
        case .claude:
            guard let apiKey = claudeAPIKey else { throw CancellationError() }
            return try await cleaner.complete(system: system, user: user, model: settings.claudeCleanupModel, apiKey: apiKey, timeout: timeout)
        case .chatgpt:
            let token = try await chatGPT.accessToken()
            return try await chatGPTCleaner.complete(
                instructions: system, user: user, model: settings.chatGPTModel,
                effort: ChatGPTCleanupModel.effort(for: settings.chatGPTModel), accessToken: token, timeout: timeout
            )
        }
    }

    /// Close matches apply at once; looser ones wait in Suggestions so a change of mind never becomes a rule.
    private func learnFromEdits(_ corrections: [VocabularyCorrection]) {
        let strong = corrections.filter(\.isStrong).map {
            LearnedRule(heard: $0.heard, preferred: $0.typed, count: 1, source: .edit)
        }
        let learned = settings.learnedVocabulary.mergeRules(strong, source: .edit)
        for correction in corrections where !correction.isStrong {
            settings.vocabularySuggestions.add(VocabularySuggestion(
                heard: correction.heard, preferred: correction.typed, origin: .edit, count: 1,
                example: "You changed “\(correction.heard)” to “\(correction.typed)”"
            ))
        }
        logger.info("Edit learning: \(learned.count, privacy: .public) learned, \(corrections.count - strong.count, privacy: .public) suggested")
        celebrateLearnedRules(learned)
    }

    private func celebrateLearnedRules(_ rules: [LearnedRule], retrying: Bool = false) {
        guard !rules.isEmpty, stateMachine.phase == .idle else { return }
        guard overlay.isIdle else {
            if !retrying {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2.6))
                    self?.celebrateLearnedRules(rules, retrying: true)
                }
            }
            return
        }
        let message = rules.count == 1
            ? "Learned: \(rules[0].heard) → \(rules[0].preferred)"
            : "Learned \(rules.count) new words"
        sounds.play(.learned)
        recorder.mutePreRoll(for: sounds.beginCaptureDelay)
        overlay.showLearnedToast(message)
    }

    private func showInsertionOutcome(_ outcome: InsertionOutcome) {
        switch outcome {
        case .replacedSelection, .pasted:
            overlay.showSuccess()
        case .copied:
            overlay.showError("Copied — press ⌘V")
        }
    }
}
