import PressayCore
import SwiftUI

struct LiveMeetingView: View {
    @ObservedObject var session: LiveSession
    let title: String
    let earlierLines: [TranscriptLine]
    let othersLabel: String
    let speakerNames: [String]
    @Binding var myNotes: String
    let onStop: () -> Void
    let onDiscard: () -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { meetingReducesMotion(systemReduceMotion) }
    @State private var confirmingDiscard = false
    @State private var followingLatest = true

    private var finishing: Bool { session.phase == .finishing }
    private var allLines: [TranscriptLine] { earlierLines + session.lines }
    private var turns: [TranscriptLinesView.Turn] {
        TranscriptLinesView(lines: allLines, isMeeting: true).turns
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 734
            VStack(alignment: .leading, spacing: 25) {
                header
                if let notice = session.notice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(PressayPalette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: compact ? 14 : 18) {
                    panel("Live transcript", inset: compact ? 16 : 20) {
                        transcript(inset: compact ? 16 : 20)
                    }
                    panel("My notes", inset: compact ? 16 : 20) {
                        notesEditor(inset: compact ? 16 : 20)
                    }.frame(width: compact ? 220 : 252)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, compact ? 26 : 34).padding(.top, 48).padding(.bottom, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(PressayPalette.text).background(PressayPalette.base)
        .toolbarVisibility(.hidden, for: .windowToolbar)
        .sheet(isPresented: $confirmingDiscard) {
            PressayConfirmation(
                title: "Discard this recording?", detail: "The transcript and your notes will be deleted.",
                action: "Discard recording", destructive: true
            ) {
                confirmingDiscard = false
                onDiscard()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 15) {
                Text(title).font(.system(size: 28, weight: .semibold)).tracking(-0.8).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    Button("Discard recording…", role: .destructive) { confirmingDiscard = true }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 16)).frame(width: 32, height: 32)
                        .foregroundStyle(PressayPalette.muted)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .pressayInteraction().disabled(finishing)
                .accessibilityLabel("More meeting actions").help("More meeting actions")
                Button(action: onStop) {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).frame(width: 8, height: 8)
                        Text("Stop meeting")
                    }
                }
                .buttonStyle(PressayButtonStyle(kind: .danger)).disabled(finishing)
                .keyboardShortcut(.return, modifiers: .command).help("Stop meeting (⌘↩)")
            }
            HStack(spacing: 9) {
                if finishing {
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 9, height: 9)
                        .accessibilityHidden(true)
                } else {
                    Circle().fill(PressayPalette.danger).frame(width: 7, height: 7)
                }
                Text(finishing ? "Finishing…" : "Recording").foregroundStyle(PressayPalette.muted)
                TimelineView(.periodic(from: session.startedAt, by: 1)) { context in
                    Text(elapsedText(at: context.date)).monospacedDigit().fontWeight(.medium)
                }

            }.font(.system(size: 12)).frame(height: 18)
        }
    }

    private func elapsedText(at date: Date) -> String {
        let elapsed = session.offset + (session.stoppedAt ?? date).timeIntervalSince(session.startedAt)
        guard elapsed < 3600 else { return TranscriptLine.timestamp(elapsed) }
        let seconds = max(0, Int(elapsed))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func panel<Content: View>(
        _ title: String, inset: CGFloat, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).padding(.horizontal, inset)
            Rectangle().fill(PressayPalette.line).frame(height: 1)
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PressayPalette.surface).clipShape(.rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PressayPalette.line))
    }

    private func transcript(inset: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 23) {
                        if allLines.isEmpty {
                            VStack(spacing: 14) {
                                ListeningWaveform(active: !finishing)
                                Text(finishing ? "Finishing…" : "Listening…").font(.system(size: 13))
                            }
                            .foregroundStyle(PressayPalette.muted)
                            .frame(maxWidth: .infinity, minHeight: 220)
                            .containerRelativeFrame(.vertical)
                        } else {
                            ForEach(turns) { turn in
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                                        Text(speakerLabel(turn)).font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(
                                                turn.speaker == .me ? PressayPalette.accent : PressayPalette.text)
                                        Text(TranscriptLine.timestamp(turn.start)).font(.system(size: 10))
                                            .monospacedDigit().foregroundStyle(PressayPalette.muted)
                                    }
                                    Text(turn.text).font(.system(size: 13)).lineSpacing(6)
                                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            if session.pending > 0 {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.mini)
                                    Text("Transcribing…").font(.system(size: 11))
                                }.foregroundStyle(PressayPalette.muted)
                            }
                        }
                        if !allLines.isEmpty { Color.clear.frame(height: 1).id("latest") }
                    }.padding(.horizontal, inset).padding(.vertical, allLines.isEmpty ? 0 : 20)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height - geometry.visibleRect.maxY <= 32
                } action: { _, atBottom in
                    followingLatest = atBottom
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .onChange(of: allLines.count) { _, _ in
                    if followingLatest { scrollToLatest(proxy) }
                }
                .onChange(of: session.pending > 0) { _, _ in
                    if followingLatest { scrollToLatest(proxy) }
                }
                if !followingLatest {
                    Button {
                        followingLatest = true
                        scrollToLatest(proxy)
                    } label: {
                        Label("Latest", systemImage: "arrow.down").font(.system(size: 11))
                    }.buttonStyle(PressayButtonStyle()).padding(.bottom, 14)
                }
            }
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("latest", anchor: .bottom) }
    }

    private func speakerLabel(_ turn: TranscriptLinesView.Turn) -> String {
        if turn.speaker == .me { return "You" }
        return TranscriptLine(speaker: .others, start: 0, text: "", voice: turn.voice)
            .voiceLabel(names: speakerNames) ?? othersLabel
    }

    private func notesEditor(inset: CGFloat) -> some View {
        TextEditor(text: $myNotes).font(.system(size: 13)).lineSpacing(6)
            .scrollContentBackground(.hidden).padding(.leading, -5)
            .padding(.horizontal, inset).padding(.vertical, 18)
            .overlay(alignment: .topLeading) {
                if myNotes.isEmpty {
                    Text("Add a note…").font(.system(size: 13)).foregroundStyle(PressayPalette.muted)
                        .padding(.horizontal, inset).padding(.top, 18).allowsHitTesting(false)
                }
            }
            .disabled(finishing).accessibilityLabel("My meeting notes")
    }
}

/// A waiting rhythm rather than a simulated input level. Reduced Motion keeps a fixed waveform.
private struct ListeningWaveform: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { meetingReducesMotion(systemReduceMotion) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !active)) { context in
            let time = reduceMotion || !active ? 0 : context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<5) { index in
                    let wave = (sin(time * 2.6 - Double(index) * 0.7) + 1) / 2
                    Capsule().frame(width: 2, height: [9.0, 19, 27, 19, 9][index] * (0.55 + wave * 0.45))
                }
            }.frame(width: 30, height: 30)
        }.accessibilityHidden(true)
    }
}

@MainActor
private func meetingReducesMotion(_ systemValue: Bool) -> Bool {
    #if DEBUG
        if DesignReview.enabled, ProcessInfo.processInfo.environment["PRESSAY_REVIEW_REDUCE_MOTION"] == "1" {
            return true
        }
    #endif
    return systemValue
}
