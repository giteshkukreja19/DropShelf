import AppKit
import SwiftUI
import Speech
import ScreenCaptureKit
import CoreMedia
@preconcurrency import AVFoundation
import QuartzCore

// All mutable state is used on the main queue, including SCStream's sample callback.
@available(macOS 15.0, *)
final class CaptureSpeech: NSObject, ObservableObject, SCStreamOutput {
    struct Cue { let start: Double; let end: Double; let text: String }
    @Published private(set) var caption = "Waiting for speech…"
    private let recognizer: SFSpeechRecognizer
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var token = UUID()
    private var offset = 0.0
    private var current: [Cue] = []
    private var committed: [Cue] = []
    private var currentText = ""
    private var paragraphs: [String] = []
    private var problem: String?
    private init(_ recognizer: SFSpeechRecognizer) { self.recognizer = recognizer }
    static func authorized(locale: String) async throws -> CaptureSpeech {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw failure("Speech recognition permission is not granted.") }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { throw failure("On-device speech recognition is unavailable for this language. Choose another language or download its speech assets in macOS.") }
        return CaptureSpeech(recognizer)
    }
    private static func failure(_ message: String) -> NSError { NSError(domain: "DropShelf.CaptureSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    func begin(offset: Double) {
        end(); self.offset = offset; caption = "Listening…"
        let id = UUID(); token = id
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.token == id else { return }
                if let result {
                    let transcription = result.bestTranscription
                    self.currentText = transcription.formattedString
                    self.current = transcription.segments.map { segment in
                        Cue(start: self.offset + segment.timestamp, end: self.offset + segment.timestamp + max(segment.duration, 0.05), text: segment.substring)
                    }
                    self.caption = transcription.formattedString.split(separator: " ").suffix(22).joined(separator: " ")
                }
                if let error { self.problem = error.localizedDescription; self.caption = "Speech recognition interrupted"; self.request = nil }
                if result?.isFinal == true { self.request = nil }
            }
        }
    }
    func end() {
        token = UUID(); request?.endAudio(); task?.cancel(); task = nil; request = nil
        committed.append(contentsOf: current); current = []
        if !currentText.isEmpty { paragraphs.append(currentText) }; currentText = ""
        caption = "Speech paused"
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .microphone, CMSampleBufferIsValid(sampleBuffer) else { return }
        request?.appendAudioSampleBuffer(sampleBuffer)
    }
    static func stamp(_ seconds: Double) -> String {
        let ms = max(0, Int((seconds * 1000).rounded()))
        return String(format: "%02d:%02d:%02d,%03d", ms/3600000, ms/60000%60, ms/1000%60, ms%1000)
    }
    func save(beside url: URL) throws {
        let text = paragraphs.joined(separator: "\n\n")
        guard !text.isEmpty else { if let problem { throw Self.failure(problem) }; return }
        let defaults = UserDefaults.standard
        let folder = defaults.string(forKey: "recorder.speechFolder") ?? ""
        let directory = folder.isEmpty ? url.deletingLastPathComponent() : URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = directory.appendingPathComponent(url.deletingPathExtension().lastPathComponent)
        let format = defaults.string(forKey: "recorder.speechFormat") ?? "Both"
        let txt = stem.appendingPathExtension("txt"), srt = stem.appendingPathExtension("srt")
        let subtitles = committed.enumerated().map { index, cue in
            "\(index + 1)\n\(Self.stamp(cue.start)) --> \(Self.stamp(cue.end))\n\(cue.text)\n"
        }.joined(separator: "\n")
        if format != "SRT" { try Data(text.utf8).write(to: txt, options: .withoutOverwriting) }
        if format != "TXT" { try Data(subtitles.utf8).write(to: srt, options: .withoutOverwriting) }
        if let problem { throw Self.failure("Partial transcript saved: " + problem) }
    }
    @MainActor func exportCaptionedCopy(of url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0, let track = try await asset.loadTracks(withMediaType: .video).first else { throw Self.failure("No valid video track.") }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: natural).applying(transform).standardized
        let size = CGSize(width: ceil(bounds.width / 2) * 2, height: ceil(bounds.height / 2) * 2)
        guard size.width > 0, size.height > 0 else { throw Self.failure("Invalid video dimensions.") }
        var phrases: [Cue] = []
        for cue in committed where cue.start.isFinite && cue.end.isFinite && cue.start < duration.seconds {
            if let last = phrases.last, cue.start - last.end < 0.65, cue.end - last.start < 3.5, last.text.count + cue.text.count < 85 {
                phrases[phrases.count - 1] = Cue(start: last.start, end: cue.end, text: last.text + " " + cue.text)
            } else { phrases.append(cue) }
        }
        guard !phrases.isEmpty else { throw Self.failure("No recognized speech to include.") }
        let parent = CALayer(); parent.frame = CGRect(origin: .zero, size: size)
        let video = CALayer(); video.frame = parent.bounds; parent.addSublayer(video)
        for (index, cue) in phrases.enumerated() {
            let start = max(0, cue.start)
            let nextStart = index + 1 < phrases.count ? phrases[index + 1].start : duration.seconds
            let end = min(duration.seconds, nextStart, max(cue.end, start + 0.5))
            guard end > start else { continue }
            let fontSize = max(12, min(size.height * 0.045, size.width * 0.045))
            let layer = CATextLayer()
            layer.string = cue.text; layer.font = NSFont.systemFont(ofSize: fontSize, weight: .medium); layer.fontSize = fontSize
            layer.foregroundColor = NSColor.white.cgColor; layer.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
            layer.alignmentMode = .center; layer.isWrapped = true; layer.contentsScale = 2; layer.cornerRadius = 8
            layer.frame = CGRect(x: size.width * 0.08, y: size.height * 0.07, width: size.width * 0.84, height: fontSize * 2.8)
            layer.opacity = 0
            let animation = CABasicAnimation(keyPath: "opacity"); animation.fromValue = 1; animation.toValue = 1
            animation.beginTime = AVCoreAnimationBeginTimeAtZero + start; animation.duration = end - start
            animation.isRemovedOnCompletion = false; animation.fillMode = .removed
            layer.add(animation, forKey: "caption"); parent.addSublayer(layer)
        }
        let composition = AVMutableVideoComposition(); composition.renderSize = size; composition.frameDuration = CMTime(value: 1, timescale: 30)
        let instruction = AVMutableVideoCompositionInstruction(); instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let videoInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        videoInstruction.setTransform(transform.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)), at: .zero)
        instruction.layerInstructions = [videoInstruction]; composition.instructions = [instruction]
        composition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { throw Self.failure("Cannot prepare caption export.") }
        session.videoComposition = composition
        let dest = url.deletingPathExtension().appendingPathExtension("captioned.mp4")
        guard !FileManager.default.fileExists(atPath: dest.path) else { throw Self.failure("Captioned copy already exists.") }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await session.export(to: temporary, as: .mp4)
        let result = AVURLAsset(url: temporary)
        guard try await result.load(.duration).seconds > 0, !(try await result.loadTracks(withMediaType: .video)).isEmpty else { throw Self.failure("Caption export validation failed.") }
        try FileManager.default.moveItem(at: temporary, to: dest)
    }

}
@available(macOS 15.0, *)
struct CaptureSpeechCaption: View {
    @ObservedObject var speech: CaptureSpeech
    var body: some View {
        Text(speech.caption).font(.system(size: 16, weight: .medium)).foregroundStyle(.white)
            .lineLimit(3).multilineTextAlignment(.center).padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
    }
}
@available(macOS 15.0, *)
struct CaptureSpeechSettings: View {
    let microphone: Bool
    @AppStorage("recorder.speechEnabled") private var enabled = false
    @AppStorage("recorder.speechLocale") private var locale = "en-IN"
    @AppStorage("recorder.speechCaptions") private var captions = true
    @AppStorage("recorder.speechSave") private var save = true
    @AppStorage("recorder.speechEmbed") private var embed = false
    @AppStorage("recorder.speechFormat") private var format = "Both"
    @AppStorage("recorder.speechFolder") private var folder = ""
    private func toggle(_ title: String, _ value: Binding<Bool>) -> some View {
        HStack { Text(title); Spacer(); Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch) }
    }
    private var options: [(String, String)] {
        SFSpeechRecognizer.supportedLocales().map { ($0.identifier, Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier) }.sorted { $0.1 < $1.1 }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toggle("Enable speech recognition", $enabled).disabled(!microphone)
            if enabled {
                HStack { Text("Language"); Spacer(); ModernSettingsMenu(title: "Language", selection: $locale, options: options) }
                toggle("Show live captions", $captions)
                toggle("Include captions in video", $embed)
                if embed { Text("Exports a separate captioned video; the original is preserved.").font(.caption).foregroundStyle(.secondary) }
                toggle("Save transcript file", $save)
                if save {
                    HStack { Text("Transcript format"); Spacer(); ModernSettingsMenu(title: "Format", selection: $format, options: [("TXT", "TXT"), ("SRT", "SRT"), ("Both", "TXT & SRT")]) }
                    HStack { Text("Transcript location"); Spacer(); Button("Choose…") { let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; if panel.runModal() == .OK, let url = panel.url { folder = url.path } }; if !folder.isEmpty { Button("Reset") { folder = "" } } }
                    Text(folder.isEmpty ? "Same as recording" : folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            if !microphone { Text("Enable Microphone to use live speech recognition.").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
