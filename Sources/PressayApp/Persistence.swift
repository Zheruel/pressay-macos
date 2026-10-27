import AVFoundation
import Foundation
import PressayCore
import SwiftData

@Model
final class DictationRecord: Identifiable {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var duration: TimeInterval
    var targetBundleID: String?
    var engineRawValue: String
    var rawTranscript: String
    var polishedText: String
    var correction: String?
    var asrLatency: TimeInterval
    var polishLatency: TimeInterval
    var totalLatency: TimeInterval
    var audioPath: String?
    var isPinned: Bool
    var usedLanguageModel: Bool

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        duration: TimeInterval,
        targetBundleID: String?,
        engine: String,
        rawTranscript: String,
        polishedText: String,
        correction: String? = nil,
        asrLatency: TimeInterval,
        polishLatency: TimeInterval,
        totalLatency: TimeInterval,
        audioPath: String?,
        isPinned: Bool = false,
        usedLanguageModel: Bool
    ) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.targetBundleID = targetBundleID
        self.engineRawValue = engine
        self.rawTranscript = rawTranscript
        self.polishedText = polishedText
        self.correction = correction
        self.asrLatency = asrLatency
        self.polishLatency = polishLatency
        self.totalLatency = totalLatency
        self.audioPath = audioPath
        self.isPinned = isPinned
        self.usedLanguageModel = usedLanguageModel
    }

    var referenceText: String { correction?.isEmpty == false ? correction! : polishedText }
    var isRetained: Bool { isPinned || correction?.isEmpty == false }
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var records: [DictationRecord] = []
    private var wordCounts: [UUID: (text: String, count: Int)] = [:]
    private var statsEntries: [DictationStats.Entry] = []

    private let container: ModelContainer
    private let context: ModelContext
    private let retention = RetentionPolicy()
    private let managesAudioFiles: Bool

    init(inMemory: Bool = false) throws {
        // Preview and test history must never delete recordings from the installed app.
        managesAudioFiles = !inMemory
        // Explicit store URL in our own directory: the shared Application Support
        // default.store collided with another app's store, forcing in-memory history.
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        } else {
            let directory = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Pressay", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            configuration = ModelConfiguration(url: directory.appending(path: "History.store"))
        }
        container = try ModelContainer(for: DictationRecord.self, configurations: configuration)
        context = ModelContext(container)
        try refresh()
        try applyRetention()
    }

    func add(_ record: DictationRecord) throws {
        context.insert(record)
        try context.save()
        try refresh()
    }

    func update(_ record: DictationRecord, correction: String, pin: Bool) throws {
        record.correction = correction.trimmingCharacters(in: .whitespacesAndNewlines)
        record.isPinned = pin || !record.correction!.isEmpty
        try context.save()
        try refresh()
    }

    func togglePin(_ record: DictationRecord) throws {
        record.isPinned.toggle()
        try context.save()
        try refresh()
    }

    func delete(_ record: DictationRecord) throws {
        if managesAudioFiles, let audioPath = record.audioPath { try? FileManager.default.removeItem(atPath: audioPath) }
        context.delete(record)
        try context.save()
        try refresh()
    }

    func deleteAll() throws {
        for record in try fetchAllRecords() {
            if managesAudioFiles, let audioPath = record.audioPath { try? FileManager.default.removeItem(atPath: audioPath) }
            context.delete(record)
        }
        try context.save()
        try refresh()
    }

    func stats(now: Date = .now, calendar: Calendar = .current) -> DictationStats {
        DictationStats(entries: statsEntries, now: now, calendar: calendar)
    }

    /// One-time fixup after the LocalFlow→Pressay Application Support rename (stored audio
    /// paths are absolute). Only rewrites records whose file exists at the new location.
    func rewriteAudioPaths(from oldComponent: String, to newComponent: String) throws {
        var changed = false
        for record in try fetchAllRecords() {
            guard let path = record.audioPath, path.contains(oldComponent) else { continue }
            let rewritten = path.replacingOccurrences(of: oldComponent, with: newComponent)
            guard FileManager.default.fileExists(atPath: rewritten) else { continue }
            record.audioPath = rewritten
            changed = true
        }
        if changed {
            try context.save()
            try refresh()
        }
    }

    func applyRetention(now: Date = .now) throws {
        let allRecords = try fetchAllRecords()
        for record in allRecords {
            if let path = record.audioPath,
               retention.shouldDeleteAudio(createdAt: record.createdAt, isPinned: record.isRetained, now: now) {
                if managesAudioFiles { try? FileManager.default.removeItem(atPath: path) }
                record.audioPath = nil
            }
            if retention.shouldDeleteText(createdAt: record.createdAt, isPinned: record.isRetained, now: now) {
                context.delete(record)
            }
        }
        try removeExpiredOrphanedAudio(
            referencedNames: Set(allRecords.compactMap { record in
                record.audioPath.map { URL(fileURLWithPath: $0).lastPathComponent }
            }),
            now: now
        )
        try context.save()
        try refresh()
    }

    private func refresh() throws {
        var descriptor = FetchDescriptor<DictationRecord>(
            sortBy: [SortDescriptor(\DictationRecord.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 500
        let fetched = try context.fetch(descriptor)
        var updatedCounts: [UUID: (text: String, count: Int)] = [:]
        statsEntries = fetched.map { record in
            let text = record.referenceText
            let count: Int
            if let cached = wordCounts[record.id], cached.text == text {
                count = cached.count
            } else {
                count = DictationStats.wordCount(text)
            }
            updatedCounts[record.id] = (text, count)
            return .init(date: record.createdAt, words: count, duration: record.duration)
        }
        wordCounts = updatedCounts
        records = fetched
    }

    private func fetchAllRecords() throws -> [DictationRecord] {
        try context.fetch(FetchDescriptor<DictationRecord>())
    }

    /// Orphans are matched by file name (record UUIDs), not full path, so a
    /// directory migration with not-yet-rewritten stored paths can never make
    /// referenced audio look orphaned.
    private func removeExpiredOrphanedAudio(referencedNames: Set<String>, now: Date) throws {
        guard managesAudioFiles else { return }
        let directory = AudioFileStore.directory
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let cutoff = Calendar.current.date(byAdding: .day, value: -retention.audioDays, to: now)!
        for url in urls where !referencedNames.contains(url.lastPathComponent) {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

enum AudioFileStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Pressay/Audio", directoryHint: .isDirectory)
    }

    static func save(_ clip: AudioClip, id: UUID) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(id.uuidString).caf")
        guard
            let format = AVAudioFormat(standardFormatWithSampleRate: Double(clip.sampleRate), channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(clip.samples.count))
        else { throw PressayError.audioConversionFailed }
        buffer.frameLength = buffer.frameCapacity
        clip.samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: clip.samples.count)
        }
        try catchingObjCException {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        return url
    }

}
