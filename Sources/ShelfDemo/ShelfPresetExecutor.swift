import AppKit
import Foundation

@MainActor enum ShelfPresetExecutor {
    private static var running = Set<UUID>()
    static func run(_ preset: ShelfCustomAction, items: [ShelfItem], manager: ShelfManager, shelfID: UUID) {
        guard preset.valid, !running.contains(shelfID) else { return }
        let urls = items.compactMap(\.fileURL)
        guard !urls.isEmpty, urls.count == items.count else { return }
        if preset.kind == "open" {
            guard let path = preset.applicationPath, FileManager.default.fileExists(atPath: path) else {
                ShelfDataLocation.alert("Application unavailable", "Edit the preset and choose an installed application."); return
            }
            NSWorkspace.shared.open(urls, withApplicationAt: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { Task { @MainActor in ShelfDataLocation.alert("Open failed", error.localizedDescription) } }
            }
            return
        }
        if ["move", "rename"].contains(preset.kind) {
            let alert = NSAlert(); alert.messageText = "\(preset.name)?"
            alert.informativeText = "This changes the location or name of \(urls.count) selected original files. Existing destination files will not be overwritten."
            alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        running.insert(shelfID)
        Task { @MainActor in
            defer { running.remove(shelfID) }
            do {
                if ["move", "rename"].contains(preset.kind) {
                    var failures: [String] = []
                    for (index, item) in items.enumerated() {
                        guard let source = item.fileURL, manager.items(of: shelfID).contains(where: { $0.id == item.id && $0.fileURL == source }) else { continue }
                        do {
                            let target: URL
                            if preset.kind == "move", let folder = preset.folder { target = folder.appendingPathComponent(source.lastPathComponent) }
                            else {
                                let base = (preset.renamePattern ?? "").replacingOccurrences(of: "#", with: String(index + 1))
                                guard !base.isEmpty, !base.hasPrefix("."), !base.contains("/"), !base.contains(":"), !base.contains("\u{0}") else { throw CocoaError(.fileWriteInvalidFileName) }
                                target = source.deletingLastPathComponent().appendingPathComponent(base + (source.pathExtension.isEmpty ? "" : "." + source.pathExtension))
                            }
                            try Self.check(source: source, target: target)
                            try manager.renameItem(id: item.id, to: target, in: shelfID)
                        } catch { failures.append(source.lastPathComponent + ": " + error.localizedDescription) }
                    }
                    if !failures.isEmpty { ShelfDataLocation.alert("Some files were not changed", failures.joined(separator: "\n")) }
                    return
                }
                let result = try await Task.detached(priority: .userInitiated) { () -> ([URL], String?, [String]) in
                    if preset.kind == "ocr" {
                        var chunks: [String] = [], failures: [String] = []
                        for url in urls {
                            do { chunks.append(try await ImageOCR.extractText(source: url)) }
                            catch { failures.append(url.lastPathComponent + ": " + error.localizedDescription) }
                        }
                        guard !chunks.isEmpty else { return ([], nil, failures) }
                        let text = chunks.joined(separator: "\n\n")
                        if preset.ocrOutput != "Text File" { return ([], text, failures) }
                        let folder = try preset.destination.directory(chosen: preset.folder)
                        let output = UniqueDestination.url(preferred: folder.appendingPathComponent("Extracted Text.txt"))
                        try ShelfWritableStorage.commit(Data(text.utf8), to: output)
                        return ([output], nil, failures)
                    }
                    if preset.kind == "zip" {
                        let folder = try preset.destination.directory(chosen: preset.folder)
                        let output = UniqueDestination.url(preferred: folder.appendingPathComponent("Archive.zip"))
                        try ShelfArchiveAction.build(urls: urls, destination: output)
                        return ([output], nil, [])
                    }
                    guard preset.kind == "copy", let folder = preset.folder else { throw CocoaError(.fileWriteInvalidFileName) }
                    var outputs: [URL] = [], failures: [String] = []
                    for source in urls {
                        let target = folder.appendingPathComponent(source.lastPathComponent)
                        do { try Self.check(source: source, target: target); try FileManager.default.copyItem(at: source, to: target); outputs.append(target) }
                        catch { failures.append(source.lastPathComponent + ": " + error.localizedDescription) }
                    }
                    return (outputs, nil, failures)
                }.value
                if let text = result.1 { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                if !result.0.isEmpty {
                    if preset.kind != "copy", preset.destination == .shelf, manager.shelf(id: shelfID) != nil {
                        for url in result.0 { _ = manager.addFile(url: url, to: shelfID) }
                    } else { NSWorkspace.shared.activateFileViewerSelecting(result.0) }
                }
                if !result.2.isEmpty { ShelfDataLocation.alert("Some files could not be processed", result.2.joined(separator: "\n")) }
            } catch { ShelfDataLocation.alert("Custom Action Failed", error.localizedDescription) }
        }
    }
    private nonisolated static func check(source: URL, target: URL) throws {
        let src = source.resolvingSymlinksInPath().standardizedFileURL.path
        let dst = target.resolvingSymlinksInPath().standardizedFileURL.path
        guard src != dst, !dst.hasPrefix(src + "/"), !FileManager.default.fileExists(atPath: target.path) else { throw CocoaError(.fileWriteFileExists) }
    }
}
