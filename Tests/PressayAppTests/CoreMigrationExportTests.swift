import Foundation
import SwiftData
import Testing

@testable import PressayApp

@MainActor
struct CoreMigrationExportTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "PressayMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func storeFiles(in directory: URL) throws -> [String: Data] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try Dictionary(uniqueKeysWithValues: files.filter { $0.lastPathComponent.hasPrefix("History.store") }
            .map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }

    @Test func exportsEveryRecordWithoutRetentionOrSourceMutation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "History.store")
        let container = try ModelContainer(for: DictationRecord.self,
            configurations: ModelConfiguration(url: storeURL, cloudKitDatabase: .none))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let oldDate = Date(timeIntervalSince1970: 946_684_800.125)
        let audio = directory.appending(path: "retained-audio.caf")
        try Data("original audio fixture".utf8).write(to: audio)
        for index in 0..<501 {
            context.insert(DictationRecord(createdAt: oldDate.addingTimeInterval(Double(index)),
                duration: 2.5, targetBundleID: "example.target", targetAppName: "Target app",
                engine: "Unknown future engine", rawTranscript: "Raw \(index)", polishedText: "Clean \(index)",
                correction: index == 0 ? "Manual correction" : nil, asrLatency: 0.2, polishLatency: 0.1,
                totalLatency: 0.4, audioPath: audio.path, isPinned: index == 1, usedLanguageModel: true))
        }
        try context.save()
        let before = try storeFiles(in: directory)
        let data = try CoreMigrationExport.snapshot(directory: directory, preferences: [:], source: "fixture")
        let result = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(result["schema"] as? Int == 1)
        #expect(result["source"] as? String == "pressay-macos:fixture")
        let records = try #require(result["dictations"] as? [[String: Any]])
        #expect(records.count == 501)
        let first = try #require(records.first)
        #expect(first["created_at"] as? Double == oldDate.timeIntervalSince1970)
        #expect(first["correction"] as? String == "Manual correction")
        #expect(first["pinned"] as? Bool == false)
        #expect(first["model"] as? String == "Unknown future engine")
        let legacy = try #require(first["legacy"] as? [String: Any])
        #expect(legacy["targetAppName"] as? String == "Target app")
        #expect(legacy["audioPath"] as? String == audio.path)
        #expect(legacy["usedLanguageModel"] as? Bool == true)
        #expect(try storeFiles(in: directory) == before)
        #expect(try context.fetchCount(FetchDescriptor<DictationRecord>()) == 501)
        #expect(try Data(contentsOf: audio) == Data("original audio fixture".utf8))
    }

    @Test func preservesRawSettingsAndNotesWithoutExportingCredentials() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let domain = "PressayMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("future-model-not-yet-known", forKey: "asrModel")
        defaults.set("Project Aurora <= project a roar a", forKey: "vocabulary")
        defaults.set(Data([1, 2, 3]), forKey: "vocabularyTuner.rules")
        defaults.set(["Ada", "Lin"], forKey: "vocabularyTuner.seenCandidates")
        defaults.set("fake-test-secret", forKey: "openAIAPIKey")
        defaults.set("fake-test-token", forKey: "refreshToken")
        let before = try #require(defaults.persistentDomain(forName: domain))
        let notes = Data("""
        [{"id":"meeting-1","createdAt":"1970-01-01T00:00:00.125Z","updatedAt":"2026-01-01T00:00:00Z",
        "title":"Fixture meeting","futureField":{"preserved":true},"lines":[{"start":1.5,"text":"Hello"}]}]
        """.utf8)
        let notesURL = directory.appending(path: "Notes.json")
        try notes.write(to: notesURL)
        let data = try CoreMigrationExport.snapshot(directory: directory, preferences: before)
        let result = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let settings = try #require(result["settings"] as? [String: Any])
        #expect(settings["asrModel"] as? String == "future-model-not-yet-known")
        #expect(settings["vocabulary"] as? String == "Project Aurora <= project a roar a")
        #expect(settings["vocabularyTuner.seenCandidates"] as? [String] == ["Ada", "Lin"])
        #expect((settings["vocabularyTuner.rules"] as? [String: String])?["data"] == "AQID")
        #expect(settings["openAIAPIKey"] == nil)
        #expect(settings["refreshToken"] == nil)
        let meeting = try #require((result["notes"] as? [[String: Any]])?.first)
        #expect(meeting["created_at"] as? Double == 0.125)
        #expect(meeting["createdAt"] as? String == "1970-01-01T00:00:00.125Z")
        #expect((meeting["futureField"] as? [String: Bool])?["preserved"] == true)
        #expect(try Data(contentsOf: notesURL) == notes)
        #expect(NSDictionary(dictionary: defaults.persistentDomain(forName: domain) ?? [:]).isEqual(to: before))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "History.store").path))
        let second = try #require(JSONSerialization.jsonObject(with: CoreMigrationExport.snapshot(
            directory: directory, preferences: before)) as? [String: Any])
        #expect(result["source"] as? String != second["source"] as? String)
    }

    @Test func privateAtomicExportCannotReplaceOriginalData() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "Original")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let original = source.appending(path: "Notes.json")
        try Data("original".utf8).write(to: original)
        let export = directory.appending(path: "Export.json")
        try CoreMigrationExport.write(Data("export".utf8), to: export, sourceDirectory: source)
        #expect(try Data(contentsOf: export) == Data("export".utf8))
        let permissions = try FileManager.default.attributesOfItem(atPath: export.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        try CoreMigrationExport.write(Data("replacement".utf8), to: export, sourceDirectory: source)
        #expect(try Data(contentsOf: export) == Data("replacement".utf8))
        #expect(throws: (any Error).self) {
            try CoreMigrationExport.write(Data("must not replace".utf8), to: original, sourceDirectory: source)
        }
        let link = directory.appending(path: "alias.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        #expect(throws: (any Error).self) {
            try CoreMigrationExport.write(Data("must not replace".utf8), to: link, sourceDirectory: source)
        }
        #expect(try Data(contentsOf: original) == Data("original".utf8))
    }

    @Test func unreadableNotesFailWithoutRenamingOrOverwritingThem() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appending(path: "Notes.json")
        let data = Data("{broken JSON".utf8)
        try data.write(to: original)
        #expect(throws: (any Error).self) {
            try CoreMigrationExport.snapshot(directory: directory, preferences: [:])
        }
        #expect(try Data(contentsOf: original) == data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["Notes.json"])
    }
}
