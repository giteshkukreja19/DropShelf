import AppKit
import ApplicationServices
import QuartzCore

/// Opt-in, fail-closed browser UI automation. Never presses Send, moves files,
/// alters the pasteboard, or treats a file-picker action as upload confirmation.
@MainActor
enum ShelfSmartAttach {
    private static var running = false
    static func report(_ message: String) {
        UserDefaults.standard.set(message, forKey: "shelf.smartAttachStatus")
        NSLog("DropShelf Smart Attach: %@", message)
    }
    private static let supportedBrowsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "com.brave.Browser", "com.microsoft.edgemac"
    ]

    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func sourceFrame() -> NSRect? {
        if let source = DragInitiatorView.activeSourceWindow { return source.frame }
        let mouse = NSEvent.mouseLocation
        return NSApp.windows.filter { $0 is ShelfPanelMarker && $0.isVisible }
            .min { distance($0.frame, mouse) < distance($1.frame, mouse) }?.frame
    }

    private static func distance(_ rect: NSRect, _ point: NSPoint) -> CGFloat {
        hypot(rect.midX - point.x, rect.midY - point.y)
    }

    static func start(file: URL, origin: NSRect?) {
        guard !running else { report("Another attachment attempt is running."); return }
        guard AXIsProcessTrusted() else {
            report("Accessibility permission missing. Attach manually.")
            return
        }
        guard file.isFileURL,
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            report("Selected item is not a readable regular file. Attach manually.")
            return
        }
        running = true
        report("Waiting for Gmail attachment control…")
        Task { @MainActor in
            defer {
                running = false
                let status = UserDefaults.standard.string(forKey: "shelf.smartAttachStatus") ?? ""
                if status.hasSuffix("…") { report("Attachment attempt interrupted. Attach manually.") }
            }
            await attach(file, origin: origin)
        }
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(_ node: AXUIElement) -> [AXUIElement] {
        attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func string(_ node: AXUIElement, _ key: String) -> String? {
        attribute(node, key) as? String
    }

    private static func nodes(_ root: AXUIElement, limit: Int = 2200) -> [AXUIElement] {
        var queue = [root], result: [AXUIElement] = []
        var index = 0
        let deadline = CACurrentMediaTime() + 0.65
        while index < queue.count && index < limit && CACurrentMediaTime() < deadline {
            let node = queue[index]; index += 1; result.append(node)
            if queue.count < limit { queue.append(contentsOf: children(node).prefix(limit - queue.count)) }
        }
        return result
    }

    private static func isGmail(_ node: AXUIElement) -> Bool {
        guard string(node, kAXRoleAttribute) == "AXWebArea",
              let url = attribute(node, kAXURLAttribute) as? URL else { return false }
        return url.scheme == "https" && url.host == "mail.google.com" && url.path.hasPrefix("/mail/") && (url.fragment?.contains("compose=") == true)
    }

    private static func named(_ node: AXUIElement, _ name: String) -> Bool {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].contains {
            string(node, $0)?.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    private static func isFront(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private static func wait() async { try? await Task.sleep(nanoseconds: 250_000_000) }

    private static func attach(_ file: URL, origin: NSRect?) async {
        // Wait for the initiating physical drag to finish, and for the new tab.
        var browser: NSRunningApplication?
        var app: AXUIElement?
        var button: AXUIElement?
        for _ in 0..<48 {
            await wait()
            guard !Task.isCancelled else { return }
            guard !DragInitiatorView.hasActiveDrag, NSEvent.pressedMouseButtons == 0,
                  let front = NSWorkspace.shared.frontmostApplication,
                  let bundle = front.bundleIdentifier, supportedBrowsers.contains(bundle) else { continue }
            let candidate = AXUIElementCreateApplication(front.processIdentifier)
            AXUIElementSetMessagingTimeout(candidate, 0.25)
            guard let window = element(attribute(candidate, kAXFocusedWindowAttribute)) else { continue }
            let tree = nodes(window)
            let documents = tree.filter(isGmail)
            guard documents.count == 1 else { continue }
            let buttons = nodes(documents[0]).filter { string($0, kAXRoleAttribute) == kAXButtonRole && named($0, "Attach files") }
            guard buttons.count == 1 else { continue }
            browser = front; app = candidate; button = buttons[0]; break
        }
        guard let browser, let app, let button, isFront(browser.processIdentifier) else {
            report("Gmail attachment control not found uniquely. Check browser accessibility and attach manually.")
            return
        }
        report("Gmail attachment control found. Opening picker…")
        let pid = browser.processIdentifier
        if let origin, let target = frame(button), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            await fly(file: file, origin: origin, target: target)
        }
        guard isFront(pid), NSEvent.pressedMouseButtons == 0,
              let current = element(attribute(app, kAXFocusedWindowAttribute)),
              nodes(current).filter(isGmail).contains(where: { doc in nodes(doc).contains(where: { CFEqual($0, button) }) }),
              AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { report("Attachment button could not be activated. Attach manually."); return }

        // Native Open panel only. Never inject text into the Gmail message.
        var picker: AXUIElement?
        for _ in 0..<24 {
            await wait()
            guard isFront(pid) else { return }
            if let window = element(attribute(app, kAXFocusedWindowAttribute)),
               let dialog = fileDialog(window) { picker = dialog; break }
        }
        guard let picker, isFront(pid), NSEvent.pressedMouseButtons == 0 else { report("Native file picker not detected. Attach manually."); return }
        report("File picker found. Locating selected file…")
        // Ask the native picker to navigate to the exact file path.
        key(5, flags: [.maskCommand, .maskShift], pid: pid) // Cmd-Shift-G
        var pathField: AXUIElement?
        for _ in 0..<16 {
            await wait()
            guard isFront(pid), let window = element(attribute(app, kAXFocusedWindowAttribute)),
                  fileDialog(window) != nil else { return }
            guard let field = element(attribute(app, kAXFocusedUIElementAttribute)),
                  [kAXTextFieldRole, kAXComboBoxRole].contains(string(field, kAXRoleAttribute) ?? ""),
                  nodes(window).contains(where: { CFEqual($0, field) }) else { continue }
            // Require the native Go to Folder prompt, not just any text field.
            let tree = nodes(window)
            guard tree.contains(where: { named($0, "Go to Folder") || named($0, "Go to the folder:") || named($0, "Go to Folder:") }) else { continue }
            pathField = field; break
        }
        guard let field = pathField, isFront(pid),
              AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, file.path as CFString) == .success,
              string(field, kAXValueAttribute) == file.path else { report("Could not verify file path in picker. Choose the file manually."); return }
        key(36, flags: [], pid: pid) // Return only in verified native path field
        for _ in 0..<16 {
            await wait()
            guard isFront(pid), let window = element(attribute(app, kAXFocusedWindowAttribute)),
                  let dialog = fileDialog(window) else { return }
            let tree = nodes(dialog)
            let selected = tree.filter { (attribute($0, kAXSelectedAttribute) as? Bool) == true }
            // Only confirm when AX exposes the exact selected file URL. If not,
            // leave the chooser open for the user to verify and click Open.
            let exact = selected.contains { node in
                guard let url = attribute(node, kAXURLAttribute) as? URL, url.isFileURL else { return false }
                return url.standardizedFileURL == file.standardizedFileURL
            }
            guard exact, let open = tree.first(where: { string($0, kAXRoleAttribute) == kAXButtonRole && named($0, "Open") && (attribute($0, kAXEnabledAttribute) as? Bool) == true }) else { continue }
            guard isFront(pid), NSEvent.pressedMouseButtons == 0 else { return }
            _ = AXUIElementPerformAction(open, kAXPressAction as CFString)
            // This requests attachment only. Gmail may reject the upload.
            report("File picker confirmed. Verify upload in Gmail draft.")
            return
        }
        _ = picker // retain the identified native dialog while navigating
        report("Verify the selected file and click Open manually.")
    }

    private static func fileDialog(_ window: AXUIElement) -> AXUIElement? {
        let candidates = [window] + children(window).filter { string($0, kAXRoleAttribute) == kAXSheetRole }
        return candidates.first { node in
            let role = string(node, kAXRoleAttribute)
            guard role == kAXSheetRole || string(node, kAXSubroleAttribute) == kAXDialogSubrole else { return false }
            let tree = nodes(node, limit: 600)
            return tree.contains { string($0, kAXRoleAttribute) == kAXButtonRole && named($0, "Open") }
                && tree.contains { string($0, kAXRoleAttribute) == kAXButtonRole && named($0, "Cancel") }
        }
    }

    private static func key(_ code: CGKeyCode, flags: CGEventFlags, pid: pid_t) {
        guard isFront(pid), NSEvent.pressedMouseButtons == 0,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return }
        down.flags = flags; up.flags = flags
        down.postToPid(pid); up.postToPid(pid)
    }

    private static func frame(_ node: AXUIElement) -> NSRect? {
        guard let p = attribute(node, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = attribute(node, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID(),
              let main = NSScreen.screens.first else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &position), AXValueGetValue(s as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return NSRect(x: position.x, y: main.frame.maxY - position.y - size.height, width: size.width, height: size.height)
    }

    private static func fly(file: URL, origin: NSRect, target: NSRect) async {
        let size: CGFloat = 72
        let from = NSRect(x: origin.midX - size/2, y: origin.midY - size/2, width: size, height: size)
        let to = NSRect(x: target.midX - 12, y: target.midY - 12, width: 24, height: 24)
        let panel = NSPanel(contentRect: from, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false; panel.level = .floating
        let view = NSImageView(frame: NSRect(origin: .zero, size: from.size))
        if let preview = ShelfImagePreview.load(url: file, maxPixel: 144) {
            view.image = NSImage(cgImage: preview, size: .zero)
        } else {
            view.image = NSWorkspace.shared.icon(forFile: file.path)
        }
        view.imageScaling = .scaleProportionallyUpOrDown
        view.autoresizingMask = [.width, .height]; panel.contentView = view
        panel.orderFrontRegardless()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.38
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(to, display: true)
                panel.animator().alphaValue = 0.15
            } completionHandler: { continuation.resume() }
        }
        panel.orderOut(nil)
    }
}
