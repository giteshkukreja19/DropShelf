import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor enum ShelfArchiveAction {
    static func run(urls: [URL]) {
        guard !urls.isEmpty else { return }
        let panel = NSSavePanel()
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = "Archive.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        let owner = NSApp.keyWindow
        let previous = owner?.level
        owner?.level = .normal
        panel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            let destination = panel.url
            panel.orderOut(nil)
            if let owner, let previous { owner.level = previous }
            guard response == .OK, let destination else { return }
            Task { @MainActor in
                do {
                    try await Task.detached(priority: .userInitiated) { try Self.build(urls: urls, destination: destination) }.value
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                } catch {
                    ShelfDataLocation.alert("Archive Failed", error.localizedDescription)
                }
            }
        }
        panel.makeKeyAndOrderFront(nil)
    }
    nonisolated static func build(urls: [URL], destination: URL) throws {
        let fm = FileManager.default
        let target = destination.resolvingSymlinksInPath().standardizedFileURL.path
        for url in urls {
            let source = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard target != source, !target.hasPrefix(source + "/") else {
                throw NSError(domain: "DropShelf.Archive", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a destination outside the selected files and folders."])
            }
        }
        guard !fm.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        let staging = fm.temporaryDirectory.appendingPathComponent("DropShelf-ZIP-" + UUID().uuidString, isDirectory: true)
        let stagingPath = staging.resolvingSymlinksInPath().standardizedFileURL.path
        guard !urls.contains(where: { url in
            let source = url.resolvingSymlinksInPath().standardizedFileURL.path
            return stagingPath == source || stagingPath.hasPrefix(source + "/")
        }) else { throw CocoaError(.fileWriteInvalidFileName) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".DropShelf-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: temporary) }
        var basenames: [String] = []
        for url in urls {
            let copy = UniqueDestination.url(preferred: staging.appendingPathComponent(url.lastPathComponent))
            try fm.copyItem(at: url, to: copy)
            basenames.append("./" + copy.lastPathComponent)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = staging
        process.arguments = ["-q", "-r", "-y", temporary.path] + basenames
        // Avoid pipe deadlocks with large archives. No unbounded console buffer.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0, fm.fileExists(atPath: temporary.path) else {
            throw NSError(domain: "DropShelf.Archive", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "ZIP creation failed. Check available disk space and file permissions."])
        }
        try fm.moveItem(at: temporary, to: destination)
    }
}
