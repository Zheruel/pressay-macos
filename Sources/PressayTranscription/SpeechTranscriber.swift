import Foundation
import PressayCore

/// A local speech-to-text engine the dictation pipeline can run on.
public protocol SpeechTranscriber: Sendable {
    /// Human-readable engine/model name, recorded per dictation.
    var engineName: String { get async }
    /// Downloads/loads whatever the engine needs; safe to call repeatedly.
    func prepare() async throws
    func transcribe(_ clip: AudioClip) async throws -> ASRTranscript
    /// Forced decoding language ("en", …) or "auto"; engines without a
    /// language hint ignore it.
    func setLanguage(_ language: String) async
    /// Progress line for the menu bar while prepare() downloads a model.
    func setStatusHandler(_ handler: @escaping @Sendable (String) -> Void) async
    /// Fractional download progress in 0...1 while prepare() fetches a model,
    /// or `nil` when the total size is unknown or no download is in flight.
    func setProgressHandler(_ handler: @escaping @Sendable (Double?) -> Void) async
}
