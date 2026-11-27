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
    @State private var stitchColumns = 1
    @State private var stitchRows = 0
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
        VStack(alignment: .leading, spacing: 12) {
            ActionPanelHeader(title: title, subtitle: "\(entries.count) \(entries.count == 1 ? "file" : "files") selected", symbol: action == .stitch ? "photo.on.rectangle.angled" : "doc.on.doc")
                .measureToolHeight("header")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if reorderable { Text("Drag the handles or use the arrows to change the document order.").font(.caption).foregroundStyle(.secondary) }
                    ActionPanelGroup {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider() }
                            documentRow(entry, index: index)
                        }
                    }
                    if action == .stitch {
                        ActionPanelGroup {
                            Picker("Columns", selection: $stitchColumns) { ForEach(1...12, id: \.self) { Text("\($0)").tag($0) } }.pickerStyle(.menu)
                            Picker("Rows", selection: $stitchRows) {
                                Text("Automatic").tag(0)
                                ForEach(1...12, id: \.self) { Text("\($0)").tag($0) }
                            }.pickerStyle(.menu)
                            Text("\(stitchRows == 0 ? (entries.count + stitchColumns - 1) / stitchColumns : stitchRows) × \(stitchColumns) (rows × columns)").font(.caption)
                            if stitchRows > 0 && entries.count > stitchRows * stitchColumns { Text("Increase rows or columns to fit every image.").foregroundStyle(.red).font(.caption) }
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
                    ActionPanelError(message: error)
                }.padding(1).fixedSize(horizontal: false, vertical: true).measureToolHeight("body").disabled(busy || choosing)
            }
            Divider()
            Group {
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
    private func documentRow(_ entry: Entry, index: Int) -> some View {
        HStack(spacing: 10) {
            if reorderable {
                Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).padding(5)
                    .onDrag { NSItemProvider(object: entry.id.uuidString as NSString) }
                    .help("Drag to reorder")
            }
            Image(systemName: "doc.fill").foregroundStyle(entry.url.pathExtension.lowercased() == "pdf" ? Color.red : Color.accentColor)
                .font(.system(size: 22)).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text("\(index + 1) of \(entries.count) · \(entry.url.deletingLastPathComponent().lastPathComponent)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                    pages: pageSpec, dpi: resolution, password: secret, flag: flag, stitchColumns: stitchColumns, stitchRows: stitchRows)
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
