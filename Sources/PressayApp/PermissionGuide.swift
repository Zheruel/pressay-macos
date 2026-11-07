import AppKit
import CoreGraphics
import SwiftUI

/// A nonactivating utility panel keeps Settings focused while explaining the current grant.
/// It uses only documented permission checks; it never reads the private TCC database.
@MainActor
final class PermissionGuideController {
    private weak var permissions: PermissionController?
    private var panel: NSPanel?
    private var kind: PermissionController.Kind?

    init(permissions: PermissionController) { self.permissions = permissions }

    func present(_ kind: PermissionController.Kind) {
        guard let permissions else { return }
        self.kind = kind
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: PermissionGuideView(
            permissions: permissions, kind: kind, dismiss: { [weak self] in self?.dismiss() }
        ))
        positionBesideSettings(panel)
        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        kind = nil
    }

    func refresh() {
        guard let kind, let panel, panel.isVisible else { return }
        if permissions?.isGranted(kind) == true { dismiss() }
        else { positionBesideSettings(panel) }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 350),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.title = "Pressay permission guide"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }

    private func positionBesideSettings(_ panel: NSPanel) {
        guard let mainScreen = NSScreen.screens.first else { return }
        // CGWindow bounds are public metadata in top-left screen coordinates. No screen
        // recording request or AX traversal of another app is needed to position the guide.
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
            .first?.processIdentifier
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let settingsFrame = windows.first { window in
            (window[kCGWindowOwnerPID as String] as? Int32) == pid
                && (window[kCGWindowLayer as String] as? Int) == 0
        }.flatMap { window -> CGRect? in
            guard let bounds = window[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: bounds)
        }.map { frame in
            NSRect(x: frame.minX, y: mainScreen.frame.maxY - frame.maxY,
                   width: frame.width, height: frame.height)
        }
        let screen = settingsFrame.flatMap { frame in NSScreen.screens.first { $0.frame.intersects(frame) } }
            ?? NSScreen.main ?? mainScreen
        let visible = screen.visibleFrame
        let size = panel.frame.size
        var origin = NSPoint(x: visible.maxX - size.width - 20, y: visible.midY - size.height / 2)
        if let frame = settingsFrame {
            origin.x = frame.maxX + 16
            if origin.x + size.width > visible.maxX { origin.x = frame.minX - size.width - 16 }
            origin.y = frame.maxY - size.height - 35
        }
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))
        origin.y = max(visible.minY + 8, min(origin.y, visible.maxY - size.height - 8))
        panel.setFrameOrigin(origin)
    }
}

private struct PermissionGuideView: View {
    @ObservedObject var permissions: PermissionController
    let kind: PermissionController.Kind
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("PRESSAY SETUP").font(.system(size: 10, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(PressayPalette.muted)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(PressayButtonStyle(kind: .quiet)).accessibilityLabel("Close permission guide")
            }
            Text("Allow \(kind.title)").font(.system(size: 21, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(kind.instructions).font(.system(size: 12)).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            if kind == .accessibility {
                if Bundle.main.bundleURL.pathExtension == "app" {
                    AppBundleDragTile().frame(height: 64)
                        .accessibilityLabel("Pressay app. Drag into the Accessibility list in System Settings.")
                    Button("Show Pressay in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }.buttonStyle(PressayButtonStyle(kind: .quiet))
                    .help("Keyboard alternative: use the plus button in Accessibility to select this app.")
                } else {
                    Text("Build and open Pressay.app to add it to Accessibility.")
                        .font(.system(size: 11)).foregroundStyle(PressayPalette.warning)
                }
            }
            Text("Waiting for approval in System Settings…").font(.system(size: 11))
                .foregroundStyle(PressayPalette.muted)
            Spacer(minLength: 0)
        }
        .padding(22).padding(.top, 12)
        .frame(width: 300, height: 350)
        .background(PressayPalette.base).foregroundStyle(PressayPalette.text)
    }
}

private struct AppBundleDragTile: NSViewRepresentable {
    func makeNSView(context: Context) -> AppBundleDragView { AppBundleDragView(frame: .zero) }
    func updateNSView(_ nsView: AppBundleDragView, context: Context) {}
}

/// The drag carries the actual installed bundle URL, not an icon or an alias.
private final class AppBundleDragView: NSView, NSDraggingSource {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Pressay app. Drag to the Accessibility list.")
        setAccessibilityHelp("Alternatively, use the plus button in System Settings to choose Pressay.app.")
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        PressayBrand.appIcon.draw(in: NSRect(x: 10, y: 10, width: 44, height: 44))
        ("Drag Pressay into the list" as NSString).draw(
            at: NSPoint(x: 64, y: 26), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                     .foregroundColor: NSColor.labelColor]
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(NSRect(x: 10, y: 10, width: 44, height: 44), contents: PressayBrand.appIcon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}
