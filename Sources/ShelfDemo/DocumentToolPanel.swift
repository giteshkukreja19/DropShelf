import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct DocumentToolPanel: View {
    struct Entry: Identifiable {
        let id = UUID()
        let url: URL
    }
    let action: SmartFileActions.Action
    let manager: ShelfManager
    let shelfID: UUID
    let close: () -> Void
    let setBusy: (Bool) -> Void
    let owner: ShelfWindowReference
    private let preset: ShelfCustomAction?
    @State private var startedPreset = false
    @State private var entries: [Entry]
    @State private var name: String
    @State private var destination: ShelfOutputDestination = .shelf
    @State private var folder: URL?
    @State private var pages = ""
    @State private var stitchEnhance = false
    @State private var stitchColumns = 1
    @State private var stitchRows = 0
    @State private var stitchGap = 0.0
    @State private var stitchBackground = "Transparent"
    @State private var dpi = 120.0
    @State private var password = ""
    @State private var busy = false
    @State private var choosing = false
    @State private var error = ""
    @State private var cancellation: DocumentCancellation?
    @State private var cancelling = false

    init(action: SmartFileActions.Action, urls: [URL], manager: ShelfManager, shelfID: UUID,
         close: @escaping () -> Void, setBusy: @escaping (Bool) -> Void, owner: ShelfWindowReference, preset: ShelfCustomAction? = nil) {
        self.action = action; self.manager = manager; self.shelfID = shelfID
        self.close = close; self.setBusy = setBusy; self.owner = owner; self.preset = preset
        _destination = State(initialValue: preset?.destination ?? .shelf)
        _folder = State(initialValue: preset?.folder)
        _dpi = State(initialValue: Double(preset?.pdfDPI ?? 120))
        _stitchColumns = State(initialValue: min(12, max(1, preset?.stitchColumns ?? 1)))
        _stitchRows = State(initialValue: min(12, max(0, preset?.stitchRows ?? 0)))
        _stitchGap = State(initialValue: Double(min(100, max(0, preset?.stitchGap ?? 0))))
        _stitchBackground = State(initialValue: preset?.stitchBackground ?? "Transparent")
        _stitchEnhance = State(initialValue: preset?.enhanceImages ?? false)
        _entries = State(initialValue: urls.map { Entry(url: $0) })
        _name = State(initialValue: action == .mergePDF || action == .combinedPDF ? "Merged" :
            (urls.first?.deletingPathExtension().lastPathComponent ?? "DropShelf Output") + "-" + Self.suffix(action))
    }
    private static func suffix(_ action: SmartFileActions.Action) -> String {
        switch action {
        case .compressPDF: return "compressed"
        case .protectPDF: return "protected"
        case .splitPDF: return "pages"
        case .extractPDF, .wordText: return "text"
        case .mergeWord: return "merged"
        case .pdfWord, .wordPDF: return "converted"
        case .rotatePDF: return "rotated"
        case .stitch: return "stitched"
        default: return "output"
        }
    }
    private var title: String { action.rawValue.replacingOccurrences(of: "…", with: "") }
    private var ext: String { SmartFileActions.documentExtension(action) }
    private var reorderable: Bool {
        [.mergePDF, .combinedPDF, .mergeWord, .imagePDF, .stitch, .wordPDF, .extractPDF, .wordText, .rotatePDF].contains(action) && entries.count > 1
    }
    private var cancellable: Bool {
        ![.mergeWord, .wordText].contains(action)
    }
    private var valid: Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entries.isEmpty, !n.isEmpty, !n.hasPrefix("."), !n.contains("/"), !n.contains(":"), !n.contains("\u{0}"), n.utf8.count <= 200,
              destination != .folder || folder != nil else { return false }
        if [.extractPages, .deletePages].contains(action) { return !pages.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if action == .stitch && stitchRows > 0 && entries.count > stitchRows * stitchColumns { return false }
        if action == .protectPDF { return !password.isEmpty }
        return true
    }
    var body: some View {
        VStack(alignment: .leading, spacing: action == .stitch ? 8 : 12) {
            ActionPanelHeader(title: title, subtitle: "\(entries.count) \(entries.count == 1 ? "file" : "files") selected", symbol: action == .stitch ? "photo.on.rectangle.angled" : "doc.on.doc")
                .measureToolHeight("header")
            ScrollView {
                VStack(alignment: .leading, spacing: action == .stitch ? 8 : 12) {
                    if action == .stitch {
                        Text("Drag or use arrows to reorder images.").font(.caption).foregroundStyle(.secondary)
                        ScrollView {
                            VStack(spacing: 3) {
                                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                    if index > 0 { Divider() }
                                    documentRow(entry, index: index)
                                }
                            }.padding(6)
                        }.frame(height: min(CGFloat(entries.count) * 32 + 12, 112))
                            .background(Color.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 12) {
                                Text("Columns"); Spacer(minLength: 2)
                                ModernSettingsMenu(title: "Columns", selection: $stitchColumns, options: (1...12).map { ($0, String($0)) })
                                Text("Rows"); Spacer(minLength: 2)
                                ModernSettingsMenu(title: "Rows", selection: $stitchRows, options: [(0, "Automatic")] + (1...12).map { ($0, String($0)) })
                            }
                            Divider()
                            HStack {
                                Text("Spacing")
                                Slider(value: Binding(get: { stitchGap }, set: { stitchGap = $0.rounded() }), in: 0...100).accessibilityLabel("Image spacing in pixels")
                                TextField("Pixels", value: Binding(get: { Int(stitchGap) }, set: { stitchGap = Double(min(100, max(0, $0))) }), format: .number)
                                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 46).accessibilityLabel("Image spacing pixels")
                                Text("px").font(.caption)
                            }
                            HStack { Text("Background"); Spacer(); ModernSettingsMenu(title: "Background", selection: $stitchBackground, options: ["Transparent", "White", "Black"].map { ($0, $0) }) }
                            HStack { Text("Enhance image clarity"); Spacer(); Toggle("Enhance image clarity", isOn: $stitchEnhance).labelsHidden().toggleStyle(.switch) }
                            Divider()
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Layout preview").font(.caption).foregroundStyle(.secondary)
                                    Text("\(stitchRows == 0 ? (entries.count + stitchColumns - 1) / stitchColumns : stitchRows) × \(stitchColumns)").font(.caption)
                                }
                                Spacer()
                                stitchPreview.frame(maxWidth: 150)
                            }
                            if stitchRows > 0 && entries.count > stitchRows * stitchColumns { Text("Increase rows or columns to fit every image.").foregroundStyle(.red).font(.caption) }
                        }.padding(9).background(Color.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 10))
                    } else {
                        if reorderable { Text("Drag the handles or use the arrows to change the document order.").font(.caption).foregroundStyle(.secondary) }
                        ActionPanelGroup {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { Divider() }
                                documentRow(entry, index: index)
                            }
                        }
                        if [.imagePDF, .combinedPDF].contains(action) {
                            ActionPanelGroup { HStack { Text("Enhance image clarity"); Spacer(); Toggle("Enhance image clarity", isOn: $stitchEnhance).labelsHidden().toggleStyle(.switch) } }
                        }
                    }
                    if [.extractPages, .deletePages, .compressPDF, .protectPDF].contains(action) {
                        ActionPanelGroup {
                            if [.extractPages, .deletePages].contains(action) {
                                Text(action == .deletePages ? "Pages to remove" : "Pages to keep, in order").font(.headline)
                                TextField("e.g. 3, 1, 5-7", text: $pages).textFieldStyle(.roundedBorder)
                                Text("Use page numbers and ranges separated by commas.").font(.caption).foregroundStyle(.secondary)
                            } else if action == .compressPDF {
                                HStack { Text("Resolution").font(.headline); Spacer(); Text("\(Int(dpi)) DPI").monospacedDigit().foregroundStyle(Color.accentColor) }
                                Slider(value: $dpi, in: 72...200).accessibilityLabel("PDF resolution")
                                HStack { Text("Smaller file"); Spacer(); Text("Higher quality") }.font(.caption).foregroundStyle(.secondary)
                                Text("Rasterizes pages. Searchable text, links and forms may be lost. Output size is not guaranteed.").font(.caption).foregroundStyle(.secondary)
                            } else {
                                SecureField("Password for the new PDF", text: $password).textFieldStyle(.roundedBorder)
                                Text("Keep your password safe. The original remains unchanged.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if action != .stitch { outputOptions }
                    ActionPanelError(message: error)
                }.padding(1).fixedSize(horizontal: false, vertical: true).measureToolHeight("body").disabled(busy || choosing)
            }
            Divider()
            VStack(spacing: 8) {
            if action == .stitch { outputOptions.disabled(busy || choosing) }
            if busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(cancelling ? "Cancelling…" : "Processing…").foregroundStyle(.secondary)
                    Spacer()
                    if cancellable {
                        Button("Cancel Processing") { cancelling = true; cancellation?.cancel() }.disabled(cancelling)
                    }
                }
            } else {
                ActionPanelFooter(title: title, busy: false, valid: valid && !choosing, close: requestBack, run: run)
            }
            }.measureToolHeight("footer")
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if preset != nil, !startedPreset { startedPreset = true; if valid { run() } } }
        .onReceive(NotificationCenter.default.publisher(for: .shelfToolBackRequested)) { event in
            if event.object as? UUID == shelfID { requestBack() }
        }
    }
    private var outputOptions: some View {
        ActionPanelGroup {
                        HStack {
                            Text(action == .splitPDF ? "Folder name" : "Output name"); Spacer()
                            TextField("Name", text: $name).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                                .padding(8).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            if action != .splitPDF { Text(".\(ext)").foregroundStyle(.secondary) }
                        }
                        Divider()
                        ActionOutputPicker(label: "Save to", destination: $destination,
                                           folder: folder, choose: chooseFolder)
                        Divider()
                        ActionPanelSafety()
                    }
    }
    private var stitchPreview: some View {
        let rowCount = stitchRows == 0 ? (entries.count + stitchColumns - 1) / stitchColumns : stitchRows
        let spacing = CGFloat(stitchGap / 40)
        let background: Color = stitchBackground == "White" ? .white : stitchBackground == "Black" ? .black : Color.secondary.opacity(0.14)
        return VStack(spacing: spacing) {
            ForEach(0..<min(rowCount, 6), id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(0..<stitchColumns, id: \.self) { col in
                        let index = row * stitchColumns + col
                        RoundedRectangle(cornerRadius: 2).fill(index < entries.count ? Color.accentColor.opacity(0.65) : Color.clear)
                            .overlay { if index < entries.count { Text(String(index + 1)).font(.system(size: 9)).foregroundStyle(.white) } }
                            .frame(height: max(3, 35 / CGFloat(min(rowCount, 6))))
                    }
                }
            }
        }.padding(4).background(background, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Grid layout preview, not final image dimensions")
    }
    private func documentRow(_ entry: Entry, index: Int) -> some View {
        HStack(spacing: 10) {
            if reorderable {
                Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).padding(action == .stitch ? 2 : 5)
                    .onDrag { NSItemProvider(object: entry.id.uuidString as NSString) }
                    .help("Drag to reorder")
            }
            Image(systemName: "doc.fill").foregroundStyle(entry.url.pathExtension.lowercased() == "pdf" ? Color.red : Color.accentColor)
                .font(.system(size: action == .stitch ? 15 : 22)).frame(width: action == .stitch ? 18 : 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                if action != .stitch { Text("\(index + 1) of \(entries.count) · \(entry.url.deletingLastPathComponent().lastPathComponent)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            if reorderable {
                Button { move(entry.id, to: index - 1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0).help("Move up")
                Button { move(entry.id, to: index + 1) } label: { Image(systemName: "chevron.down") }.disabled(index == entries.count - 1).help("Move down")
            }
        }.buttonStyle(.borderless)
        .contentShape(Rectangle())
        .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
            guard reorderable, !busy, let provider = providers.first, provider.canLoadObject(ofClass: NSString.self) else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let text = object as? String, let id = UUID(uuidString: text) else { return }
                Task { @MainActor in
                    guard !busy, let target = entries.firstIndex(where: { $0.id == entry.id }) else { return }
                    move(id, to: target)
                }
            }
            return true
        }
    }
    private func move(_ id: UUID, to index: Int) {
        guard !busy, let from = entries.firstIndex(where: { $0.id == id }), entries.indices.contains(index), from != index else { return }
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.18)) {
            let entry = entries.remove(at: from); entries.insert(entry, at: index)
        }
    }

    private func chooseFolder() {
        guard !choosing, !busy else { return }

        choosing = true; setBusy(true)
        error = ""

        ShelfFolderPicker.choose(owner: owner.window, initial: folder) { selected in
            choosing = false; setBusy(false)

            if let selected {
                folder = selected
            }
        }
    }

    private func requestBack() {
        if choosing { ShelfFolderPicker.cancel(owner: owner.window); return }
        if busy { if cancellable { cancelling = true; cancellation?.cancel() }; return }
        close()
    }

    private func run() {
        guard valid, !busy, !choosing else { return }
        busy = true; setBusy(true); error = ""; cancelling = false
        let flag = DocumentCancellation(); cancellation = flag
        let inputs = entries.map(\.url)
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosenFolder = folder
        let target = destination, pageSpec = pages, resolution = dpi, secret = password
        Task { @MainActor in
            do {
                let targetFolder = target == .shelf ? nil : try target.directory(chosen: chosenFolder)
                let resolvedName = preset != nil && targetFolder != nil ? UniqueDestination.url(preferred: targetFolder!.appendingPathComponent(base).appendingPathExtension(ext)).deletingPathExtension().lastPathComponent : base
                let outputs = try await SmartFileActions.performDocument(action, urls: inputs, name: resolvedName, folder: targetFolder,
                    pages: pageSpec, dpi: resolution, password: secret, flag: flag, stitchColumns: stitchColumns, stitchRows: stitchRows, enhanceImages: stitchEnhance, stitchGap: Int(stitchGap), stitchBackground: stitchBackground, rotation: preset?.rotation ?? 90, wordMode: preset?.wordMode)
                // Once the write has committed, deliver the files even if a late cancel arrived.
                if target == .shelf, manager.shelf(id: shelfID) != nil {
                    for url in outputs { _ = manager.addFile(url: url, to: shelfID) }
                } else { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
                busy = false; setBusy(false); cancellation = nil; close()
            } catch is CancellationError {
                busy = false; setBusy(false); cancellation = nil; cancelling = false
            } catch {
                busy = false; setBusy(false); cancellation = nil; cancelling = false
                self.error = error.localizedDescription
            }
        }
    }
    static func present(action: SmartFileActions.Action, urls: [URL], manager: ShelfManager, shelfID: UUID) {
        ShelfToolRouter.open(
            action: action,
            urls: urls,
            shelfID: shelfID
        )
    }
}

final class DocumentCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func check() throws { if isCancelled() { throw CancellationError() } }
}
