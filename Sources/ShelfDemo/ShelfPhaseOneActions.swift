import AppKit
import SwiftUI
import Vision
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers

@MainActor enum ShelfPhaseOneActions {
    static func options(_ urls: [URL]) -> [String] {
        guard !urls.isEmpty else { return [] }
        let exts = Set(urls.map { $0.pathExtension.lowercased() })
        var result: [String] = []
        if #available(macOS 14, *), exts.isSubset(of: ["jpg","jpeg","png","heic","heif","webp","tiff","tif"]) { result.append("Remove Background…") }
        let office: Set<String> = ["ppt","pptx","odp","doc","docx","odt","xls","xlsx","ods","pages","key","numbers","txt","rtf","html","htm","md","csv"]
        if exts.isSubset(of: office) { result.append("Convert Document to PDF…") }
        if exts.isSubset(of: ["ppt","pptx","odp","key"]) { result += ["Export Slides as PNG…", "Extract Presentation Text…"] }
        if exts.isSubset(of: ["pptx","docx","xlsx"]) { result.append("Extract Embedded Images…") }
        if exts.isSubset(of: ["ppt","pptx","odp"]) { result.append("Convert Presentation to ODP…") }
        if exts.isSubset(of: ["doc","docx","odt","rtf"]) { result += ["Convert Document to TXT…", "Convert Document to RTF…"] }
        if exts.isSubset(of: ["xls","xlsx","ods","csv","numbers"]) { result.append("Convert First Worksheet to CSV…") }
        if exts == ["csv"] { result.append("Convert CSV to JSON…") }
        if exts.isSubset(of: ["csv","xls","ods","numbers"]) { result.append("Convert Spreadsheet to XLSX…") }
        if exts.isSubset(of: ["pages","doc","odt","rtf"]) { result.append("Convert Document to DOCX…") }
        if exts.isSubset(of: ["key","ppt","odp"]) { result.append("Convert Presentation to PPTX…") }
        if exts.isSubset(of: ["mov","mp4","m4v"]) && urls.count == 1 { result.append("Remove Silent Parts…") }
        return result
    }
    static func append(to menu: NSMenu, urls: [URL], target: AnyObject, selector: Selector) {
        let actions = options(urls)
        guard !actions.isEmpty else { return }
        let heading = NSMenuItem(title: "More File Actions", action: nil, keyEquivalent: "")
        heading.isEnabled = false; menu.addItem(heading)
        for name in actions {
            let row = NSMenuItem(title: name, action: selector, keyEquivalent: "")
            row.target = target; row.representedObject = "phase1:" + name
            row.image = NSImage(systemSymbolName: name.contains("Background") ? "person.crop.rectangle" : "doc.on.doc", accessibilityDescription: nil)
            menu.addItem(row)
        }
        menu.addItem(.separator())
    }
    static func run(_ raw: String, urls: [URL], manager: ShelfManager, shelfID: UUID) {
        let name = String(raw.dropFirst("phase1:".count))
        guard options(urls).contains(name) else { return }
        if name == "Remove Silent Parts…" {
            if #available(macOS 15, *) { ShelfSilenceEditor.open(urls[0]) { url in _ = manager.addFile(url: url, to: shelfID) } }
            return
        }
        let folder: URL
        do { folder = try ShelfWritableStorage.newFolder("Output") }
        catch { ShelfDataLocation.alert("Cannot create output folder", error.localizedDescription); return }
        ShelfPhasePanel.open(title: name, subtitle: "\(urls.count) selected file(s)", operation: { whiteBackground, progress in
            var result: [URL] = []
            for (i, url) in urls.enumerated() {
                try Task.checkCancellation()
                let output = folder.appendingPathComponent(String(i + 1), isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
                result += try ShelfPhaseWorker.process(name, url: url, folder: output, whiteBackground: whiteBackground)
                await progress(i+1, urls.count)
            }
            return result
        }, completion: { results in
            for url in results { _ = manager.addFile(url: url, to: shelfID) }
            NSWorkspace.shared.activateFileViewerSelecting(results)
        }, cleanup: { try? FileManager.default.removeItem(at: folder) })
    }
}

@MainActor final class ShelfPhasePanel: ObservableObject {
    @Published var whiteBackground = false
    @Published var progress = "Ready"
    @Published var running = false
    @Published var message = ""
    private var window: NSPanel?
    private var task: Task<Void, Never>?
    private var worker: Task<[URL], Error>?
    private let operation: @Sendable (Bool, @escaping @MainActor @Sendable (Int, Int) -> Void) async throws -> [URL]
    private let completion: ([URL]) -> Void
    private let cleanup: () -> Void
    private let title: String
    private let subtitle: String
    private init(title: String, subtitle: String, operation: @escaping @Sendable (Bool, @escaping @MainActor @Sendable (Int, Int) -> Void) async throws -> [URL], completion: @escaping ([URL]) -> Void, cleanup: @escaping () -> Void) {
        self.title = title; self.subtitle = subtitle; self.operation = operation; self.completion = completion; self.cleanup = cleanup
    }
    static func open(title: String, subtitle: String, operation: @escaping @Sendable (Bool, @escaping @MainActor @Sendable (Int, Int) -> Void) async throws -> [URL], completion: @escaping ([URL]) -> Void, cleanup: @escaping () -> Void) {
        let model = ShelfPhasePanel(title: title, subtitle: subtitle, operation: operation, completion: completion, cleanup: cleanup)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: title == "Remove Background…" ? 320 : 240), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = title; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ShelfPhasePanelView(model: model))
        model.window = panel; panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    fileprivate var view: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(self.title).font(.headline); Text(self.subtitle).foregroundStyle(.secondary)
            Label("Original files are preserved", systemImage: "checkmark.shield").font(.caption)
            if self.title == "Remove Background…" {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Output Background").font(.subheadline.weight(.semibold))
                    Picker("Output Background", selection: Binding(get: { self.whiteBackground }, set: { self.whiteBackground = $0 })) {
                        Text("Transparent").tag(false)
                        Text("White background").tag(true)
                    }.pickerStyle(.radioGroup).labelsHidden().disabled(self.running)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }
            if self.running { HStack { ProgressView().controlSize(.small); Text(self.progress) } }
            if !self.message.isEmpty { Text(self.message).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(self.running ? "Cancel" : "Close") {
                    if self.running { self.worker?.cancel(); self.progress = "Cancelling…" }
                    else { self.cleanup(); self.close() }
                }
                Button("Continue") { self.start() }.keyboardShortcut(.defaultAction).disabled(self.running || !self.message.isEmpty)
            }
        }.padding(22).frame(width: 420)
    }
    private func start() {
        guard !running else { return }; running = true; progress = "Processing…"
        let operation = self.operation
        let whiteBackground = self.whiteBackground
        let callback: @MainActor @Sendable (Int, Int) -> Void = { [weak self] i, total in self?.progress = "\(i) of \(total) completed" }
        let job = Task.detached(priority: .userInitiated) { try await operation(whiteBackground, callback) }; worker = job
        task = Task {
            do { let results = try await job.value; guard !job.isCancelled else { throw CancellationError() }; completion(results); close() }
            catch { cleanup(); message = error is CancellationError ? "Cancelled." : error.localizedDescription; running = false }
            worker = nil; task = nil
        }
    }
    private func close() { window?.orderOut(nil); window?.contentView = nil; window = nil }
}

enum ShelfPhaseWorker {
    static func error(_ message: String) -> NSError { NSError(domain: "DropShelf.PhaseOne", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    static func process(_ name: String, url: URL, folder: URL, whiteBackground: Bool = false) throws -> [URL] {
        try Task.checkCancellation()
        if name == "Remove Background…" {
            guard #available(macOS 14, *) else { throw error("Requires macOS 14 or later.") }
            let image = try cutout(url, whiteBackground: whiteBackground)
            let dest = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + (whiteBackground ? "-white.png" : "-transparent.png"))
            try Task.checkCancellation(); try ShelfWritableStorage.commit(image, to: dest); return [dest]
        }
        if name == "Convert CSV to JSON…" {
            let dest = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".json")
            try ShelfWritableStorage.commit(try csvJSON(url), to: dest); return [dest]
        }
        if name == "Extract Embedded Images…" { return try extractImages(url, folder) }
        if name == "Export Slides as PNG…" || name == "Extract Presentation Text…" {
            let pdf = try convert(url, to: "pdf", folder: folder)
            guard let doc = PDFDocument(url: pdf), doc.pageCount > 0 else { throw error("Cannot open rendered presentation.") }
            var results: [URL] = []
            if name == "Extract Presentation Text…" {
                let content = (0..<doc.pageCount).map { "Slide \($0+1)\n" + (doc.page(at: $0)?.string ?? "") }.joined(separator: "\n\n")
                guard (doc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { throw error("No searchable text in the rendered presentation.") }
                let dest = folder.appendingPathComponent("Slides.txt"); try ShelfWritableStorage.commit(Data(content.utf8), to: dest); results.append(dest)
            } else {
                for index in 0..<doc.pageCount {
                    try Task.checkCancellation()
                    guard let page = doc.page(at: index) else { throw error("Missing slide.") }
                    let bounds = page.bounds(for: .mediaBox)
                    let scale = min(2, 2400 / max(bounds.width, bounds.height))
                    let thumb = page.thumbnail(of: CGSize(width: bounds.width*scale, height: bounds.height*scale), for: .mediaBox)
                    guard let tiff = thumb.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { throw error("Cannot render slide.") }
                    let dest = folder.appendingPathComponent(String(format: "Slide-%03d.png", index+1)); try ShelfWritableStorage.commit(png, to: dest); results.append(dest)
                }
            }
            try FileManager.default.removeItem(at: pdf); return results
        }
        let formats = ["Convert Document to PDF…":"pdf", "Convert Presentation to ODP…":"odp", "Convert Document to TXT…":"txt", "Convert Document to RTF…":"rtf", "Convert First Worksheet to CSV…":"csv", "Convert Spreadsheet to XLSX…":"xlsx", "Convert Document to DOCX…":"docx", "Convert Presentation to PPTX…":"pptx"]
        guard let ext = formats[name] else { throw error("Unsupported action.") }
        return [try convert(url, to: ext, folder: folder)]
    }
    @available(macOS 14, *) private static func cutout(_ url: URL, whiteBackground: Bool) throws -> Data {
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]), image.extent.width > 0, image.extent.height > 0 else { throw error("Cannot read image.") }
        let extent = image.extent
        guard extent.width * extent.height <= 80_000_000 else { throw error("Image is too large for safe background removal.") }
        let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let handler = VNImageRequestHandler(ciImage: normalized, options: [:]); let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request]); try Task.checkCancellation()
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { throw error("No foreground subject found.") }
        let mask = CIImage(cvPixelBuffer: try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler))
        let transparent = CIImage(color: whiteBackground ? CIColor(red: 1, green: 1, blue: 1, alpha: 1) : CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: normalized.extent)
        let blended = normalized.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: transparent, kCIInputMaskImageKey: mask]).cropped(to: normalized.extent)
        let result = whiteBackground ? blended.composited(over: transparent).cropped(to: normalized.extent) : blended
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB), let png = CIContext().pngRepresentation(of: result, format: .RGBA8, colorSpace: cs) else { throw error("Could not encode transparent PNG.") }
        return png
    }
    private static func convert(_ url: URL, to ext: String, folder: URL) throws -> URL {
        let executable = URL(fileURLWithPath: "/Applications/LibreOffice.app/Contents/MacOS/soffice")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw error("Install the free LibreOffice app in Applications for document rendering.") }
        let profile = folder.appendingPathComponent(".lo-profile", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: profile) }
        _ = try run(executable, ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--convert-to", ext, "--outdir", folder.path, url.path], folder: folder)
        let dest = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent).appendingPathExtension(ext)
        guard let size = try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { throw error("LibreOffice could not convert \(url.lastPathComponent). This format may not be supported.") }
        if ext == "pdf", (PDFDocument(url: dest)?.pageCount ?? 0) == 0 { throw error("Invalid PDF output.") }
        return dest
    }
    // CSV fields support quoted commas, escaped quotes and multiline values.
    // Use arrays to preserve duplicate headings and uneven rows without loss.
    private static func csvJSON(_ url: URL) throws -> Data {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 25_000_000 else { throw error("CSV is too large.") }
        guard var text = String(data: try Data(contentsOf: url), encoding: .utf8) else { throw error("CSV must use UTF-8 encoding.") }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, closed = false
        var iterator = text.makeIterator(), pending: Character? = iterator.next()
        while let c = pending {
            pending = iterator.next()
            if quoted {
                if c == "\"" { if pending == "\"" { field.append(c); pending = iterator.next() } else { quoted = false; closed = true } }
                else { field.append(c) }
            } else if c == "," { row.append(field); field = ""; closed = false }
            else if c == "\n" || c == "\r" || c == "\r\n" {
                if c == "\r", pending == "\n" { pending = iterator.next() }
                row.append(field); rows.append(row); row = []; field = ""; closed = false
                try Task.checkCancellation()
            } else if c == "\"", field.isEmpty, !closed { quoted = true }
            else if closed || c == "\"" { throw error("Malformed CSV quoting.") }
            else { field.append(c) }
        }
        guard !quoted else { throw error("Unclosed CSV quoted field.") }
        if !row.isEmpty || !field.isEmpty || closed { row.append(field); rows.append(row) }
        return try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
    }
    private static func extractImages(_ url: URL, _ folder: URL) throws -> [URL] {
        let unzip = URL(fileURLWithPath: "/usr/bin/unzip")
        let list = try run(unzip, ["-Z1", url.path], folder: folder)
        guard let names = String(data: list, encoding: .utf8) else { throw error("Cannot read document package.") }
        let entries = names.split(separator: "\n").map(String.init).filter { n in
            let parts = n.split(separator: "/")
            return parts.count == 3 && ["ppt","word","xl"].contains(String(parts[0])) && parts[1] == "media" && n.rangeOfCharacter(from: CharacterSet(charactersIn: "*?[]\\")) == nil && UTType(filenameExtension: URL(fileURLWithPath: n).pathExtension)?.conforms(to: .image) == true
        }
        guard !entries.isEmpty, entries.count <= 500 else { throw error("No embedded images, or too many images.") }
        var output: [URL] = []
        for (i, entry) in entries.enumerated() {
            try Task.checkCancellation()
            let data = try run(unzip, ["-p", url.path, entry], folder: folder)
            guard !data.isEmpty else { throw error("Empty embedded image.") }
            let dest = folder.appendingPathComponent("\(i+1)-" + URL(fileURLWithPath: entry).lastPathComponent)
            try ShelfWritableStorage.commit(data, to: dest); output.append(dest)
        }
        return output
    }
    private static func run(_ executable: URL, _ args: [String], folder: URL) throws -> Data {
        let log = folder.appendingPathComponent(".process-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: log.path, contents: nil) else { throw error("Cannot create process output.") }
        defer { try? FileManager.default.removeItem(at: log) }
        let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
        let p = Process(); p.executableURL = executable; p.arguments = args; p.standardOutput = handle; p.standardError = FileHandle.nullDevice
        try p.run(); let started = Date()
        while p.isRunning {
            if Task.isCancelled || Date().timeIntervalSince(started) > 180 || ((try? log.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 100_000_000 {
                p.terminate(); p.waitUntilExit(); try Task.checkCancellation(); throw error("Conversion exceeded time or size limit.")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard p.terminationStatus == 0 else { throw error("Document tool exited with error \(p.terminationStatus).") }
        guard ((try? log.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) <= 100_000_000 else { throw error("Process output too large.") }
        return try Data(contentsOf: log)
    }
}

private struct ShelfPhasePanelView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: ShelfPhasePanel
    var body: some View { model.view.frame(maxWidth: .infinity, maxHeight: .infinity).background(ShelfSettingsPalette.content(colorScheme)) }
}
