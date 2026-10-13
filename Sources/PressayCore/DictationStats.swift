import Foundation

/// The Home page's numbers, from the dictations kept in History.
public struct DictationStats: Equatable, Sendable {
    public struct Entry: Sendable {
        public let date: Date
        public let words: Int
        public let duration: TimeInterval

        public init(date: Date, words: Int, duration: TimeInterval) {
            self.date = date
            self.words = words
            self.duration = duration
        }
    }

    /// An average typist; speaking is roughly three times faster.
    public static let typingWordsPerMinute = 40.0

    public let wordsThisWeek: Int
    public let dictationsThisWeek: Int
    /// Typing time the week's words would have taken, minus the time spent speaking them.
    public let minutesSavedThisWeek: Int
    /// Speaking pace across the week; nil before there's enough to measure.
    public let wordsPerMinute: Int?
    /// Days in a row with a dictation, counting today, or up to yesterday if none yet today.
    public let streakDays: Int

    public init(entries: [Entry], now: Date = .now, calendar: Calendar = .current) {
        let weekStart = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        let week = entries.filter { $0.date >= weekStart && $0.date <= now }
        wordsThisWeek = week.reduce(0) { $0 + $1.words }
        dictationsThisWeek = week.count
        let typing = Double(wordsThisWeek) / Self.typingWordsPerMinute
        let speaking = week.reduce(0) { $0 + $1.duration } / 60
        minutesSavedThisWeek = max(0, Int((typing - speaking).rounded()))
        wordsPerMinute = speaking >= 0.5 ? Int((Double(wordsThisWeek) / speaking).rounded()) : nil

        let days = Set(entries.map { calendar.startOfDay(for: $0.date) })
        var day = calendar.startOfDay(for: now)
        if !days.contains(day) { day = calendar.date(byAdding: .day, value: -1, to: day) ?? day }
        var streak = 0
        while days.contains(day) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        streakDays = streak
    }

    public static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}
