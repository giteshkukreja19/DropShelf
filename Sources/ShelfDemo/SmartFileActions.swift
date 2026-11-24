import AppKit
import PDFKit
import UniformTypeIdentifiers

@MainActor
enum SmartFileActions {
    enum Action: String {
        case splitPDF = "Split PDF into Pages…", extractPages = "Extract / Reorder PDF Pages…", deletePages = "Delete PDF Pages…", compressPDF = "Compress PDF…", protectPDF = "Password Protect PDF…", wordPDF = "Convert Word to PDF…"
        case mergePDF = "Merge PDFs…", combinedPDF = "Create Combined PDF…", imagePDF = "Create PDF…", mergeWord = "Merge Word Documents…", rotatePDF = "Rotate PDF Pages 90°…", extractPDF = "Extract PDF Text…", wordText = "Extract Word Text…", stitch = "Stitch Images…", resize = "Resize Images…", compress = "Compress Images…", metadata = "Remove Image Metadata"
    }
    static func files(_ items: [ShelfItem]) -> [URL] {
        items.compactMap(\.fileURL).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }
    static func image(_ u: URL) -> Bool { UTType(filenameExtension: u.pathExtension)?.conforms(to: .image) == true }
    static func pdf(_ u: URL) -> Bool { u.pathExtension.lowercased() == "pdf" }
    static func word(_ u: URL) -> Bool { u.pathExtension.lowercased() == "docx" }
    static func options(_ urls: [URL]) -> [Action] {
        guard !urls.isEmpty else { return [] }
        if urls.allSatisfy(pdf) { return (urls.count > 1 ? [.mergePDF] : []) + [.rotatePDF, .extractPDF] + (urls.count == 1 ? [.splitPDF, .extractPages, .deletePages, .compressPDF, .protectPDF] : []) }
        if urls.allSatisfy(word) { return (urls.count > 1 ? [.mergeWord] : []) + [.wordText, .wordPDF] }
        if urls.allSatisfy(image) { return [.imagePDF, .resize, .compress, .metadata] + (urls.count > 1 ? [.stitch] : []) }
        if urls.count > 1 && urls.allSatisfy({ pdf($0) || image($0) }) { return [.combinedPDF] }
        return []
    }
    static func append(to menu: NSMenu, items: [ShelfItem], target: AnyObject, selector: Selector) {
        let urls = files(items)
        guard urls.count == items.count else { return }
        let actions = options(urls)
        guard !actions.isEmpty else { return }
        for action in actions {
            let row = NSMenuItem(title: action.rawValue, action: selector, keyEquivalent: "")
            row.target = target
            row.representedObject = action.rawValue
            row.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            menu.addItem(row)
        }
        menu.addItem(.separator())
    }
    static func run(_ sender: NSMenuItem, items: [ShelfItem], manager: ShelfManager, shelfID: UUID) {
        guard let raw = sender.representedObject as? String, let action = Action(rawValue: raw) else { return }
        var urls = files(items)
        guard urls.count == items.count, options(urls).contains(action) else { return }
        if action == .wordPDF && PDFToolkit.libreOffice == nil { failure("Install LibreOffice in Applications, then try again."); return }
        if [.splitPDF, .extractPages, .deletePages, .compressPDF, .protectPDF].contains(action) {
            guard let url = urls.first, let doc = PDFDocument(url: url), !doc.isLocked, doc.pageCount > 0 else { failure("Cannot read PDF."); return }
            do {
                if action == .splitPDF {
                    let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
                    guard panel.runModal() == .OK, let folder = panel.url else { return }
                    let output = folder.appendingPathComponent("Split PDF-" + UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
                    var complete = false
                    defer { if !complete { try? FileManager.default.removeItem(at: output) } }
                    var generated: [URL] = []
                    for i in 0..<doc.pageCount {
                        let dest = output.appendingPathComponent("Page-\(i+1).pdf")
                        try PDFToolkit.subset(doc, indices: [i]).write(to: dest, options: .atomic)
                        guard PDFDocument(url: dest)?.pageCount == 1 else { throw PDFToolkit.error("Invalid split output.") }
                        generated.append(dest)
                    }
                    complete = true
                    for dest in generated { _ = manager.addFile(url: dest, to: shelfID) }
                    return
                }
                let data: Data
                switch action {
                case .extractPages, .deletePages:
                    guard let input = PDFToolkit.prompt(action.rawValue, detail: "Enter pages or ranges, e.g. 3,1,5-7. Originals are kept.") else { return }
                    let chosen = try PDFToolkit.pages(input, count: doc.pageCount)
                    let indices = action == .deletePages ? (0..<doc.pageCount).filter { !chosen.contains($0) } : chosen
                    data = try PDFToolkit.subset(doc, indices: indices)
                case .compressPDF:
                    guard let input = PDFToolkit.prompt("Compress PDF", detail: "Enter resolution: 72–200 DPI. Rasterizes pages; searchable text, links and forms may be lost. Output size is not guaranteed.", initial: "120"), let dpi = Double(input), (72...200).contains(dpi) else { return }
                    let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + "-compressed.pdf"
                    guard panel.runModal() == .OK, let dest = panel.url else { return }
                    guard dest.resolvingSymlinksInPath().standardizedFileURL != url.resolvingSymlinksInPath().standardizedFileURL else { throw PDFToolkit.error("Choose a different output file.") }
                    background(title: "Compressing PDF", destination: dest, manager: manager, shelfID: shelfID) { cancelled in
                        guard let input = PDFDocument(url: url), !input.isLocked else { throw PDFToolkit.error("Cannot read PDF.") }
                        let bytes = try PDFToolkit.compress(input, dpi: CGFloat(dpi), quality: 0.55, cancelled: cancelled)
                        guard PDFDocument(data: bytes)?.pageCount == input.pageCount else { throw PDFToolkit.error("Invalid compressed output.") }
                        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes.count >= size { throw PDFToolkit.error("Compressed copy is not smaller. Try a lower resolution.") }
                        return bytes
                    }
                    return
                case .protectPDF:
                    guard let password = PDFToolkit.prompt("Password Protect PDF", detail: "Enter a nonempty password to open the new PDF.", secure: true), !password.isEmpty else { return }
                    guard let protected = doc.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: password, PDFDocumentWriteOption.ownerPasswordOption: UUID().uuidString]), PDFDocument(data: protected)?.isLocked == true else { throw PDFToolkit.error("Could not verify PDF encryption.") }
                    data = protected
                default: return
                }
                let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + "-edited.pdf"
                guard panel.runModal() == .OK, let dest = panel.url else { return }
                guard dest.resolvingSymlinksInPath().standardizedFileURL != url.resolvingSymlinksInPath().standardizedFileURL else { throw PDFToolkit.error("Choose a different output file.") }
                try data.write(to: dest, options: .atomic); _ = manager.addFile(url: dest, to: shelfID)
            } catch { failure(error.localizedDescription) }
            return
        }
        if [.resize, .compress, .metadata].contains(action) {
            let dimension = action == .resize ? ImageActionPrompts.resizeMaxDimension() : nil
            let quality = action == .compress ? ImageActionPrompts.compressionQuality() : nil
            if action == .resize && dimension == nil || action == .compress && quality == nil { return }
            for url in urls {
                let result: URL?
                switch action {
                case .resize: result = dimension.flatMap { ImageActions.resize(url: url, maxDimension: $0) }
                case .compress: result = quality.flatMap { ImageActions.compress(url: url, quality: $0) }
                default: result = ImageActions.removeMetadata(url: url)
                }
                if let result { _ = manager.addFile(url: result, to: shelfID) } else { failure("Could not process \(url.lastPathComponent)") }
            }
            return
        }
        if urls.count > 1 {
            let alert = NSAlert(); alert.messageText = action.rawValue
            alert.informativeText = "Choose the order using the numbered fields. Originals are kept."
            let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading
            var fields: [NSTextField] = []
            for (i, url) in urls.enumerated() {
                let field = NSTextField(string: String(i + 1)); field.widthAnchor.constraint(equalToConstant: 48).isActive = true
                fields.append(field)
                let label = NSTextField(labelWithString: url.lastPathComponent); label.lineBreakMode = .byTruncatingMiddle
                label.widthAnchor.constraint(equalToConstant: 300).isActive = true
                let row = NSStackView(views: [field, label]); stack.addArrangedSubview(row)
            }
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: min(240, max(40, urls.count * 30))))
            stack.frame = NSRect(x: 0, y: 0, width: 360, height: urls.count * 30); scroll.documentView = stack; scroll.hasVerticalScroller = true
            alert.accessoryView = scroll; alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let order = fields.compactMap { Int($0.stringValue) }
            guard order.count == urls.count, Set(order) == Set(1...urls.count) else { failure("Enter each position exactly once."); return }
            urls = zip(order, urls).sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        let ext = action == .mergeWord ? "docx" : ([.extractPDF, .wordText].contains(action) ? "txt" : (action == .stitch ? "png" : "pdf"))
        let panel = NSSavePanel(); panel.nameFieldStringValue = "DropShelf Output.\(ext)"; panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        guard !urls.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL == dest.resolvingSymlinksInPath().standardizedFileURL }) else { failure("Choose a different output file to preserve originals."); return }
        if action == .wordPDF {
            let inputs = urls
            background(title: "Converting Word to PDF", destination: dest, manager: manager, shelfID: shelfID) { cancelled in
                try PDFToolkit.wordPDF(inputs, cancelled: cancelled)
            }
            return
        }
        do {
            let data = try output(action, urls)
            try data.write(to: dest, options: .atomic)
            _ = manager.addFile(url: dest, to: shelfID)
        } catch { failure(error.localizedDescription) }
    }
    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func cancel() { lock.lock(); value = true; lock.unlock() }
        func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    private static func background(title: String, destination: URL, manager: ShelfManager, shelfID: UUID, work: @escaping @Sendable (() -> Bool) throws -> Data) {
        let flag = CancellationFlag()
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = "Processing locally. Please wait."
        alert.addButton(withTitle: "Cancel")
        let progress = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 260, height: 20))
        progress.isIndeterminate = true; progress.style = .bar; progress.startAnimation(nil); alert.accessoryView = progress
        // Modal event loop remains responsive while work runs on a worker queue.
        var result: Result<Data, Error>?
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try work { flag.isCancelled() } }
            DispatchQueue.main.async {
                result = outcome
                if !flag.isCancelled() { NSApp.stopModal(withCode: .alertSecondButtonReturn) }
            }
        }
        let response = alert.runModal()
        if response != .alertSecondButtonReturn { flag.cancel(); return }
        do {
            guard let result else { throw PDFToolkit.error("No output produced.") }
            let data = try result.get()
            guard let pdf = PDFDocument(data: data), pdf.pageCount > 0 else { throw PDFToolkit.error("Invalid PDF output.") }
            try data.write(to: destination, options: .atomic)
            _ = manager.addFile(url: destination, to: shelfID)
        } catch { failure(error.localizedDescription) }
    }
    private static func failure(_ message: String) { let a = NSAlert(); a.messageText = "File Action Failed"; a.informativeText = message; a.runModal() }
    private static func invalid(_ url: URL) -> NSError { NSError(domain: "DropShelf", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read or convert \(url.lastPathComponent)"]) }
    private static func output(_ action: Action, _ urls: [URL]) throws -> Data {
        if action == .mergeWord || action == .wordText {
            let merged = NSMutableAttributedString(string: "")
            for url in urls {
                let part = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
                if merged.length > 0 { merged.append(NSAttributedString(string: "\n\n")) }; merged.append(part)
            }
            if action == .wordText { return Data(merged.string.utf8) }
            return try merged.data(from: NSRange(location: 0, length: merged.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        }
        if action == .stitch {
            let images = try urls.map { u -> NSImage in guard let i = NSImage(contentsOf: u), i.size.width > 0, i.size.height > 0 else { throw invalid(u) }; return i }
            let width = images.map { $0.size.width }.max() ?? 0; let height = images.reduce(CGFloat(0)) { $0 + $1.size.height }
            guard width * height <= 40_000_000, width <= 16000, height <= 16000 else { throw invalid(urls[0]) }
            let canvas = NSImage(size: NSSize(width: width, height: height)); canvas.lockFocus(); var y = height
            for i in images { y -= i.size.height; i.draw(in: NSRect(x: 0, y: y, width: i.size.width, height: i.size.height)) }; canvas.unlockFocus()
            guard let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]) else { throw invalid(urls[0]) }; return data
        }
        let result = PDFDocument(); var strings: [String] = []
        for url in urls {
            if pdf(url) {
                guard let doc = PDFDocument(url: url), !doc.isLocked, doc.pageCount > 0 else { throw invalid(url) }
                if action == .extractPDF { strings.append(doc.string ?? ""); continue }
                for index in 0..<doc.pageCount {
                    guard let page = doc.page(at: index)?.copy() as? PDFPage else { throw invalid(url) }
                    if action == .rotatePDF { page.rotation = (page.rotation + 90) % 360 }; result.insert(page, at: result.pageCount)
                }
            } else {
                guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else { throw invalid(url) }; result.insert(page, at: result.pageCount)
            }
        }
        if action == .extractPDF { let text = strings.joined(separator: "\n\n"); guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid(urls[0]) }; return Data(text.utf8) }
        guard let data = result.dataRepresentation() else { throw invalid(urls[0]) }; return data
    }
}
