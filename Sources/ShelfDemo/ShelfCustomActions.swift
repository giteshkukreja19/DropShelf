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
    var destination: ShelfOutputDestination { ShelfOutputDestination(rawValue: destinationRaw ?? "") ?? .shelf }
    var folder: URL? { folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } }
    var valid: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
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
        case "convert": return "Convert to \(format.uppercased())"
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
            Text("Save parameters to run this action directly from your shelf.").font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            ActionPanelGroup { HStack { Text("Display name"); Spacer(); TextField("Name", text: $item.name).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(maxWidth: 240) } }
            HStack { Text("Action"); Spacer(); ModernSettingsMenu(title: "Action", selection: $item.kind, options: ShelfCustomAction.kinds) }
            .onChange(of: item.kind) { kind in
                if ShelfCustomAction.kinds.contains(where: { $0.1 == item.name }) {
                    item.name = ShelfCustomAction.kinds.first { $0.0 == kind }?.1 ?? item.name
                }
            }
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
            if item.kind == "resize" { Toggle("Allow enlargement", isOn: Binding(get: { item.enlarge ?? false }, set: { item.enlarge = $0 })).toggleStyle(.switch) }
            if item.kind == "ocr" {
                HStack { Text("Output"); Spacer(); ModernSettingsMenu(title: "Output", selection: Binding(get: { item.ocrOutput ?? "Clipboard" }, set: { item.ocrOutput = $0 }), options: [("Clipboard", "Clipboard"), ("Text File", "Text File")]) }
            }
            if item.kind == "rename" {
                HStack { Text("Name pattern (# = number)"); Spacer(); TextField("File-#", text: Binding(get: { item.renamePattern ?? "" }, set: { item.renamePattern = $0 })).textFieldStyle(.roundedBorder) }
            } else if item.kind == "open" {
                HStack { Text("Application"); Spacer(); Button(item.applicationPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Choose Application…") { chooseApplication() }.buttonStyle(ShelfSmallButton()) }
            } else if ["move", "copy"].contains(item.kind) {
                folderRow
            } else if item.kind != "ocr" || item.ocrOutput == "Text File" {
                HStack { Text("Show output in"); Spacer(); ModernSettingsMenu(title: "Output", selection: Binding(get: { item.destinationRaw ?? ShelfOutputDestination.shelf.rawValue }, set: { item.destinationRaw = $0 }), options: ShelfOutputDestination.allCases.map { ($0.rawValue, $0.rawValue) }) }
                if item.destination == .folder { folderRow }
            }
            Text("Outputs are new copies. Move and Rename change the selected originals after confirmation.").font(.caption).foregroundStyle(.secondary)
            HStack { Button("Cancel", action: cancel).buttonStyle(ShelfGlassButton()).keyboardShortcut(.cancelAction); Spacer(); Button("Save") { save(item) }.buttonStyle(ShelfGlassButton(prominent: true)).keyboardShortcut(.defaultAction).disabled(!item.valid || choosing) }
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
