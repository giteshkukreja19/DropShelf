import Foundation

enum ShelfWritableStorage {
    static func stagingDirectory() throws -> URL {
        let folder = ShelfDataLocation.root.appendingPathComponent("Staged", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }
    static func isStagedFile(_ url: URL) -> Bool {
        guard let folder = try? stagingDirectory(),
              url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    static func newFolder(_ category: String) throws -> URL {
        let fm = FileManager.default
        let folder = ShelfDataLocation.root.appendingPathComponent(category, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }
}


enum ShelfOutputDestination: String, CaseIterable, Sendable {
    case shelf = "Current Shelf"
    case downloads = "Downloads"
    case folder = "Choose Folder…"

    func directory(chosen: URL?) throws -> URL {
        switch self {
        case .shelf: return try ShelfWritableStorage.newFolder("Output")
        case .downloads:
            return try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        case .folder:
            guard let chosen else {
                throw NSError(domain: "DropShelf.Output", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose an output folder first."])
            }
            return chosen
        }
    }
}

extension ShelfWritableStorage {
    // Always create the temporary file alongside the final output. A move on
    // the same volume commits it without replacing an existing user file.
    static func temporarySibling(of destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(".DropShelf-\(UUID().uuidString).partial")
    }

    static func commit(_ data: Data, to destination: URL) throws {
        let temporary = temporarySibling(of: destination)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}
