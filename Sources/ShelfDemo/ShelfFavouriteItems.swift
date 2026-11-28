import AppKit
import SwiftUI
import CryptoKit

/// Separate collection, deliberately not a shelf or a replacement for Favourite Locations.
@MainActor enum ShelfFavouriteItems {
    struct Entry: Codable {
        let id: UUID
        let key: String
        let name: String
        let text: String?
        let bookmark: Data?
        let relativePath: String?
        var url: URL? {
            if let relativePath { return ShelfDataLocation.root.appendingPathComponent(relativePath) }
            guard let bookmark else { return nil }
            var stale = false
            return try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        }
    }
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "favouriteItems.enabled") }
    static var showInMenuBar: Bool { UserDefaults.standard.object(forKey: "favouriteItems.menuBar") == nil || UserDefaults.standard.bool(forKey: "favouriteItems.menuBar") }
    private static var store: URL { ShelfDataLocation.root.appendingPathComponent("favourite-items.json") }
    private static func load() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: store.path) else { return [] }
        return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: store))
    }
    private static func save(_ entries: [Entry]) throws { try JSONEncoder().encode(entries).write(to: store, options: .atomic) }
    private static func key(_ item: ShelfItem) -> String {
        if item.type == .text, let text = item.textContent { return "text:" + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
        return "file:" + (item.fileURL?.standardizedFileURL.path ?? item.id.uuidString)
    }
    static func contains(_ item: ShelfItem) -> Bool { (try? load())?.contains { $0.key == key(item) } ?? false }
    static func toggle(_ item: ShelfItem) {
        guard enabled else { return }
        do {
            var entries = try load(); let k = key(item)
            if let index = entries.firstIndex(where: { $0.key == k }) { entries.remove(at: index); try save(entries); return }
            var bookmark: Data?; var relative: String?; var text: String?
            if item.type == .text { text = item.textContent; guard text != nil else { return } }
            else if let url = item.fileURL {
                // App-owned staged files may expire with their original shelf. Retain an independent copy.
                if ShelfWritableStorage.isStagedFile(url) {
                    let folder = try ShelfWritableStorage.newFolder("FavouriteItems")
                    let dest = folder.appendingPathComponent(url.lastPathComponent)
                    try FileManager.default.copyItem(at: url, to: dest)
                    relative = "FavouriteItems/" + folder.lastPathComponent + "/" + dest.lastPathComponent
                } else { bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
            } else { return }
            entries.append(Entry(id: UUID(), key: k, name: item.displayName, text: text, bookmark: bookmark, relativePath: relative))
            try save(entries)
        } catch { ShelfDataLocation.alert("Favourite Items", error.localizedDescription) }
    }
    static func remove(_ id: UUID) {
        do { var entries = try load(); entries.removeAll { $0.id == id }; try save(entries) }
        catch { ShelfDataLocation.alert("Favourite Items", error.localizedDescription) }
    }
    static func copy(_ entry: Entry) {
        if let text = entry.text { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
        else if let url = entry.url, FileManager.default.fileExists(atPath: url.path) { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([url as NSURL]) }
        else { ShelfDataLocation.alert("File unavailable", "The original file could not be located.") }
    }
    static func menuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Favourite Items", action: nil, keyEquivalent: "")
        let menu = NSMenu(); root.submenu = menu
        let entries: [Entry]
        do { entries = try load() } catch { let item = NSMenuItem(title: "Cannot read favourites", action: nil, keyEquivalent: ""); menu.addItem(item); return root }
        if entries.isEmpty { menu.addItem(NSMenuItem(title: "No favourite items", action: nil, keyEquivalent: "")) }
        for entry in entries {
            let item = NSMenuItem(title: entry.name, action: nil, keyEquivalent: "")
            let sub = NSMenu(); item.submenu = sub
            if entry.text == nil { sub.addItem(FavouriteCommandItem("Open", entry: entry, operation: .open)) }
            sub.addItem(FavouriteCommandItem("Copy", entry: entry, operation: .copy))
            sub.addItem(.separator()); sub.addItem(FavouriteCommandItem("Remove from Favourites", entry: entry, operation: .remove))
            menu.addItem(item)
        }
        return root
    }
}

@MainActor private final class FavouriteCommandItem: NSMenuItem {
    enum Operation { case open, copy, remove }
    let entry: ShelfFavouriteItems.Entry
    let operation: Operation
    init(_ title: String, entry: ShelfFavouriteItems.Entry, operation: Operation) {
        self.entry = entry; self.operation = operation
        super.init(title: title, action: nil, keyEquivalent: "")
        target = self; action = #selector(performCommand)
    }
    required init(coder: NSCoder) { fatalError("Not supported") }
    @objc private func performCommand() {
        switch operation {
        case .copy: ShelfFavouriteItems.copy(entry)
        case .remove: ShelfFavouriteItems.remove(entry.id)
        case .open:
            if let url = entry.url, FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
            else { ShelfDataLocation.alert("File unavailable", "The original file could not be located.") }
        }
    }
}

struct ShelfFavouriteSettings: View {
    @AppStorage("favouriteItems.enabled") private var enabled = false
    @AppStorage("favouriteItems.menuBar") private var menuBar = true
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Enable Favourite Items"); Spacer(); Toggle("Enable Favourite Items", isOn: $enabled).labelsHidden().toggleStyle(.switch); ShelfSettingsInfo(message: "Right-click a shelf item to add it. Disabling this feature keeps your saved favourites.") }
            if enabled {
                Divider()
                HStack { Text("Show Favourites in menu bar"); Spacer(); Toggle("Show Favourites in menu bar", isOn: $menuBar).labelsHidden().toggleStyle(.switch) }
            }
        }
    }
}
