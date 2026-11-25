import AppKit

@MainActor
final class CloudSharing {
    static let shared = CloudSharing()
    private var busy = false

    static let destinations = ["iCloud Drive", "Google Drive", "OneDrive"]

    static func menu(target: AnyObject, action: Selector, enabled: Bool) -> NSMenuItem {
        let parent = NSMenuItem(title: "Copy to Cloud", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "icloud.and.arrow.up", accessibilityDescription: nil)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for name in destinations {
            let row = NSMenuItem(title: name + "…", action: action, keyEquivalent: "")
            row.target = target
            row.representedObject = name
            row.isEnabled = enabled
            submenu.addItem(row)
        }
        parent.submenu = submenu
        parent.isEnabled = enabled
        return parent
    }

    func copy(items: [ShelfItem], provider: String) {
        guard !busy else { return }
        let urls = items.compactMap { $0.fileURL }
        guard !urls.isEmpty else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cloud = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let fm = FileManager.default
        let roots = (try? fm.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil)) ?? []
        let candidates: [URL]
        switch provider {
        case "iCloud Drive": candidates = [home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")]
        case "Google Drive": candidates = roots.filter { $0.lastPathComponent.hasPrefix("GoogleDrive") }
        case "OneDrive": candidates = roots.filter { $0.lastPathComponent.hasPrefix("OneDrive") } + [home.appendingPathComponent("OneDrive")]
        default: return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose a \(provider) folder"
        panel.message = "Choose a synced folder. Your cloud provider handles uploading and sharing permissions."
        panel.prompt = "Copy Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = candidates.first { fm.fileExists(atPath: $0.path) } ?? home
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        busy = true
        Task {
            let result = await Task.detached(priority: .utility) { () -> ([URL], [String]) in
                let fm = FileManager.default
                var copied: [URL] = []
                var errors: [String] = []
                for url in urls {
                    do {
                        let target = UniqueDestination.url(preferred: destination.appendingPathComponent(url.lastPathComponent))
                        let sourcePath = url.resolvingSymlinksInPath().standardizedFileURL.path
                        let targetPath = target.resolvingSymlinksInPath().standardizedFileURL.path
                        guard targetPath != sourcePath, !targetPath.hasPrefix(sourcePath + "/") else {
                            errors.append(url.lastPathComponent + ": destination is inside source")
                            continue
                        }
                        try fm.copyItem(at: url, to: target)
                        copied.append(target)
                    } catch { errors.append(url.lastPathComponent + ": " + error.localizedDescription) }
                }
                return (copied, errors)
            }.value
            busy = false
            let alert = NSAlert()
            alert.messageText = "Copied \(result.0.count) of \(urls.count) items"
            alert.informativeText = "Cloud sync is managed by \(provider); upload completion is not verified." + (result.1.isEmpty ? "" : "\n\n" + result.1.joined(separator: "\n"))
            alert.addButton(withTitle: "Show in Finder")
            alert.addButton(withTitle: "Done")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting(result.0.isEmpty ? [destination] : result.0)
            }
        }
    }
}
