import AppKit
import Foundation
import LocalFlowCore
import LocalFlowPostProcessing
import LocalFlowTranscription
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

    private let recorder = AudioRecorder()
    private let hotkey = HotkeyMonitor()
    private let accessibility = AccessibilityBridge()
    private let overlay = OverlayPanelController()
    private let sounds = DictationSoundPlayer()
    private let transcriber = WhisperTranscriber()
    private let polisher = ApplePromptPolisher()
    private let validator = ProtectedTokenValidator()
    private let logger = Logger(subsystem: "dev.localflow.app", category: "pipeline")
    private var stateMachine = DictationStateMachine()
    private var target: CapturedTarget?
    private var processingTask: Task<Void, Never>?
    private lazy var onboardingWindow = OnboardingWindowController(coordinator: self)
    private lazy var settingsWindow = SettingsWindowController(coordinator: self)

    private init() {
        do {
            history = try HistoryStore()
        } catch {
            history = try! HistoryStore(inMemory: true)
            lastError = "History will not persist: \(error.localizedDescription)"
        }
        hotkey.delegate = self
        recorder.onLevel = { [weak self] frame in
            Task { @MainActor in self?.overlay.state.levels = frame.bars }
        }
        permissions.onStatusChange = { [weak self] in
            guard let self else { return }
            if permissions.inputMonitoringGranted {
                restartHotkey()
            } else {
                hotkey.stop()
            }
        }
    }

    func start() {
        permissions.startMonitoring()
        settings.refreshLaunchAtLogin()
        try? history.applyRetention()
        // Model preparation is independent of TCC onboarding. Starting it here
        // removes the manual Download / prepare step and makes every later launch
        // warm as soon as possible.
        Task { await prepareModel() }
        if !settings.onboardingComplete {
            showOnboarding()
        }
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

    func prepareModel() async {
        guard !modelReady, !modelPreparing else { return }
        modelPreparing = true
        modelReady = false
        modelStatus = "Preparing \(WhisperTranscriber.modelName)…"
        defer { modelPreparing = false }
        do {
            try await transcriber.prepare()
            modelReady = true
            modelStatus = "\(WhisperTranscriber.modelName) ready · local"
            logger.info("Local transcription model is ready")
        } catch {
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

    func holdKeyPressed() {
        permissions.refresh()
        guard permissions.microphoneGranted, permissions.accessibilityGranted else {
            overlay.showError("Finish setup in Pressay")
            return
        }
        guard modelReady else {
            overlay.showError("Wait for the local model to finish preparing")
            return
        }
        guard stateMachine.begin() else { return }
        do {
            // Keep the start earcon out of the microphone input. Its short,
            // prewarmed duration still finishes before a normal speech reaction.
            sounds.play(.begin)
            Thread.sleep(forTimeInterval: sounds.beginCaptureDelay)
            try recorder.start()
            target = accessibility.capture(vocabulary: settings.vocabularyTerms)
            overlay.showRecording()
            settings.hasUsedDictation = true
            Task { await polisher.prewarm() }
        } catch {
            stateMachine.fail(error.localizedDescription)
            overlay.showError(error.localizedDescription)
            stateMachine.reset()
        }
    }

    func holdKeyReleased() {
        guard stateMachine.stop() else { return }
        do {
            let clip = try recorder.stop()
            sounds.play(.release)
            overlay.showProcessing()
            let captured = target ?? accessibility.capture(vocabulary: settings.vocabularyTerms)
            let target = accessibility.refreshInsertionTarget(captured)
            processingTask = Task { [weak self] in await self?.process(clip, target: target) }
        } catch LocalFlowError.recordingTooShort {
            resetAfterNonResult()
        } catch LocalFlowError.silence {
            resetAfterNonResult()
        } catch {
            fail(error)
        }
    }

    func holdKeyCancelled() {
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

    private func process(_ clip: AudioClip, target: CapturedTarget) async {
        let releasedAt = Date()
        let recordID = UUID()
        // Save before inference so timeouts and empty short transcripts remain
        // available for local diagnosis. Unreferenced files expire after seven days.
        let audioURL = try? AudioFileStore.save(clip, id: recordID)
        do {
            let asrTimeout = DictationProcessingPolicy.asrTimeout(duration: clip.duration)
            logger.info("Transcribing \(clip.duration, privacy: .public)s clip with \(asrTimeout, privacy: .public)s budget")
            let transcript = try await Timeout.run(for: .seconds(asrTimeout)) { [transcriber] in
                try await transcriber.transcribe(clip)
            }
            guard !Task.isCancelled else { return }

            let deterministic = DeterministicPromptCleaner.clean(
                transcript.text,
                vocabulary: settings.vocabularyEntries
            )
            var polish = PolishResult(
                text: deterministic,
                usedLanguageModel: false,
                processingTime: 0
            )

            let timeAfterASR = Date().timeIntervalSince(releasedAt)
            let isLongForm = DictationProcessingPolicy.isLongForm(
                duration: clip.duration,
                characterCount: transcript.text.count
            )
            let languageModelWouldHelp = isLongForm
                || PromptPolishGate.shouldUseLanguageModel(for: transcript.text)
            let polishTimeout = DictationProcessingPolicy.polishTimeout(
                duration: clip.duration,
                characterCount: transcript.text.count,
                elapsed: timeAfterASR
            )
            if languageModelWouldHelp, let polishTimeout, polishTimeout > 0 {
                let polishStarted = Date()
                do {
                    let candidate = try await Timeout.run(for: .seconds(polishTimeout)) { [polisher] in
                        try await polisher.polish(deterministic, context: target.context)
                    }
                    let validation = validator.validate(
                        source: deterministic,
                        candidate: candidate,
                        vocabulary: settings.vocabularyTerms
                    )
                    if validation.isValid {
                        polish = PolishResult(
                            text: candidate,
                            usedLanguageModel: true,
                            processingTime: Date().timeIntervalSince(polishStarted)
                        )
                    } else {
                        logger.info("Prompt polish rejected: \(validation.reason ?? "validation failed", privacy: .public)")
                        polish = PolishResult(
                            text: deterministic,
                            usedLanguageModel: false,
                            processingTime: Date().timeIntervalSince(polishStarted)
                        )
                    }
                } catch {
                    logger.info("Prompt polish fell back: \(error.localizedDescription, privacy: .public)")
                    polish = PolishResult(
                        text: deterministic,
                        usedLanguageModel: false,
                        processingTime: Date().timeIntervalSince(polishStarted)
                    )
                }
            } else if languageModelWouldHelp {
                logger.info("Skipping prompt polish because ASR consumed the latency budget")
            }

            guard !Task.isCancelled else { return }
            let insertion = await accessibility.insert(polish.text, into: target)
            let insertionLatency = Date().timeIntervalSince(releasedAt)
            let record = DictationRecord(
                id: recordID,
                duration: clip.duration,
                targetBundleID: target.bundleID,
                rawTranscript: transcript.text,
                polishedText: polish.text,
                asrLatency: transcript.processingTime,
                polishLatency: polish.processingTime,
                totalLatency: insertionLatency,
                audioPath: audioURL?.path,
                usedLanguageModel: polish.usedLanguageModel
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
        } catch {
            if let audioURL {
                logger.error("Failed dictation audio retained locally at \(audioURL.lastPathComponent, privacy: .public)")
            }
            fail(error)
        }
    }

    private func resetAfterNonResult() {
        stateMachine.reset()
        target = nil
        overlay.hide()
    }

    private func fail(_ error: Error) {
        lastError = error.localizedDescription
        logger.error("Dictation failed: \(error.localizedDescription, privacy: .public)")
        stateMachine.fail(error.localizedDescription)
        overlay.showError(error.localizedDescription)
        sounds.play(.error)
        target = nil
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.stateMachine.reset()
        }
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
