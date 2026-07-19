import Foundation

public struct RetentionPolicy: Sendable {
    public let textDays: Int
    public let audioDays: Int

    public init(textDays: Int = 30, audioDays: Int = 7) {
        self.textDays = textDays
        self.audioDays = audioDays
    }

    public func shouldDeleteText(createdAt: Date, isPinned: Bool, now: Date = .now) -> Bool {
        !isPinned && createdAt < Calendar.current.date(byAdding: .day, value: -textDays, to: now)!
    }

    public func shouldDeleteAudio(createdAt: Date, isPinned: Bool, now: Date = .now) -> Bool {
        !isPinned && createdAt < Calendar.current.date(byAdding: .day, value: -audioDays, to: now)!
    }
}
