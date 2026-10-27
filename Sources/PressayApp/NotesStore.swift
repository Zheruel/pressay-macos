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
    /// Why the last write-up failed (not persisted).
    var writeUpError: String?
    /// Recorded but not written up yet, e.g. the app quit mid-meeting.
    var needsWriteUp = false
    /// Who else was on the call, as the user typed them.
    var participants: [String] = []
    /// Names for told-apart voices: index 0 is "Speaker 1"; empty for unnamed.
    var speakerNames: [String] = []
    /// Action item lines already sent to Reminders, so they aren't added twice.
    var sentToReminders: [String] = []

    enum CodingKeys: String, CodingKey {
        case id, kind, createdAt, updatedAt, title, body, transcripts, edited, lines, duration, myNotes, needsWriteUp, participants, sentToReminders, speakerNames
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
        needsWriteUp = try c.decodeIfPresent(Bool.self, forKey: .needsWriteUp) ?? false
        participants = try c.decodeIfPresent([String].self, forKey: .participants) ?? []
        sentToReminders = try c.decodeIfPresent([String].self, forKey: .sentToReminders) ?? []
        speakerNames = try c.decodeIfPresent([String].self, forKey: .speakerNames) ?? []
    }

    var transcriptText: String {
        guard !lines.isEmpty else { return transcripts.joined(separator: "\n\n") }
        return lines.map { $0.plain(names: speakerNames) }.joined(separator: "\n")
    }

    /// Adds AI-found names to the empty slots only.
    static func merging(_ found: [Int: String], into names: [String]) -> [String] {
        var names = names
        for (voice, name) in found where voice >= 1 {
            if names.count < voice { names += Array(repeating: "", count: voice - names.count) }
            if names[voice - 1].isEmpty { names[voice - 1] = name }
        }
        return names
    }

    /// Who else was on the call, for the header: a label per told-apart voice, else the typed names.
    var speakerLabels: [String] {
        guard !voices.isEmpty else { return participants }
        return voices.map { TranscriptLine(speaker: .others, start: 0, text: "", voice: $0).voiceLabel(names: speakerNames) ?? "" }
    }

    var hasNames: Bool { voices.isEmpty ? !participants.isEmpty : speakerNames.contains { !$0.isEmpty } }

    /// Told-apart voices, in order: 1, 2, 3.
    var voices: [Int] { Set(lines.compactMap(\.voice)).sorted() }

    /// "You" for the user, then a name, "Speaker N" or the label for everyone else.
    func label(for line: TranscriptLine) -> String {
        line.speaker == .me ? "You" : line.voiceLabel(names: speakerNames) ?? othersLabel
    }

    /// The transcript's label for the other side: a name when there was only one other person.
    var othersLabel: String { participants.count == 1 ? participants[0] : "Others" }

    var exportText: String { body.isEmpty ? title : "\(title)\n\n\(body)" }
}

@MainActor
final class NotesStore: ObservableObject {
    @Published private(set) var notes: [Note] = []
    private var actionItemsByNote: [UUID: [ActionItem]] = [:]
    private(set) var openActionItemCount = 0
    private let url: URL
    private let logger = Logger(subsystem: "dev.localflow.app", category: "notes")

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Pressay", directoryHint: .isDirectory)) {
        url = directory.appending(path: "Notes.json")
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            notes = try JSONDecoder.notes.decode([Note].self, from: data).sorted { $0.updatedAt > $1.updatedAt }
            for note in notes { updateActionItems(for: note) }
        } catch {
            // Keep the unreadable file rather than overwrite it with an empty list on the next save.
            let backup = directory.appending(path: "Notes.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            logger.error("Notes.json unreadable, moved to \(backup.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func note(_ id: UUID) -> Note? { notes.first { $0.id == id } }

    func actionItems(for id: UUID) -> [ActionItem] { actionItemsByNote[id] ?? [] }

    private func updateActionItems(for note: Note) {
        openActionItemCount -= actionItems(for: note.id).filter { $0.isMine && !$0.done }.count
        let items = note.body.isEmpty ? [] : ActionItem.parse(note.body)
        actionItemsByNote[note.id] = items
        openActionItemCount += items.filter { $0.isMine && !$0.done }.count
    }

    func add(_ note: Note) {
        updateActionItems(for: note)
        notes.insert(note, at: 0)
        flush()
    }

    func modify(_ id: UUID, persist: Bool = true, keepOrder: Bool = false, _ change: (inout Note) -> Void) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let previousBody = notes[index].body
        change(&notes[index])
        // Live transcript and title changes don't invalidate the parsed summary.
        if notes[index].body != previousBody { updateActionItems(for: notes[index]) }
        guard persist else { return }
        if !keepOrder {
            notes[index].updatedAt = .now
            let note = notes.remove(at: index)
            notes.insert(note, at: 0)
        }
        scheduleSave()
    }

    private var pendingSave: Task<Void, Never>?

    /// Typing and live transcripts change notes constantly; coalesce the rewrites of Notes.json.
    private func scheduleSave() {
        guard pendingSave == nil else { return }
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.flush()
        }
    }

    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        save()
    }

    func delete(_ id: UUID) {
        openActionItemCount -= actionItems(for: id).filter { $0.isMine && !$0.done }.count
        actionItemsByNote[id] = nil
        notes.removeAll { $0.id == id }
        flush()
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
