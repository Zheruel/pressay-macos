import AppKit
import AVFoundation
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
    private var engineModel: ASRModel
    private var modelChangeTask: Task<Void, Never>?
    private var meetingStartTask: Task<Void, Never>?
    @Published private(set) var meetingStarting = false
    private let logger = Logger(subsystem: "dev.localflow.app", category: "pipeline")
    private var stateMachine = DictationStateMachine()
    private var target: CapturedTarget?
    private var processingTask: Task<Void, Never>?
    /// Only this monitor's release/cancel may end the session.
    private var activeMonitor: HotkeyMonitor?
    /// Captured at key press so a mid-session model swap can't hand the clip to an unprepared engine.
    private var sessionEngine: (any SpeechTranscriber)?
    /// Transcribes long dictations while the key is held.
    private let dictationDetector = SpeechDetector.make()
    private var streamer: DictationStreamer?
    /// Invalidates stale prepare completions after a model swap.
    private var prepareGeneration = 0
    private var coolDownTask: Task<Void, Never>?
    /// Backstop for the readiness cue when a device never reports live audio.
    private var armingTimeoutTask: Task<Void, Never>?
    private var lastDictationEnded: Date?
    /// Parks warming after a failed open so a broken device can't spin.
    private var warmUpFailed = false
    private var keyPressedAt = Date.distantPast
    private var commandMode = false
    private let cleaner = ClaudeCleaner()
    private let chatGPTCleaner = ChatGPTCleaner()
    private let editWatcher = EditWatcher()
    let chatGPT = ChatGPTAccount()
    #if DEBUG
    // PRESSAY_NOTES_DIR points design reviews at sample meetings.
    let notes = ProcessInfo.processInfo.environment["PRESSAY_NOTES_DIR"]
        .map { NotesStore(directory: URL(fileURLWithPath: $0)) } ?? NotesStore()
    #else
    let notes = NotesStore()
    #endif
    @Published private(set) var liveSession: LiveSession?
    @Published var recordingError: String?
    private var chatGPTForward: AnyCancellable?
    /// Cached so the CGEventTap callback never makes a keychain IPC.
    @Published private(set) var claudeAPIKey: String?
    private lazy var onboardingWindow = OnboardingWindowController(coordinator: self)
    private lazy var settingsWindow = SettingsWindowController(coordinator: self)
    private lazy var notepad = NotepadPanelController(coordinator: self)
    private let callPrompt = CallPromptController()
    private let callDetector = CallDetector()
    /// A main-window section to switch to, e.g. "notes" for the Notetaker.
    @Published var settingsPaneRequest: String?
    @Published var notetakerSettingsShown = false
    /// A hand-edited note waiting for the user to confirm a rewrite.
    @Published var rewriteRequest: UUID?
    private var callSettingsWatch: AnyCancellable?
    private var finishTask: Task<Void, Never>?

    private init() {
        // Before the history store opens: its retention pass must see audio at its final location.
        Self.migrateApplicationSupportDirectory()
        do {
            history = try HistoryStore()
        } catch {
            history = try! HistoryStore(inMemory: true)
            lastError = "History will not persist: \(error.localizedDescription)"
        }
        engineModel = settings.asrModel
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
        try? history.applyRetention()
        reloadClaudeKey()
        callDetector.onEvent = { [weak self] in self?.handleCall($0) }
        callSettingsWatch = settings.$detectCalls.sink { [weak self] in self?.applyCallDetection($0) }
        for note in notes.notes where note.needsWriteUp { writeUpNote(note.id, review: true) }
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

    #if DEBUG
    private func runStreamDemo() async {
        let environment = ProcessInfo.processInfo.environment
        guard let dir = environment["PRESSAY_STREAM_DIR"] else { return }
        let speed = Double(environment["PRESSAY_LIVE_SPEED"] ?? "1") ?? 1
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".wav") }.sorted()
        for file in files {
            guard let audio = try? AVAudioFile(forReading: URL(fileURLWithPath: "\(dir)/\(file)")),
                  let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)),
                  (try? audio.read(into: buffer)) != nil, let channel = buffer.floatChannelData?[0]
            else { continue }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let started = Date()
            let streamer = DictationStreamer(engine: transcriber, detector: dictationDetector) { offset in
                let revealed = min(samples.count, Int(Date().timeIntervalSince(started) * speed * 16_000))
                guard offset <= revealed else { return nil }
                return AudioRecorder.LiveAudio(samples: Array(samples[offset..<revealed]), sampleRate: 16_000, earconWindow: nil)
            }
            await streamer.start()
            let duration = Double(samples.count) / 16_000
            try? await Task.sleep(for: .seconds(duration / speed))
            let released = Date()
            let capture = AudioRecorder.RawCapture(segments: [.init(samples: samples, sampleRate: 16_000)], earconWindow: nil)
            let streamed = await streamer.finish(capture)
            let wait = Date().timeIntervalSince(released)
            let wholeStarted = Date()
            let whole = (try? AudioTrimmer.trim(samples)).map { AudioClip(samples: $0) }
            let wholeText = whole == nil ? "" : ((try? await transcriber.transcribe(whole!))?.text ?? "")
            let row: [String: Any] = [
                "id": (file as NSString).deletingPathExtension, "duration": duration, "streamed": streamed != nil,
                "wait": streamed != nil ? wait : Date().timeIntervalSince(wholeStarted) + wait,
                "wholeLatency": Date().timeIntervalSince(wholeStarted), "text": streamed?.text ?? wholeText, "whole": wholeText,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: row) { print(String(decoding: data, as: UTF8.self)) }
        }
    }
    #endif

    /// Design review hook: `open --env PRESSAY_DEMO=<mode>`.
    private var designDemoWindow: NSWindow?

    private func runDesignDemo() {
        switch ProcessInfo.processInfo.environment["PRESSAY_DEMO"] {
        case "meeting":
            // With PRESSAY_LIVE_FILE: records the file as a meeting, then stops.
            Task {
                while !modelReady { try? await Task.sleep(for: .milliseconds(250)) }
                startMeeting()
                showNotes()
                liveSession?.onInjectedFileEnd = { self.stopRecording(automatic: true) }
            }
        case "stream":
            // PRESSAY_STREAM_DIR of 16 kHz WAVs, "spoken" at PRESSAY_LIVE_SPEED× through the streamer;
            // prints one JSON line per file comparing it with whole-clip transcription, then quits.
            #if DEBUG
            Task { @MainActor in
                while !self.modelReady { try? await Task.sleep(for: .milliseconds(200)) }
                await self.runStreamDemo()
                NSApp.terminate(nil)
            }
            #endif
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
        case "call":
            callPrompt.show(app: "Zoom") {}
        case let mode? where mode.hasPrefix("record-"):
            // e.g. "record-meeting-40": meeting, stops after 40 s.
            let parts = mode.split(separator: "-")
            let seconds = parts.count > 2 ? Double(parts[2]) ?? 30 : 30
            showNotes()
            Task { @MainActor in
                while !self.modelReady { try? await Task.sleep(for: .milliseconds(200)) }
                self.startMeeting()
                try? await Task.sleep(for: .seconds(seconds))
                self.stopRecording()
            }
        case "overlay":
            Task { @MainActor in
                let overlay = self.overlay
                while true {
                    overlay.showArming(style: commandMode ? .command : .dictation)
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

    var commandModeAvailable: Bool { !settings.holdKey.isShift }

    private var cleanupActive: Bool {
        settings.claudeCleanup && cleanupConfigured
    }

    private func runCleanup(
        _ raw: String,
        targetBundleID: String?,
        style: AppStyle?,
        vocabulary: [VocabularyParser.Entry],
        timeout: TimeInterval
    ) async throws -> String {
        switch settings.cleanupProvider {
        case .claude:
            guard let apiKey = claudeAPIKey else { throw CancellationError() }
            return try await cleaner.clean(
                raw,
                targetBundleID: targetBundleID,
                style: style,
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
                style: style,
                vocabulary: vocabulary,
                model: settings.chatGPTModel,
                effort: ChatGPTCleanupModel.effort,
                accessToken: token,
                timeout: timeout
            )
        }
    }

    /// Command Mode runs on the AI Cleanup provider and model, with a longer budget than cleanup.
    private func runCommand(_ instruction: String, selection: String?, target: CapturedTarget, style: AppStyle?) async throws -> String {
        let context = target.context.leadingText + target.context.trailingText
        let user = CommandPrompt.user(instruction: instruction, selection: selection, context: context, app: target.bundleID, style: style)
        let timeout: TimeInterval = 20 + Double(selection?.count ?? 0) / 400
        return try await Timeout.run(for: .seconds(timeout + 5)) { [self] in
            try await requestCommand(user: user, timeout: timeout)
        }
    }

    private func requestCommand(user: String, timeout: TimeInterval) async throws -> String {
        switch settings.cleanupProvider {
        case .claude:
            guard let apiKey = claudeAPIKey else { throw NotesAIError.notConfigured }
            return try await cleaner.complete(
                system: CommandPrompt.system, user: user, model: settings.claudeCleanupModel, apiKey: apiKey, timeout: timeout
            )
        case .chatgpt:
            let token = try await chatGPT.accessToken()
            return try await chatGPTCleaner.complete(
                instructions: CommandPrompt.system, user: user, model: settings.chatGPTModel,
                effort: ChatGPTCleanupModel.effort, accessToken: token, timeout: timeout
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
        SpeechTranscribers.make(model: model, language: language.whisperCode)
    }

    /// An in-flight dictation keeps the engine captured at its key press.
    func applyASRModel() {
        modelChangeTask?.cancel()
        guard liveSession == nil, !meetingStarting else { return }
        guard stateMachine.phase == .idle else {
            modelChangeTask = Task { [weak self] in
                while let self, self.stateMachine.phase != .idle {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { return }
                }
                guard !Task.isCancelled else { return }
                self?.applyASRModel()
            }
            return
        }
        let model = settings.asrModel
        if !model.supportedLanguages.contains(settings.language) {
            settings.language = model.defaultLanguage
        }
        installEngine(model)
        Task { await prepareModel(force: true) }
    }

    private func installEngine(_ model: ASRModel) {
        sessionEngine = nil
        engineModel = model
        transcriber = Self.makeTranscriber(for: model, language: settings.language)
        modelReady = false
        // A prepare for the old engine may still be running; its completion must not mark this one ready.
        prepareGeneration += 1
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
            if !engineModel.usesWorker { await WorkerTranscriber.releaseResidentModel() }
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
        settingsPaneRequest = "notes"
        settingsWindow.present()
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
            overlay.showError("Stop the Notetaker to dictate")
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
        commandMode = commandModeAvailable && NSEvent.modifierFlags.contains(.shift)
        if commandMode, !cleanupConfigured {
            commandMode = false
            overlay.showError("Command Mode needs AI. Set it up in Settings › AI Cleanup.")
            stateMachine.reset()
            return
        }
        coolDownTask?.cancel()
        do {
            // Cue waits for real audio: a cold Bluetooth link gives 550 ms+ of silence, and beeping
            // through it trains people to talk into a dead mic.
            overlay.showArming(style: commandMode ? .command : .dictation)
            try recorder.start()
            let streamer = DictationStreamer(engine: transcriber, detector: dictationDetector) { [recorder] in
                recorder.liveAudio(from: $0)
            }
            self.streamer = streamer
            Task { await streamer.start() }
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
        overlay.showRecording(style: commandMode ? .command : .dictation)
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
        let streamer = self.streamer
        self.streamer = nil
        do {
            let raw = try recorder.stop()
            // After stop(): coolDown() refuses to cut a live dictation.
            scheduleMicCoolDown()
            // Held-key duration, not clip duration: pre-roll seeds every warm capture with up to 0.5 s.
            let held = Date().timeIntervalSince(keyPressedAt)
            guard held >= DictationProcessingPolicy.minimumClipDuration else {
                Task { await streamer?.cancel() }
                resetAfterNonResult()
                return
            }
            sounds.play(.release)
            recorder.mutePreRoll(for: sounds.beginCaptureDelay)
            // Shift can join at any point during the hold.
            let command = commandMode || (commandModeAvailable && cleanupConfigured && NSEvent.modifierFlags.contains(.shift))
            if command { overlay.showRecording(style: .command) }
            overlay.showProcessing()
            let captured = target ?? accessibility.capture(vocabulary: settings.vocabularyTerms)
            let target = accessibility.refreshInsertionTarget(captured)
            let engine = sessionEngine ?? transcriber
            sessionEngine = nil
            processingTask = Task { [weak self] in
                guard let self else { return }
                if command {
                    var selection = target.selectedText
                    if selection == nil, !AppStyle.copiesLineWithoutSelection(target.bundleID) {
                        selection = await accessibility.copySelection(from: target)
                    }
                    if selection?.isEmpty == true { selection = nil }
                    await process(raw, target: target, engine: engine, streamer: streamer, command: .some(selection))
                } else {
                    await process(raw, target: target, engine: engine, streamer: streamer)
                }
            }
        } catch PressayError.recordingTooShort {
            Task { await streamer?.cancel() }
            resetAfterNonResult()
        } catch {
            Task { await streamer?.cancel() }
            fail(error)
        }
    }

    func holdKeyCancelled(_ monitor: HotkeyMonitor) {
        guard monitor === activeMonitor else { return }
        guard stateMachine.phase == .recording || stateMachine.phase == .arming else { return }
        sessionEngine = nil
        armingTimeoutTask?.cancel()
        armingTimeoutTask = nil
        recorder.cancel()
        let streamer = self.streamer
        self.streamer = nil
        Task { await streamer?.cancel() }
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

    /// The mic the recorder will open: the chosen one while it is connected, else the system default.
    private var inputIsBluetooth: Bool {
        if let uid = settings.inputDeviceUID, let device = AudioDeviceMonitor.device(forUID: uid) {
            return device.isBluetooth
        }
        return AudioDeviceMonitor.defaultInputIsBluetooth
    }

    private func warmConditions(at now: Date) -> MicWarmPolicy.Conditions {
        MicWarmPolicy.Conditions(
            enabled: settings.keepMicWarm,
            isBluetooth: inputIsBluetooth,
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

    /// `command` is set in Command Mode, holding the selected text if there is any.
    private func process(
        _ raw: AudioRecorder.RawCapture,
        target: CapturedTarget,
        engine: any SpeechTranscriber,
        streamer: DictationStreamer? = nil,
        command: String?? = nil
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
                // Long dictations were mostly transcribed while the key was held.
                if let streamed = await streamer?.finish(raw) { return streamed }
                return try await engine.transcribe(clip)
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
            let style = settings.matchAppStyle ? AppStyle.detect(bundleID: target.bundleID, windowTitle: target.windowTitle) : nil
            let snippet = SnippetExpander.exactMatch(deterministic, snippets: settings.snippets)
            if case .some(let selection) = command {
                guard cleanupConfigured else {
                    overlay.showError("Command Mode needs AI. Set it up in Settings › AI Cleanup.")
                    resetAfterNonResult()
                    return
                }
                overlay.showPolishing()
                do {
                    finalText = try await runCommand(deterministic, selection: selection, target: target, style: style)
                    usedLanguageModel = true
                } catch {
                    logger.error("Command failed: \(error.localizedDescription, privacy: .public)")
                    fail(error, message: "The command didn’t work. Try again.")
                    return
                }
            } else if let snippet {
                finalText = snippet.text
            } else if cleanupActive,
               ClaudeCleanupPolicy.shouldClean(transcript.text, isTerminal: isTerminal) {
                // Raw transcript: the rules' phonetic rewrites would only hand Claude errors to undo.
                let raw = transcript.text
                let vocabulary = settings.vocabularyEntries
                let timeout = ClaudeCleanupPolicy.timeout(for: raw)
                overlay.showPolishing()
                do {
                    finalText = try await Timeout.run(for: .seconds(timeout)) { [self] in
                        try await runCleanup(raw, targetBundleID: target.bundleID, style: style, vocabulary: vocabulary, timeout: timeout)
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
            if !usedLanguageModel, snippet == nil, settings.structuredDictation, !isTerminal {
                finalText = TranscriptStructurer.structure(deterministic)
            }
            if command == nil, snippet == nil {
                finalText = SnippetExpander.expand(finalText, snippets: settings.snippets)
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
            if settings.learnFromEdits, command == nil, !isTerminal, insertion != .copied {
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

    // MARK: - Notetaker

    var notesModel: NotesModel? {
        NotesModel.resolve(
            stored: settings.notesModel, preferChatGPT: settings.cleanupProvider == .chatgpt,
            claude: claudeAPIKey != nil, chatGPT: chatGPT.isSignedIn
        )
    }

    var notesModelOptions: [NotesModel] {
        NotesModel.options(claude: claudeAPIKey != nil, chatGPT: chatGPT.isSignedIn)
    }

    private func applyCallDetection(_ detect: Bool) {
        if detect {
            callDetector.start()
        } else {
            callDetector.stop()
            callPrompt.dismiss()
        }
    }

    private func handleCall(_ event: CallDetectionState.Event) {
        switch event {
        case .started(let app):
            guard settings.detectCalls, liveSession == nil else { return }
            callPrompt.show(app: app) { [weak self] in
                self?.startMeeting()
            }
        case .ended:
            callPrompt.dismiss()
            if settings.stopWhenCallEnds, let session = liveSession, session.fromCall {
                stopRecording(automatic: true)
            }
        }
    }

    func startMeeting() {
        guard !meetingStarting, liveSession == nil, finishTask == nil else { return }
        guard permissions.microphoneGranted, stateMachine.phase == .idle, !modelPreparing else {
            recordingError = !permissions.microphoneGranted
                ? "Allow microphone access in System Settings to start the Notetaker."
                : "Finish dictating or preparing the model, then start the Notetaker."
            showNotes()
            return
        }
        meetingStarting = true
        recorder.forceClose()
        installEngine(settings.meetingASRModel)
        showNotes()
        meetingStartTask = Task { [weak self] in
            guard let self else { return }
            await prepareModel(force: true)
            guard !Task.isCancelled, meetingStarting else { return }
            meetingStarting = false
            meetingStartTask = nil
            if modelReady {
                beginMeetingCapture()
            } else {
                recordingError = lastError ?? "Could not prepare the meeting model. Try again or choose another model."
                applyASRModel()
            }
        }
    }

    func cancelMeetingStart() {
        meetingStartTask?.cancel()
        meetingStartTask = nil
        meetingStarting = false
        applyASRModel()
    }

    private func beginMeetingCapture() {
        guard liveSession == nil, finishTask == nil else { return }
        guard permissions.microphoneGranted else {
            recordingError = "Pressay needs microphone access to record. Allow it in System Settings › Privacy & Security › Microphone."
            showNotes()
            return
        }
        guard modelReady else {
            recordingError = "Wait for the local model to finish preparing."
            showNotes()
            return
        }
        guard stateMachine.phase == .idle else {
            recordingError = "Finish dictating, then start the Notetaker."
            showNotes()
            return
        }
        callPrompt.dismiss()

        let noteID = UUID()
        coolDownTask?.cancel()
        coolDownTask = nil
        recorder.forceClose()
        do {
            let session = try LiveSession(
                noteID: noteID,
                kind: .meeting,
                offset: 0,
                transcriber: transcriber,
                vocabulary: settings.vocabularyEntries,
                inputUID: settings.inputDeviceUID,
                captureSystemAudio: settings.meetingSystemAudio,
                separateVoices: settings.separateVoices
            )
            session.onLine = { [weak self] line in
                self?.notes.modify(noteID) { $0.lines.append(line) }
            }
            session.createdNote = true
            // Also covers clicking Start during a call that was already detected.
            session.fromCall = callDetector.inCall
            notes.add(Note(id: noteID, kind: .meeting, title: "Meeting", body: "", transcripts: [], duration: 0))
            liveSession = session
            sounds.play(.begin)
            // From the window, the notepad appears once the user switches away.
            if settingsWindow.isKey || !settings.openNotepad {
                showNotes()
            } else {
                notepad.show(session: session)
            }
            scheduleLengthLimit(for: session)
            logger.info("Notetaker started\(session.fromCall ? " during a call" : "", privacy: .public)")
        } catch {
            logger.error("Recording failed to start: \(error.localizedDescription, privacy: .public)")
            recordingError = "Couldn’t start the Notetaker: \(error.localizedDescription)"
            showNotes()
            applyMicWarmth()
            applyASRModel()
        }
    }

    private func scheduleLengthLimit(for session: LiveSession) {
        let limit = TimeInterval(max(1, settings.maxMeetingHours) * 3600)
        Task { [weak self, weak session] in
            try? await Task.sleep(for: .seconds(max(0, limit - 120)))
            guard let self, let session, liveSession === session, session.phase == .recording else { return }
            let warning = "The Notetaker stops in 2 minutes, at the \(settings.maxMeetingHours)-hour limit you set."
            session.notice = session.notice.map { "\($0)\n\(warning)" } ?? warning
            try? await Task.sleep(for: .seconds(120))
            guard liveSession === session, session.phase == .recording else { return }
            stopRecording(automatic: true)
        }
    }

    /// Saves the meeting before quitting; the write-up runs on next launch.
    func finishRecordingForQuit() async {
        if let finishTask {
            await finishTask.value
        } else if let session = liveSession, session.phase == .recording {
            let duration = session.elapsed
            let lines = await session.finish()
            liveSession = nil
            notepad.dismiss()
            if lines.contains(where: { !$0.text.isEmpty }) {
                notes.modify(session.noteID) { note in
                    note.duration += duration
                    note.lines = note.lines.filter { $0.start < session.offset } + lines
                    note.lines.sort { $0.start < $1.start }
                    note.title = Self.placeholderTitle(note)
                    note.needsWriteUp = settings.notesUseAI
                }
            } else if notes.note(session.noteID)?.myNotes.isEmpty == true {
                notes.delete(session.noteID)
            }
        }
        notes.flush()
    }

    /// `automatic` when the call ended or the length limit hit: no alerts, no window.
    func stopRecording(automatic: Bool = false) {
        guard let session = liveSession, session.phase == .recording, finishTask == nil else { return }
        sounds.play(.release)
        let duration = session.elapsed
        notepad.dismiss()
        finishTask = Task { [weak self] in
            let lines = await session.finish()
            guard let self else { return }
            liveSession = nil
            finishTask = nil
            applyASRModel()
            applyMicWarmth()
            finishNote(session.noteID, newLines: lines, from: session.offset, duration: duration, automatic: automatic)
        }
    }

    func showNotepadIfRecording() {
        guard let session = liveSession, session.phase == .recording, settings.openNotepad else { return }
        notepad.show(session: session)
    }

    private static func placeholderTitle(_ note: Note) -> String {
        note.title == "Meeting" ? "Meeting on \(note.createdAt.formatted(.dateTime.month(.wide).day()))" : note.title
    }

    func discardRecording() {
        guard let session = liveSession else { return }
        session.discard()
        liveSession = nil
        notepad.dismiss()
        sounds.play(.cancel)
        applyASRModel()
        if session.createdNote {
            notes.delete(session.noteID)
        } else {
            notes.modify(session.noteID) { $0.lines.removeAll { $0.start >= session.offset } }
        }
        applyMicWarmth()
    }

    /// `newLines` replace the ones streamed in live from `offset` on: they now say which voice spoke.
    private func finishNote(_ id: UUID, newLines: [TranscriptLine], from offset: TimeInterval, duration: TimeInterval, automatic: Bool) {
        guard let note = notes.note(id) else { return }
        guard newLines.contains(where: { !$0.text.isEmpty }) else {
            if note.myNotes.isEmpty {
                notes.delete(id)
            } else {
                notes.modify(id) { $0.title = Self.placeholderTitle($0) }
            }
            if !automatic {
                recordingError = "Nothing was heard. Check your microphone in Settings › General."
                showNotes()
            }
            return
        }
        notes.modify(id) { note in
            note.duration += duration
            note.lines = note.lines.filter { $0.start < offset } + newLines
            note.lines.sort { $0.start < $1.start }
            note.title = Self.placeholderTitle(note)
        }
        writeUpNote(id, review: true)
    }

    /// Hand-edited notes are rewritten only when `replacingEdits`, after the user confirms.
    /// `review` first names speakers and fixes misheard terms, once, right after a recording.
    func writeUpNote(_ id: UUID, replacingEdits: Bool = false, review: Bool = false) {
        guard settings.notesUseAI, notesModel != nil, let note = notes.note(id), !note.formatting,
              !note.edited || replacingEdits, note.kind == .meeting, !note.lines.isEmpty else { return }
        let hasNotes = !note.myNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let system = MeetingPrompt.system(vocabulary: settings.vocabularyEntries, hasUserNotes: hasNotes)
        // About a minute per hour of meeting on top of the base budget.
        let timeout = 90 + note.duration / 60
        notes.modify(id, persist: false) {
            $0.formatting = true
            $0.writeUpError = nil
        }
        Task { [weak self] in
            guard let self else { return }
            defer { notes.modify(id, persist: false) { $0.formatting = false } }
            if review { await reviewTranscript(id) }
            guard let note = notes.note(id) else { return }
            let user = MeetingPrompt.user(
                lines: note.lines, userNotes: note.myNotes, participants: note.participants, speakerNames: note.speakerNames
            )
            do {
                let reply = try await completeNote(system: system, user: user, timeout: timeout)
                guard let parsed = NotePrompt.parse(reply) else {
                    notes.modify(id, persist: false) { $0.writeUpError = "The AI’s reply couldn’t be read." }
                    return
                }
                // The user may have started editing while the AI was writing.
                guard replacingEdits || notes.note(id)?.edited == false else { return }
                notes.modify(id) {
                    $0.title = parsed.title
                    $0.body = ActionItem.carryingTicks(from: $0.body, into: parsed.body)
                    $0.edited = false
                    $0.needsWriteUp = false
                }
            } catch {
                logger.error("Note write-up failed: \(error.localizedDescription, privacy: .public)")
                notes.modify(id, persist: false) { $0.writeUpError = Self.describe(error) }
            }
        }
    }

    /// Names told-apart voices (never overwriting the user's names) and fixes misheard names and terms.
    private func reviewTranscript(_ id: UUID) async {
        guard let note = notes.note(id), !note.lines.isEmpty else { return }
        let review: TranscriptReview.Result
        do {
            let reply = try await completeNote(
                system: TranscriptReview.system(vocabulary: settings.vocabularyEntries),
                user: TranscriptReview.user(lines: note.lines, participants: note.participants),
                timeout: 60 + note.duration / 120
            )
            review = TranscriptReview.parse(reply, lines: note.lines, participants: note.participants)
        } catch {
            logger.notice("Transcript review skipped: \(error.localizedDescription, privacy: .public)")
            return
        }
        logger.info("Review named \(review.names.count, privacy: .public) of \(note.voices.count, privacy: .public) voices, \(review.fixes.count, privacy: .public) fixes")
        guard !review.names.isEmpty || !review.fixes.isEmpty else { return }
        notes.modify(id, keepOrder: true) { note in
            note.lines = TranscriptReview.apply(review.fixes, to: note.lines)
            note.speakerNames = Note.merging(review.names, into: note.speakerNames)
            for name in review.names.values.sorted() where !note.participants.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                note.participants.append(name)
            }
        }
    }

    /// Answers from one meeting, or from recent meetings when `noteID` is nil.
    func ask(_ question: String, about noteID: UUID?) async throws -> String {
        guard settings.notesUseAI else { throw NotesAIError.turnedOff }
        let source = noteID.flatMap(notes.note).map { [$0] } ?? Self.relevantMeetings(for: question, in: notes.notes)
        guard !source.isEmpty else { return "There are no meetings to search yet." }
        let meetings = source.map {
            MeetingAskPrompt.Meeting(title: $0.title, date: $0.createdAt, notes: $0.body, myNotes: $0.myNotes, transcript: $0.transcriptText)
        }
        return try await completeNote(
            system: MeetingAskPrompt.system,
            user: MeetingAskPrompt.user(question: question, meetings: meetings),
            timeout: 90
        )
    }

    private func completeNote(system: String, user: String, timeout: TimeInterval) async throws -> String {
        switch notesModel {
        case .claude(let model)?:
            guard let apiKey = claudeAPIKey else { throw NotesAIError.notConfigured }
            return try await cleaner.complete(system: system, user: user, model: model, apiKey: apiKey, timeout: timeout)
        case .chatgpt(let slug)?:
            let token = try await chatGPT.accessToken()
            return try await chatGPTCleaner.complete(
                instructions: system, user: user, model: slug,
                effort: ChatGPTCleanupModel.effort, accessToken: token, timeout: timeout
            )
        case nil:
            throw NotesAIError.notConfigured
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? NotesAIError { return error.localizedDescription }
        if (error as? URLError)?.code == .timedOut { return "The AI took too long to reply." }
        return "The AI couldn’t write this note: \(error.localizedDescription)"
    }

    /// Meetings that mention the question's words first, then the newest.
    private static func relevantMeetings(for question: String, in notes: [Note], limit: Int = 30) -> [Note] {
        let words = question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 3 }
        func hits(_ note: Note) -> Int {
            let text = (note.title + " " + note.body + " " + note.myNotes).lowercased()
            return words.filter { text.contains($0) }.count
        }
        let meetings: [Note] = notes.filter { $0.kind == .meeting && $0.hasTranscript }
        let scored: [(note: Note, hits: Int)] = meetings.map { ($0, hits($0)) }
        let ranked = scored.sorted { a, b in
            a.hits != b.hits ? a.hits > b.hits : a.note.createdAt > b.note.createdAt
        }
        let picked: [Note] = ranked.prefix(limit).map { $0.note }
        return picked.sorted { $0.createdAt > $1.createdAt }
    }

    /// Ticking a box is not an edit, so a later write-up can still replace the notes.
    @Published private(set) var sendingToReminders: Set<UUID> = []

    /// Adds the open items not already sent; false if Reminders refused.
    @discardableResult
    func addToReminders(_ items: [ActionItem], noteID: UUID) async -> Bool {
        guard let note = notes.note(noteID), !sendingToReminders.contains(noteID) else { return false }
        let fresh = items.filter { !$0.done && !$0.wasSent(note.sentToReminders) }
        guard !fresh.isEmpty else { return true }
        sendingToReminders.insert(noteID)
        defer { sendingToReminders.remove(noteID) }
        do {
            try await RemindersExporter.add(fresh, from: note)
            notes.modify(noteID, keepOrder: true) { $0.sentToReminders.append(contentsOf: fresh.map(\.text)) }
            return true
        } catch {
            recordingError = error.localizedDescription
            return false
        }
    }

    func toggleActionItem(_ noteID: UUID, item: ActionItem) {
        guard let body = notes.note(noteID)?.body, let toggled = ActionItem.toggling(item, in: body) else { return }
        notes.modify(noteID, persist: true, keepOrder: true) { $0.body = toggled }
    }

    func openNotetakerSettings() {
        showNotes()
        notetakerSettingsShown = true
    }

    func canWriteUp(_ note: Note) -> Bool {
        note.kind == .meeting && note.hasTranscript && !note.formatting && settings.notesUseAI
            && notesModel != nil && liveSession?.noteID != note.id
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
