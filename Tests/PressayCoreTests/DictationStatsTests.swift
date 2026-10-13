import Foundation
import Testing
@testable import PressayCore

struct DictationStatsTests {
    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func daysAgo(_ days: Int, words: Int = 40, duration: TimeInterval = 20) -> DictationStats.Entry {
        DictationStats.Entry(date: now.addingTimeInterval(-Double(days) * 86_400), words: words, duration: duration)
    }

    @Test func countsOnlyTheLastSevenDays() {
        let stats = DictationStats(entries: [daysAgo(0), daysAgo(6), daysAgo(8)], now: now, calendar: calendar)
        #expect(stats.wordsThisWeek == 80)
        #expect(stats.dictationsThisWeek == 2)
    }

    @Test func timeSavedIsTypingMinusSpeaking() {
        // 400 words take 10 min to type; spoken in 3 min.
        let stats = DictationStats(entries: [daysAgo(0, words: 400, duration: 180)], now: now, calendar: calendar)
        #expect(stats.minutesSavedThisWeek == 7)
        #expect(stats.wordsPerMinute == 133)
    }

    @Test func streakSurvivesUntilToday() {
        let stats = DictationStats(entries: [daysAgo(1), daysAgo(2), daysAgo(4)], now: now, calendar: calendar)
        #expect(stats.streakDays == 2)
    }

    @Test func noRecentDictationsMeansNoStreak() {
        #expect(DictationStats(entries: [daysAgo(3)], now: now, calendar: calendar).streakDays == 0)
    }
}
