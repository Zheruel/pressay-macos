import AppKit
import ApplicationServices
import Foundation
import PressayCore
import OSLog

final class CapturedTarget: @unchecked Sendable {
    let pid: pid_t
    let bundleID: String?
    let element: AXUIElement?
    let context: DictationContext

    init(pid: pid_t, bundleID: String?, element: AXUIElement?, context: DictationContext) {
        self.pid = pid
        self.bundleID = bundleID
        self.element = element
        self.context = context
    }
}

enum InsertionOutcome {
    case replacedSelection
    case pasted
    case copied
}

@MainActor
final class AccessibilityBridge {
    private let logger = Logger(subsystem: "dev.localflow.app", category: "insertion")
    /// The user clipboard awaiting restore while our inserted text sits on the
    /// pasteboard, keyed by the changeCount of that insertion.
    private var pendingRestore: (snapshot: PasteboardSnapshot, insertedChangeCount: Int)?
    private var restoreWorkItem: DispatchWorkItem?

    func capture(vocabulary: [String]) -> CapturedTarget {
        let application = NSWorkspace.shared.frontmostApplication
        let pid = application?.processIdentifier ?? 0
        let bundleID = application?.bundleIdentifier
        let element = focusedElement(belongingTo: pid)

        let excerpt = element.map(readContext) ?? ("", "")
        let context = DictationContext(
            targetBundleID: bundleID,
            leadingText: excerpt.0,
            trailingText: excerpt.1,
            vocabulary: vocabulary
        )
        return CapturedTarget(pid: pid, bundleID: bundleID, element: element, context: context)
    }

    /// Reacquires the editor at key release. Some Electron editors replace their
    /// accessibility object while a long dictation is in progress, making the
    /// object captured on key-down stale even though the cursor never moved.
    func refreshInsertionTarget(_ target: CapturedTarget) -> CapturedTarget {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
            return target
        }
        return CapturedTarget(
            pid: target.pid,
            bundleID: target.bundleID,
            element: focusedElement(belongingTo: target.pid),
            context: target.context
        )
    }

    func runningTarget(bundleID: String?, vocabulary: [String]) -> CapturedTarget? {
        guard let bundleID,
              let application = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID
              ).first else { return nil }
        let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            == application.processIdentifier
        let element = isFrontmost
            ? focusedElement(belongingTo: application.processIdentifier)
            : nil
        let excerpt = element.map(readContext) ?? ("", "")
        return CapturedTarget(
            pid: application.processIdentifier,
            bundleID: bundleID,
            element: element,
            context: DictationContext(
                targetBundleID: bundleID,
                leadingText: excerpt.0,
                trailingText: excerpt.1,
                vocabulary: vocabulary
            )
        )
    }

    func insert(
        _ text: String,
        into target: CapturedTarget,
        reactivateTarget: Bool = false
    ) async -> InsertionOutcome {
        if reactivateTarget {
            // A MenuBarExtra remains the key responder after its Retry button is
            // clicked even though NSWorkspace still calls the prior app frontmost.
            // Dismiss it and explicitly restore the original app before posting.
            NSApplication.shared.hide(nil)
            guard let application = NSRunningApplication(processIdentifier: target.pid) else {
                copy(text)
                return .copied
            }
            NSApplication.shared.yieldActivation(to: application)
            _ = application.activate(from: .current, options: [])
            try? await Task.sleep(for: .milliseconds(150))
        }

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
            copy(text)
            return .copied
        }

        // Paste is the universal primary path. Web/Electron editors can claim that
        // AXSelectedText was set while silently ignoring the visible edit. A normal
        // Command-V travels through the active app's responder chain and updates the
        // real editor at its current cursor in native, Chromium, and Electron apps.
        if pastePreservingClipboard(text) { return .pasted }

        // If Quartz could not create the keyboard events, retain AX replacement as
        // a best-effort fallback for correctly implemented native text controls.
        if let element = target.element {
            let result = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                text as CFString
            )
            if result == .success {
                logger.info("Inserted through the Accessibility fallback")
                return .replacedSelection
            }
            logger.info("Accessibility fallback failed with code \(result.rawValue, privacy: .public)")
        }
        copy(text)
        return .copied
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func focusedElement(belongingTo expectedPID: pid_t) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard result == .success,
              let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)
        var actualPID = pid_t()
        guard AXUIElementGetPid(element, &actualPID) == .success,
              actualPID == expectedPID else { return nil }
        return element
    }

    private func readContext(_ element: AXUIElement) -> (String, String) {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String else { return ("", "") }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef,
              CFGetTypeID(rangeRef) == AXValueGetTypeID() else {
            return (String(value.suffix(500)), "")
        }
        let rangeValue = unsafeDowncast(rangeRef as AnyObject, to: AXValue.self)
        guard
              AXValueGetType(rangeValue) == .cfRange else {
            return (String(value.suffix(500)), "")
        }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return ("", "") }
        let nsValue = value as NSString
        let location = min(max(0, range.location), nsValue.length)
        let end = min(nsValue.length, location + max(0, range.length))
        let leadingStart = max(0, location - 500)
        let trailingLength = min(500, nsValue.length - end)
        return (
            nsValue.substring(with: NSRange(location: leadingStart, length: location - leadingStart)),
            nsValue.substring(with: NSRange(location: end, length: trailingLength))
        )
    }

    private func pastePreservingClipboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        // A second dictation within the restore window must preserve the
        // user's original clipboard, not our still-pending inserted text.
        let snapshot: PasteboardSnapshot
        if let pending = pendingRestore, pending.insertedChangeCount == pasteboard.changeCount {
            snapshot = pending.snapshot
        } else {
            snapshot = PasteboardSnapshot(pasteboard)
        }
        restoreWorkItem?.cancel()
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            pendingRestore = nil
            return false
        }
        let insertedTextChangeCount = pasteboard.changeCount

        // The app is still verified as frontmost above. Post through the normal HID
        // route so Electron sends the shortcut to its focused renderer process;
        // postToPid targets Electron's main process and can silently drop the paste.
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        guard let keyDown, let keyUp else {
            // The requested text remains on the clipboard when synthetic input
            // cannot be created, which is the final insertion fallback.
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        logger.info("Posted paste through the frontmost application")

        // Electron/content-editable clients may read the pasteboard asynchronously.
        // Keep our value available long enough for that read, and never overwrite a
        // clipboard change the user made in the meantime.
        pendingRestore = (snapshot, insertedTextChangeCount)
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { [weak self] in
                defer { self?.pendingRestore = nil }
                guard pasteboard.changeCount == insertedTextChangeCount else { return }
                snapshot.restore(to: pasteboard)
            }
        }
        restoreWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
        return true
    }
}

private struct PasteboardSnapshot: @unchecked Sendable {
    let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ pasteboard: NSPasteboard) {
        items = pasteboard.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        } ?? []
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
