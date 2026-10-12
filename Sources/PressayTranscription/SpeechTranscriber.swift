import Foundation
import PressayCore

public protocol SpeechTranscriber: Sendable {
    var engineName: String { get async }
    /// Safe to call repeatedly.
    func prepare() async throws
    func transcribe(_ clip: AudioClip) async throws -> ASRTranscript
    /// "en", …, or "auto"; engines without a language hint ignore it.
    func setLanguage(_ language: String) async
    func setStatusHandler(_ handler: @escaping @Sendable (String) -> Void) async
    /// 0...1, or `nil` when total size is unknown or no download is in flight.
    func setProgressHandler(_ handler: @escaping @Sendable (Double?) -> Void) async
}
