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

struct NotetakerPage: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var store: NotesStore
    @ObservedObject private var settings: AppSettings
    @State private var path: [NotetakerRoute] = []
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
        .overlay(alignment: .bottomTrailing) {
            if store.notes.contains(where: \.hasTranscript) {
                AskChat(coordinator: coordinator, noteID: askNoteID)
            }
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
                    let first = store.notes.max(by: { $0.createdAt < $1.createdAt })
                {
                    path =
                        ProcessInfo.processInfo.environment["PRESSAY_OPEN_NOTE"] == "actions"
                        ? [.actionItems] : [.note(first.id)]
                }
            }
        #endif
    }

    /// The meeting on screen, when it has a transcript to ask about.
    private var askNoteID: UUID? {
        guard case .note(let id)? = path.last, store.note(id)?.hasTranscript == true,
            coordinator.liveSession?.noteID != id
        else { return nil }
        return id
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

    private var home: some View {
        let openItemCount = store.openActionItemCount
        return PressayPage(lazy: true) {
            PressayHeading(title: "Notetaker") {
                HStack(spacing: 8) {
                    StartNotetakerButton(coordinator: coordinator, prominent: true)
                    Button {
                        coordinator.openNotetakerSettings()
                    } label: {
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }
                }
            }
            if coordinator.meetingStarting {
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large)
                    Text("Preparing meeting").font(.system(size: 19, weight: .semibold))
                    Text(coordinator.modelStatus).font(.system(size: 12)).foregroundStyle(PressayPalette.muted)
                    if let value = coordinator.modelDownloadProgress { ProgressView(value: value).frame(width: 220) }
                    Button("Cancel") { coordinator.cancelMeetingStart() }
                }.frame(maxWidth: .infinity, minHeight: 450)
            } else if store.notes.isEmpty {
                PressayEmpty(
                    title: "No meetings yet",
                    detail: "Start Notetaker for a call or an in-person meeting. Your meetings will appear here.", systemImage: "person.2")
            } else {
                if openItemCount > 0 {
                    NavigationLink(value: NotetakerRoute.actionItems) {
                        HStack(spacing: 12) {
                            Image(systemName: "checklist").font(.system(size: 18)).foregroundStyle(
                                PressayPalette.accent)
                            Text("\(openItemCount) open action \(openItemCount == 1 ? "item" : "items") for you").font(
                                .system(size: 12))
                            Spacer();
                            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(
                                PressayPalette.muted)
                        }.contentShape(.rect)
                    }.buttonStyle(PressayPlainButtonStyle()).padding(.bottom, 20)
                    Rectangle().fill(PressayPalette.line).frame(height: 1).padding(.bottom, 24)
                }
                PressaySection(title: "Recent meetings") {
                    PressayGroup(lazy: true) {
                        ForEach(store.notes.sorted { $0.createdAt > $1.createdAt }) { note in
                            NavigationLink(value: NotetakerRoute.note(note.id)) {
                                HStack(spacing: 12) {
                                    Image(systemName: "person.2.wave.2").font(.system(size: 18)).foregroundStyle(
                                        PressayPalette.accent
                                    )
                                    .frame(width: 34, height: 34).background(
                                        PressayPalette.accentSurface, in: .rect(cornerRadius: 8))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(note.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                        Text(
                                            [
                                                note.createdAt.formatted(date: .abbreviated, time: .shortened),
                                                note.durationText, note.participants.joined(separator: ", "),
                                            ].filter { !$0.isEmpty }.joined(separator: " · ")
                                        )
                                        .font(.system(size: 10)).foregroundStyle(PressayPalette.muted).lineLimit(1)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Text(
                                        note.formatting
                                            ? "Writing up…" : note.body.isEmpty ? "Transcript only" : "Written up"
                                    )
                                    .font(.system(size: 10, weight: .medium)).foregroundStyle(
                                        note.body.isEmpty ? PressayPalette.muted : PressayPalette.success
                                    )
                                    .padding(.horizontal, 9).padding(.vertical, 4)
                                    .background(
                                        note.body.isEmpty ? PressayPalette.button : PressayPalette.successSurface,
                                        in: .capsule)
                                }.padding(.horizontal, 18).padding(.vertical, 15).contentShape(.rect)
                            }.buttonStyle(PressayPlainButtonStyle())
                                .overlay(alignment: .bottom) { Rectangle().fill(PressayPalette.line).frame(height: 1) }
                                .contextMenu {
                                    NoteMenuItems(
                                        coordinator: coordinator, note: note, onDelete: { deleting = note.id })
                                }
                        }
                    }
                }
            }
        }.navigationTitle("")
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

struct StartNotetakerButton: View {
    @ObservedObject var coordinator: AppCoordinator
    var prominent = false

    var body: some View {
        if coordinator.meetingStarting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(coordinator.modelStatus).font(.caption)
                Button("Cancel") { coordinator.cancelMeetingStart() }
            }
        } else {
            Button {
                coordinator.startMeeting()
            } label: {
                Label("Start Notetaker", systemImage: "plus")
            }
            .buttonStyle(PressayButtonStyle(kind: prominent ? .primary : .standard))
            .disabled(coordinator.liveSession != nil)
        }
    }
}

extension Note {
    var hasTranscript: Bool { !lines.isEmpty }

    var durationText: String {
        guard duration >= 60 else { return "under 1 min" }
        return Duration.seconds(duration).formatted(
            .units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    }
}

// MARK: - Note page

private struct NotePage: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var store: NotesStore
    let id: UUID
    let onDelete: () -> Void
    #if DEBUG
        @State private var tab =
            ProcessInfo.processInfo.environment["PRESSAY_OPEN_NOTE"].flatMap(NoteTab.init(rawValue:))
            ?? .summary
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
                LiveMeetingView(
                    session: session,
                    title: store.note(id)?.title ?? "Meeting",
                    onStop: { coordinator.stopRecording() },
                    onDiscard: coordinator.discardRecording
                )
                .navigationTitle("")
                .navigationBarBackButtonHidden(true)
            } else if let note = store.note(id) {
                VStack(spacing: 0) {
                    header(for: note)
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
                }
                .background(PressayPalette.base)
                .navigationTitle("")
                .navigationBarBackButtonHidden(true)
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

    private func header(for note: Note) -> some View {
        HStack(spacing: 16) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "arrow.left")
                    .font(.system(size: 13))
                    .frame(width: 26, height: 30)
            }
            .buttonStyle(PressayPlainButtonStyle()).foregroundStyle(PressayPalette.muted)
            .help("Back to Notetaker").accessibilityLabel("Back to Notetaker")
            Rectangle().fill(PressayPalette.line).frame(width: 1, height: 16)
            HStack(spacing: 0) {
                ForEach(NoteTab.allCases, id: \.self) { choice in
                    Button {
                        tab = choice
                    } label: {
                        Text(choice.title)
                            .font(.system(size: 13, weight: tab == choice ? .semibold : .medium))
                            .foregroundStyle(tab == choice ? PressayPalette.text : PressayPalette.muted)
                            .fixedSize()
                            .frame(height: 56)
                            .overlay(alignment: .bottom) {
                                if tab == choice {
                                    Rectangle().fill(PressayPalette.accent).frame(height: 2)
                                }
                            }
                            .padding(.horizontal, 11)
                            // The whole tab is clickable, not just the glyphs.
                            .contentShape(.rect)
                    }
                    .buttonStyle(PressayPlainButtonStyle())
                    .accessibilityAddTraits(tab == choice ? .isSelected : [])
                }
            }
            .disabled(editing || !note.hasTranscript)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if !editing { RemindersButton(coordinator: coordinator, note: note).font(.callout).padding(.trailing, 6) }
                Button(editing ? "Done" : "Edit") { editing.toggle() }
                    .buttonStyle(PressayButtonStyle())
                    .disabled(tab != .summary || (!editing && note.formatting))
                    .help(editing ? "Finish editing" : "Edit the summary")
                ShareLink(item: note.exportText, subject: Text(note.title)) {
                    Image(systemName: "square.and.arrow.up").frame(width: 14)
                }
                .buttonStyle(PressayButtonStyle(kind: .quiet))
                .help("Share meeting").accessibilityLabel("Share meeting")
                Menu {
                    NoteMenuItems(coordinator: coordinator, note: note, onDelete: onDelete)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 14, height: 30)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .pressayInteraction()
                .foregroundStyle(PressayPalette.muted)
                .help("More meeting actions").accessibilityLabel("More meeting actions")
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 56)
        .background(PressayPalette.base)
        .overlay(alignment: .bottom) { Rectangle().fill(PressayPalette.line).frame(height: 1) }
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
                .font(.system(size: 28, weight: .semibold))
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                if note.duration >= 60 {
                    Text("·")
                    Text(note.durationText)
                }
                if note.kind == .meeting {
                    Text("·")
                    Text(speakerChips.joined(separator: ", "))
                    Button(note.hasNames ? "Edit names" : "Add names") { editingNames = true }
                        .buttonStyle(.link).pressayInteraction()
                        .help("Who else was on the call")
                        .popover(isPresented: $editingNames, arrowEdge: .bottom) {
                            if note.voices.isEmpty {
                                SpeakersEditor(coordinator: coordinator, note: note)
                            } else {
                                VoiceNamesEditor(coordinator: coordinator, note: note)
                            }
                        }
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(PressayPalette.muted)
        }
        .padding(.bottom, 20)
    }

    /// Who spoke: "You" only when the mic picked you up, then the other side.
    private var speakerChips: [String] {
        let others = note.lines.contains { $0.speaker == .others }
        var chips = note.lines.contains { $0.speaker == .me } ? ["You"] : []
        if !note.voices.isEmpty {
            chips += note.speakerLabels
        } else if !note.participants.isEmpty {
            chips += note.participants
        } else if others {
            chips.append("Others")
        }
        var seen = Set<String>()
        return chips.filter { seen.insert($0).inserted }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 28, weight: .semibold))
            TextEditor(text: $text)
                .font(.system(size: 15))
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: 700, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 40)
        .padding(.top, 28)
        .frame(maxWidth: .infinity)
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
                Text("Connect an Anthropic API key or a ChatGPT subscription to write a summary, decisions and action items. The full transcript is in the Transcript tab.")
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
            .frame(maxWidth: 700)
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity)
            // Full width, so the scroller sits at the window edge rather than beside the text.
            MyNotesEditor(text: $myNotes, fontSize: 15, column: 700)
        }
        .padding(.top, 28)
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
                TranscriptLinesView(
                    lines: note.lines, isMeeting: note.kind == .meeting,
                    othersLabel: note.othersLabel, speakerNames: note.speakerNames, highlight: query
                )
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var summaryLine: String {
        let mine = note.lines.contains { $0.speaker == .me }
        let speakers = note.voices.isEmpty ? Set(note.lines.map(\.speaker)).count : note.voices.count + (mine ? 1 : 0)
        let length = TranscriptLine.timestamp(max(note.duration, note.lines.last?.start ?? 0))
        guard note.kind == .meeting else { return length }
        let who: String
        if speakers == 1 {
            who = "1 speaker"
        } else if note.speakerLabels.isEmpty {
            who = "You and others"
        } else {
            who = ((mine ? ["You"] : []) + note.speakerLabels).formatted(.list(type: .and))
        }
        return "\(who) · \(length)"
    }
}

/// Meetings show turns as chat bubbles, yours on the right; long turns split about every 45 s.
struct TranscriptLinesView: View {
    let lines: [TranscriptLine]
    let isMeeting: Bool
    var othersLabel = "Others"
    var speakerNames: [String] = []
    var highlight = ""

    struct Turn: Identifiable {
        let id: Int
        let speaker: TranscriptLine.Speaker
        let voice: Int?
        let start: TimeInterval
        var text: String
    }

    var body: some View {
        let visibleTurns = visibleTurns
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
                Text(label(turn)).fontWeight(.semibold)
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

    private func label(_ turn: Turn) -> String {
        if turn.speaker == .me { return "You" }
        return TranscriptLine(speaker: .others, start: 0, text: "", voice: turn.voice).voiceLabel(names: speakerNames) ?? othersLabel
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
            if var last = result.last, last.speaker == line.speaker, last.voice == line.voice, line.start - last.start < 45 {
                last.text += " " + line.text
                result[result.count - 1] = last
            } else {
                result.append(Turn(id: index, speaker: line.speaker, voice: line.voice, start: line.start, text: line.text))
            }
        }
        return result
    }
}

// MARK: - Ask anything

/// A chat in the bottom-right corner, about the open meeting or all of them.
struct AskChat: View {
    @ObservedObject var coordinator: AppCoordinator
    /// The meeting on screen, if any.
    let noteID: UUID?

    private struct Exchange: Identifiable {
        let id = UUID()
        let question: String
        var answer: String?
        var failed = false
    }

    #if DEBUG
        @State private var open = ProcessInfo.processInfo.environment["PRESSAY_REVIEW_ASK"] == "1"
    #else
        @State private var open = false
    #endif
    @State private var question = ""
    @State private var exchanges: [Exchange] = []
    @State private var allMeetings = false
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if open {
                panel.transition(.scale(scale: 0.92, anchor: .bottomTrailing).combined(with: .opacity))
            } else {
                launcher.transition(.opacity)
            }
        }
        .padding(20)
        .onChange(of: scope) { _, _ in newChat() }
    }

    private var scope: UUID? { allMeetings ? nil : noteID }

    private var launcher: some View {
        Button {
            withAnimation(.snappy) { open = true }
            focused = true
        } label: {
            Label("Ask", systemImage: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16)
                .frame(height: 38)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help(noteID == nil ? "Ask about your meetings" : "Ask about this meeting")
        .keyboardShortcut("j", modifiers: .command)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            messages
            input
        }
        .frame(width: 380, height: 500)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .onExitCommand { close() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if noteID != nil {
                Picker("Ask about", selection: $allMeetings) {
                    Text("This meeting").tag(false)
                    Text("All meetings").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            } else {
                Text("All meetings").font(.system(size: 13, weight: .semibold))
            }
            Spacer()
            Button(action: newChat) { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless).pressayInteraction()
                .disabled(exchanges.isEmpty)
                .help("New chat")
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(.borderless).pressayInteraction()
                .help("Close")
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if exchanges.isEmpty { suggestions }
                    ForEach(exchanges) { exchange in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(exchange.question)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(PressayPalette.accentSurface, in: .rect(cornerRadius: 14))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            if let answer = exchange.answer {
                                MarkdownNoteBody(markdown: answer, fontSize: 13.5, dimmed: exchange.failed)
                            } else {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text(scope == nil ? "Reading your meetings…" : "Reading the meeting…")
                                        .foregroundStyle(.secondary)
                                }
                                .font(.system(size: 13))
                            }
                        }
                        .id(exchange.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .onChange(of: exchanges.count) { _, _ in
                if let last = exchanges.last { withAnimation { proxy.scrollTo(last.id, anchor: .top) } }
            }
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(scope == nil ? "Ask anything across your meetings." : "Ask anything about this meeting.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .padding(.bottom, 4)
            ForEach(scope == nil ? Self.acrossMeetings : Self.aboutMeeting, id: \.self) { prompt in
                Button {
                    send(prompt)
                } label: {
                    Text(prompt)
                        .font(.system(size: 13))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(PressayPalette.button, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .disabled(!available)
            }
        }
    }

    private static let aboutMeeting = ["What did we decide?", "What do I need to do?", "Write a follow-up email"]
    private static let acrossMeetings = ["What do I owe people?", "Summarize this week’s meetings", "What’s still unresolved?"]

    private var input: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit { send(question) }
                .disabled(!available)
                .padding(.vertical, 4)
            Button {
                send(question)
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
            }
            .buttonStyle(.borderless).pressayInteraction()
            .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy || !available)
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
        .background(PressayPalette.base.opacity(0.6), in: .rect(cornerRadius: 16))
        .padding(10)
    }

    private var available: Bool { coordinator.notesModel != nil && coordinator.settings.notesUseAI }

    private var placeholder: String {
        if coordinator.notesModel == nil { return "Set up AI in Settings to ask" }
        if !coordinator.settings.notesUseAI { return "AI is off in Notetaker settings" }
        return exchanges.isEmpty ? "Ask a question" : "Ask a follow-up"
    }

    private var busy: Bool { exchanges.last.map { $0.answer == nil } ?? false }

    private func close() {
        withAnimation(.snappy) { open = false }
    }

    private func newChat() {
        task?.cancel()
        exchanges = []
        question = ""
    }

    private func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy, available else { return }
        question = ""
        let history = exchanges.compactMap { exchange in
            exchange.answer.flatMap { exchange.failed ? nil : MeetingAskPrompt.Exchange(question: exchange.question, answer: $0) }
        }
        let exchange = Exchange(question: text)
        exchanges.append(exchange)
        let scope = scope
        task = Task {
            let answer: String
            var failed = false
            do {
                answer = try await coordinator.ask(text, history: history, about: scope)
            } catch {
                answer = error.localizedDescription
                failed = true
            }
            guard !Task.isCancelled, let index = exchanges.firstIndex(where: { $0.id == exchange.id }) else { return }
            exchanges[index].answer = answer
            exchanges[index].failed = failed
        }
    }
}

// MARK: - Live

struct MyNotesEditor: View {
    @Binding var text: String
    var fontSize: CGFloat = 14
    /// A centred reading column inside a full-width editor; nil fills the space.
    var column: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let inset = column.map { max(40, (proxy.size.width - $0) / 2) } ?? 0
            TextEditor(text: $text)
                .font(.system(size: fontSize))
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .contentMargins(.horizontal, inset, for: .scrollContent)
                .padding(.leading, -5)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Jot down anything that matters…")
                            .font(.system(size: fontSize))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, inset)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}

/// The Markdown subset notes use: headings, lists, checkboxes, inline emphasis.
/// One text view for the whole note, so a selection can run across paragraphs like a document.
struct MarkdownNoteBody: View {
    let markdown: String
    /// Without it, tasks show as plain bullets.
    var onToggleTask: ((ActionItem) -> Void)?
    var fontSize: CGFloat = 15
    var dimmed = false

    private enum Block {
        case heading(String)
        case paragraph(String)
        case bullet(String, nested: Bool)
        case numbered(String, String)
        case task(ActionItem)
        case othersHeading
        case othersTask(ActionItem)
    }

    var body: some View {
        let blocks = blocks
        let tasks = blocks.compactMap { if case .task(let item) = $0 { item } else { nil } }
        SelectableText(text: attributed(blocks)) { url in
            guard url.scheme == "pressay-task", let line = Int(url.host() ?? ""),
                let item = tasks.first(where: { $0.line == line })
            else { return }
            onToggleTask?(item)
        }
    }

    private func attributed(_ blocks: [Block]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: fontSize)
        let primary = dimmed ? NSColor.secondaryLabelColor : NSColor.labelColor
        for (index, block) in blocks.enumerated() {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = spacing(before: index, in: blocks)
            style.lineSpacing = 3
            var line = NSMutableAttributedString()
            func append(_ text: String, _ attributes: [NSAttributedString.Key: Any] = [:]) {
                line.append(NSAttributedString(string: text, attributes: [.font: body, .foregroundColor: primary].merging(attributes) { $1 }))
            }
            func hang(_ indent: CGFloat, marker: CGFloat = 0) {
                style.firstLineHeadIndent = marker
                style.headIndent = indent
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            }
            switch block {
            case .heading(let text):
                line = inline(text, font: .systemFont(ofSize: fontSize + 3, weight: .semibold), color: primary)
            case .paragraph(let text):
                style.lineSpacing = 4
                line = inline(text, font: body, color: primary)
            case .bullet(let text, let nested):
                hang(nested ? 36 : 16, marker: nested ? 20 : 0)
                append((nested ? "◦" : "•") + "\t", [.foregroundColor: NSColor.secondaryLabelColor])
                line.append(inline(text, font: body, color: primary))
            case .numbered(let number, let text):
                hang(22)
                append(number + "\t", [.foregroundColor: NSColor.secondaryLabelColor])
                line.append(inline(text, font: body, color: primary))
            case .othersHeading:
                line = NSMutableAttributedString(string: "For others", attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize - 2, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
                ])
            case .othersTask(let item):
                hang(16)
                append("•\t", [.foregroundColor: NSColor.secondaryLabelColor])
                append((item.owner ?? "") + "  ", [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
                line.append(inline(item.text, font: body, color: .secondaryLabelColor, struck: item.done))
            case .task(let item):
                hang(24)
                if onToggleTask == nil {
                    append("•\t", [.foregroundColor: NSColor.secondaryLabelColor])
                } else {
                    line.append(checkbox(item, height: fontSize))
                    append("\t")
                }
                line.append(inline(item.text, font: body, color: item.done ? .secondaryLabelColor : primary, struck: item.done))
                if let owner = item.owner {
                    append("  " + (item.isMine ? "You" : owner), [
                        .font: NSFont.systemFont(ofSize: fontSize - 2, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor,
                    ])
                }
            }
            if index < blocks.count - 1 { line.append(NSAttributedString(string: "\n", attributes: [.font: body])) }
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            result.append(line)
        }
        return result
    }

    private func checkbox(_ item: ActionItem, height: CGFloat) -> NSAttributedString {
        let config = NSImage.SymbolConfiguration(pointSize: height + 1, weight: .regular)
            .applying(.init(paletteColors: [item.done ? .controlAccentColor : .secondaryLabelColor]))
        let attachment = NSTextAttachment()
        attachment.image = NSImage(
            systemSymbolName: item.done ? "checkmark.circle.fill" : "circle",
            accessibilityDescription: item.done ? "Mark as not done" : "Mark as done"
        )?.withSymbolConfiguration(config)
        if let size = attachment.image?.size {
            attachment.bounds = CGRect(x: 0, y: -(size.height - height) / 2 - 2, width: size.width, height: size.height)
        }
        let box = NSMutableAttributedString(attachment: attachment)
        box.addAttribute(.link, value: URL(string: "pressay-task://\(item.line)")!, range: NSRange(location: 0, length: box.length))
        return box
    }

    private func spacing(before index: Int, in blocks: [Block]) -> CGFloat {
        guard index > 0 else { return 0 }
        switch (blocks[index - 1], blocks[index]) {
        case (_, .heading): return 22
        case (.heading, _): return 8
        case (.bullet, .bullet), (.numbered, .numbered), (.task, .task), (.othersTask, .othersTask): return 6
        case (_, .othersHeading): return 16
        case (.othersHeading, _): return 6
        default: return 12
        }
    }

    private func inline(_ text: String, font: NSFont, color: NSColor, struck: Bool = false) -> NSMutableAttributedString {
        let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            var runFont = font
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.stronglyEmphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
            if intent.contains(.code) { runFont = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular) }
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: color]
            if struck { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }

    private var blocks: [Block] {
        let tasks = Dictionary(ActionItem.parse(markdown).map { ($0.line, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Block] = []
        var paragraph: [String] = []
        var run: [ActionItem] = []
        func flushParagraph() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        func flush() {
            flushParagraph()
            // Your tasks stay a checklist; other people's are listed after, by person, for reference.
            guard !run.isEmpty else { return }
            let others = run.filter { $0.owner != nil && !$0.isMine }
            result += run.filter { $0.owner == nil || $0.isMine }.map(Block.task)
            if !others.isEmpty {
                let order = others.compactMap(\.owner).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                result.append(.othersHeading)
                result += order.flatMap { owner in others.filter { $0.owner == owner } }.map(Block.othersTask)
            }
            run = []
        }
        for (index, rawLine) in markdown.components(separatedBy: "\n").enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flushParagraph(); continue }
            if let item = tasks[index] {
                flushParagraph()
                run.append(item)
            } else if let match = line.firstMatch(of: /^#{1,6}\s+(.+)$/) {
                flush()
                result.append(.heading(String(match.1)))
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
                .buttonStyle(.link).pressayInteraction()
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
        PressaySheet(title: "Who was on the call?", width: 410) {
            Text("Names help identify speakers and correct spelling.").font(.system(size: 12)).foregroundStyle(
                PressayPalette.muted
            ).padding(.top, -12).padding(.bottom, 22)
            Text("Names").font(.system(size: 12, weight: .semibold)).padding(.bottom, 8)
            TextField("Names", text: $names).modifier(PressayField()).onSubmit(save)
            Text("Separate names with commas. This helps Pressay spell names correctly and attribute the conversation.")
                .font(.system(size: 11)).foregroundStyle(PressayPalette.muted).padding(.top, 10)
            Rectangle().fill(PressayPalette.line).frame(height: 1).padding(.top, 24)
            HStack(spacing: 8) {
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).buttonStyle(PressayButtonStyle(kind: .primary)).keyboardShortcut(
                    .defaultAction)
            }.padding(.top, 18)
        }.onAppear {
            names = note.participants.joined(separator: ", "); original = names
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

/// Names each told-apart voice; the transcript and the write-up use the names.
private struct VoiceNamesEditor: View {
    @ObservedObject var coordinator: AppCoordinator
    let note: Note
    @Environment(\.dismiss) private var dismiss
    @State private var names: [String] = []
    @State private var original: [String] = []

    var body: some View {
        PressaySheet(title: "Speaker names", width: 410) {
            Text("Update the speaker labels used in your transcript.").font(.system(size: 12)).foregroundStyle(
                PressayPalette.muted
            ).padding(.top, -12).padding(.bottom, 22)
            ForEach(Array(names.indices), id: \.self) { index in
                Text("Speaker \(index + 1)").font(.system(size: 12, weight: .semibold)).padding(.bottom, 8)
                TextField("Name", text: $names[index]).modifier(PressayField()).onSubmit(save).padding(.bottom, 18)
            }
            Text("Use the existing Transcript tab to check which voice belongs to each person.").font(.system(size: 11))
                .foregroundStyle(PressayPalette.muted)
            Rectangle().fill(PressayPalette.line).frame(height: 1).padding(.top, 24)
            HStack(spacing: 8) {
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).buttonStyle(PressayButtonStyle(kind: .primary)).keyboardShortcut(
                    .defaultAction)
            }.padding(.top, 18)
        }.onAppear {
            let count = note.voices.max() ?? 0
            names = (0..<count).map { note.speakerNames.indices.contains($0) ? note.speakerNames[$0] : "" }
            original = names
        }
    }

    private func trimmed(_ name: String) -> String { name.trimmingCharacters(in: .whitespaces) }

    /// Names the user typed before, and owners of action items, not yet used.
    private var suggestions: [String] {
        let used = Set(names.map { trimmed($0).lowercased() })
        var seen = Set<String>()
        return (note.participants + ActionItem.otherOwners(in: note.body))
            .filter { !used.contains($0.lowercased()) && seen.insert($0.lowercased()).inserted }
            .prefix(4).map { $0 }
    }

    private func fill(_ name: String) {
        guard let index = names.firstIndex(where: { trimmed($0).isEmpty }) else { return }
        names[index] = name
    }

    private func save() {
        let list = names.map(trimmed)
        coordinator.notes.modify(note.id, keepOrder: true) { note in
            note.speakerNames = list
            var seen = Set<String>()
            note.participants = list.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        }
        original = names
        dismiss()
    }
}

// MARK: - Action items

private struct ActionItemsPage: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var store: NotesStore
    @Environment(\.dismiss) private var dismiss
    @State private var completedThisVisit: Set<String> = []
    init(coordinator: AppCoordinator) { self.coordinator = coordinator; store = coordinator.notes }
    private struct Group: Identifiable { let note: Note; let items: [ActionItem]; var id: UUID { note.id } }
    private var groups: [Group] {
        store.notes.sorted { $0.createdAt > $1.createdAt }.compactMap { note in
            let items = store.actionItems(for: note.id).filter {
                $0.isMine && (!$0.done || completedThisVisit.contains(note.id.uuidString + $0.text))
            }
            return items.isEmpty ? nil : Group(note: note, items: items)
        }
    }
    var body: some View {
        let groups = groups
        PressayPage(lazy: true) {
            Button {
                dismiss()
            } label: {
                Label("Notetaker", systemImage: "chevron.left").font(.system(size: 11))
            }
            .buttonStyle(PressayPlainButtonStyle()).foregroundStyle(PressayPalette.muted).padding(.bottom, 18)
            PressayHeading(title: "Action items") { EmptyView() }
            if groups.isEmpty {
                PressayEmpty(title: "No open action items", detail: "Action items assigned to you in your meeting notes will appear here.", systemImage: "checkmark.circle", actionTitle: "Back to meetings", primaryAction: false, action: { dismiss() })
            }
            ForEach(groups) { group in
                HStack {
                    NavigationLink(group.note.title, value: NotetakerRoute.note(group.note.id)).buttonStyle(PressayPlainButtonStyle())
                        .font(.system(size: 13, weight: .semibold))
                    Text(group.note.createdAt.formatted(.dateTime.month(.abbreviated).day())).font(.system(size: 11))
                        .foregroundStyle(PressayPalette.muted)
                    Spacer()
                }.padding(.bottom, 12)
                PressayGroup(lazy: true) {
                    ForEach(group.items, id: \.self) { item in
                        HStack(spacing: 12) {
                            Toggle(
                                isOn: Binding(
                                    get: { item.done },
                                    set: { _ in
                                        completedThisVisit.insert(group.note.id.uuidString + item.text);
                                        coordinator.toggleActionItem(group.note.id, item: item)
                                    })
                            ) { Text(item.text) }
                            .toggleStyle(ActionItemToggleStyle())
                        }.padding(.horizontal, 18).padding(.vertical, 16)
                            .overlay(alignment: .bottom) { Rectangle().fill(PressayPalette.line).frame(height: 1) }
                            .contextMenu { NavigationLink("Open meeting", value: NotetakerRoute.note(group.note.id)) }
                    }
                }.padding(.bottom, 25)
            }
            if !groups.isEmpty {
                HStack {
                    Spacer()
                    Button {
                        Task {
                            for group in groups {
                                let items = group.items.filter { !$0.done && !$0.wasSent(group.note.sentToReminders) }
                                if !items.isEmpty { _ = await coordinator.addToReminders(items, noteID: group.note.id) }
                            }
                        }
                    } label: {
                        Label("Add to Reminders", systemImage: "checklist")
                    }
                    .disabled(!coordinator.sendingToReminders.isEmpty)
                }
            }
        }.navigationTitle("").navigationBarBackButtonHidden(true)
    }
}

private struct ActionItemToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Circle().strokeBorder(
                    configuration.isOn ? PressayPalette.accent : PressayPalette.strongLine, lineWidth: 1.3
                )
                .background(configuration.isOn ? PressayPalette.accentSurface : .clear, in: .circle)
                .overlay {
                    if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(
                            PressayPalette.accent)
                    }
                }
                .frame(width: 17, height: 17)
                configuration.label.font(.system(size: 12)).strikethrough(configuration.isOn).foregroundStyle(
                    configuration.isOn ? PressayPalette.muted : PressayPalette.text)
                Spacer()
            }.contentShape(.rect)
        }.buttonStyle(PressayPlainButtonStyle()).accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.checkbox)
        }
    }
}

struct HoverHighlight: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.primary.opacity(hovering ? 0.06 : 0))
                    .padding(.horizontal, -8)
                    .padding(.vertical, -2)
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    func hoverHighlight() -> some View { modifier(HoverHighlight()) }
}

/// A read-only, selectable text view sized to its content, for text SwiftUI can only select one block at a time.
struct SelectableText: NSViewRepresentable {
    let text: NSAttributedString
    var onLink: (URL) -> Void = { _ in }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        view.delegate = context.coordinator
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.onLink = onLink
        guard view.textStorage?.isEqual(to: text) != true else { return }
        let selection = view.selectedRanges
        view.textStorage?.setAttributedString(text)
        view.selectedRanges = selection.filter { NSMaxRange($0.rangeValue) <= text.length }.nonEmpty ?? [NSValue(range: NSRange())]
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 600
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(onLink: onLink) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onLink: (URL) -> Void
        init(onLink: @escaping (URL) -> Void) { self.onLink = onLink }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }
            if url.scheme == "pressay-task" { onLink(url) } else { NSWorkspace.shared.open(url) }
            return true
        }
    }
}

private extension Array {
    var nonEmpty: Self? { isEmpty ? nil : self }
}
