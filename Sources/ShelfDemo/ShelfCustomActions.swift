import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShelfCustomAction: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name = "Compress Images"
    var kind = "compress"
    var width = 1200
    var height = 1200
    var quality = 80
    var format = "png"
    var enabled = true
    var pdfDPI: Int? = nil
    var destinationRaw: String? = nil
    var folderPath: String? = nil
    var applicationPath: String? = nil
    var renamePattern: String? = nil
    var ocrOutput: String? = nil
    var enlarge: Bool? = nil
    var archiveName: String? = nil
    var stitchColumns: Int? = nil
    var stitchRows: Int? = nil
    var stitchGap: Int? = nil
    var stitchBackground: String? = nil
    var enhanceImages: Bool? = nil
    var rotation: Int? = nil
    var wordMode: String? = nil
    var archiveBase: String { (archiveName ?? "Archive").trimmingCharacters(in: .whitespacesAndNewlines) }
    var description: String {
        switch kind {
        case "move": return "Move selected files to a predefined folder."
        case "copy": return "Copy selected files to a predefined folder."
        case "open": return "Open selected files with your preferred application."
        case "rename": return "Rename files using a reusable naming pattern."
        case "ocr": return "Extract text from images to the clipboard or a text file."
        case "stitch": return "Combine images using a saved grid, spacing and background."
        case "compress": return "Reduce image size using your preferred JPEG quality."
        case "resize": return "Fit images within your chosen dimensions, preserving proportions."
        case "convert": return "Convert images to your preferred format and quality."
        case "metadata": return "Create copies without embedded image metadata."
        case "imagePDF": return "Combine images into a PDF with optional clarity enhancement."
        case "compressPDF": return "Reduce PDF size using a saved raster resolution."
        case "rotatePDF": return "Rotate every page by a predefined angle."
        case "pdfWord": return "Convert PDFs using your preferred Word conversion mode."
        case "zip": return "Combine files into a reusable named ZIP archive."
        default: return "Save reusable action parameters."
        }
    }
    var destination: ShelfOutputDestination { ShelfOutputDestination(rawValue: destinationRaw ?? "") ?? .shelf }
    var folder: URL? { folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } }
    var valid: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if kind == "zip" && (archiveBase.isEmpty || archiveBase.hasPrefix(".") || archiveBase.contains("/") || archiveBase.contains(":") || archiveBase.contains("\u{0}") || archiveBase.utf8.count > 180) { return false }
        if kind == "resize" && (!(1...16000).contains(width) || !(1...16000).contains(height)) { return false }
        if ["move", "copy"].contains(kind) { return folder != nil }
        if kind == "open" { return applicationPath != nil }
        if kind == "rename" { return !(renamePattern ?? "").isEmpty && !(renamePattern ?? "").contains("/") && !(renamePattern ?? "").contains(":") }
        return destination != .folder || folder != nil
    }

    static let kinds: [(String, String)] = [
        ("move", "Move Files to Folder"), ("copy", "Copy Files to Folder"), ("open", "Open with Application"), ("rename", "Rename Files"), ("ocr", "Extract Text from Image"), ("stitch", "Stitch Images"), ("compress", "Compress Images"), ("resize", "Resize Images"),
        ("convert", "Convert Image Format"), ("metadata", "Remove Image Metadata"),
        ("imagePDF", "Create PDF"), ("compressPDF", "Compress PDF"),
        ("rotatePDF", "Rotate PDF"), ("pdfWord", "Convert PDF to Word"), ("zip", "Create ZIP Archive")
    ]
    var action: SmartFileActions.Action? {
        switch kind {
        case "compress": return .compress
        case "resize": return .resize
        case "convert": return .convertImage
        case "metadata": return .metadata
        case "stitch": return .stitch
        case "imagePDF": return .imagePDF
        case "compressPDF": return .compressPDF
        case "rotatePDF": return .rotatePDF
        case "pdfWord": return .pdfWord
        default: return nil
        }
    }
    var summary: String {
        switch kind {
        case "move", "copy": return folder?.path ?? "Choose a folder"
        case "open": return applicationPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Choose an application"
        case "rename": return renamePattern ?? "Name pattern"
        case "ocr": return ocrOutput ?? "Clipboard"
        case "resize": return "Maximum \(width) × \(height) px"
        case "convert": return "Convert to \(format.uppercased())" + (["jpg", "heic"].contains(format) ? " · \(quality)%" : "")
        case "zip": return archiveBase
        case "rotatePDF": return "Rotate \(rotation ?? 90)°"
        case "stitch": return "\(stitchColumns ?? 1) columns · \(stitchGap ?? 0) px spacing"
        case "pdfWord": return wordMode ?? "System preference"
        case "compress": return "JPEG quality \(quality)%"
        case "compressPDF": return "PDF resolution \(pdfDPI ?? 120) DPI"
        default: return Self.kinds.first { $0.0 == kind }?.1 ?? kind
        }
    }
    static let key = "shelf.customActions.v1"
    static func decode(_ data: Data) -> [Self] { (try? JSONDecoder().decode([Self].self, from: data)) ?? [] }
    static func load() -> [Self] { decode(UserDefaults.standard.data(forKey: key) ?? Data()) }
}

struct ShelfCustomActionsSettings: View {
    @AppStorage(ShelfCustomAction.key) private var data = Data()
    @State private var editing: ShelfCustomAction?
    private var items: [ShelfCustomAction] { ShelfCustomAction.decode(data) }
    private func save(_ rows: [ShelfCustomAction]) { if let encoded = try? JSONEncoder().encode(rows) { data = encoded } }
    private func move(_ item: ShelfCustomAction, by delta: Int) {
        var rows = items
        guard let i = rows.firstIndex(where: { $0.id == item.id }), rows.indices.contains(i + delta) else { return }
        rows.swapAt(i, i + delta); save(rows)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if items.isEmpty { Text("No custom actions yet. Add a preset to reuse your preferred parameters.").foregroundStyle(.secondary) }
            ForEach(items) { item in
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
                    VStack(alignment: .leading) { Text(item.name).fontWeight(.medium); Text(item.summary).font(.caption).foregroundStyle(.secondary) }
                    Spacer(minLength: 8)
                    Toggle("Enabled", isOn: Binding(get: { item.enabled }, set: { value in var rows = items; if let i = rows.firstIndex(where: { $0.id == item.id }) { rows[i].enabled = value; save(rows) } })).labelsHidden().toggleStyle(.switch)
                    ShelfSettingsActionMenu(title: "Reorder", commands: [
                        ShelfSettingsCommand(title: "Move Up", enabled: items.first?.id != item.id) { move(item, by: -1) },
                        ShelfSettingsCommand(title: "Move Down", enabled: items.last?.id != item.id) { move(item, by: 1) }
                    ])
                    Button("Edit…") { editing = item }.buttonStyle(ShelfSmallButton())
                    Button { save(items.filter { $0.id != item.id }) } label: { Image(systemName: "trash") }.buttonStyle(ShelfSmallButton()).accessibilityLabel("Delete preset")
                }
                if item.id != items.last?.id { Divider() }
            }
            HStack {
                Spacer()
                ShelfSettingsActionMenu(title: "Add Action…", commands: ShelfCustomAction.kinds.map { kind, name in
                    ShelfSettingsCommand(title: name) {
                        var draft = ShelfCustomAction()
                        draft.kind = kind
                        draft.name = name
                        editing = draft
                    }
                })
            }
        }
        .sheet(item: $editing) { item in
            ShelfCustomActionEditor(item: item) { changed in
                var rows = items
                if let i = rows.firstIndex(where: { $0.id == changed.id }) { rows[i] = changed } else { rows.append(changed) }
                save(rows); editing = nil
            } cancel: { editing = nil }
        }
    }
}

private struct ShelfCustomActionEditor: View {
    @State var item: ShelfCustomAction
    let save: (ShelfCustomAction) -> Void
    let cancel: () -> Void
    @State private var choosing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(ShelfCustomAction.kinds.first { $0.0 == item.kind }?.1 ?? "Custom Action").font(.system(size: 22, weight: .semibold)).frame(maxWidth: .infinity)
            Text(item.description).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            ActionPanelGroup { HStack { Text("Display name"); Spacer(); TextField("Name", text: $item.name).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(maxWidth: 240) } }
            if !["metadata"].contains(item.kind) {
            ActionPanelGroup {
            if item.kind == "resize" {
                HStack { Text("Maximum width"); Spacer(); TextField("Width", value: $item.width, format: .number).textFieldStyle(.plain).padding(7).background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)).frame(width: 95); Text("px").foregroundStyle(.secondary) }
                HStack { Text("Maximum height"); Spacer(); TextField("Height", value: $item.height, format: .number).textFieldStyle(.plain).padding(7).background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)).frame(width: 95); Text("px").foregroundStyle(.secondary) }
            } else if item.kind == "compress" {
                HStack { Text("Quality"); Spacer(); Text("\(item.quality)%") }
                Slider(value: Binding(get: { Double(item.quality) }, set: { item.quality = Int($0.rounded()) }), in: 10...100)
            } else if item.kind == "convert" {
                HStack { Text("Format"); Spacer(); ModernSettingsMenu(title: "Format", selection: $item.format, options: [("png", "PNG"), ("jpg", "JPEG"), ("heic", "HEIC"), ("tiff", "TIFF")]) }
                if ["jpg", "heic"].contains(item.format) {
                    HStack { Text("Image quality"); Spacer(); Text("\(item.quality)%") }
                    Slider(value: Binding(get: { Double(item.quality) }, set: { item.quality = Int($0.rounded()) }), in: 10...100)
                }
            } else if item.kind == "compressPDF" {
                HStack { Text("Resolution"); Spacer(); Text("\(item.pdfDPI ?? 120) DPI") }
                Slider(value: Binding(get: { Double(item.pdfDPI ?? 120) }, set: { item.pdfDPI = Int($0.rounded()) }), in: 72...200)
            }
            if item.kind == "resize" { Divider(); HStack { Text("Allow enlargement"); Spacer(); Toggle("Allow enlargement", isOn: Binding(get: { item.enlarge ?? false }, set: { item.enlarge = $0 })).labelsHidden().toggleStyle(.switch) } }
            if item.kind == "zip" {
                HStack { Text("Archive name"); Spacer(); TextField("Archive", text: Binding(get: { item.archiveName ?? "Archive" }, set: { item.archiveName = $0 })).textFieldStyle(.roundedBorder).frame(maxWidth: 220) }
            }
            if item.kind == "stitch" {
                HStack { Text("Columns"); Spacer(); ModernSettingsMenu(title: "Columns", selection: Binding(get: { item.stitchColumns ?? 1 }, set: { item.stitchColumns = $0 }), options: (1...12).map { ($0, String($0)) }) }
                Divider()
                HStack { Text("Rows"); Spacer(); ModernSettingsMenu(title: "Rows", selection: Binding(get: { item.stitchRows ?? 0 }, set: { item.stitchRows = $0 }), options: [(0, "Automatic")] + (1...12).map { ($0, String($0)) }) }
                Divider()
                HStack { Text("Spacing"); Spacer(); Text("\(item.stitchGap ?? 0) px") }
                Slider(value: Binding(get: { Double(item.stitchGap ?? 0) }, set: { item.stitchGap = Int($0.rounded()) }), in: 0...100)
                HStack { Text("Background"); Spacer(); ModernSettingsMenu(title: "Background", selection: Binding(get: { item.stitchBackground ?? "Transparent" }, set: { item.stitchBackground = $0 }), options: ["Transparent", "White", "Black"].map { ($0, $0) }) }
            }
            if ["stitch", "imagePDF"].contains(item.kind) {
                HStack { Text("Enhance image clarity"); Spacer(); Toggle("Enhance image clarity", isOn: Binding(get: { item.enhanceImages ?? false }, set: { item.enhanceImages = $0 })).labelsHidden().toggleStyle(.switch) }
            }
            if item.kind == "rotatePDF" {
                HStack { Text("Rotation"); Spacer(); ModernSettingsMenu(title: "Rotation", selection: Binding(get: { item.rotation ?? 90 }, set: { item.rotation = $0 }), options: [(90,"90° clockwise"),(180,"180°"),(270,"90° counterclockwise")]) }
            }
            if item.kind == "pdfWord" {
                HStack { Text("Conversion mode"); Spacer(); ModernSettingsMenu(title: "Conversion mode", selection: Binding(get: { item.wordMode ?? "default" }, set: { item.wordMode = $0 == "default" ? nil : $0 }), options: [("default","System preference"),("automatic","Automatic"),("editable","Editable Word"),("appearance","Preserve appearance")]) }
            }
            if item.kind == "ocr" {
                HStack { Text("Output"); Spacer(); ModernSettingsMenu(title: "Output", selection: Binding(get: { item.ocrOutput ?? "Clipboard" }, set: { item.ocrOutput = $0 }), options: [("Clipboard", "Clipboard"), ("Text File", "Text File")]) }
            }
            if item.kind == "rename" {
                HStack { Text("Name pattern (# = number)"); Spacer(); TextField("File-#", text: Binding(get: { item.renamePattern ?? "" }, set: { item.renamePattern = $0 })).textFieldStyle(.roundedBorder) }
            } else if item.kind == "open" {
                HStack { Text("Application"); Spacer(); Button(item.applicationPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Choose Application…") { chooseApplication() }.buttonStyle(ShelfSmallButton()) }
            } else if ["move", "copy"].contains(item.kind) {
                folderRow
            }
            }
            }
            if !["rename", "open", "move", "copy"].contains(item.kind) && (item.kind != "ocr" || item.ocrOutput == "Text File") {
                ActionPanelGroup {
                HStack { Text("Show output in"); Spacer(); ModernSettingsMenu(title: "Output", selection: Binding(get: { item.destinationRaw ?? ShelfOutputDestination.shelf.rawValue }, set: { item.destinationRaw = $0 }), options: ShelfOutputDestination.allCases.map { ($0.rawValue, $0.rawValue) }) }
                if item.destination == .folder { Divider(); folderRow }
                }
            }
            if ["move", "rename"].contains(item.kind) {
                Text("Original files are changed only after confirmation.").font(.caption).foregroundStyle(.secondary)
            } else if item.kind == "compressPDF" {
                Text("Rasterizes pages; searchable text, links and forms may be lost. Original files are preserved.").font(.caption).foregroundStyle(.secondary)
            } else if item.kind != "open" && !(item.kind == "ocr" && item.ocrOutput != "Text File") {
                Text("Original files are preserved.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack { Spacer(); Button("Cancel", action: cancel).keyboardShortcut(.cancelAction); Button("Save") { save(item) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!item.valid || choosing) }.buttonStyle(.bordered)
        }.padding(22).frame(width: 470).background(.regularMaterial).disabled(choosing)
    }

    private var folderRow: some View {
        HStack { Text("Destination"); Spacer(); Button(item.folder?.lastPathComponent ?? "Choose Folder…") {
            choosing = true
            ShelfFolderPicker.choose(owner: NSApp.keyWindow, initial: item.folder) { url in
                if let url { item.folderPath = url.path }; choosing = false
            }
        }.buttonStyle(ShelfSmallButton()) }
    }
    private func chooseApplication() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        choosing = true
        panel.begin { response in
            if response == .OK { item.applicationPath = panel.url?.path }; choosing = false
        }
    }
}
