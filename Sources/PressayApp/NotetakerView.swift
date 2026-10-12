import AppKit
import PressayCore
import SwiftUI

enum NoteTab: String, CaseIterable {
    case summary, transcript, myNotes

    var title: String {
        switch self {
        case .summary: "Summary"
        case .transcript: "Transcript"
        case .myNotes: "My Notes"
        }
    }
}

/// The Notetaker page of the main window: past meetings, then a note page pushed on top.
struct NotetakerPage: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var store: NotesStore
    @ObservedObject private var settings: AppSettings
    @State private var path: [UUID] = []
    @State private var search = ""
    @State private var deleting: UUID?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        store = coordinator.notes
        settings = coordinator.settings
    }

    var body: some View {
        NavigationStack(path: $path) {
            home
                .navigationDestination(for: UUID.self) { id in
                    NotePage(coordinator: coordinator, id: id, onDelete: { deleting = id })
                }
        }
        .sheet(isPresented: $coordinator.notetakerSettingsShown) {
            NotetakerSettingsSheet(coordinator: coordinator)
        }
        .confirmationDialog("Delete this meeting?", isPresented: deletingShown) {
            Button("Delete", role: .destructive) {
                if let id = deleting {
                    path.removeAll { $0 == id }
                    store.delete(id)
                }
            }
        } message: {
            Text("Its notes and transcript are deleted. You can’t undo this.")
        }
        .confirmationDialog("Replace your edits?", isPresented: rewriteShown) {
            Button("Write Up Again", role: .destructive) {
                if let id = coordinator.rewriteRequest { coordinator.writeUpNote(id, replacingEdits: true) }
            }
        } message: {
            Text("The AI writes the notes again from the transcript, replacing the changes you made.")
        }
        .alert("Notetaker", isPresented: errorShown) {
            Button("OK") {}
        } message: {
            Text(coordinator.recordingError ?? "")
        }
        .onChange(of: coordinator.liveSession?.noteID, initial: true) { _, id in
            if let id, path.last != id { path = [id] }
        }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.environment["PRESSAY_OPEN_NOTE"] != nil,
               let first = store.notes.max(by: { $0.createdAt < $1.createdAt }) { path = [first.id] }
        }
        #endif
    }

    private var deletingShown: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private var rewriteShown: Binding<Bool> {
        Binding(get: { coordinator.rewriteRequest != nil }, set: { if !$0 { coordinator.rewriteRequest = nil } })
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { coordinator.recordingError != nil }, set: { if !$0 { coordinator.recordingError = nil } })
    }

    // MARK: Home

    @ViewBuilder
    private var home: some View {
        Group {
            if store.notes.isEmpty {
                NotetakerHero(coordinator: coordinator)
            } else {
                List {
                    Section {
                        StartCard(coordinator: coordinator)
                            .listRowSeparator(.hidden)
                    }
                    let groups = groups
                    ForEach(groups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.notes) { note in
                                NavigationLink(value: note.id) {
                                    NoteListRow(note: note, recording: coordinator.liveSession?.noteID == note.id)
                                }
                                .contextMenu { NoteMenuItems(coordinator: coordinator, note: note, onDelete: { deleting = note.id }) }
                            }
                        }
                    }
                    if groups.isEmpty {
                        ContentUnavailableView.search(text: search)
                    }
                }
                .listStyle(.inset)
                .searchable(text: $search, placement: .toolbar, prompt: "Search meetings")
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if store.notes.contains(where: { $0.kind == .meeting && $0.hasTranscript }) {
                        AskBar(coordinator: coordinator, noteID: nil)
                    }
                }
            }
        }
        .navigationTitle("Notetaker")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NotetakerSettingsButton(coordinator: coordinator)
            }
        }
    }

    private var groups: [(title: String, notes: [Note])] {
        let notes = store.notes.sorted { $0.createdAt > $1.createdAt }.filter { note in
            search.isEmpty
                || note.title.localizedCaseInsensitiveContains(search)
                || note.body.localizedCaseInsensitiveContains(search)
                || note.myNotes.localizedCaseInsensitiveContains(search)
                || note.lines.contains { $0.text.localizedCaseInsensitiveContains(search) }
        }
        let calendar = Calendar.current
        var result: [(title: String, notes: [Note])] = []
        for note in notes {
            let title: String
            if calendar.isDateInToday(note.createdAt) {
                title = "Today"
            } else if calendar.isDateInYesterday(note.createdAt) {
                title = "Yesterday"
            } else if calendar.isDate(note.createdAt, equalTo: .now, toGranularity: .year) {
                title = note.createdAt.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            } else {
                title = note.createdAt.formatted(.dateTime.month(.abbreviated).day().year())
            }
            if result.last?.title == title {
                result[result.count - 1].notes.append(note)
            } else {
                result.append((title, [note]))
            }
        }
        return result
    }
}

private struct NotetakerSettingsButton: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        Button { coordinator.notetakerSettingsShown = true } label: {
            Label("Notetaker Settings", systemImage: "gearshape")
        }
        .help("Notetaker settings")
    }
}

private struct NoteMenuItems: View {
    @ObservedObject var coordinator: AppCoordinator
    let note: Note
    let onDelete: () -> Void

    var body: some View {
        Button("Copy as Markdown") { copyToPasteboard(note.exportText) }
        if note.hasTranscript {
            Button("Copy Transcript") { copyToPasteboard(note.transcriptText) }
        }
        if coordinator.canWriteUp(note) {
            Button(note.edited ? "Write Up Again…" : "Write Up Again") {
                if note.edited { coordinator.rewriteRequest = note.id } else { coordinator.writeUpNote(note.id) }
            }
        }
        Divider()
        Button("Delete…", role: .destructive, action: onDelete)
            .disabled(coordinator.liveSession?.noteID == note.id)
    }
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// The top of the meetings list: start now, and whether calls are picked up.
private struct StartCard: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var settings: AppSettings

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        settings = coordinator.settings
    }

    var body: some View {
        HStack(spacing: 14) {
            NotetakerIcon(size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(coordinator.liveSession == nil ? "Take notes for a meeting" : "Taking notes now")
                    .font(.headline)
                CallDetectionStatus(coordinator: coordinator)
            }
            Spacer()
            if coordinator.liveSession == nil {
                Button { coordinator.startMeeting() } label: {
                    Label("Start Notetaker", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.6)))
        .padding(.vertical, 6)
    }
}

private struct CallDetectionStatus: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        if coordinator.settings.detectCalls {
            Label("Pressay offers to take notes when a call starts.", systemImage: "phone.badge.waveform")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Button("Offer to take notes when a call starts") {
                coordinator.settings.detectCalls = true
            }
            .buttonStyle(.link)
            .font(.callout)
        }
    }
}

struct NotetakerIcon: View {
    var size: CGFloat = 64

    var body: some View {
        Image(systemName: "person.2.wave.2.fill")
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).fill(Color.orange.gradient))
    }
}

private struct NoteListRow: View {
    let note: Note
    var recording = false

    var body: some View {
        HStack(spacing: 12) {
            Text(note.createdAt.formatted(.dateTime.hour().minute()))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title).font(.headline).lineLimit(1)
                Group {
                    if recording {
                        Label("Recording", systemImage: "record.circle").foregroundStyle(.red)
                    } else if note.formatting {
                        Text("Writing up…").foregroundStyle(.secondary)
                    } else {
                        Text(preview).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .font(.subheadline)
            }
            Spacer()
            if note.duration >= 60 {
                Text(note.durationText).font(.callout).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private var preview: String {
        note.body
            .components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: #"^\s*(#+ |- \[[ xX]\] |- |\* |\d+\. )"#, with: "", options: .regularExpression) }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "Transcript only"
    }
}

extension Note {
    var hasTranscript: Bool { !lines.isEmpty }

    var durationText: String {
        guard duration >= 60 else { return "under 1 min" }
        return Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    }
}

private struct NotetakerHero: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(spacing: 14) {
            NotetakerIcon()
            Text("Notetaker").font(.largeTitle.weight(.bold))
            Text("Pressay transcribes your meetings on this Mac as people talk, then writes up the notes: a summary, decisions and action items.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button { coordinator.startMeeting() } label: {
                Label("Start Notetaker", systemImage: "record.circle")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .disabled(coordinator.liveSession != nil)
            .padding(.top, 6)
            CallDetectionStatus(coordinator: coordinator).padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Note page

private struct NotePage: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var store: NotesStore
    let id: UUID
    let onDelete: () -> Void
    #if DEBUG
    @State private var tab = ProcessInfo.processInfo.environment["PRESSAY_OPEN_NOTE"].flatMap(NoteTab.init(rawValue:)) ?? .summary
    #else
    @State private var tab: NoteTab = .summary
    #endif
    @State private var editing = false

    init(coordinator: AppCoordinator, id: UUID, onDelete: @escaping () -> Void) {
        self.coordinator = coordinator
        store = coordinator.notes
        self.id = id
        self.onDelete = onDelete
    }

    var body: some View {
        Group {
            if let session = coordinator.liveSession, session.noteID == id {
                LiveRecordingView(
                    session: session,
                    earlierLines: store.note(id)?.lines.filter { $0.start < session.offset } ?? [],
                    myNotes: myNotes(persist: false),
                    onStop: { coordinator.stopRecording() },
                    onDiscard: coordinator.discardRecording
                )
                .navigationTitle("Taking Notes")
            } else if let note = store.note(id) {
                NoteDetailView(
                    coordinator: coordinator,
                    note: note,
                    tab: tab,
                    editing: $editing,
                    myNotes: myNotes(persist: true),
                    canWriteUp: coordinator.canWriteUp(note),
                    onChange: { title, body in
                        store.modify(id) {
                            $0.title = title
                            $0.body = body
                            $0.edited = true
                        }
                    },
                    onToggleTask: { line in toggleTask(line, in: note) }
                )
                .navigationTitle(note.createdAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .toolbar { toolbar(for: note) }
            } else {
                ContentUnavailableView("Meeting Deleted", systemImage: "trash")
            }
        }
    }

    private func myNotes(persist: Bool) -> Binding<String> {
        Binding(
            get: { store.note(id)?.myNotes ?? "" },
            set: { text in store.modify(id, persist: persist) { $0.myNotes = text } }
        )
    }

    @ToolbarContentBuilder
    private func toolbar(for note: Note) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $tab) {
                ForEach(NoteTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(editing || !note.hasTranscript)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button(editing ? "Done" : "Edit") { editing.toggle() }
                .disabled(tab != .summary || (!editing && note.formatting))
                .help(editing ? "Finish editing" : "Edit the summary")
            ShareLink(item: note.exportText, subject: Text(note.title)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Menu {
                NoteMenuItems(coordinator: coordinator, note: note, onDelete: onDelete)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More")
        }
    }

    /// Not an edit, so a later write-up can still replace the notes.
    private func toggleTask(_ lineIndex: Int, in note: Note) {
        var lines = note.body.components(separatedBy: "\n")
        guard lines.indices.contains(lineIndex) else { return }
        let line = lines[lineIndex]
        if let range = line.range(of: "- [ ] ") {
            lines[lineIndex] = line.replacingCharacters(in: range, with: "- [x] ")
        } else if let range = line.range(of: "- [x] ", options: .caseInsensitive) {
            lines[lineIndex] = line.replacingCharacters(in: range, with: "- [ ] ")
        }
        store.modify(note.id) { $0.body = lines.joined(separator: "\n") }
    }
}

private struct NoteDetailView: View {
    @ObservedObject var coordinator: AppCoordinator
    let note: Note
    let tab: NoteTab
    @Binding var editing: Bool
    @Binding var myNotes: String
    let canWriteUp: Bool
    let onChange: (String, String) -> Void
    let onToggleTask: (Int) -> Void

    @State private var title = ""
    @State private var text = ""
    @State private var notesAtOpen = ""

    var body: some View {
        VStack(spacing: 0) {
            switch tab {
            case .summary where editing: editor
            case .summary: summary
            case .transcript: TranscriptTab(note: note)
            case .myNotes: myNotesTab
            }
            if !editing, note.kind == .meeting, note.hasTranscript {
                AskBar(coordinator: coordinator, noteID: note.id)
            }
        }
        .onAppear {
            title = note.title
            text = note.body
            notesAtOpen = note.myNotes
        }
        .onChange(of: editing) { _, now in
            if now {
                title = note.title
                text = note.body
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(note.title)
                .font(.system(size: 28, weight: .bold, design: .serif))
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Label(note.createdAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()), systemImage: "calendar")
                if note.duration >= 1 {
                    Label(note.durationText, systemImage: "clock")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
        .padding(.bottom, 20)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 28, weight: .bold, design: .serif))
            TextEditor(text: $text)
                .font(.system(size: 15))
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
        }
        .padding(.horizontal, 40)
        .padding(.top, 24)
        .onChange(of: title) { _, value in if value != note.title { onChange(value, text) } }
        .onChange(of: text) { _, value in if value != note.body { onChange(title, value) } }
    }

    private var summary: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let error = note.writeUpError, !note.formatting {
                    writeUpErrorBanner(error)
                }
                if note.formatting, note.body.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Writing up your notes…")
                    }
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                } else if note.body.isEmpty {
                    emptySummary
                } else {
                    if note.formatting {
                        Label("Writing up again…", systemImage: "sparkles")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 12)
                    }
                    MarkdownNoteBody(markdown: note.body, onToggleTask: onToggleTask)
                }
            }
            .frame(maxWidth: 700, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var emptySummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            if coordinator.notesModel == nil {
                Text("Set up AI to have this meeting written up into a summary, decisions and action items. The full transcript is in the Transcript tab.")
                Button("Set Up AI…") { coordinator.settingsPaneRequest = "claude"; coordinator.showSettings() }
            } else if !coordinator.settings.notesUseAI {
                Text("AI notes are off. The full transcript is in the Transcript tab.")
                if canWriteUp || note.hasTranscript {
                    Button("Turn On AI Notes") {
                        coordinator.settings.notesUseAI = true
                        coordinator.writeUpNote(note.id)
                    }
                }
            } else if canWriteUp {
                Text("This meeting hasn’t been written up yet.")
                Button("Write Up Notes") { coordinator.writeUpNote(note.id) }
            } else {
                Text("Nothing was transcribed in this meeting.")
            }
        }
        .font(.system(size: 15))
        .foregroundStyle(.secondary)
    }

    private func writeUpErrorBanner(_ error: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(error).frame(maxWidth: .infinity, alignment: .leading)
            if canWriteUp {
                Button("Try Again") { coordinator.writeUpNote(note.id, replacingEdits: true) }
            }
        }
        .font(.callout)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary))
        .padding(.bottom, 16)
    }

    private var myNotesTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Your private notes. Pressay works them into the summary.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if canWriteUp, !note.edited, myNotes != notesAtOpen {
                    Button("Update Summary") {
                        notesAtOpen = myNotes
                        coordinator.writeUpNote(note.id)
                    }
                }
            }
            MyNotesEditor(text: $myNotes, fontSize: 15)
        }
        .frame(maxWidth: 700)
        .padding(.horizontal, 40)
        .padding(.top, 24)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Transcript

private struct TranscriptTab: View {
    let note: Note
    @State private var query = ""
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(summaryLine).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search transcript", text: $query)
                        .textFieldStyle(.plain)
                        .frame(width: 160)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(.quaternary))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(note.transcriptText, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .help("Copy the transcript")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                TranscriptLinesView(lines: note.lines, isMeeting: note.kind == .meeting, highlight: query)
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var summaryLine: String {
        let speakers = Set(note.lines.map(\.speaker)).count
        let length = TranscriptLine.timestamp(max(note.duration, note.lines.last?.start ?? 0))
        guard note.kind == .meeting else { return length }
        return "\(speakers == 1 ? "1 speaker" : "You and others") · \(length)"
    }
}

/// Meetings show turns as chat bubbles, yours on the right; long turns split about every 45 s.
struct TranscriptLinesView: View {
    let lines: [TranscriptLine]
    let isMeeting: Bool
    var highlight = ""

    struct Turn: Identifiable {
        let id: Int
        let speaker: TranscriptLine.Speaker
        let start: TimeInterval
        var text: String
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(visibleTurns) { turn in
                if isMeeting {
                    bubble(turn)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(TranscriptLine.timestamp(turn.start)).font(.subheadline).monospacedDigit().foregroundStyle(.tertiary)
                        Text(marked(turn.text)).font(.system(size: 15)).lineSpacing(4).textSelection(.enabled)
                    }
                    .id(turn.id)
                }
            }
            if visibleTurns.isEmpty, !highlight.isEmpty {
                Text("No matches for “\(highlight)”.").foregroundStyle(.secondary)
            }
        }
    }

    private func bubble(_ turn: Turn) -> some View {
        let mine = turn.speaker == .me
        return VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(mine ? "You" : "Others").fontWeight(.semibold)
                Text(TranscriptLine.timestamp(turn.start)).monospacedDigit().foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(marked(turn.text))
                .font(.system(size: 14))
                .lineSpacing(3)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(mine ? AnyShapeStyle(Color.accentColor.opacity(0.16)) : AnyShapeStyle(.quaternary))
                )
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(mine ? .leading : .trailing, 60)
        .id(turn.id)
    }

    private func marked(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard !highlight.isEmpty else { return result }
        var searchRange = result.startIndex..<result.endIndex
        while let range = result[searchRange].range(of: highlight, options: [.caseInsensitive, .diacriticInsensitive]) {
            result[range].backgroundColor = .yellow.opacity(0.45)
            searchRange = range.upperBound..<result.endIndex
        }
        return result
    }

    private var visibleTurns: [Turn] {
        guard !highlight.isEmpty else { return turns }
        return turns.filter { $0.text.localizedCaseInsensitiveContains(highlight) }
    }

    var turns: [Turn] {
        var result: [Turn] = []
        for (index, line) in lines.enumerated() {
            if var last = result.last, last.speaker == line.speaker, line.start - last.start < 45 {
                last.text += " " + line.text
                result[result.count - 1] = last
            } else {
                result.append(Turn(id: index, speaker: line.speaker, start: line.start, text: line.text))
            }
        }
        return result
    }
}

// MARK: - Ask anything

private struct AskBar: View {
    @ObservedObject var coordinator: AppCoordinator
    let noteID: UUID?

    private struct Exchange: Identifiable {
        let id = UUID()
        let question: String
        var answer: String?
        var failed = false
    }

    @State private var question = ""
    @State private var exchanges: [Exchange] = []
    @State private var expanded = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if expanded, !exchanges.isEmpty {
                answers
                Divider()
            }
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
                TextField(placeholder, text: $question)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(send)
                    .disabled(!available)
                if !exchanges.isEmpty {
                    Button {
                        withAnimation(.snappy) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .help(expanded ? "Hide answers" : "Show answers")
                }
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                .opacity(focused ? 1 : 0.6)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
            .frame(maxWidth: 700)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private var available: Bool { coordinator.notesModel != nil && coordinator.settings.notesUseAI }

    private var placeholder: String {
        if coordinator.notesModel == nil { return "Set up AI in Settings to ask about your meetings" }
        if !coordinator.settings.notesUseAI { return "AI is off in Notetaker settings" }
        return noteID == nil ? "Ask anything about your meetings" : "Ask anything about this meeting"
    }

    private var busy: Bool { exchanges.last.map { $0.answer == nil } ?? false }

    private var answers: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(exchanges) { exchange in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(exchange.question).font(.callout.weight(.semibold))
                            if let answer = exchange.answer {
                                MarkdownNoteBody(markdown: answer, onToggleTask: { _ in })
                                    .font(.system(size: 14))
                                    .foregroundStyle(exchange.failed ? .secondary : .primary)
                            } else {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Thinking…").foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                        }
                        .id(exchange.id)
                    }
                }
                .frame(maxWidth: 700, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: 280)
            .onChange(of: exchanges.count) { _, _ in
                if let last = exchanges.last { proxy.scrollTo(last.id, anchor: .top) }
            }
        }
    }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy, available else { return }
        question = ""
        let exchange = Exchange(question: text)
        exchanges.append(exchange)
        withAnimation(.snappy) { expanded = true }
        Task {
            let answer: String
            var failed = false
            do {
                answer = try await coordinator.ask(text, about: noteID)
            } catch {
                answer = error.localizedDescription
                failed = true
            }
            if let index = exchanges.firstIndex(where: { $0.id == exchange.id }) {
                exchanges[index].answer = answer
                exchanges[index].failed = failed
            }
        }
    }
}

// MARK: - Live

private struct LiveRecordingView: View {
    @ObservedObject var session: LiveSession
    let earlierLines: [TranscriptLine]
    @Binding var myNotes: String
    let onStop: () -> Void
    let onDiscard: () -> Void

    @State private var confirmingDiscard = false

    var body: some View {
        VStack(spacing: 0) {
            LiveHeader(session: session)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            Divider()
            HSplitView {
                transcript.frame(minWidth: 300)
                myNotesEditor.frame(minWidth: 240, idealWidth: 300)
            }
            controls
        }
        .confirmationDialog("Discard this recording?", isPresented: $confirmingDiscard) {
            Button("Discard", role: .destructive, action: onDiscard)
        } message: {
            Text("What was transcribed in this recording will be deleted.")
        }
    }

    private var allLines: [TranscriptLine] { earlierLines + session.lines }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let notice = session.notice {
                        Label(notice, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .symbolRenderingMode(.multicolor)
                    }
                    if allLines.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Listening…").font(.system(size: 15, weight: .medium))
                            Text("What you and the others say appears here after each pause.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        TranscriptLinesView(lines: allLines, isMeeting: true)
                    }
                    if session.pending > 0 {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Transcribing…")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
            }
            .onChange(of: session.lines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var myNotesEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("My Notes").font(.headline)
            Text("Private. Pressay works them into the summary.")
                .font(.caption)
                .foregroundStyle(.secondary)
            MyNotesEditor(text: $myNotes)
        }
        .padding(16)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if session.phase == .finishing {
                ProgressView().controlSize(.small)
                Text("Finishing the transcript…").foregroundStyle(.secondary)
            } else {
                Button("Discard…", role: .destructive) { confirmingDiscard = true }
                    .controlSize(.large)
                Button(action: onStop) {
                    Label("Stop", systemImage: "stop.fill")
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Stop and write up the notes (⌘↩)")
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .background(.bar)
    }
}

struct LiveHeader: View {
    @ObservedObject var session: LiveSession
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            RecordingDot(active: session.phase == .recording)
            VStack(alignment: .leading, spacing: 1) {
                if !compact {
                    Text("Taking notes").font(.headline)
                }
                TimelineView(.periodic(from: session.startedAt, by: 1)) { context in
                    Text(TranscriptLine.timestamp(session.offset + context.date.timeIntervalSince(session.startedAt)))
                        .monospacedDigit()
                        .foregroundStyle(compact ? .primary : .secondary)
                }
                .font(compact ? .headline : .subheadline)
            }
            Spacer(minLength: 4)
            LevelMeter(label: "You", level: session.micLevel, tint: .accentColor)
            LevelMeter(label: "Others", level: session.othersLevel, tint: .orange)
        }
    }
}

struct MyNotesEditor: View {
    @Binding var text: String
    var fontSize: CGFloat = 14

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: fontSize))
            .lineSpacing(3)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.automatic)
            .padding(.leading, -5)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Jot down anything that matters…")
                        .font(.system(size: fontSize))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// The Markdown subset notes use: headings, lists, checkboxes, inline emphasis.
struct MarkdownNoteBody: View {
    let markdown: String
    let onToggleTask: (Int) -> Void

    private enum Block {
        case heading(String)
        case paragraph(String)
        case bullet(String, nested: Bool)
        case numbered(String, String)
        case task(String, done: Bool, line: Int)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block)
                    .padding(.top, spacing(before: index))
            }
        }
        .font(.system(size: 15))
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let text):
            Text(inline(text)).font(.system(size: 18, weight: .semibold))
        case .paragraph(let text):
            Text(inline(text)).lineSpacing(4)
        case .bullet(let text, let nested):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(nested ? "◦" : "•").foregroundStyle(.secondary)
                Text(inline(text)).lineSpacing(3)
            }
            .padding(.leading, nested ? 20 : 0)
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(number).monospacedDigit().foregroundStyle(.secondary)
                Text(inline(text)).lineSpacing(3)
            }
        case .task(let text, let done, let line):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { onToggleTask(line) } label: {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(done ? Color.accentColor : .secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(done ? "Mark as not done" : "Mark as done")
                Text(inline(text))
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
            }
        }
    }

    private func spacing(before index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        switch (blocks[index - 1], blocks[index]) {
        case (_, .heading): return 22
        case (.heading, _): return 8
        case (.bullet, .bullet), (.numbered, .numbered), (.task, .task): return 6
        default: return 12
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for (index, rawLine) in markdown.components(separatedBy: "\n").enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if let match = line.firstMatch(of: /^#{1,6}\s+(.+)$/) {
                flush(); result.append(.heading(String(match.1)))
            } else if let match = line.firstMatch(of: /^[-*]\s+\[([ xX])\]\s+(.+)$/) {
                flush(); result.append(.task(String(match.2), done: match.1 != " ", line: index))
            } else if let match = line.firstMatch(of: /^[-*•]\s+(.+)$/) {
                flush(); result.append(.bullet(String(match.1), nested: rawLine.hasPrefix("  ") || rawLine.hasPrefix("\t")))
            } else if let match = line.firstMatch(of: /^(\d+[.)])\s+(.+)$/) {
                flush(); result.append(.numbered(String(match.1), String(match.2)))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return result
    }
}

struct RecordingDot: View {
    let active: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(active ? Color.red : Color.secondary)
            .frame(width: 10, height: 10)
            .background(
                Circle()
                    .fill(Color.red.opacity(0.35))
                    .scaleEffect(pulse && active ? 2.2 : 1)
                    .opacity(pulse && active ? 0 : 1)
            )
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
            }
            .accessibilityLabel(active ? "Recording" : "Stopped")
    }
}

struct LevelMeter: View {
    let label: String?
    let level: Float
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            if let label {
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 2) {
                ForEach(0..<8, id: \.self) { index in
                    Capsule()
                        .fill(Float(index) < level * 8 ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary))
                        .frame(width: 3, height: 6 + CGFloat(index) * 1.5)
                }
            }
            .frame(height: 18, alignment: .center)
            .animation(.easeOut(duration: 0.1), value: level)
        }
        .accessibilityHidden(true)
    }
}

