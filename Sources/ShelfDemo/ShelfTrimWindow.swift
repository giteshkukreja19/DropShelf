import AppKit
import SwiftUI
import AVKit
@preconcurrency import AVFoundation
import UniformTypeIdentifiers

@available(macOS 15.0, *)
@MainActor final class ShelfTrimWindow: NSObject, ObservableObject, NSWindowDelegate {
    private static var active: [UUID: ShelfTrimWindow] = [:]
    private let id = UUID()
    let source: URL
    let player: AVPlayer
    private let completion: (URL) -> Void
    private var panel: NSPanel?
    private var task: Task<Void, Never>?
    @Published var start = 0.0
    @Published var end = 0.0
    @Published var duration = 0.0
    @Published var message = "Loading video…"
    @Published var busy = false
    private init(_ url: URL, completion: @escaping (URL) -> Void) { source = url; player = AVPlayer(url: url); self.completion = completion }
    static func supports(_ url: URL) -> Bool {
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        return type?.conforms(to: .movie) == true
    }
    static func open(_ url: URL, completion: @escaping (URL) -> Void) {
        let editor = ShelfTrimWindow(url, completion: completion)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 470), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Trim Video"; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ShelfTrimView(editor: editor))
        panel.delegate = editor; editor.panel = panel; active[editor.id] = editor
        panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        editor.task = Task { await editor.load() }
    }
    private func load() async {
        do {
            let asset = AVURLAsset(url: source)
            let d = try await asset.load(.duration).seconds
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard d.isFinite, d > 0.1, !tracks.isEmpty else { throw ShelfRecordingEditor.error("No usable video track") }
            guard !Task.isCancelled else { return }
            duration = d; end = d; message = "Choose the start and end. Original video is preserved."
        } catch { if !Task.isCancelled { message = error.localizedDescription } }
    }
    func seek(_ value: Double) { player.pause(); player.seek(to: CMTime(seconds: value, preferredTimescale: 600)) }
    func save() {
        guard !busy, duration > 0, end > start else { return }
        let a = start, b = end, url = source
        player.pause(); busy = true; message = "Exporting video…"
        task = Task {
            do {
                let root = try ShelfWritableStorage.newFolder("Output")
                let dest = root.appendingPathComponent(url.deletingPathExtension().lastPathComponent + " (trimmed).mp4")
                try await ShelfRecordingEditor.export([.init(url: url, start: a, duration: b-a)], to: dest)
                try Task.checkCancellation()
                completion(dest); busy = false; close()
            } catch { busy = false; message = error.localizedDescription }
        }
    }
    func close() { guard !busy else { task?.cancel(); return }; task?.cancel(); player.pause(); panel?.close() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }
    func windowWillClose(_ notification: Notification) { task?.cancel(); player.pause(); panel = nil; Self.active.removeValue(forKey: id) }
}

@available(macOS 15.0, *)
private struct ShelfTrimView: View {
    @ObservedObject var editor: ShelfTrimWindow
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editor.source.lastPathComponent).font(.headline).lineLimit(1)
            VideoPlayer(player: editor.player).frame(height: 215).clipShape(RoundedRectangle(cornerRadius: 8))
            HStack { Text("Start"); Spacer(); Text(String(format: "%.2f s", editor.start)).monospacedDigit() }
            Slider(value: Binding(get: { editor.start }, set: { editor.start = min($0, max(0, editor.end - 0.1)); editor.seek(editor.start) }), in: 0...max(0.1, editor.duration)).disabled(editor.busy || editor.duration == 0)
            HStack { Text("End"); Spacer(); Text(String(format: "%.2f s", editor.end)).monospacedDigit() }
            Slider(value: Binding(get: { editor.end }, set: { editor.end = max($0, min(editor.duration, editor.start + 0.1)); editor.seek(editor.end) }), in: 0...max(0.1, editor.duration)).disabled(editor.busy || editor.duration == 0)
            Text(String(format: "Trimmed duration: %.2f s", max(0, editor.end-editor.start))).font(.caption)
            Text(editor.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                if editor.busy { ProgressView().controlSize(.small) }
                Spacer(); Button(editor.busy ? "Cancel Export" : "Close") { editor.close() }
                Button("Save Copy") { editor.save() }.keyboardShortcut(.defaultAction).disabled(editor.busy || editor.duration == 0 || editor.end <= editor.start)
            }
        }.padding(18).frame(width: 520, height: 470).background(ShelfSettingsPalette.content(colorScheme))
    }
}
