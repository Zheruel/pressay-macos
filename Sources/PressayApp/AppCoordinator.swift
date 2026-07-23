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
        transcriber = Self.makeTranscriber(for: settings.asrModel, language: settings.language)
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
        do {
            try await preparing.prepare()
            guard generation == prepareGeneration else { return }
            modelReady = true
            modelStatus = "\(name) ready · local"
            logger.info("Local transcription model is ready")
        } catch {
            guard generation == prepareGeneration else { return }
            modelStatus = "Model unavailable"
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
        permissions.refresh()
        guard permissions.microphoneGranted, permissions.accessibilityGranted else {
            overlay.showError("Finish setup in Pressay")
            return
        }
        guard modelReady else {
            overlay.showError("Wait for the local model to finish preparing")
            return
        }
        guard stateMachine.begin() else {
            if stateMachine.phase == .processing {
                overlay.showError("Still processing the previous dictation")
            }
            return
        }
        activeMonitor = monitor
        sessionEngine = transcriber
        do {
            // Keep the start earcon out of the microphone input. Its short,
            // prewarmed duration still finishes before a normal speech reaction.
            sounds.play(.begin)
            Thread.sleep(forTimeInterval: sounds.beginCaptureDelay)
            try recorder.start()
            target = accessibility.capture(vocabulary: settings.vocabularyTerms)
            overlay.showRecording(style: .dictation)
            settings.hasUsedDictation = true
        } catch {
            stateMachine.fail(error.localizedDescription)
            overlay.showError(error.localizedDescription)
            stateMachine.reset()
        }
    }

    func holdKeyReleased(_ monitor: HotkeyMonitor) {
        guard monitor === activeMonitor else { return }
        guard stateMachine.stop() else { return }
        do {
            let raw = try recorder.stop()
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
        guard stateMachine.phase == .recording else { return }
        recorder.cancel()
        processingTask?.cancel()
        stateMachine.cancel()
        target = nil
        overlay.hide()
        sounds.play(.cancel)
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
                return AudioClip(samples: try AudioTrimmer.trim(converted))
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
