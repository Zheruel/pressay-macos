import AppKit
import SwiftUI

enum PressayPalette {
    static let base = adaptive(0x202125, 0xf6f6f8)
    static let surface = adaptive(0x27282d, 0xffffff)
    static let sidebar = adaptive(0x1a1b1f, 0xeaeaf0)
    static let text = adaptive(0xeeeef2, 0x252630)
    static let muted = adaptive(0xa0a1ac, 0x656772)
    static let navigation = adaptive(0xbbbdc7, 0x51535f)
    static let line = adaptive(0x38393f, 0xe1e2e8)
    static let strongLine = adaptive(0x474953, 0xcccdd7)
    static let button = adaptive(0x33353d, 0xf7f7fa)
    static let hover = adaptive(0x3a3c46, 0xe9eaf0)
    static let selected = adaptive(0x30323d, 0xd9dce9)
    static let accent = adaptive(0xa6b1ff, 0x505dca)
    static let accentText = adaptive(0x20243f, 0xffffff)
    static let accentSurface = adaptive(0x343951, 0xeceefe)
    static let success = adaptive(0x8dceaf, 0x26714a)
    static let successSurface = adaptive(0x293c34, 0xeaf5ef)
    static let warning = adaptive(0xecc48d, 0x825716)
    static let warningSurface = adaptive(0x393227, 0xfaf1df)
    static let updateTrack = adaptive(0x292b31, 0xdfe0e7)
    static let updateFill = adaptive(0x454851, 0xc3c6d1)
    static let updateSecondary = adaptive(0xbfc1cb, 0x4f515d)
    static let danger = adaptive(0xf4a0a2, 0xb63c43)

    private static func adaptive(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return NSColor(
                    srgbRed: Double((value >> 16) & 255) / 255,
                    green: Double((value >> 8) & 255) / 255,
                    blue: Double(value & 255) / 255, alpha: 1)
            })
    }
}

private struct PressayInteraction: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(PressayPalette.text.opacity(isEnabled && hovering ? 0.08 : 0))
                    .allowsHitTesting(false)
            }
            .pointerStyle(isEnabled ? .link : nil)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isEnabled && hovering)
    }
}

extension View {
    func pressayInteraction(cornerRadius: CGFloat = 6) -> some View {
        modifier(PressayInteraction(cornerRadius: cornerRadius))
    }
}

struct PressayPlainButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(.rect)
            .pressayInteraction()
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.7 : 1)
    }
}

struct PressayButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    enum Kind { case standard, primary, quiet, danger }
    var kind: Kind = .standard
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, kind == .quiet ? 8 : 12)
            .frame(minHeight: 32)
            .foregroundStyle(
                kind == .primary
                    ? PressayPalette.accentText : kind == .danger ? PressayPalette.danger : PressayPalette.text
            )
            .background(
                kind == .primary ? PressayPalette.accent : kind == .quiet ? .clear : PressayPalette.button,
                in: .rect(cornerRadius: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6).strokeBorder(
                    kind == .quiet ? .clear : PressayPalette.strongLine, lineWidth: 1)
            )
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.7 : 1)
            .contentShape(.rect(cornerRadius: 6))
            .pressayInteraction()
    }
}

struct PressaySwitchStyle: ToggleStyle {
    var showsLabel = true
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            if showsLabel {
                configuration.label
                Spacer(minLength: 8)
            }
            Button {
                configuration.isOn.toggle()
            } label: {
                Capsule().fill(configuration.isOn ? PressayPalette.accent : PressayPalette.strongLine)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 14, height: 14).padding(2)
                    }
                    .frame(width: 32, height: 18)
            }
            .buttonStyle(PressayPlainButtonStyle())
        }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }
}

struct PressayPage<Content: View>: View {
    var lazy = false
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            Group {
                if lazy {
                    LazyVStack(alignment: .leading, spacing: 0) { content }
                } else {
                    VStack(alignment: .leading, spacing: 0) { content }
                }
            }
                .frame(maxWidth: 800, alignment: .leading)
                .padding(.horizontal, 34).padding(.top, 52).padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.hidden)
        .background(PressayPalette.base)
    }
}

struct PressayHeading<Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var actions: Actions
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 28, weight: .semibold)).tracking(-0.8)
                if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(PressayPalette.muted) }
            }
            Spacer(minLength: 0)
            actions.padding(.top, 3)
        }.padding(.bottom, 30)
    }
}

struct PressayGroup<Content: View>: View {
    var lazy = false
    @ViewBuilder var content: Content
    var body: some View {
        Group {
            if lazy {
                LazyVStack(spacing: 0) { content }
            } else {
                VStack(spacing: 0) { content }
            }
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PressayPalette.surface)
            .clipShape(.rect(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(PressayPalette.line, lineWidth: 1))
    }
}

struct PressaySection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(PressayPalette.muted)
            content
        }.padding(.bottom, 25)
    }
}

struct PressaySetting<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var control: Control
    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium)).frame(minHeight: 19)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(PressayPalette.muted).lineSpacing(3).frame(
                        minHeight: 16
                    ).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            control.fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(minHeight: 58)
        .overlay(alignment: .bottom) { Rectangle().fill(PressayPalette.line).frame(height: 1) }
    }
}

struct PressaySearch: View {
    @FocusState private var focused: Bool
    let placeholder: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12))
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 12)).focused($focused)
                .accessibilityLabel(placeholder)
            Text("⌘ F").font(.system(size: 10)).accessibilityHidden(true)
        }
        .background {
            Button("Find") { focused = true }.keyboardShortcut("f", modifiers: .command)
                .hidden().accessibilityHidden(true)
        }
        .foregroundStyle(PressayPalette.muted)
        .padding(.horizontal, 11).frame(width: 252, height: 34)
        .background(PressayPalette.surface, in: .rect(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(PressayPalette.line))
    }
}

struct PressayEmpty: View {
    let title: String
    let detail: String
    var systemImage: String? = nil
    var actionTitle: String? = nil
    var primaryAction = true
    var action: (() -> Void)? = nil
    var hint: String? = nil
    var body: some View {
        VStack(spacing: 14) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 42)).foregroundStyle(PressayPalette.muted)
            }
            Text(title).font(.system(size: 19, weight: .semibold)).tracking(-0.4)
            Text(detail).font(.system(size: 12)).foregroundStyle(PressayPalette.muted)
                .multilineTextAlignment(.center).frame(maxWidth: 300)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(
                    PressayButtonStyle(kind: primaryAction ? .primary : .standard))
            }
            if let hint {
                Text(hint).font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(PressayPalette.button, in: .rect(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(PressayPalette.strongLine))
            }
        }.frame(maxWidth: .infinity, minHeight: 360)
    }
}

struct PressayField: ViewModifier {
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).font(.system(size: 13))
            .padding(.horizontal, 12).padding(.vertical, 11)
            .background(PressayPalette.base, in: .rect(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(PressayPalette.strongLine))
    }
}

struct PressaySheet<Content: View>: View {
    let title: String
    var width: CGFloat = 470
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 21, weight: .semibold)).tracking(-0.5).padding(.bottom, 24)
            content
        }
        .padding(26).frame(width: width)
        .foregroundStyle(PressayPalette.text).background(PressayPalette.surface)
        .buttonStyle(PressayButtonStyle()).tint(PressayPalette.accent)
    }
}

struct AppIcon: View {
    let bundleID: String?
    var size: CGFloat = 24
    var body: some View {
        Group {
            if let icon = AppInfo.icon(for: bundleID) {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "app").resizable().scaledToFit().foregroundStyle(PressayPalette.muted).padding(2)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

enum PressayPickerItem<Value: Hashable> {
    case choice(String, Value)
    case heading(String)
}

/// Direct native menu actions preserve keyboard and accessibility activation.
struct PressayPicker<Selection: Hashable>: View {
    let label: String
    let value: String
    @Binding var selection: Selection
    let items: [PressayPickerItem<Selection>]
    var body: some View {
        Menu {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                switch item {
                case .choice(let title, let itemValue):
                    Button {
                        selection = itemValue
                    } label: {
                        if itemValue == selection { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                case .heading(let title):
                    Divider()
                    Text(title).font(.caption).foregroundStyle(.secondary)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(value).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).accessibilityHidden(true)
            }.font(.system(size: 12)).foregroundStyle(PressayPalette.text)
                .padding(.horizontal, 10).frame(height: 28)
                .background(PressayPalette.button, in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(PressayPalette.strongLine))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).tint(PressayPalette.text)
        .pressayInteraction()
        .accessibilityLabel(label).accessibilityValue(value)
    }
}
