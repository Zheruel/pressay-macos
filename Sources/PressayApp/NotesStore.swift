import Foundation
import OSLog
import PressayCore

/// Kept until the user deletes it, unlike dictation history; stored only on this Mac.
struct Note: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case voice, meeting
    }

    let id: UUID
    var kind: Kind = .voice
    let createdAt: Date
    var updatedAt: Date
    var title: String
    var body: String
    /// Oldest first; a new recording rewrites the note from all of them unless `edited`.
    var transcripts: [String]
    /// Hand-edited: later recordings append instead of rewriting.
    var edited: Bool
    /// Meetings only.
    var lines: [TranscriptLine] = []
    var duration: TimeInterval = 0
    var myNotes = ""
    /// AI write-up in flight (not persisted).
    var formatting = false

    enum CodingKeys: String, CodingKey {
        case id, kind, createdAt, updatedAt, title, body, transcripts, edited, lines, duration, myNotes
    }

    init(id: UUID = UUID(), kind: Kind, title: String, body: String, transcripts: [String], lines: [TranscriptLine] = [], duration: TimeInterval) {
        self.id = id
        self.kind = kind
        createdAt = .now
        updatedAt = .now
        self.title = title
        self.body = body
        self.transcripts = transcripts
        self.lines = lines
        self.duration = duration
        edited = false
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .voice
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decode(String.self, forKey: .body)
        transcripts = try c.decodeIfPresent([String].self, forKey: .transcripts) ?? []
        edited = try c.decodeIfPresent(Bool.self, forKey: .edited) ?? false
        lines = try c.decodeIfPresent([TranscriptLine].self, forKey: .lines) ?? []
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        myNotes = try c.decodeIfPresent(String.self, forKey: .myNotes) ?? ""
    }

    var transcriptText: String {
        guard !lines.isEmpty else { return transcripts.joined(separator: "\n\n") }
        return lines.map { "[\(TranscriptLine.timestamp($0.start))] \($0.speaker == .me ? "Me" : "Others"): \($0.text)" }
            .joined(separator: "\n")
    }

    var exportText: String { body.isEmpty ? title : "\(title)\n\n\(body)" }
}

@MainActor
final class NotesStore: ObservableObject {
    @Published private(set) var notes: [Note] = []
    private let url: URL
    private let logger = Logger(subsystem: "dev.localflow.app", category: "notes")

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Pressay", directoryHint: .isDirectory)) {
        url = directory.appending(path: "Notes.json")
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            notes = try JSONDecoder.notes.decode([Note].self, from: data).sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            // Keep the unreadable file rather than overwrite it with an empty list on the next save.
            let backup = directory.appending(path: "Notes.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            logger.error("Notes.json unreadable, moved to \(backup.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func note(_ id: UUID) -> Note? { notes.first { $0.id == id } }

    func add(_ note: Note) {
        notes.insert(note, at: 0)
        save()
    }

    func modify(_ id: UUID, persist: Bool = true, _ change: (inout Note) -> Void) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        change(&notes[index])
        if persist {
            notes[index].updatedAt = .now
            let note = notes.remove(at: index)
            notes.insert(note, at: 0)
            save()
        }
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.notes.encode(notes).write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            logger.error("Saving notes failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private extension JSONEncoder {
    static let notes: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let notes: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
