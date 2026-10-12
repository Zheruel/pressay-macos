import AppKit
import PressayCore
import SwiftUI

@MainActor
final class NotesWindowController: NSWindowController, NSWindowDelegate {
    init(coordinator: AppCoordinator) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "Notes"
        window.toolbar = NSToolbar(identifier: "PressayNotes")
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("PressayNotesWindow")
        let hosting = NSHostingController(rootView: NotesRootView(coordinator: coordinator))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 920, height: 620))
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var isKey: Bool { window?.isKeyWindow == true }

    func present() {
        guard let window else { return }
        ForegroundWindowPresenter.present(window)
    }
}

struct NotesRootView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var store: NotesStore
    @ObservedObject private var settings: AppSettings
    @State private var selection: UUID?
    @State private var search = ""
    @State private var editing = false
    @State private var confirmingDelete = false
    @State private var showingTranscript = false

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        store = coordinator.notes
        settings = coordinator.settings
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search")
        .navigationTitle("Notes")
        .toolbar { toolbarContent }
        .confirmationDialog("Delete this note?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                if let id = selection { store.delete(id) }
                selection = store.notes.first?.id
            }
        } message: {
            Text("You can’t undo this.")
        }
        .alert("Can’t Record", isPresented: errorShown) {
            Button("OK") {}
        } message: {
            Text(coordinator.recordingError ?? "")
        }
        .onChange(of: coordinator.liveSession?.noteID) { _, id in
            if let id { selection = id }
        }
        .onAppear { if selection == nil { selection = store.notes.first?.id } }
        .onChange(of: selection) { _, _ in
            editing = false
            showingTranscript = false
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { coordinator.recordingError != nil }, set: { if !$0 { coordinator.recordingError = nil } })
    }

    private var sidebar: some View {
            List(selection: $selection) {
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.notes) { note in
                            NoteListRow(note: note, recording: coordinator.liveSession?.noteID == note.id).tag(note.id)
                                .contextMenu {
                                    Button("Copy") { copy(note) }
                                    if !note.edited, coordinator.cleanupConfigured, settings.notesUseAI {
                                        Button("Write Up Again") { coordinator.writeUpNote(note.id) }
                                    }
                                    Divider()
                                    Button("Delete", role: .destructive) { store.delete(note.id) }
                                        .disabled(coordinator.liveSession?.noteID == note.id)
                                }
                        }
                    }
                }
            }
            .frame(minWidth: 240, idealWidth: 260)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
            .overlay {
                if store.notes.isEmpty {
                    ContentUnavailableView("No Notes", systemImage: "note.text")
                } else if groups.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
    }

    @ViewBuilder
    private var detail: some View {
            if let id = selection, let session = coordinator.liveSession, session.noteID == id {
                LiveRecordingView(
                    session: session,
                    earlierLines: store.note(id)?.lines.filter { $0.start < session.offset } ?? [],
                    myNotes: Binding(
                        get: { store.note(id)?.myNotes ?? "" },
                        set: { text in store.modify(id, persist: false) { $0.myNotes = text } }
                    ),
                    onStop: coordinator.stopRecording,
                    onDiscard: coordinator.discardRecording
                )
                .id(id)
            } else if let id = selection, let note = store.note(id) {
                NoteDetailView(
                    note: note,
                    editing: $editing,
                    showingTranscript: showingTranscript && note.hasTranscript,
                    canRecord: coordinator.liveSession == nil,
                    onChange: { title, body in
                        store.modify(id) {
                            $0.title = title
                            $0.body = body
                            $0.edited = true
                        }
                    },
                    onToggleTask: { line in toggleTask(line, in: note) },
                    onContinue: { coordinator.startRecording(note.kind, continuing: id) }
                )
                .id(id)
            } else {
                ContentUnavailableView {
                    Label(store.notes.isEmpty ? "Record Your First Note" : "No Note Selected", systemImage: "waveform")
                } description: {
                    Text("Talk through an idea, or record a meeting while it happens. Pressay transcribes it live and writes up the note.")
                } actions: {
                    HStack {
                        Button("New Voice Note", systemImage: "mic") { coordinator.startRecording(.voice) }
                        Button("Record Meeting", systemImage: "person.2.wave.2") { coordinator.startRecording(.meeting) }
                    }
                    .controlSize(.large)
                    .disabled(coordinator.liveSession != nil)
                }
            }
    }
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
            ToolbarItemGroup(placement: .navigation) {
                Button { coordinator.startRecording(.voice) } label: {
                    Label("New Voice Note", systemImage: "mic")
                }
                .help("Record a voice note")
                .disabled(coordinator.liveSession != nil)
                Button { coordinator.startRecording(.meeting) } label: {
                    Label("Record Meeting", systemImage: "person.2.wave.2")
                }
                .help("Transcribe a meeting live: you and everyone on the call")
                .disabled(coordinator.liveSession != nil)
            }
            if let note = selectedNote, note.hasTranscript, !isRecordingSelected {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $showingTranscript) {
                        Text("Note").tag(false)
                        Text("Transcript").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .disabled(editing)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if let note = selectedNote, !isRecordingSelected {
                    Button(editing ? "Done" : "Edit") {
                        showingTranscript = false
                        editing.toggle()
                    }
                    .disabled(!editing && note.formatting)
                    .help(editing ? "Finish editing" : "Edit the note’s text")
                    ShareLink(item: note.exportText, subject: Text(note.title)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button { copy(note) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .help("Copy note")
                    Button { confirmingDelete = true } label: { Label("Delete", systemImage: "trash") }
                        .help("Delete note")
                }
            }
    }

    private var isRecordingSelected: Bool {
        selection != nil && coordinator.liveSession?.noteID == selection
    }

    private var selectedNote: Note? { selection.flatMap(store.note) }

    private var filtered: [Note] {
        guard !search.isEmpty else { return store.notes }
        return store.notes.filter {
            $0.title.localizedCaseInsensitiveContains(search) || $0.body.localizedCaseInsensitiveContains(search)
        }
    }

    private var groups: [(title: String, notes: [Note])] {
        let calendar = Calendar.current
        let now = Date()
        var buckets: [(String, [Note])] = [("Today", []), ("Previous 7 Days", []), ("Previous 30 Days", []), ("Earlier", [])]
        for note in filtered {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: note.updatedAt), to: calendar.startOfDay(for: now)).day ?? 0
            let index = days == 0 ? 0 : days <= 7 ? 1 : days <= 30 ? 2 : 3
            buckets[index].1.append(note)
        }
        return buckets.filter { !$0.1.isEmpty }.map { (title: $0.0, notes: $0.1) }
    }

    private func copy(_ note: Note) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.exportText, forType: .string)
    }

    /// Not an edit, so later recordings can still rewrite the note.
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

private struct NoteListRow: View {
    let note: Note
    var recording = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title).font(.headline).lineLimit(1)
            HStack(spacing: 6) {
                Text(note.updatedAt, format: dateFormat)
                    .foregroundStyle(.secondary)
                if recording {
                    Label("Recording", systemImage: "record.circle")
                        .foregroundStyle(.red)
                        .labelStyle(.titleAndIcon)
                } else {
                    Text(preview).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .font(.subheadline)
        }
        .padding(.vertical, 3)
    }

    private var dateFormat: Date.FormatStyle {
        Calendar.current.isDateInToday(note.updatedAt)
            ? .dateTime.hour().minute()
            : .dateTime.day().month(.abbreviated)
    }

    private var preview: String {
        note.body
            .components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: #"^(#+ |- \[[ xX]\] |- |\* |\d+\. )"#, with: "", options: .regularExpression) }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "No additional text"
    }
}

private struct NoteDetailView: View {
    let note: Note
    @Binding var editing: Bool
    let showingTranscript: Bool
    let canRecord: Bool
    let onChange: (String, String) -> Void
    let onToggleTask: (Int) -> Void
    let onContinue: () -> Void

    @State private var title = ""
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            if editing {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Title", text: $title)
                        .textFieldStyle(.plain)
                        .font(.title.weight(.bold))
                    TextEditor(text: $text)
                        .font(.body.monospaced())
                        .scrollContentBackground(.hidden)
                }
                .padding(.horizontal, 40)
                .padding(.top, 24)
                .onChange(of: title) { _, value in if value != note.title { onChange(value, text) } }
                .onChange(of: text) { _, value in if value != note.body { onChange(title, value) } }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(dateLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 14)
                        Text(note.title)
                            .font(.system(size: 26, weight: .bold))
                            .textSelection(.enabled)
                            .padding(.bottom, 12)
                        if showingTranscript {
                            if !note.myNotes.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Your notes").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                    Text(note.myNotes).font(.system(size: 15)).lineSpacing(4).textSelection(.enabled)
                                }
                                .padding(.bottom, 20)
                            }
                            TranscriptLinesView(lines: note.lines, isMeeting: note.kind == .meeting)
                        } else if note.body.isEmpty, note.hasTranscript {
                            Text(note.formatting ? "Your note will appear here in a moment." : "Switch to Transcript to read what was said.")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                        } else {
                            MarkdownNoteBody(markdown: note.body, onToggleTask: onToggleTask)
                        }
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
            }
            if !editing {
                footer
            }
        }
        .onAppear {
            title = note.title
            text = note.body
        }
        .onChange(of: editing) { _, now in
            if now {
                title = note.title
                text = note.body
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if note.formatting {
                ProgressView().controlSize(.small)
                Text("Writing up your note…")
                    .foregroundStyle(.secondary)
            } else {
                Button(note.kind == .meeting ? "Resume Meeting" : "Record More", systemImage: "mic") { onContinue() }
                    .buttonStyle(.borderless)
                    .disabled(!canRecord)
                    .help(note.kind == .meeting ? "Keep transcribing into this meeting" : "Add another recording to this note")
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        .background(.bar)
    }

    private var dateLine: String {
        let date = note.createdAt.formatted(.dateTime.day().month(.wide).year().hour().minute())
        guard note.duration >= 1 else { return date }
        let length = Duration.seconds(note.duration).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
        return note.duration < 60 ? "\(date) · under 1 min" : "\(date) · \(length)"
    }
}

/// The Markdown subset notes use: headings, lists, checkboxes, inline emphasis.
private struct MarkdownNoteBody: View {
    let markdown: String
    let onToggleTask: (Int) -> Void

    private enum Block {
        case heading(String)
        case paragraph(String)
        case bullet(String)
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
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(text)).lineSpacing(3)
            }
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
                flush(); result.append(.bullet(String(match.1)))
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

private extension Note {
    var hasTranscript: Bool { !lines.isEmpty }
}

/// Meetings merge consecutive same-speaker lines into turns; voice notes read as paragraphs.
private struct TranscriptLinesView: View {
    let lines: [TranscriptLine]
    let isMeeting: Bool

    struct Turn: Identifiable {
        let id: Int
        let speaker: TranscriptLine.Speaker
        let start: TimeInterval
        var text: String
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(turns) { turn in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if isMeeting {
                            Text(turn.speaker == .me ? "You" : "Others")
                                .fontWeight(.semibold)
                                .foregroundStyle(turn.speaker == .me ? Color.accentColor : Color.orange)
                        }
                        Text(TranscriptLine.timestamp(turn.start))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    .font(.subheadline)
                    Text(turn.text)
                        .font(.system(size: 15))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
                .id(turn.id)
            }
        }
    }

    var turns: [Turn] {
        var result: [Turn] = []
        for (index, line) in lines.enumerated() {
            // A long turn breaks into paragraphs about every 45 s.
            if var last = result.last, last.speaker == line.speaker,
               line.start - last.start < 45 {
                last.text += " " + line.text
                result[result.count - 1] = last
            } else {
                result.append(Turn(id: index, speaker: line.speaker, start: line.start, text: line.text))
            }
        }
        return result
    }
}

private struct LiveRecordingView: View {
    @ObservedObject var session: LiveSession
    let earlierLines: [TranscriptLine]
    @Binding var myNotes: String
    let onStop: () -> Void
    let onDiscard: () -> Void

    @State private var confirmingDiscard = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
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
                                Text(session.kind == .meeting
                                     ? "What you and the others say appears here after each pause."
                                     : "Your words appear here after each pause.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            TranscriptLinesView(lines: allLines, isMeeting: session.kind == .meeting)
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
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: session.lines.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            if session.kind == .meeting {
                Divider()
                myNotesEditor
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

    private var myNotesEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your notes").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            TextEditor(text: $myNotes)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if myNotes.isEmpty {
                        Text("Jot down anything that matters. Pressay works it into the write-up.")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
        }
        .frame(height: 110)
        .frame(maxWidth: 680)
        .padding(.horizontal, 40)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(spacing: 12) {
            RecordingDot(active: session.phase == .recording)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.kind == .meeting ? "Recording meeting" : "Recording voice note")
                    .font(.headline)
                TimelineView(.periodic(from: session.startedAt, by: 1)) { context in
                    Text(TranscriptLine.timestamp(session.offset + context.date.timeIntervalSince(session.startedAt)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            Spacer()
            LevelMeter(label: session.kind == .meeting ? "You" : nil, level: session.micLevel, tint: .accentColor)
            if session.kind == .meeting {
                LevelMeter(label: "Others", level: session.othersLevel, tint: .orange)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
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
                .help("Stop and write up the note (⌘↩)")
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .background(.bar)
    }
}

private struct RecordingDot: View {
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

private struct LevelMeter: View {
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

