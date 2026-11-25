import AppKit

/// Hosts the NSSharingServicePicker so its delegate outlives the menu invocation.
@MainActor
final class ShareCoordinator: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    static let shared = ShareCoordinator()

    private var activePicker: NSSharingServicePicker?
    private var activeService: NSSharingService?

    func share(item: ShelfItem) {
        share(items: [item])
    }

    func share(items: [ShelfItem]) {
        var shareItems: [Any] = []
        for item in items {
            if let url = item.fileURL, FileManager.default.fileExists(atPath: url.path) {
                shareItems.append(url)
            } else if let text = item.textContent, !text.isEmpty {
                shareItems.append(text)
            }
        }
        guard !shareItems.isEmpty else { return }

        let picker = NSSharingServicePicker(items: shareItems)
        picker.delegate = self
        self.activePicker = picker

        // Anchor to the shelf panel's content view (the currently key window).
        if let window = NSApp.keyWindow ?? NSApp.orderedWindows.first(where: { $0.isVisible }),
           let view = window.contentView {
            let anchor = NSRect(x: view.bounds.midX, y: 0, width: 1, height: 1)
            picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
        }
    }

    func whatsApp(items: [ShelfItem]) {
        let values: [Any] = items.compactMap { item -> Any? in
            if let url = item.fileURL { return url }
            return item.textContent
        }
        _ = performInstant("WhatsApp", values: values)
    }

    @discardableResult
    func performInstant(_ name: String, values: [Any]) -> Bool {
        guard !values.isEmpty else { return false }
        let service: NSSharingService?
        switch name {
        case "AirDrop": service = NSSharingService(named: .sendViaAirDrop)
        case "Messages": service = NSSharingService(named: .composeMessage)
        case "Mail": service = NSSharingService(named: .composeEmail)
        case "WhatsApp": service = NSSharingService.sharingServices(forItems: values).first { $0.title.localizedCaseInsensitiveContains("WhatsApp") }
        default: return false
        }
        guard let service, service.canPerform(withItems: values) else {
            if name == "WhatsApp" {
                let alert = NSAlert()
                alert.messageText = "Share using WhatsApp"
                alert.informativeText = "Direct attachments are unavailable. Open WhatsApp and try pasting the copied files into a chat, or drag them from the shelf. Your shelf will remain unchanged."
                alert.addButton(withTitle: "Open WhatsApp")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.whatsapp.WhatsApp") {
                        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                    } else if let web = URL(string: "https://web.whatsapp.com/") {
                        NSWorkspace.shared.open(web)
                    }
                    let files = values.compactMap { $0 as? URL }.filter { $0.isFileURL }
                    if !files.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects(files.map { $0 as NSURL })
                    }
                }
                return false
            }
            let alert = NSAlert()
            alert.messageText = name + " sharing is unavailable"
            alert.informativeText = "Use the destination app to attach the original files manually. No files were removed."
            alert.runModal()
            return false
        }
        activeService = service
        service.delegate = self
        // Sharing from a nonactivating shelf needs an active application.
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { service.perform(withItems: values) }
        return true
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.activeService = nil
            let alert = NSAlert()
            alert.messageText = "Sharing failed"
            alert.informativeText = message + " Your shelf files remain unchanged."
            alert.runModal()
        }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        Task { @MainActor in self.activeService = nil }
    }

    // MARK: - NSSharingServicePickerDelegate

    nonisolated func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        Task { @MainActor in
            self.activePicker = nil
        }
    }
}
