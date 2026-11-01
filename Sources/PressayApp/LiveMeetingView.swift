import PressayCore
import SwiftUI

struct LiveMeetingView: View {
    @ObservedObject var session: LiveSession
    let title: String
    let onStop: () -> Void
    let onDiscard: () -> Void

    @State private var confirmingDiscard = false

    private var finishing: Bool { session.phase == .finishing }

    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            header
            if let notice = session.notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(PressayPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 14) {
                ListeningWaveform(active: !finishing).foregroundStyle(PressayPalette.accent)
                Text(finishing ? "Saving your notes…" : "Taking notes").font(.system(size: 15, weight: .semibold))
                Text(finishing ? "Your summary will be ready in a moment." : "Stop the meeting when you’re done to get your summary.")
                    .font(.system(size: 13)).foregroundStyle(PressayPalette.muted)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 34).padding(.top, 48).padding(.bottom, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(PressayPalette.text).background(PressayPalette.base)
        .toolbarVisibility(.hidden, for: .windowToolbar)
        .sheet(isPresented: $confirmingDiscard) {
            PressayConfirmation(
                title: "Discard this recording?", detail: "The recording and its transcript will be deleted.",
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
