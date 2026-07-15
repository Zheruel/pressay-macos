import AppKit

@MainActor
enum PressayBrand {
    /// Load the bundled icon directly instead of NSApplication's cached icon.
    /// LaunchServices can retain old artwork briefly after an in-place update.
    static let appIcon: NSImage = {
        guard
            let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            let image = NSImage(contentsOf: url)
        else {
            return NSApplication.shared.applicationIconImage
        }
        return image
    }()
}
