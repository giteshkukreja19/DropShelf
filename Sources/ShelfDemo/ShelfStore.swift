import AppKit
import Foundation

private struct PersistedShelfItem: Codable {
    let id: UUID
    let type: String          // "file" | "image" | "text"
    let bookmark: Data?
    let text: String?
    let translation: ShelfOCRMetadata?
    let createdAt: Date
}

private struct PersistedShelf: Codable {
    let id: UUID
    let createdAt: Date
    let items: [PersistedShelfItem]
    // Added in v3 — optional so v2 payloads decode cleanly.
    let name: String?
    let pinned: Bool?
    let accent: ShelfAccent?
}

private struct PersistedStore: Codable {
    let version: Int
    let shelves: [PersistedShelf]
    let currentShelfID: UUID?
}

struct ShelfStoreContents {
    let shelves: [Shelf]
    let currentShelfID: UUID?
}

final class ShelfStore {
    private let storeURL = ShelfDataLocation.root.appendingPathComponent("shelf.json")

    static func rebaseCopiedStore(from source: URL, to target: URL) throws {
        let fm = FileManager.default
        let file = target.appendingPathComponent("shelf.json")
        guard fm.fileExists(atPath: file.path) else { return }
        let payload = try JSONDecoder().decode(PersistedStore.self, from: Data(contentsOf: file))
        let prefix = source.standardizedFileURL.path + "/"
        let shelves = try payload.shelves.map { shelf in
            let items = try shelf.items.map { record -> PersistedShelfItem in
                guard let bookmark = record.bookmark else { return record }
                var stale = false
                guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
                      url.standardizedFileURL.path.hasPrefix(prefix) else { return record }
                let relative = String(url.standardizedFileURL.path.dropFirst(prefix.count))
                let copied = target.appendingPathComponent(relative)
                guard fm.fileExists(atPath: copied.path) else {
                    // Missing original items are not turned into new links.
                    if !fm.fileExists(atPath: url.path) { return record }
                    throw CocoaError(.fileNoSuchFile)
                }
                let data = try copied.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                return PersistedShelfItem(id: record.id, type: record.type, bookmark: data, text: record.text, translation: record.translation, createdAt: record.createdAt)
            }
            return PersistedShelf(id: shelf.id, createdAt: shelf.createdAt, items: items, name: shelf.name, pinned: shelf.pinned, accent: shelf.accent)
        }
        try JSONEncoder().encode(PersistedStore(version: payload.version, shelves: shelves, currentShelfID: payload.currentShelfID)).write(to: file, options: .atomic)
    }

    // MARK: - Save

    func save(shelves: [Shelf], currentShelfID: UUID?) {
        let records = shelves.map { shelf in
            PersistedShelf(
                id: shelf.id,
                createdAt: shelf.createdAt,
                items: shelf.items.map(persist),
                name: shelf.name,
                pinned: shelf.pinned ? true : nil,
                accent: shelf.accent
            )
        }
        let payload = PersistedStore(
            version: 3,
            shelves: records,
            currentShelfID: currentShelfID
        )
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            NSLog("Shelf: save failed — \(error)")
        }
    }

    private func persist(_ item: ShelfItem) -> PersistedShelfItem {
        let bookmark: Data? = {
            // Text snippets are backed by a temp `.txt` that's regenerated
            // from the snippet content on load — persisting a bookmark to
            // that path would resolve to a missing file (temp dir is wiped
            // between sessions) and the item would silently drop on load.
            if item.type == .text { return nil }
            guard let url = item.fileURL else { return nil }
            return try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }()
        return PersistedShelfItem(
            id: item.id,
            type: typeKey(item.type),
            bookmark: bookmark,
            text: item.textContent,
            translation: item.translation,
            createdAt: item.createdAt
        )
    }

    // MARK: - Load

    func load() -> ShelfStoreContents {
        guard let data = try? Data(contentsOf: storeURL) else {
            return ShelfStoreContents(shelves: [], currentShelfID: nil)
        }
        guard let payload = try? JSONDecoder().decode(PersistedStore.self, from: data) else {
            return ShelfStoreContents(shelves: [], currentShelfID: nil)
        }

        var resolvedShelves: [Shelf] = []
        var anyStale = false
        let fm = FileManager.default

        for shelfRecord in payload.shelves {
            var items: [ShelfItem] = []
            for record in shelfRecord.items {
                if let bookmark = record.bookmark {
                    var stale = false
                    var isDir: ObjCBool = false
                    if let url = try? URL(
                        resolvingBookmarkData: bookmark,
                        options: [],
                        relativeTo: nil,
                        bookmarkDataIsStale: &stale
                    ), fm.fileExists(atPath: url.path, isDirectory: &isDir) {
                        let type: ShelfItem.ItemType = (record.type == "image") ? .image : .file
                        let icon = NSWorkspace.shared.icon(forFile: url.path)
                        let pixelSize = (type == .image)
                            ? ShelfItem.readImagePixelSize(url: url) : nil
                        let isPDF = url.pathExtension.lowercased() == "pdf"
                        let pageCount = isPDF ? ShelfItem.readPDFPageCount(url: url) : nil
                        items.append(ShelfItem(
                            id: record.id,
                            type: type,
                            fileURL: url,
                            textContent: nil,
                            thumbnail: icon,
                            createdAt: record.createdAt,
                            pixelSize: pixelSize,
                            pageCount: pageCount,
                            isDirectory: isDir.boolValue
                        ))
                        if stale { anyStale = true }
                    }
                } else if let text = record.text {
                    // Re-stage a temp .txt so the loaded snippet has a backing
                    // fileURL — needed for Open / Reveal-in-Finder to work
                    // (the temp dir is wiped between sessions).
                    let url = ShelfItem.writeTextToTemp(text)
                    items.append(ShelfItem(
                        id: record.id,
                        type: .text,
                        fileURL: url,
                        textContent: text,
                        thumbnail: nil,
                        createdAt: record.createdAt,
                        translation: record.translation
                    ))
                }
            }
            resolvedShelves.append(Shelf(
                id: shelfRecord.id,
                items: items,
                createdAt: shelfRecord.createdAt,
                name: shelfRecord.name,
                pinned: shelfRecord.pinned ?? false,
                accent: shelfRecord.accent
            ))
        }

        let contents = ShelfStoreContents(
            shelves: resolvedShelves,
            currentShelfID: payload.currentShelfID
        )

        if anyStale {
            save(shelves: resolvedShelves, currentShelfID: contents.currentShelfID)
        }

        return contents
    }

    private func typeKey(_ type: ShelfItem.ItemType) -> String {
        switch type {
        case .file: return "file"
        case .image: return "image"
        case .text: return "text"
        }
    }
}
