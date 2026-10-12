import EventKit
import Foundation
import PressayCore

/// Adds meeting action items to the user's default Reminders list.
@MainActor
enum RemindersExporter {
    enum ExportError: LocalizedError {
        case denied
        case noList

        var errorDescription: String? {
            switch self {
            case .denied: "Pressay can’t add reminders. Allow it in System Settings › Privacy & Security › Reminders."
            case .noList: "There’s no default Reminders list. Open Reminders and create one."
            }
        }
    }

    private static let store = EKEventStore()

    static func add(_ items: [ActionItem], from note: Note) async throws {
        guard try await store.requestFullAccessToReminders() else { throw ExportError.denied }
        guard let list = store.defaultCalendarForNewReminders() else { throw ExportError.noList }
        let source = "From “\(note.title)”, \(note.createdAt.formatted(date: .abbreviated, time: .shortened))"
        for item in items {
            let reminder = EKReminder(eventStore: store)
            reminder.title = item.text
            reminder.notes = source
            reminder.calendar = list
            try store.save(reminder, commit: false)
        }
        try store.commit()
    }
}
