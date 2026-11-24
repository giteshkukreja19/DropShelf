import AppKit
import PDFKit
import CoreGraphics
import UniformTypeIdentifiers

enum PDFToolkit {
    static func error(_ message: String) -> NSError {
        NSError(domain: "DropShelf.PDF", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    @MainActor static func prompt(_ title: String, detail: String, initial: String = "", secure: Bool = false) -> String? {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        let field: NSTextField = secure ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)) : NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = initial; alert.accessoryView = field
        alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
    static func pages(_ text: String, count: Int) throws -> [Int] {
        var result: [Int] = []
        for token in text.split(separator: ",", omittingEmptySubsequences: false) {
            let parts = token.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard (1...2).contains(parts.count), let a = Int(parts[0]), let b = Int(parts.last ?? ""), a >= 1, b >= a, b <= count else { throw error("Enter valid page numbers or ranges within 1–\(count).") }
            result.append(contentsOf: (a...b).map { $0 - 1 })
        }
        guard !result.isEmpty, Set(result).count == result.count else { throw error("Choose distinct pages.") }
        return result
    }
    static func subset(_ doc: PDFDocument, indices: [Int]) throws -> Data {
        let out = PDFDocument()
        for index in indices {
            guard let page = doc.page(at: index)?.copy() as? PDFPage else { throw error("Cannot copy page.") }
            out.insert(page, at: out.pageCount)
        }
        guard let data = out.dataRepresentation(), out.pageCount > 0 else { throw error("No output pages.") }; return data
    }
    static func compress(_ doc: PDFDocument, dpi: CGFloat, quality: CGFloat, cancelled: () -> Bool) throws -> Data {
        let out = PDFDocument()
        for index in 0..<doc.pageCount {
            if cancelled() { throw CancellationError() }
            try autoreleasepool {
            guard let page = doc.page(at: index) else { throw error("Cannot read page.") }
            let bounds = page.bounds(for: .mediaBox)
            let scale = min(dpi / 72, 4000 / max(bounds.width, bounds.height))
            guard scale.isFinite, scale > 0, bounds.width > 0, bounds.height > 0 else { throw error("Invalid page size.") }
            let size = NSSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
            let thumb = page.thumbnail(of: size, for: .mediaBox)
            guard let tiff = thumb.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]), let image = NSImage(data: jpeg) else { throw error("Cannot compress page.") }
            image.size = bounds.size
            guard let newPage = PDFPage(image: image) else { throw error("Cannot create compressed page.") }
            out.insert(newPage, at: out.pageCount)
            }
        }
        guard let data = out.dataRepresentation() else { throw error("Cannot write PDF.") }; return data
    }
    static var libreOffice: String? {
        let candidates = ["/Applications/LibreOffice.app/Contents/MacOS/soffice", NSHomeDirectory() + "/Applications/LibreOffice.app/Contents/MacOS/soffice"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }
    static func wordPDF(_ urls: [URL], cancelled: () -> Bool) throws -> Data {
        guard let executable = libreOffice else { throw error("Install free LibreOffice in Applications to convert Word documents with layout preservation.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = PDFDocument()
        for (i, url) in urls.enumerated() {
            let folder = root.appendingPathComponent(String(i), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["-env:UserInstallation=\(root.appendingPathComponent("profile").absoluteString)", "--headless", "--convert-to", "pdf:writer_pdf_Export", "--outdir", folder.path, url.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            if cancelled() { throw CancellationError() }
            try process.run()
            let deadline = ProcessInfo.processInfo.systemUptime + 120
            while process.isRunning {
                if cancelled() || ProcessInfo.processInfo.systemUptime >= deadline {
                    process.terminate()
                    if cancelled() { throw CancellationError() }
                    throw error("Word conversion timed out after 120 seconds.")
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            let output = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".pdf")
            guard process.terminationStatus == 0, let doc = PDFDocument(url: output), doc.pageCount > 0 else { throw error("Word conversion failed: \(url.lastPathComponent)") }
            for n in 0..<doc.pageCount { guard let page = doc.page(at: n)?.copy() as? PDFPage else { throw error("Cannot copy converted page.") }; result.insert(page, at: result.pageCount) }
        }
        guard let data = result.dataRepresentation() else { throw error("Cannot save converted PDF.") }; return data
    }
}
