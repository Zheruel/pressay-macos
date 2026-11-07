import AppKit
import Darwin
import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// A read-only bridge into the separate Rust preview database. Export does not construct
/// AppSettings, HistoryStore, or NotesStore: each can migrate or delete original data.
enum CoreMigrationExport {
    static let settingsDomain = "dev.localflow.app"
    static let settingKeys: Set<String> = [
        "holdKey", "holdKeyCode", "language", "asrModel", "meetingASRModel", "meetingLanguage",
        "vocabulary", "manualVocabularyOnly", "onboardingComplete", "hasUsedDictation", "inputDeviceUID",
        "claudeCleanup", "claudeConnection", "cleanupProvider", "openAIConnection", "chatGPTWelcomeShown",
        "notesModel", "detectCalls", "maxMeetingHours", "notesUseAI", "keepMicWarm",
        "learnFromEdits", "vocabularyTuner.rules", "vocabularyTuner.blocklist",
        "vocabularyTuner.lastDetRun", "vocabularyTuner.lastK3Run", "vocabularyTuner.seenCandidates",
        "vocabularyTuner.schemaVersion", "vocabularySuggestions.pending", "vocabularySuggestions.lastMined",
        "vocabularySuggestions.dismissed", "snippets", "structuredDictation", "showLiveTranscript",
        "stopWhenCallEnds", "meetingSystemAudio", "separateVoices", "noteStyle", "matchAppStyle"
    ]

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Pressay", directoryHint: .isDirectory)
    }

    /// A new source UUID distinguishes later exports; importing the same file remains idempotent.
    static func snapshot(directory: URL, preferences: [String: Any], source: String = UUID().uuidString) throws -> Data {
        let settings = try preferences.filter { settingKeys.contains($0.key) }.mapValues(jsonValue)
        let records = try dictations(at: directory.appending(path: "History.store"))
        let meetings = try notes(at: directory.appending(path: "Notes.json"))
        let result: [String: Any] = [
            "schema": 1, "source": "pressay-macos:\(source)", "settings": settings,
            "dictations": records, "notes": meetings
        ]
        return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    }

    static func export(to destination: URL) throws {
        let preferences = UserDefaults.standard.persistentDomain(forName: settingsDomain) ?? [:]
        let data = try snapshot(directory: directory, preferences: preferences)
        try write(data, to: destination, sourceDirectory: directory)
    }

    private static func dictations(at url: URL) throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let configuration = ModelConfiguration(url: url, allowsSave: false, cloudKitDatabase: .none)
        let container = try ModelContainer(for: DictationRecord.self, configurations: configuration)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        // Intentionally no fetchLimit: HistoryStore.records contains only the latest 500.
        let records = try context.fetch(FetchDescriptor<DictationRecord>(
            sortBy: [SortDescriptor(\DictationRecord.createdAt), SortDescriptor(\DictationRecord.id)]
        ))
        return records.map { record in
            let legacy: [String: Any] = [
                "id": record.id.uuidString, "createdAt": record.createdAt.timeIntervalSince1970,
                "duration": record.duration, "targetBundleID": record.targetBundleID as Any? ?? NSNull(),
                "targetAppName": record.targetAppName as Any? ?? NSNull(), "engineRawValue": record.engineRawValue,
                "rawTranscript": record.rawTranscript, "polishedText": record.polishedText,
                "correction": record.correction as Any? ?? NSNull(), "asrLatency": record.asrLatency,
                "polishLatency": record.polishLatency, "totalLatency": record.totalLatency,
                "audioPath": record.audioPath as Any? ?? NSNull(), "isPinned": record.isPinned,
                "usedLanguageModel": record.usedLanguageModel
            ]
            return [
                "id": record.id.uuidString, "created_at": record.createdAt.timeIntervalSince1970,
                "duration": record.duration, "model": record.engineRawValue, "raw": record.rawTranscript,
                "text": record.polishedText, "correction": record.correction as Any? ?? NSNull(),
                "pinned": record.isPinned, "target": record.targetBundleID as Any? ?? NSNull(),
                "latency": record.totalLatency, "legacy": legacy
            ]
        }
    }

    private static func notes(at url: URL) throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        // Decode JSON directly so a future/legacy field survives the export unchanged.
        guard let notes = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]] else {
            throw Failure("Notes.json is not a list of notes. The original file has not been changed.")
        }
        return try notes.map { original in
            guard let id = original["id"] as? String, !id.isEmpty else {
                throw Failure("A meeting has no identifier. The original file has not been changed.")
            }
            var note = original
            for (legacyKey, unixKey) in [("createdAt", "created_at"), ("updatedAt", "updated_at")] {
                if let value = original[legacyKey] {
                    note[unixKey] = try unixDate(value)
                }
            }
            return note
        }
    }

    private static func unixDate(_ value: Any) throws -> TimeInterval {
        if let value = value as? NSNumber, value.doubleValue.isFinite { return value.doubleValue }
        if let text = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date.timeIntervalSince1970 }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date.timeIntervalSince1970 }
        }
        throw Failure("A meeting has an unreadable date. The original file has not been changed.")
    }

    private static func jsonValue(_ value: Any) throws -> Any {
        switch value {
        case let date as Date:
            return date.timeIntervalSince1970
        case let data as Data:
            // Legacy vocabulary rules may be encoded Data. Keep a lossless envelope rather
            // than silently discarding them or interpreting unversioned bytes as new rules.
            return ["encoding": "base64", "data": data.base64EncodedString()]
        case let values as [String: Any]:
            return try values.mapValues(jsonValue)
        case let values as [Any]:
            return try values.map(jsonValue)
        case let value as String:
            return value
        case let value as NSNumber where value.doubleValue.isFinite:
            return value
        case is NSNull:
            return NSNull()
        default:
            throw Failure("A saved preference cannot be exported without losing its value.")
        }
    }

    /// Create the temporary file owner-only *before* writing any private text, then replace
    /// the user-selected destination atomically. No permissive intermediate file is created.
    static func write(_ data: Data, to destination: URL, sourceDirectory: URL) throws {
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        let original = sourceDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        guard destination.isFileURL, target.path != original, !target.path.hasPrefix(original + "/") else {
            throw Failure("Save the export outside Pressay’s Application Support folder to keep the original data intact.")
        }
        let preferences = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Preferences/\(settingsDomain).plist").resolvingSymlinksInPath()
        guard target != preferences else { throw Failure("The export cannot replace Pressay’s original preferences.") }
        let temporary = destination.deletingLastPathComponent().appending(path: ".Pressay-export-\(UUID().uuidString).json")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

struct CoreMigrationExportButton: View {
    @State private var exporting = false
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Button(exporting ? "Exporting…" : "Export for cross-platform preview…") { chooseDestination() }
                .disabled(exporting)
            if let message {
                Text(message).font(.system(size: 11))
                    .foregroundStyle(failed ? PressayPalette.danger : PressayPalette.muted)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 290, alignment: .trailing)
            }
        }
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.title = "Export Pressay data"
        panel.nameFieldStringValue = "Pressay-export.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.message = "Save a copy of your settings, dictation history and notes. Audio and sign-in credentials are not included."
        guard let window = NSApplication.shared.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let destination = panel.url else { return }
            exporting = true
            message = nil
            Task { @MainActor in
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try CoreMigrationExport.export(to: destination)
                    }.value
                    failed = false
                    message = "Export saved. Your original Pressay data is unchanged."
                } catch {
                    failed = true
                    message = error.localizedDescription
                }
                exporting = false
            }
        }
    }
}
