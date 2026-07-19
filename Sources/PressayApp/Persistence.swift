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

    private let container: ModelContainer
    private let context: ModelContext
    private let retention = RetentionPolicy()

    init(inMemory: Bool = false) throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
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
        if let audioPath = record.audioPath { try? FileManager.default.removeItem(atPath: audioPath) }
        context.delete(record)
        try context.save()
        try refresh()
    }

    func deleteAll() throws {
        for record in try fetchAllRecords() {
            if let audioPath = record.audioPath { try? FileManager.default.removeItem(atPath: audioPath) }
            context.delete(record)
        }
        try context.save()
        try refresh()
    }

    /// One-time fixup after the LocalFlow→Pressay Application Support rename:
    /// stored audio paths are absolute and point into the old directory. A
    /// record is only rewritten when its file actually exists at the new
    /// location, so records written by an old build into a recreated old
    /// directory are left pointing at their real files.
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
                try? FileManager.default.removeItem(atPath: path)
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
        records = try context.fetch(descriptor)
    }

    private func fetchAllRecords() throws -> [DictationRecord] {
        try context.fetch(FetchDescriptor<DictationRecord>())
    }

    /// Orphans are matched by file name (record UUIDs), not full path, so a
    /// directory migration with not-yet-rewritten stored paths can never make
    /// referenced audio look orphaned.
    private func removeExpiredOrphanedAudio(referencedNames: Set<String>, now: Date) throws {
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
