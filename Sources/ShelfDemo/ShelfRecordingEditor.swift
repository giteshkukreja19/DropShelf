import AppKit
import SwiftUI
@preconcurrency import AVFoundation
import CoreMedia
import AudioToolbox

@available(macOS 15, *)
enum ShelfRecordingEditor {
    static func error(_ message: String) -> NSError { NSError(domain: "DropShelf.RecordingEdit", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    struct Part: Sendable { let url: URL; let start: Double; let duration: Double }
    struct Plan: Sendable { let duration: Double; let parts: [Part]; var kept: Double { parts.reduce(0) { $0 + $1.duration } } }
    static func fullParts(_ urls: [URL]) async throws -> [Part] {
        var result: [Part] = []
        for url in urls { let d = try await AVURLAsset(url: url).load(.duration).seconds; guard d.isFinite, d > 0 else { throw error("A recording segment is empty.") }; result.append(Part(url: url, start: 0, duration: d)) }
        return result
    }
    // Scan all audio tracks. A window is considered silent only if none of the
    // tracks exceed the peak threshold. Keep 150ms of padding around speech.
    static func analyze(_ url: URL, threshold: Double, minimum: Double) async throws -> Plan {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 12*3600 else { throw error("Recording duration is unsupported.") }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw error("This recording has no audio track.") }
        let step = 0.05, count = Int(ceil(duration/step)); var active = [Bool](repeating: false, count: count)
        let limit = Float(pow(10, threshold/20))
        for track in tracks {
            try Task.checkCancellation()
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            guard reader.canAdd(output) else { throw error("Cannot decode recording audio.") }; reader.add(output)
            guard reader.startReading() else { throw reader.error ?? error("Cannot read audio.") }
            defer { if reader.status == .reading { reader.cancelReading() } }
            while let buffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let data = CMSampleBufferGetDataBuffer(buffer), let format = CMSampleBufferGetFormatDescription(buffer), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee, asbd.mSampleRate > 0 else { throw error("Unsupported audio format.") }
                let len = CMBlockBufferGetDataLength(data), channels = Int(asbd.mChannelsPerFrame)
                guard len > 0, len % 4 == 0, channels > 0 else { continue }
                var samples = [Float](repeating: 0, count: len/4)
                let status = samples.withUnsafeMutableBytes { ptr in CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: len, destination: ptr.baseAddress!) }
                guard status == noErr else { throw error("Cannot read audio samples.") }
                let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                guard start.isFinite else { throw error("Invalid audio timing.") }
                for i in samples.indices where abs(samples[i]) >= limit {
                    let bucket = Int(floor((start + Double(i/channels)/asbd.mSampleRate)/step))
                    if active.indices.contains(bucket) { active[bucket] = true }
                }
            }
            guard reader.status == .completed else { throw reader.error ?? error("Audio scan did not finish.") }
        }
        var cuts: [(Double,Double)] = []; var i = 0
        while i < count {
            if active[i] { i += 1; continue }
            let first = i; while i < count && !active[i] { i += 1 }
            let a = Double(first)*step, b = min(duration, Double(i)*step)
            if b-a >= minimum { let lo = a == 0 ? a : a+0.15; let hi = b >= duration ? b : b-0.15; if hi > lo { cuts.append((lo,hi)) } }
        }
        var parts: [Part] = []; var cursor = 0.0
        for (a,b) in cuts { if a > cursor { parts.append(Part(url: url, start: cursor, duration: a-cursor)) }; cursor = b }
        if duration > cursor { parts.append(Part(url: url, start: cursor, duration: duration-cursor)) }
        guard !parts.isEmpty else { throw error("The whole recording is silent at this threshold. Lower sensitivity or keep the original.") }
        return Plan(duration: duration, parts: parts)
    }
    static func export(_ parts: [Part], to dest: URL) async throws {
        guard !parts.isEmpty else { throw error("Nothing to export.") }
        let composition = AVMutableComposition(); var cursor = CMTime.zero
        var videoTracks: [AVMutableCompositionTrack] = [], audioTracks: [AVMutableCompositionTrack] = []
        for part in parts {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: part.url)
            let range = CMTimeRange(start: CMTime(seconds: part.start, preferredTimescale: 600), duration: CMTime(seconds: part.duration, preferredTimescale: 600))
            let sourceVideos = try await asset.loadTracks(withMediaType: .video), sourceAudio = try await asset.loadTracks(withMediaType: .audio)
            guard !sourceVideos.isEmpty else { throw error("Missing video track.") }
            for (index, track) in sourceVideos.enumerated() {
                if index == videoTracks.count { guard let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw error("Cannot create video track.") }; target.preferredTransform = try await track.load(.preferredTransform); videoTracks.append(target) }
                let available = CMTimeRangeGetIntersection(range, otherRange: try await track.load(.timeRange))
                if available.duration.seconds > 0 { try videoTracks[index].insertTimeRange(available, of: track, at: cursor + (available.start-range.start)) }
            }
            for (index, track) in sourceAudio.enumerated() {
                if index == audioTracks.count { guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw error("Cannot create audio track.") }; audioTracks.append(target) }
                let available = CMTimeRangeGetIntersection(range, otherRange: try await track.load(.timeRange))
                if available.duration.seconds > 0 { try audioTracks[index].insertTimeRange(available, of: track, at: cursor + (available.start-range.start)) }
            }
            cursor = cursor + range.duration
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw error("Cannot prepare video export.") }
        guard !FileManager.default.fileExists(atPath: dest.path) else { throw error("Output already exists.") }
        let partial = dest.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: partial) }
        try await session.export(to: partial, as: .mp4)
        try Task.checkCancellation()
        let output = AVURLAsset(url: partial)
        guard try await output.load(.duration).seconds > 0, !(try await output.loadTracks(withMediaType: .video)).isEmpty else { throw error("Export validation failed.") }
        try FileManager.default.moveItem(at: partial, to: dest)
    }
}

@available(macOS 15, *)
@MainActor final class ShelfSilenceEditor: ObservableObject {
    @Published var threshold = -40.0
    @Published var minimum = 0.8
    @Published var message = "Analyze to see how much time can be saved."
    @Published var busy = false
    @Published private var plan: ShelfRecordingEditor.Plan?
    @Published private var preview: URL?
    private var task: Task<Void,Never>?
    private var worker: Task<ShelfRecordingEditor.Plan,Error>?
    private var exportWorker: Task<Void,Error>?
    private var panel: NSPanel?
    private let source: URL
    private let completion: (URL) -> Void
    private init(_ source: URL, completion: @escaping (URL) -> Void) { self.source = source; self.completion = completion }
    static func open(_ source: URL, completion: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }) {
        let editor = ShelfSilenceEditor(source, completion: completion)
        let panel = NSPanel(contentRect: NSRect(x: 0,y: 0,width: 440,height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Remove Silent Parts"; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ShelfSilenceEditorView(editor: editor)); editor.panel = panel; panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    fileprivate var view: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remove Silent Parts").font(.headline)
            Text(self.source.lastPathComponent).lineLimit(1).foregroundStyle(.secondary)
            HStack { Text("Silence threshold"); Spacer(); Text("\(Int(self.threshold)) dBFS") }
            Slider(value: Binding(get: { self.threshold }, set: { self.threshold = $0; self.plan = nil }), in: -60 ... -20, step: 1)
                .disabled(self.busy || self.preview != nil)
            HStack { Text("Minimum silence"); Spacer(); Text(String(format: "%.1f s", self.minimum)) }
            Slider(value: Binding(get: { self.minimum }, set: { self.minimum = $0; self.plan = nil }), in: 0.4 ... 3, step: 0.1)
                .disabled(self.busy || self.preview != nil)
            Text(self.message).font(.caption).foregroundStyle(.secondary)
            if self.busy { ProgressView().controlSize(.small) }
            HStack {
                Button(self.busy ? "Cancel" : "Close") {
                    if self.busy { self.worker?.cancel(); self.exportWorker?.cancel() }
                    else { self.close(save: false) }
                }
                Spacer()
                if let preview = self.preview {
                    Button("Play Preview") { NSWorkspace.shared.open(preview) }
                    Button("Save Copy") { self.close(save: true) }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Analyze") { self.analyze() }.disabled(self.busy)
                    Button("Create Preview") { self.create() }.disabled(self.busy || self.plan == nil)
                }
            }
            Text("Your original recording is unchanged.").font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width: 440)
    }
    private func analyze() {
        let url = source, t = threshold, m = minimum; busy = true; message = "Analyzing all audio tracks…"; plan = nil
        let job = Task.detached(priority: .userInitiated) { try await ShelfRecordingEditor.analyze(url, threshold: t, minimum: m) }; worker = job
        task = Task { do { let p = try await job.value; try Task.checkCancellation(); guard !job.isCancelled else { throw CancellationError() }; plan = p; message = String(format: "Original %.1fs · Edited %.1fs · Saved %.1fs", p.duration,p.kept,p.duration-p.kept) } catch { message = error.localizedDescription }; busy = false; worker = nil; task = nil }
    }
    private func create() {
        guard let plan else { return }; busy = true; message = "Rendering preview…"
        do {
            let folder = try ShelfWritableStorage.newFolder("Output"), dest = folder.appendingPathComponent(source.deletingPathExtension().lastPathComponent + "-trimmed.mp4")
            let job = Task.detached(priority: .userInitiated) { try await ShelfRecordingEditor.export(plan.parts, to: dest) }; exportWorker = job
            task = Task { do { try await job.value; guard !job.isCancelled else { throw CancellationError() }; preview = dest; message = "Preview ready. Play it before saving." } catch { try? FileManager.default.removeItem(at: folder); message = error.localizedDescription }; busy = false; exportWorker = nil; task = nil }
        } catch { busy = false; message = error.localizedDescription }
    }
    private func close(save: Bool) {
        if let preview { if save { completion(preview) } else { try? FileManager.default.removeItem(at: preview) } }
        panel?.orderOut(nil); panel?.contentView = nil; panel = nil
    }
}

@available(macOS 15, *) private struct ShelfSilenceEditorView: View { @ObservedObject var editor: ShelfSilenceEditor; var body: some View { editor.view.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor)) } }
