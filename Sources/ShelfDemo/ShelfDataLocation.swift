import AppKit
import Foundation

// Migration happens before ShelfManager starts, so no active shelf can write
// to the old database while it is being copied. Old data is retained.
enum ShelfDataLocation {
    private static let key = "shelf.dataRoot.v1"
    private static let pendingKey = "shelf.pendingDataParent.v1"
    static var defaultParent: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    }
    static var root: URL {
        if let path = UserDefaults.standard.string(forKey: key) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return defaultParent.appendingPathComponent("ShelfDemo", isDirectory: true)
    }
    static var pendingParent: String? { UserDefaults.standard.string(forKey: pendingKey) }
    static func schedule(parent: URL) throws {
        let parent = parent.resolvingSymlinksInPath().standardizedFileURL
        let source = root.resolvingSymlinksInPath().standardizedFileURL
        guard parent.path != source.path, !parent.path.hasPrefix(source.path + "/") else {
            throw NSError(domain: "DropShelf.Storage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a folder outside the current data directory."])
        }
        if parent.path == defaultParent.resolvingSymlinksInPath().standardizedFileURL.path,
           source.path == parent.appendingPathComponent("ShelfDemo").path {
            cancel(); return
        }
        UserDefaults.standard.set(parent.path, forKey: pendingKey)
    }
    static func cancel() { UserDefaults.standard.removeObject(forKey: pendingKey) }
    @MainActor static func prepare() -> Bool {
        let fm = FileManager.default
        let source = root
        do {
            if UserDefaults.standard.string(forKey: key) != nil {
                guard (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
                    throw CocoaError(.fileNoSuchFile)
                }
            } else {
                try fm.createDirectory(at: source, withIntermediateDirectories: true)
            }
        } catch {
            alert("DropShelf data is unavailable", "Reconnect the drive or restore access to \(source.path). No data was changed.\n\(error.localizedDescription)")
            return false
        }
        guard let pendingParent else { return true }
        cancel() // one attempt; do not loop on a disconnected drive
        do {
            let parent = URL(fileURLWithPath: pendingParent, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            let old = source.resolvingSymlinksInPath().standardizedFileURL
            guard parent.path != old.path, !parent.path.hasPrefix(old.path + "/"),
                  (try parent.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            // Never replace an existing data directory, even on reset.
            let defaultLocation = parent.path == defaultParent.resolvingSymlinksInPath().standardizedFileURL.path
            let name = defaultLocation ? "ShelfDemo" : "DropShelf Data"
            var target = parent.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: target.path) {
                target = parent.appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
            }
            try fm.copyItem(at: source, to: target)
            try ShelfStore.rebaseCopiedStore(from: source, to: target)
            UserDefaults.standard.set(target.path, forKey: key)
            // Original directory is deliberately retained as a backup.
        } catch {
            alert("Data location was not changed", "The original data remains in \(source.path). A partial copy may remain at the destination.\n\(error.localizedDescription)")
        }
        return true
    }
    @MainActor static func alert(_ title: String, _ detail: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "OK"); alert.runModal()
    }
}
