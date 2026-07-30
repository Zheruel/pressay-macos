import AppKit
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
    /// Fractional progress (0…1) while the selected model downloads, or `nil`
    /// when idle or the size is unknown. Drives the Settings/onboarding bar.
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
    /// The monitor that started the active session — only its release/cancel
    /// may end the session.
    private var activeMonitor: HotkeyMonitor?
    /// Engine captured at key press so a model swap mid-session cannot hand
    /// the clip to a new, unprepared engine.
    private var sessionEngine: (any SpeechTranscriber)?
    /// Invalidates stale prepare completions after a model swap.
    private var prepareGeneration = 0
    /// Closes the warm mic once the window lapses; re-armed after each dictation.
    private var coolDownTask: Task<Void, Never>?
    /// Backstop for the readiness cue when a device never reports live audio.
    private var armingTimeoutTask: Task<Void, Never>?
    private var lastDictationEnded: Date?
    private var outputActivity: OutputActivityObserver?
    /// Parks warming after a failed open so a broken device can't spin.
    private var warmUpFailed = false
    private lazy var onboardingWindow = OnboardingWindowController(coordinator: self)
    private lazy var settingsWindow = SettingsWindowController(coordinator: self)

    private init() {
        // Before the history store opens: its retention pass must see the
        // audio files at their final location.
        Self.migrateApplicationSupportDirectory()
        do {
            history = try HistoryStore()
        } catch {
            history = try! HistoryStore(inMemory: true)
            lastError = "History will not persist: \(error.localizedDescription)"
        }
        transcriber = Self.makeTranscriber(for: settings.asrModel, language: settings.language)
        hotkey.delegate = self
        tunerRunner.onLearned = { [weak self] rules in
            self?.celebrateLearnedRules(rules)
        }
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
            // Always a fresh run-loop turn: holdKeyPressed refreshes permissions
            // synchronously, and restarting a monitor re-entrantly from inside
            // its own press callback resets isPressed mid-press — the release
            // would never be delivered and the recording would never stop.
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
        try? history.rewriteAudioPaths(from: "/LocalFlow/", to: "/Pressay/")
        permissions.startMonitoring()
        settings.refreshLaunchAtLogin()
        applyTranscriptionLanguage()
        // Applies the input-device preference. The mic stays closed until a
        // first dictation gives us reason to keep it warm.
        applyMicWarmth()
        // Pausing a video, dictating, then resuming is a common pattern, and it
        // drops playback right inside the warm window. React to playback
        // starting rather than only sampling when the dictation ended.
        let observer = OutputActivityObserver { [weak self] _ in
            self?.applyMicWarmth()
        }
        observer.start()
        outputActivity = observer
        try? history.applyRetention()
        // Model preparation is independent of TCC onboarding. Starting it here
        // removes the manual Download / prepare step and makes every later launch
        // warm as soon as possible.
        Task { await prepareModel() }
        Task { @MainActor in tunerRunner.scheduleIfNeeded(history: history, settings: settings) }
        if !settings.onboardingComplete {
            showOnboarding()
        }
    }

    /// Moves ~/Library/Application Support/LocalFlow → Pressay once, so the
    /// downloaded models and history audio survive the code rename. Stored
    /// audio paths are rewritten separately in start().
    private static func migrateApplicationSupportDirectory() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appending(path: "LocalFlow", directoryHint: .isDirectory)
        let new = base.appending(path: "Pressay", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: old.path),
              !FileManager.default.fileExists(atPath: new.path) else { return }
        try? FileManager.default.moveItem(at: old, to: new)
    }

    /// Suspends the hold-key monitor while a KeyCaptureButton is recording a
    /// new binding; restartHotkey() resumes it.
    func suspendHotkeys() {
        hotkey.stop()
    }

    /// Single wiring point for KeyCaptureButton so every capture site gets the
    /// suspend-while-capturing behavior; forgetting it at one site would let
    /// rebinding the current hold key start a dictation mid-capture.
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

    /// Swap the local speech model. A dictation already in flight keeps the
    /// engine captured at its key press; new sessions use the new engine.
    func applyASRModel() {
        // Snap the language to something this engine can actually decode
        // before building it, so the new transcriber never starts on a hint
        // the model will reject.
        let model = settings.asrModel
        if !model.supportedLanguages.contains(settings.language) {
            settings.language = model.defaultLanguage
        }
        transcriber = Self.makeTranscriber(for: model, language: settings.language)
        modelReady = false
        // A prepare may still be running for the previous engine; bump the
        // generation so its completion cannot mark the new engine ready, and
        // force a fresh prepare for the swapped-in engine.
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

    func completeOnboarding() {
        permissions.refresh()
        guard permissions.allGranted, modelReady else { return }
        settings.onboardingComplete = true
        restartHotkey()
        onboardingWindow.dismiss()
    }

    func holdKeyPressed(_ monitor: HotkeyMonitor) {
        // No synchronous TCC refresh here: this runs inside the CGEventTap
        // callback, and startMonitoring() already keeps these current. A revoked
        // permission still surfaces as microphoneUnavailable from the recorder.
        guard permissions.microphoneGranted, permissions.accessibilityGranted else {
            overlay.showError("Finish setup in Pressay")
            return
        }
        guard modelReady else {
            overlay.showError("Wait for the local model to finish preparing")
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
        coolDownTask?.cancel()
        do {
            // The mic opens first and the cue waits for real audio. A cold
            // Bluetooth link hands out digital silence for 550 ms+, and beeping
            // through that is what trains people to talk into a dead mic.
            overlay.showArming()
            try recorder.start()
            target = accessibility.capture(vocabulary: settings.vocabularyTerms)
            settings.hasUsedDictation = true
            startArmingTimeout()
        } catch {
            stateMachine.fail(error.localizedDescription)
            overlay.showError(error.localizedDescription)
            stateMachine.reset()
        }
    }

    /// The mic is genuinely delivering samples. Warm starts reach this within a
    /// frame, so the burst case still feels instant.
    private func captureBecameLive() {
        guard stateMachine.phase == .arming else { return }
        armingTimeoutTask?.cancel()
        armingTimeoutTask = nil
        stateMachine.begin()
        sounds.play(.begin)
        recorder.markEarcon(duration: sounds.beginCaptureDelay)
        overlay.showRecording(style: .dictation)
    }

    /// If a device never reports live audio, cue anyway rather than leaving the
    /// user holding a key with no feedback.
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
            // Only once the recorder is idle: coolDown() refuses to cut a live
            // dictation, so warming decided any earlier would never take effect.
            scheduleMicCoolDown()
            // Cheap too-short check: accidental taps reset silently, without
            // the release earcon. Silence is detected later, during trim.
            guard raw.duration >= DictationProcessingPolicy.minimumClipDuration else {
                resetAfterNonResult()
                return
            }
            sounds.play(.release)
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
        scheduleMicCoolDown()
    }

    // MARK: - Warm microphone

    /// Marks the end of a dictation and closes the stream once the warm window
    /// lapses. Re-entrant: each dictation restarts the clock.
    private func scheduleMicCoolDown() {
        lastDictationEnded = Date()
        // A dictation just succeeded on this device, so an earlier warm-up
        // failure is stale.
        warmUpFailed = false
        coolDownTask?.cancel()
        guard warmConditions(at: Date()).enabled else {
            recorder.coolDown()
            return
        }
        coolDownTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(DictationProcessingPolicy.micWarmWindow))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.applyMicWarmth() }
        }
        applyMicWarmth()
    }

    /// Single place that reconciles the recorder's stream with the policy.
    /// Called after dictations, when the setting changes, and on the cool-down
    /// deadline.
    func applyMicWarmth() {
        guard stateMachine.phase != .recording, stateMachine.phase != .arming else { return }
        // A warm stream is bound to the device it opened with, so switching the
        // picker has to close it before the choice can take effect.
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
            recorder.coolDown()
            return
        }
        do {
            try recorder.warmUp()
        } catch {
            // Not worth surfacing: the next press opens the mic normally.
            warmUpFailed = true
            logger.info("could not keep the mic warm: \(error.localizedDescription, privacy: .public)")
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

    /// Sleep and screen lock must not leave a stream open: resuming into a
    /// half-torn-down Bluetooth link is how the input wedges into silence.
    func releaseMicForSystemEvent() {
        coolDownTask?.cancel()
        lastDictationEnded = nil
        recorder.coolDown()
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
            // Resample and trim off the main actor (~5 ms per second of audio).
            let clip = try await Task.detached(priority: .userInitiated) {
                let converted = try raw.segments.flatMap {
                    try AudioResampler.convert($0.samples, from: $0.sampleRate)
                }
                // Resampling preserves duration, so the cue's position on the
                // capture timeline maps straight onto the 16 kHz clip.
                let earconGuard = raw.earconWindow.map {
                    Int($0.lowerBound * 16_000)..<Int($0.upperBound * 16_000)
                }
                return AudioClip(
                    samples: try AudioTrimmer.trim(converted, earconGuard: earconGuard)
                )
            }.value
            // Save before inference so timeouts and empty short transcripts remain
            // available for local diagnosis. Unreferenced files expire after seven days.
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

            // Shell commands are case-sensitive; never auto-capitalize into a
            // terminal.
            let isTerminal = target.bundleID.map {
                DeterministicPromptCleaner.terminalBundleIDs.contains($0)
            } ?? false
            let deterministic = DeterministicPromptCleaner.clean(
                transcript.text,
                vocabulary: settings.vocabularyEntries,
                capitalizeFirstWord: !isTerminal
            )
            var finalText = deterministic
            var structureLatency: TimeInterval = 0
            if settings.structuredDictation, !isTerminal {
                let structureStarted = Date()
                finalText = TranscriptStructurer.structure(deterministic)
                structureLatency = Date().timeIntervalSince(structureStarted)
            }

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
                usedLanguageModel: false
            )
            do {
                try history.add(record)
            } catch {
                lastError = "Prompt inserted, but history could not be saved: \(error.localizedDescription)"
                logger.error("History save failed after insertion: \(error.localizedDescription, privacy: .public)")
            }
            stateMachine.succeed()
            showInsertionOutcome(insertion)
            try? await Task.sleep(for: .milliseconds(700))
            stateMachine.reset()
            self.target = nil
            celebrateLearnedRules(learnedRules)
            tunerRunner.scheduleIfNeeded(history: history, settings: settings)
            // runModal spins a nested run loop; hop to a plain run-loop callout
            // so it never sits on this async task's concurrency frames.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.maybeShowVocabularyExplainer() }
            }
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
        guard stateMachine.phase == .recording else { return }
        fail(PressayError.microphoneUnavailable, message: message)
    }

    private func resetAfterNonResult() {
        stateMachine.reset()
        target = nil
        overlay.hide()
    }

    /// A cancelled process() must not exit with the phase stuck in
    /// .processing and the spinner showing — nothing else ever resets those.
    private func cleanUpCancelledProcessing() {
        guard stateMachine.phase == .processing else { return }
        resetAfterNonResult()
    }

    private func maybeShowVocabularyExplainer() {
        let key = "vocabularyTuner.keyPromptShown"
        let snoozeKey = "vocabularyTuner.keyPromptSnoozeUntilRecords"
        guard history.records.count >= max(3, UserDefaults.standard.integer(forKey: snoozeKey)),
              !UserDefaults.standard.bool(forKey: key),
              KimiAPIKeyStore.read() == nil else { return }
        // A hold-key press during the modal would capture Pressay itself and
        // dictate into the secure field; keep the monitors down until it closes.
        suspendHotkeys()
        defer { restartHotkey() }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Make Pressay even sharper"
        alert.informativeText = "Pressay already fixes names it mishears, on-device. Add a Kimi API key and it can also ask Kimi to review new names in the background — everything works without one."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "sk-kimi-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save key")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Don't ask again")
        let response = alert.runModal()
        // "Later" snoozes until well after the next batch of dictations;
        // saving a key or declining permanently ends the prompt.
        guard response != .alertSecondButtonReturn else {
            UserDefaults.standard.set(history.records.count + 15, forKey: snoozeKey)
            return
        }
        UserDefaults.standard.set(true, forKey: key)
        guard response == .alertFirstButtonReturn else { return }
        let apiKey = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return }
        if !KimiAPIKeyStore.save(apiKey) {
            lastError = "The Kimi key could not be saved to the keychain."
        }
        showSettings()
    }

    private func fail(_ error: Error, message: String? = nil) {
        lastError = error.localizedDescription
        logger.error("Dictation failed: \(error.localizedDescription, privacy: .public)")
        stateMachine.fail(error.localizedDescription)
        overlay.showError(message ?? error.localizedDescription)
        sounds.play(.error)
        target = nil
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.stateMachine.reset()
        }
    }

    private func celebrateLearnedRules(_ rules: [LearnedRule], retrying: Bool = false) {
        guard !rules.isEmpty, stateMachine.phase == .idle else { return }
        guard overlay.state.phase == .idle else {
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
