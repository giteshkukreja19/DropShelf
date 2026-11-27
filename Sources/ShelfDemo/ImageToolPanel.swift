import AppKit
import SwiftUI

@MainActor
struct ImageToolPanel: View {
    let action: SmartFileActions.Action
    let urls: [URL]
    let manager: ShelfManager
    let shelfID: UUID
    let close: () -> Void
    let setBusy: (Bool) -> Void
    let owner: ShelfWindowReference
    var preset: ShelfCustomAction? = nil
    @State private var didLoadPreset = false
    @State private var width = "500"
    @State private var height = "500"
    @State private var quality = 0.75
    @State private var format = "png"
    @State private var destination: ShelfOutputDestination = .shelf
    @State private var allowEnlargement = false
    @State private var cancellation: DocumentCancellation?
    @State private var cancelling = false
    @State private var outputFolder: URL?
    @State private var choosingFolder = false
    @State private var busy = false
    @State private var error = ""

    private var title: String {
        switch action {
        case .resize: return "Resize"
        case .compress: return "Compress"
        case .convertImage: return "Convert Format"
        default: return "Remove Metadata"
        }
    }
    private var buttonTitle: String {
        switch action {
        case .resize: return "Resize"
        case .compress: return "Compress"
        case .convertImage: return "Convert"
        default: return "Remove Metadata"
        }
    }
    private var symbol: String {
        switch action {
        case .resize: return "arrow.up.left.and.arrow.down.right"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .convertImage: return "arrow.triangle.2.circlepath"
        default: return "tag.slash"
        }
    }
    private func numberField(_ label: String, value: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(label, text: value).textFieldStyle(.plain)
                .multilineTextAlignment(.trailing).font(.body.monospacedDigit())
                .padding(8).frame(width: 92)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
            Text("px").font(.caption).foregroundStyle(.secondary)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ActionPanelHeader(title: title, subtitle: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) images selected", symbol: symbol)
                .measureToolHeight("header")
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ActionPanelGroup {
                        if action == .resize {
                            numberField("Maximum width", value: $width)
                            Divider()
                            numberField("Maximum height", value: $height)
                            Toggle("Allow enlargement", isOn: $allowEnlargement).toggleStyle(.switch)
                            Text(resizeExplanation).font(.caption).foregroundStyle(.secondary)
                        } else if action == .compress {
                            HStack {
                                Text("Image quality")
                                Spacer()
                                Text("\(Int(quality * 100))%").font(.body.weight(.semibold).monospacedDigit())
                            }
                            Slider(value: $quality, in: 0.1...1).accessibilityLabel("JPEG quality")
                            HStack { Text("Smaller file"); Spacer(); Text("Higher quality") }.font(.caption).foregroundStyle(.secondary)
                            Text("Creates a JPEG copy. Output size may vary.").font(.caption).foregroundStyle(.secondary)
                        } else if action == .convertImage {
                            HStack {
                                Text("Output format"); Spacer()
                                ModernSettingsMenu(title: "Output format", selection: $format, options: [("png", "PNG"), ("jpg", "JPEG"), ("heic", "HEIC"), ("tiff", "TIFF")])
                            }
                        } else {
                            Label("Create a copy without the original embedded metadata.", systemImage: "tag.slash")
                        }
                    }
                    ActionPanelGroup {
                        ActionOutputPicker(label: "Show output in", destination: $destination,
                                           folder: outputFolder, choose: chooseOutputFolder)
                        Divider()
                        ActionPanelSafety()
                    }
                    ActionPanelError(message: error)
                }.padding(1).fixedSize(horizontal: false, vertical: true).measureToolHeight("body").disabled(busy || choosingFolder)
            }
            Divider()
            Group {
            if busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(cancelling ? "Cancelling…" : "Processing…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel Processing", action: requestBack).disabled(cancelling)
                }
            } else {
                ActionPanelFooter(title: buttonTitle, busy: false, valid: valid, close: requestBack, run: run)
            }
            }.measureToolHeight("footer")
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard !didLoadPreset else { return }; didLoadPreset = true
            if let preset {
                width = String(preset.width); height = String(preset.height); quality = Double(preset.quality) / 100; format = preset.format
                destination = preset.destination; outputFolder = preset.folder; allowEnlargement = preset.enlarge ?? false
                if valid { run() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .shelfToolBackRequested)) { event in
            if event.object as? UUID == shelfID { requestBack() }
        }
    }
    private var valid: Bool {
        guard !choosingFolder else { return false }
        guard destination != .folder
            || outputFolder != nil
        else { return false }

        return action != .resize || ((Int(width.trimmingCharacters(in: .whitespacesAndNewlines)).map { (1...16000).contains($0) } ?? false) && (Int(height.trimmingCharacters(in: .whitespacesAndNewlines)).map { (1...16000).contains($0) } ?? false))
    }

    private func chooseOutputFolder() {
        guard !choosingFolder, !busy else { return }

        choosingFolder = true; setBusy(true)
        error = ""

        ShelfFolderPicker.choose(
            owner: owner.window, initial: outputFolder
        ) { selected in
            choosingFolder = false; setBusy(false)

            if let selected {
                outputFolder = selected
            }
        }
    }

    private var resizeExplanation: String {
        let base = allowEnlargement ? "Aspect ratio is preserved; small images can be enlarged." : "Aspect ratio is preserved; small images stay their original size."
        guard urls.count == 1, let source = manager.items(of: shelfID).first(where: { $0.fileURL == urls[0] })?.pixelSize,
              let w = Int(width.trimmingCharacters(in: .whitespacesAndNewlines)),
              let h = Int(height.trimmingCharacters(in: .whitespacesAndNewlines)),
              let result = ShelfPixelSize(width: Int(source.width), height: Int(source.height)).fitted(maxWidth: w, maxHeight: h, allowEnlargement: allowEnlargement) else { return base }
        return "Output: \(result.width) × \(result.height) px. " + base
    }

    private func requestBack() {
        if choosingFolder { ShelfFolderPicker.cancel(owner: owner.window); return }
        if busy { cancelling = true; cancellation?.cancel(); return }
        close()
    }

    private func run() {
        guard valid, !busy else { return }
        busy = true; setBusy(true); error = ""; cancelling = false
        let flag = DocumentCancellation(); cancellation = flag
        let a = action, inputs = urls
        let w = Int(width.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 500
        let h = Int(height.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 500
        let q = quality, f = format, enlarge = allowEnlargement
        let presetQuality = preset == nil ? 1.0 : q
        let target = destination, chosenFolder = outputFolder
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () -> (outputs: [URL], errors: [String], cancelled: Bool) in
                var outputs: [URL] = [], errors: [String] = []
                do {
                    try flag.check()
                    let folder = try target.directory(chosen: chosenFolder)
                    for url in inputs {
                        if flag.isCancelled() { break }
                        do {
                            let output: URL = try autoreleasepool {
                                switch a {
                                case .resize: return try ImageActions.resize(url: url, width: w, height: h, allowEnlargement: enlarge, folder: folder)
                                case .compress: return try ImageActions.compress(url: url, quality: q, folder: folder)
                                case .convertImage: return try ImageActions.convert(url: url, format: f, folder: folder, quality: presetQuality)
                                default: return try ImageActions.removeMetadata(url: url, folder: folder)
                                }
                            }
                            outputs.append(output)
                        } catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                    }
                } catch is CancellationError {
                    // A cancel before the first file is not an error.
                } catch { errors.append(error.localizedDescription) }
                return (outputs, errors, flag.isCancelled())
            }.value
            if target == .shelf, manager.shelf(id: shelfID) != nil {
                for url in result.outputs { _ = manager.addFile(url: url, to: shelfID) }
            } else if !result.outputs.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(result.outputs)
            }
            busy = false; setBusy(false); cancellation = nil; cancelling = false
            if result.cancelled {
                error = "Cancelled. \(result.outputs.count) completed copies were kept."
            } else if result.errors.isEmpty && result.outputs.count == inputs.count {
                close()
            } else {
                error = result.errors.joined(separator: "\n") + "\n\(result.outputs.count) successful copies were kept."
            }
        }
    }
    static func present(action: SmartFileActions.Action, urls: [URL], manager: ShelfManager, shelfID: UUID) {
        guard !urls.isEmpty else { return }
        ShelfToolRouter.open(
            action: action,
            urls: urls,
            shelfID: shelfID
        )
    }
}
