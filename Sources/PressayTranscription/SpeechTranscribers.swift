import Foundation
import PressayCore

public enum SpeechTranscribers {
    /// The app shares one worker. CLI replay may pass a built app bundle so
    /// it exercises the same signed runtime instead of a research environment.
    public static func make(model: ASRModel, language: String = "auto", bundleURL: URL? = nil) -> any SpeechTranscriber {
        if model.usesWorker { return WorkerTranscriber(model: model, bundleURL: bundleURL) }
        return GGMLTranscriber(model: model, language: language)
    }
}
