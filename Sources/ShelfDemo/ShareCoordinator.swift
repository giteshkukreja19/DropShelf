import AppKit

/// Hosts the NSSharingServicePicker so its delegate outlives the menu invocation.
@MainActor
final class ShareCoordinator: NSObject, NSSharingServicePickerDelegate {
    static let shared = ShareCoordinator()

    private var activePicker: NSSharingServicePicker?

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
            let alert = NSAlert()
            alert.messageText = name + " sharing is unavailable"
            alert.informativeText = "Use the destination app to attach the original files manually. No files were removed."
            alert.runModal()
            return false
        }
        service.perform(withItems: values)
        return true
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
