import AppKit

@MainActor
enum ShelfFolderPicker {
    private static var active: NSOpenPanel?
    private static weak var activeOwner: NSWindow?

    static func choose(owner: NSWindow?, initial: URL?, completion: @escaping (URL?) -> Void) {
        guard active == nil else { completion(nil); return }
        let panel = NSOpenPanel()
        active = panel
        activeOwner = owner
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose Output Folder"
        panel.prompt = "Choose"
        panel.directoryURL = initial ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        // Borderless nonactivating shelf panels are not reliable sheet hosts.
        // A separate native chooser, above the shelf, avoids nested modal loops.
        let previousLevel = owner?.level
        owner?.level = .normal
        panel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { result in
            let url = result == .OK ? panel.url : nil
            panel.orderOut(nil)
            active = nil
            activeOwner = nil
            if let owner, let previousLevel {
                owner.level = previousLevel
                if owner.isVisible { owner.makeKeyAndOrderFront(nil) }
            }
            completion(url)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    static func cancel(owner: NSWindow?) {
        guard activeOwner === owner else { return }
        active?.cancel(nil)
    }
}
