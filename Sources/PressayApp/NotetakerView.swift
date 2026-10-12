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

enum NotetakerRoute: Hashable {
    case note(UUID)
    case actionItems
}

/// The Notetaker page of the main window: past meetings, then a note page pushed on top.
struct NotetakerPage: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var store: NotesStore
    @ObservedObject private var settings: AppSettings
    @State private var path: [NotetakerRoute] = []
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
                .navigationDestination(for: NotetakerRoute.self) { route in
                    switch route {
                    case .note(let id): NotePage(coordinator: coordinator, id: id, onDelete: { deleting = id })
                    case .actionItems: ActionItemsPage(coordinator: coordinator)
                    }
                }
        }
        .sheet(isPresented: $coordinator.notetakerSettingsShown) {
            NotetakerSettingsSheet(coordinator: coordinator)
        }
        .confirmationDialog("Delete this meeting?", isPresented: deletingShown) {
            Button("Delete", role: .destructive) {
                if let id = deleting {
                    path.removeAll { $0 == .note(id) }
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
            if let id, path.last != .note(id) { path = [.note(id)] }
        }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.environment["PRESSAY_OPEN_NOTE"] != nil,
               let first = store.notes.max(by: { $0.createdAt < $1.createdAt }) {
                path = ProcessInfo.processInfo.environment["PRESSAY_OPEN_NOTE"] == "actions" ? [.actionItems] : [.note(first.id)]
            }
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
                        if search.isEmpty, openItemCount > 0 {
                            NavigationLink(value: NotetakerRoute.actionItems) {
                                Label {
                                    Text(openItemCount == 1 ? "1 open action item for you" : "\(openItemCount) open action items for you")
                                } icon: {
                                    Image(systemName: "checklist").foregroundStyle(.orange)
                                }
                                .font(.headline)
                                .padding(.vertical, 6)
                            }
                            .listRowSeparator(.hidden)
                        }
                    }
                    let groups = groups
                    ForEach(groups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.notes) { note in
                                NavigationLink(value: NotetakerRoute.note(note.id)) {
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

    private var openItemCount: Int {
        store.notes.reduce(0) { count, note in
            count + ActionItem.parse(note.body).filter { $0.isMine && !$0.done }.count
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
        HStack(spacing: 16) {
            if coordinator.liveSession == nil {
                Button { coordinator.startMeeting() } label: {
                    Label("Start Notetaker", systemImage: "mic.fill")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            } else {
                Label("Taking notes now", systemImage: "record.circle")
                    .font(.headline)
                    .foregroundStyle(.red)
            }
            CallDetectionStatus(coordinator: coordinator)
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary.opacity(0.6)))
        .padding(.vertical, 6)
    }
}

private struct CallDetectionStatus: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if coordinator.settings.detectCalls {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text("Listening for calls").font(.callout.weight(.medium))
                }
                Text("When Zoom, Meet, Teams or Slack uses your mic, Pressay offers to take notes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Call detection is off").font(.callout.weight(.medium))
                Button("Offer to take notes when a call starts") { coordinator.settings.detectCalls = true }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
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
                    onToggleTask: { item in coordinator.toggleActionItem(note.id, item: item) }
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
}

private struct NoteDetailView: View {
    @ObservedObject var coordinator: AppCoordinator
    let note: Note
    let tab: NoteTab
    @Binding var editing: Bool
    @Binding var myNotes: String
    let canWriteUp: Bool
    let onChange: (String, String) -> Void
    let onToggleTask: (ActionItem) -> Void

    @State private var title = ""
    @State private var text = ""
    @State private var notesAtOpen = ""
    @State private var editingNames = false

    var body: some View {
        VStack(spacing: 0) {
            switch tab {
            case .summary where editing: editor
            case .summary: summary
            case .transcript: TranscriptTab(coordinator: coordinator, note: note)
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
            HStack(spacing: 6) {
                Text(note.createdAt.formatted(.dateTime.hour().minute()))
                if note.duration >= 60 {
                    Text("·")
                    Text(note.durationText)
                }
                if note.kind == .meeting {
                    Text("·")
                    ForEach(["You"] + note.participants, id: \.self) { name in
                        Text(name)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.quaternary))
                    }
                    Button(note.participants.isEmpty ? "Add names" : "Edit names") { editingNames = true }
                        .buttonStyle(.link)
                        .help("Who else was on the call")
                        .popover(isPresented: $editingNames, arrowEdge: .bottom) {
                            SpeakersEditor(coordinator: coordinator, note: note)
                        }
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
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
                    MarkdownNoteBody(markdown: note.body, onToggleTask: onToggleTask, tasksAccessory: AnyView(RemindersButton(coordinator: coordinator, note: note)))
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
    @ObservedObject var coordinator: AppCoordinator
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
                TranscriptLinesView(lines: note.lines, isMeeting: note.kind == .meeting, othersLabel: note.othersLabel, highlight: query)
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
        let who: String
        if speakers == 1 {
            who = "1 speaker"
        } else if note.participants.isEmpty {
            who = "You and others"
        } else {
            who = (["You"] + note.participants).formatted(.list(type: .and))
        }
        return "\(who) · \(length)"
    }
}

/// Meetings show turns as chat bubbles, yours on the right; long turns split about every 45 s.
struct TranscriptLinesView: View {
    let lines: [TranscriptLine]
    let isMeeting: Bool
    var othersLabel = "Others"
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
                Text(mine ? "You" : othersLabel).fontWeight(.semibold)
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
                                MarkdownNoteBody(markdown: answer)
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
        }
        .toolbar { controls }
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
            Text("Jot anything. Pressay folds your notes into the summary when you stop.")
                .font(.caption)
                .foregroundStyle(.secondary)
            MyNotesEditor(text: $myNotes)
        }
        .padding(16)
    }

    @ToolbarContentBuilder
    private var controls: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if session.phase == .finishing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Finishing…").foregroundStyle(.secondary)
                }
            } else {
                Button("Discard…") { confirmingDiscard = true }
                    .help("Delete this recording")
                Button(action: onStop) {
                    Label("Stop", systemImage: "stop.fill").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Stop and write up the notes (⌘↩)")
            }
        }
    }
}

private struct LiveHeader: View {
    @ObservedObject var session: LiveSession

    var body: some View {
        HStack(spacing: 12) {
            RecordingDot(active: session.phase == .recording)
            VStack(alignment: .leading, spacing: 1) {
                Text("Taking notes").font(.headline)
                TimelineView(.periodic(from: session.startedAt, by: 1)) { context in
                    Text(TranscriptLine.timestamp(session.offset + context.date.timeIntervalSince(session.startedAt)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
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
    /// Without it, tasks show as plain bullets.
    var onToggleTask: ((ActionItem) -> Void)?
    /// Shown beside the heading of the first task list.
    var tasksAccessory: AnyView?

    private enum Block {
        case heading(String, accessory: Bool)
        case paragraph(String)
        case bullet(String, nested: Bool)
        case numbered(String, String)
        case task(ActionItem)
    }

    var body: some View {
        let blocks = blocks
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block)
                    .padding(.top, spacing(before: index, in: blocks))
            }
        }
        .font(.system(size: 15))
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let text, let accessory):
            HStack(alignment: .firstTextBaseline) {
                Text(inline(text)).font(.system(size: 18, weight: .semibold))
                if accessory, let tasksAccessory {
                    Spacer()
                    tasksAccessory.font(.callout)
                }
            }
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
        case .task(let item) where onToggleTask == nil:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text("\(Text(inline(item.text)))\(ownerText(item))")
            }
        case .task(let item):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { onToggleTask?(item) } label: {
                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.done ? Color.accentColor : .secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.done ? "Mark as not done" : "Mark as done")
                Text("\(Text(inline(item.text)).strikethrough(item.done))\(ownerText(item))")
                    .foregroundStyle(item.done ? .secondary : .primary)
            }
        }
    }

    private func ownerText(_ item: ActionItem) -> Text {
        guard let owner = item.owner else { return Text("") }
        return Text("  " + (item.isMine ? "You" : owner)).font(.callout.weight(.medium)).foregroundStyle(.secondary)
    }

    private func spacing(before index: Int, in blocks: [Block]) -> CGFloat {
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
        let tasks = Dictionary(ActionItem.parse(markdown).map { ($0.line, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Block] = []
        var paragraph: [String] = []
        var lastHeading: Int?
        var accessoryPlaced = tasksAccessory == nil
        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for (index, rawLine) in markdown.components(separatedBy: "\n").enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if let item = tasks[index] {
                flush()
                if !accessoryPlaced, let heading = lastHeading, case .heading(let text, _) = result[heading] {
                    result[heading] = .heading(text, accessory: true)
                    accessoryPlaced = true
                }
                result.append(.task(item))
            } else if let match = line.firstMatch(of: /^#{1,6}\s+(.+)$/) {
                flush()
                lastHeading = result.count
                result.append(.heading(String(match.1), accessory: false))
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

/// "Add to Reminders" for a meeting's open items, or a note that they're already there.
struct RemindersButton: View {
    @ObservedObject var coordinator: AppCoordinator
    let note: Note
    /// The meeting page also takes tasks nobody owns; the Mine list shows only the user's.
    var includeUnowned = true

    var body: some View {
        let open = ActionItem.parse(note.body).filter { !$0.done && ($0.isMine || (includeUnowned && $0.owner == nil)) }
        let unsent = open.filter { !$0.wasSent(note.sentToReminders) }
        if !open.isEmpty {
            if unsent.isEmpty {
                Label("In Reminders", systemImage: "checkmark")
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            } else {
                Button(unsent.count == open.count ? "Add to Reminders" : "Add \(unsent.count) to Reminders") {
                    Task { await coordinator.addToReminders(unsent, noteID: note.id) }
                }
                .buttonStyle(.link)
                .disabled(coordinator.sendingToReminders.contains(note.id))
            }
        }
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


// MARK: - Speakers

/// Names the other side of the call. One name labels the transcript; any names help the write-up.
private struct SpeakersEditor: View {
    @ObservedObject var coordinator: AppCoordinator
    let note: Note
    @Environment(\.dismiss) private var dismiss
    @State private var names = ""
    @State private var original = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Who else was on the call?").font(.headline)
            TextField("Names, separated by commas", text: $names)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit(save)
            if !suggestions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(suggestions, id: \.self) { name in
                        Button("+ \(name)") { add(name) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
            Text("Helps the AI say who said what and spell names right. With one name, the transcript shows it instead of “Others”.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if coordinator.canWriteUp(note), !note.edited, parsed != Self.parse(original) {
                    Button("Save and Update Summary") {
                        save()
                        coordinator.writeUpNote(note.id)
                    }
                }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onAppear {
            names = note.participants.joined(separator: ", ")
            original = names
        }
    }

    private var parsed: [String] { Self.parse(names) }

    private static func parse(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Owners of action items are usually the other people on the call.
    private var suggestions: [String] {
        let current = Set(parsed.map { $0.lowercased() })
        return ActionItem.otherOwners(in: note.body).filter { !current.contains($0.lowercased()) }.prefix(4).map { $0 }
    }

    private func add(_ name: String) {
        names = (parsed + [name]).joined(separator: ", ")
    }

    private func save() {
        let list = parsed
        coordinator.notes.modify(note.id, keepOrder: true) { $0.participants = list }
        original = names
        dismiss()
    }
}

// MARK: - Action items

private struct ActionItemsPage: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var store: NotesStore
    private enum Scope { case mine, everyone }
    @State private var scope = Scope.mine
    @State private var showDone = false

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        store = coordinator.notes
    }

    private struct Group: Identifiable {
        let note: Note
        let items: [ActionItem]
        var id: UUID { note.id }
    }

    var body: some View {
        let groups = groups
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.items, id: \.self) { item in
                        ActionItemRow(item: item, showOwner: scope == .everyone) {
                            coordinator.toggleActionItem(group.note.id, item: item)
                        }
                        .contextMenu {
                            NavigationLink("Open Meeting", value: NotetakerRoute.note(group.note.id))
                        }
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        NavigationLink(value: NotetakerRoute.note(group.note.id)) {
                            HStack(spacing: 6) {
                                Text(group.note.title).foregroundStyle(.primary)
                                Text(group.note.createdAt.formatted(.dateTime.month(.abbreviated).day()))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        RemindersButton(coordinator: coordinator, note: group.note, includeUnowned: scope == .everyone)
                            .font(.callout)
                    }
                }
            }
            if !groups.isEmpty {
                Text("Ticking an item here ticks it in the meeting notes too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView(
                    hasAnyItems ? "All Done" : "No Action Items",
                    systemImage: "checklist.checked",
                    description: Text(scope == .mine ? "Action items assigned to you in your meeting notes appear here." : "Action items from your meeting notes appear here.")
                )
            }
        }
        .navigationTitle("Action Items")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $scope) {
                    Text("Mine").tag(Scope.mine)
                    Text("Everyone").tag(Scope.everyone)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $showDone) { Text("Show Completed") }
                    .toggleStyle(.button)
                    .help(showDone ? "Hide completed items" : "Show completed items")
            }
        }
    }

    private var groups: [Group] {
        store.notes.sorted { $0.createdAt > $1.createdAt }.compactMap { note in
            let items = ActionItem.parse(note.body).filter { (scope == .everyone || $0.isMine) && (showDone || !$0.done) }
            return items.isEmpty ? nil : Group(note: note, items: items)
        }
    }

    private var hasAnyItems: Bool {
        store.notes.contains { note in ActionItem.parse(note.body).contains { scope == .everyone || $0.isMine } }
    }
}

private struct ActionItemRow: View {
    let item: ActionItem
    let showOwner: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.done ? Color.accentColor : .secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.done ? "Mark as not done" : "Mark as done")
            Text(item.text)
                .strikethrough(item.done)
                .foregroundStyle(item.done ? .secondary : .primary)
            Spacer()
            if showOwner, let owner = item.owner {
                Text(item.isMine ? "You" : owner)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
            }
        }
        .padding(.vertical, 3)
    }
}
