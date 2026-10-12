import AppKit
import ApplicationServices
import PressayCore

/// Polls rather than using AX notifications, which Electron and web editors send unreliably.
/// Nothing read here is stored; only the corrections leave.
@MainActor
final class EditWatcher {
    private static let window: Duration = .seconds(20)
    private static let interval: Duration = .milliseconds(700)
    /// Whole documents aren't worth diffing every poll.
    private static let maximumLength = 20_000

    private var task: Task<Void, Never>?

    func stop() {
        task?.cancel()
        task = nil
    }

    func watch(pid: pid_t, inserted: String, onCorrections: @escaping ([VocabularyCorrection]) -> Void) {
        stop()
        task = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled,
                  let element = Self.focusedTextElement(pid: pid),
                  let baseline = Self.value(of: element),
                  let inserted = Self.insertedRange(of: inserted, in: baseline, element: element) else { return }

            // Must hold for two polls so a half-typed word is never learned.
            var previous: [String: String] = [:]
            var confirmed: [String: VocabularyCorrection] = [:]
            let deadline = ContinuousClock.now + Self.window
            while ContinuousClock.now < deadline, !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      let focused = Self.focusedTextElement(pid: pid), CFEqual(focused, element),
                      let current = Self.value(of: element) else { break }
                guard current != baseline else { continue }
                let found = EditCorrectionDetector.corrections(baseline: baseline, inserted: inserted, current: current)
                var now: [String: String] = [:]
                for correction in found {
                    let key = correction.heard.lowercased()
                    now[key] = correction.typed
                    if previous[key] == correction.typed { confirmed[key] = correction }
                }
                previous = now
            }
            guard !confirmed.isEmpty else { return }
            onCorrections(Array(confirmed.values))
        }
    }

    private static func focusedTextElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        if (subrole as? String) == (kAXSecureTextFieldSubrole as String) { return nil }
        return element
    }

    private static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String, text.utf16.count <= maximumLength else { return nil }
        return text
    }

    /// Just before the caret when known, else the last occurrence.
    private static func insertedRange(of inserted: String, in baseline: String, element: AXUIElement) -> Range<Int>? {
        let needle = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        let nsBaseline = baseline as NSString
        var found = NSRange(location: NSNotFound, length: 0)
        if let caret = caretLocation(element), caret <= nsBaseline.length {
            let candidate = nsBaseline.range(of: needle, options: .backwards, range: NSRange(location: 0, length: caret))
            if candidate.location != NSNotFound, caret - NSMaxRange(candidate) <= 2 { found = candidate }
        }
        if found.location == NSNotFound { found = nsBaseline.range(of: needle, options: .backwards) }
        guard found.location != NSNotFound,
              let range = Range(found, in: baseline) else { return nil }
        let start = baseline.distance(from: baseline.startIndex, to: range.lowerBound)
        return start..<(start + baseline[range].count)
    }

    private static func caretLocation(_ element: AXUIElement) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(ref as AnyObject, to: AXValue.self), .cfRange, &range) else { return nil }
        return range.location
    }
}
