import AppKit
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum SmartFileActions {
    enum Action: String, Sendable {
        case splitPDF = "Split PDF into Pages…", extractPages = "Extract / Reorder PDF Pages…", deletePages = "Delete PDF Pages…", compressPDF = "Compress PDF…", protectPDF = "Password Protect PDF…", wordPDF = "Convert Word to PDF…"
        case pdfWord = "Convert PDF to Word (.docx)…"
        case mergePDF = "Merge PDFs…", combinedPDF = "Create Combined PDF…", imagePDF = "Create PDF…", mergeWord = "Merge Word Documents…", rotatePDF = "Rotate PDF Pages 90°…", extractPDF = "Extract PDF Text…", wordText = "Extract Word Text…", stitch = "Stitch Images…", resize = "Resize Images…", compress = "Compress Images…", metadata = "Remove Image Metadata", convertImage = "Convert Image Format…"
    }
    static func files(_ items: [ShelfItem]) -> [URL] {
        items.compactMap(\.fileURL).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }
    nonisolated static func image(_ u: URL) -> Bool { UTType(filenameExtension: u.pathExtension)?.conforms(to: .image) == true }
    nonisolated static func pdf(_ u: URL) -> Bool { u.pathExtension.lowercased() == "pdf" }
    static func word(_ u: URL) -> Bool { u.pathExtension.lowercased() == "docx" }
    static func options(_ urls: [URL]) -> [Action] {
        guard !urls.isEmpty else { return [] }
        if urls.allSatisfy(pdf) { return (urls.count > 1 ? [.mergePDF] : []) + [.rotatePDF, .extractPDF] + (urls.count == 1 ? [.splitPDF, .extractPages, .deletePages, .compressPDF, .protectPDF, .pdfWord] : []) }
        if urls.allSatisfy(word) { return (urls.count > 1 ? [.mergeWord] : []) + [.wordText, .wordPDF] }
        if urls.allSatisfy(image) { return [.imagePDF, .resize, .compress, .convertImage, .metadata] + (urls.count > 1 ? [.stitch] : []) }
        if urls.count > 1 && urls.allSatisfy({ pdf($0) || image($0) }) { return [.combinedPDF] }
        return []
    }
    static func append(to menu: NSMenu, items: [ShelfItem], target: AnyObject, selector: Selector) {
        let urls = files(items)
        let actions = urls.count == items.count ? options(urls) : []
        let archiveURLs = items.compactMap(\.fileURL)
        let canArchive = !items.isEmpty && archiveURLs.count == items.count && archiveURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        var appended = false
        do {
            let presets = ShelfCustomAction.load().filter { preset in
                preset.enabled && preset.valid && (["zip", "move", "copy", "open", "rename"].contains(preset.kind) ? canArchive : preset.kind == "ocr" ? (urls.count == items.count && !urls.isEmpty && urls.allSatisfy(image)) : preset.action.map { actions.contains($0) } == true)
            }
            if !presets.isEmpty {
                let entry = NSMenuItem(title: "Custom Actions", action: nil, keyEquivalent: "")
                entry.isEnabled = false; menu.addItem(entry)
                for preset in presets {
                    let item = NSMenuItem(title: preset.name, action: selector, keyEquivalent: "")
                    item.target = target; item.representedObject = preset.id.uuidString
                    menu.addItem(item)
                }
                appended = true
                if !actions.isEmpty { menu.addItem(.separator()) }
            }
        }
        if !actions.isEmpty { let heading = NSMenuItem(title: urls.allSatisfy(image) ? "Image Actions" : "Document Actions", action: nil, keyEquivalent: ""); heading.isEnabled = false; menu.addItem(heading) }
        for action in actions {
            let row = NSMenuItem(title: action.rawValue, action: selector, keyEquivalent: "")
            row.target = target
            row.representedObject = action.rawValue
            row.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            menu.addItem(row)
        }
        if appended || !actions.isEmpty { menu.addItem(.separator()) }
        if urls.count == items.count { ShelfPhaseOneActions.append(to: menu, urls: urls, target: target, selector: selector) }
        let general = NSMenuItem(title: "General Actions", action: nil, keyEquivalent: ""); general.isEnabled = false; menu.addItem(general)
    }
    static func run(_ sender: NSMenuItem, items: [ShelfItem], manager: ShelfManager, shelfID: UUID) {
        guard let raw = sender.representedObject as? String else { return }
        let urls = files(items)
        if raw.hasPrefix("phase1:") { if urls.count == items.count { ShelfPhaseOneActions.run(raw, urls: urls, manager: manager, shelfID: shelfID) }; return }
        if let preset = ShelfCustomAction.load().first(where: { $0.id.uuidString == raw && $0.enabled }) {
            if ["zip", "move", "copy", "open", "rename", "ocr"].contains(preset.kind) {
                let selected = items.compactMap(\.fileURL)
                guard !selected.isEmpty, selected.count == items.count,
                      selected.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return }
                ShelfPresetExecutor.run(preset, items: items, manager: manager, shelfID: shelfID)
                return
            }
            guard preset.valid, !urls.isEmpty, urls.count == items.count, let action = preset.action,
                  options(urls).contains(action) else { return }
            ShelfToolRouter.open(action: action, urls: urls, shelfID: shelfID, preset: preset)
            return
        }
        guard let action = Action(rawValue: raw) else { return }
        guard urls.count == items.count, options(urls).contains(action) else { return }
        if action == .wordPDF && PDFToolkit.libreOffice == nil { failure("Install LibreOffice in Applications, then try again."); return }
        if [.resize, .compress, .convertImage, .metadata].contains(action) {
            ImageToolPanel.present(action: action, urls: urls, manager: manager, shelfID: shelfID)
        } else {
            DocumentToolPanel.present(action: action, urls: urls, manager: manager, shelfID: shelfID)
        }
    }

    nonisolated static func documentExtension(_ action: Action) -> String {
        if action == .mergeWord || action == .pdfWord { return "docx" }
        if [.extractPDF, .wordText].contains(action) { return "txt" }
        if action == .stitch { return "png" }
        return "pdf"
    }

    // Output is always a new file. The selected folder is optional; the default
    // is a fresh app-owned directory, never the source folder or a stale save location.
    static func performDocument(_ action: Action, urls: [URL], name: String, folder: URL?, pages: String,
                                dpi: Double, password: String, flag: DocumentCancellation, stitchColumns: Int = 1, stitchRows: Int = 0, enhanceImages: Bool = false, stitchGap: Int = 0, stitchBackground: String = "Transparent", rotation: Int = 90, wordMode: String? = nil) async throws -> [URL] {
        try flag.check()
        guard !urls.isEmpty, options(urls).contains(action) else { throw PDFToolkit.error("No compatible files selected.") }
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !base.hasPrefix("."), !base.contains("/"), !base.contains(":"), !base.contains("\u{0}"), base.utf8.count <= 200 else {
            throw PDFToolkit.error("Enter a valid output name.")
        }
        let root = try folder ?? ShelfWritableStorage.newFolder("Output")
        let ext = documentExtension(action)
        let dest = root.appendingPathComponent(base.lowercased().hasSuffix("." + ext) ? base : base + "." + ext)
        if action == .splitPDF, let url = urls.first {
            let output = root.appendingPathComponent(base, isDirectory: true)
            return try await Task.detached(priority: .userInitiated) {
                guard let doc = PDFDocument(url: url), !doc.isLocked, doc.pageCount > 0 else { throw PDFToolkit.error("Cannot read PDF.") }
                try flag.check()
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
                var complete = false
                var generated: [URL] = []
                defer {
                    if !complete {
                        for file in generated { try? FileManager.default.removeItem(at: file) }
                        if (try? FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty) == true {
                            try? FileManager.default.removeItem(at: output)
                        }
                    }
                }
                for i in 0..<doc.pageCount {
                    try flag.check()
                    let file = output.appendingPathComponent("Page-\(i + 1).pdf")
                    try ShelfWritableStorage.commit(PDFToolkit.subset(doc, indices: [i]), to: file)
                    generated.append(file)
                    guard PDFDocument(url: file)?.pageCount == 1 else { throw PDFToolkit.error("Invalid split output.") }
                }
                try flag.check(); complete = true; return generated
            }.value
        }
        guard !FileManager.default.fileExists(atPath: dest.path),
              !urls.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL == dest.resolvingSymlinksInPath().standardizedFileURL }) else {
            throw PDFToolkit.error("An output with this name already exists. Choose a different name to preserve all files.")
        }
        let data: Data
        if action == .pdfWord {
            data = try await Task.detached(priority: .userInitiated) {
                try PDFWordConverter.convert(urls[0], modeOverride: wordMode, cancelled: { flag.isCancelled() })
            }.value
        } else if action == .wordPDF {
            data = try await Task.detached(priority: .userInitiated) {
                try PDFToolkit.wordPDF(urls, cancelled: { flag.isCancelled() })
            }.value
        } else if [.extractPages, .deletePages, .compressPDF, .protectPDF].contains(action) {
            data = try await Task.detached(priority: .userInitiated) {
                guard let doc = PDFDocument(url: urls[0]), !doc.isLocked, doc.pageCount > 0 else { throw PDFToolkit.error("Cannot read PDF.") }
                try flag.check()
                switch action {
                case .extractPages, .deletePages:
                    let chosen = try PDFToolkit.pages(pages, count: doc.pageCount)
                    let indices = action == .deletePages ? (0..<doc.pageCount).filter { !chosen.contains($0) } : chosen
                    return try PDFToolkit.subset(doc, indices: indices)
                case .compressPDF:
                    guard (72...200).contains(dpi) else { throw PDFToolkit.error("Choose a resolution from 72 to 200 DPI.") }
                    let bytes = try PDFToolkit.compress(doc, dpi: CGFloat(dpi), quality: 0.55, cancelled: { flag.isCancelled() })
                    guard PDFDocument(data: bytes)?.pageCount == doc.pageCount else { throw PDFToolkit.error("Invalid compressed output.") }
                    if let size = try? urls[0].resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes.count >= size {
                        throw PDFToolkit.error("Compressed copy is not smaller. Try a lower resolution.")
                    }
                    return bytes
                case .protectPDF:
                    guard !password.isEmpty, let bytes = doc.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: password, PDFDocumentWriteOption.ownerPasswordOption: UUID().uuidString]),
                          PDFDocument(data: bytes)?.isLocked == true else { throw PDFToolkit.error("Could not verify PDF encryption.") }
                    return bytes
                default: throw PDFToolkit.error("Unsupported PDF action.")
                }
            }.value
        } else if [.mergePDF, .rotatePDF, .extractPDF, .imagePDF, .combinedPDF].contains(action) {
            // PDFKit and CoreGraphics objects stay within the worker.
            data = try await Task.detached(priority: .userInitiated) { try pdfOutput(action, urls, flag: flag, enhance: enhanceImages, rotation: rotation) }.value
        } else if action == .stitch {
            data = try await Task.detached(priority: .userInitiated) { try stitchedImage(urls, flag: flag, columns: stitchColumns, rows: stitchRows, enhance: enhanceImages, gap: stitchGap, background: stitchBackground) }.value
        } else {
            // Word attributed-string import can require the main thread.
            data = try wordOutput(action, urls, flag: flag)
        }
        return try await Task.detached(priority: .userInitiated) {
            try flag.check()
            if ext == "pdf", action != .protectPDF {
                guard let document = PDFDocument(data: data), document.pageCount > 0 else { throw PDFToolkit.error("Invalid PDF output.") }
                if action == .imagePDF && document.pageCount != urls.count {
                    throw PDFToolkit.error("One or more images did not become PDF pages.")
                }
            }
            try flag.check()
            try ShelfWritableStorage.commit(data, to: dest)
            return [dest]
        }.value
    }
    private static func failure(_ message: String) { let a = NSAlert(); a.messageText = "File Action Failed"; a.informativeText = message; a.runModal() }
    nonisolated private static func pdfOutput(_ action: Action, _ urls: [URL], flag: DocumentCancellation, enhance: Bool = false, rotation: Int = 90) throws -> Data {
        let result = PDFDocument()
        var strings: [String] = []
        for url in urls {
            try flag.check()
            if pdf(url) {
                guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else {
                    throw PDFToolkit.error("Cannot read \(url.lastPathComponent).")
                }
                if action == .extractPDF { strings.append(document.string ?? ""); continue }
                for index in 0..<document.pageCount {
                    try flag.check()
                    guard let page = document.page(at: index)?.copy() as? PDFPage else { throw PDFToolkit.error("Cannot copy PDF page.") }
                    if action == .rotatePDF { page.rotation = (page.rotation + rotation) % 360 }
                    result.insert(page, at: result.pageCount)
                }
            } else if action == .imagePDF || action == .combinedPDF {
                let page = try autoreleasepool { try imagePDFPage(url, enhance: enhance) }
                try flag.check()
                result.insert(page, at: result.pageCount)
            } else {
                throw PDFToolkit.error("Unsupported input: \(url.lastPathComponent).")
            }
        }
        try flag.check()
        if action == .extractPDF {
            let text = strings.joined(separator: "\n\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PDFToolkit.error("No searchable text. Try OCR first.") }
            return Data(text.utf8)
        }
        guard result.pageCount > 0, let data = result.dataRepresentation() else { throw PDFToolkit.error("Cannot create PDF.") }
        return data
    }

    nonisolated private static func imagePDFPage(_ url: URL, enhance: Bool = false) throws -> PDFPage {
        let image = try ImageActions.enhanced(ImageActions.fullImage(url), enabled: enhance)
        let scale = min(CGFloat(1), 14400 / CGFloat(max(image.width, image.height)))
        var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw PDFToolkit.error("Cannot create a PDF page for \(url.lastPathComponent).")
        }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(box)
        context.interpolationQuality = .high
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
        guard let document = PDFDocument(data: data as Data), let page = document.page(at: 0)?.copy() as? PDFPage else {
            throw PDFToolkit.error("Cannot read the generated PDF page.")
        }
        return page
    }

    nonisolated private static func stitchedImage(_ urls: [URL], flag: DocumentCancellation, columns: Int, rows: Int, enhance: Bool = false, gap: Int = 0, background: String = "Transparent") throws -> Data {
        guard (0...100).contains(gap), (1...12).contains(columns), (0...12).contains(rows), !urls.isEmpty else { throw PDFToolkit.error("Invalid grid.") }
        let rowCount = rows == 0 ? (urls.count + columns - 1) / columns : rows
        guard urls.count <= rowCount * columns, rowCount <= 1000 else { throw PDFToolkit.error("Grid is too small or too large.") }
        var sizes: [ShelfPixelSize] = []
        var widths = Array(repeating: 0, count: columns), heights = Array(repeating: 0, count: rowCount)
        for (i,url) in urls.enumerated() {
            try flag.check()
            let source = try ImageActions.open(url)
            guard let size = ImageActions.orientedSize(of: source), size.isSafeToRender else { throw PDFToolkit.error("Cannot render image.") }
            sizes.append(size)
            widths[i % columns] = max(widths[i % columns], size.width)
            heights[i / columns] = max(heights[i / columns], size.height)
        }
        let fallbackW = widths.max() ?? 1, fallbackH = heights.max() ?? 1
        widths = widths.map { $0 == 0 ? fallbackW : $0 }; heights = heights.map { $0 == 0 ? fallbackH : $0 }
        let width = widths.reduce(0,+) + gap * (columns - 1), height = heights.reduce(0,+) + gap * (rowCount - 1)
        guard ShelfPixelSize(width: width, height: height).isSafeToRender,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PDFToolkit.error("Grid exceeds the supported dimensions or 40 megapixel limit.") }
        context.clear(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        if background == "White" || background == "Black" {
            context.setFillColor(gray: background == "White" ? 1 : 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        }
        for (i,url) in urls.enumerated() {
            try flag.check()
            let col = i % columns, row = i / columns, size = sizes[i]
            let x = widths.prefix(col).reduce(0,+) + gap * col + (widths[col]-size.width)/2
            let y = height - heights.prefix(row).reduce(0,+) - gap * row - heights[row] + (heights[row]-size.height)/2
            try autoreleasepool { let image = try ImageActions.enhanced(ImageActions.fullImage(url), enabled: enhance); context.draw(image, in: CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(size.width), height: CGFloat(size.height))) }
        }
        try flag.check()
        let data = NSMutableData()
        guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { throw PDFToolkit.error("Cannot encode grid.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PDFToolkit.error("Cannot save grid.") }
        return data as Data
    }

    private static func wordOutput(_ action: Action, _ urls: [URL], flag: DocumentCancellation) throws -> Data {
        guard action == .mergeWord || action == .wordText else { throw PDFToolkit.error("Unsupported document action.") }
        let merged = NSMutableAttributedString(string: "")
        for url in urls {
            try flag.check()
            let part = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
            if merged.length > 0 { merged.append(NSAttributedString(string: "\n\n")) }
            merged.append(part)
        }
        if action == .wordText { return Data(merged.string.utf8) }
        return try merged.data(from: NSRange(location: 0, length: merged.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    }
}
