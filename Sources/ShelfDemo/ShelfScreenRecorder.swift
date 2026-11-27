import AppKit
import SwiftUI
import ScreenCaptureKit
import AVFoundation
import UniformTypeIdentifiers

@available(macOS 15.0, *)
@MainActor final class ShelfScreenRecorder: NSObject, ObservableObject, SCRecordingOutputDelegate {
    static let shared = ShelfScreenRecorder()
    @Published private(set) var busy = false
    @Published private(set) var recording = false
    @Published private(set) var status = "Ready"
    private var stream: SCStream?
    private var speech: CaptureSpeech?
    private var captionPanel: NSPanel?
    private var output: SCRecordingOutput?
    private var cameraSession: AVCaptureSession?
    private var cameraPanel: NSPanel?
    private var controls: NSPanel?
    private var destination: URL?
    private var stopping = false
    @Published private(set) var countdownRemaining = 0
    private var countdownCancelled = false
    nonisolated static func countdownDuration(enabled: Bool, stored: Int?) -> Int {
        guard enabled else { return 0 }
        guard let stored, [0, 3, 5, 10].contains(stored) else { return 3 }
        return stored
    }
    func cancelCountdown() { if countdownRemaining > 0 { countdownCancelled = true } }
    private var finishAction = "save"
    @Published private(set) var paused = false
    @Published private(set) var transitioning = false
    @Published private(set) var accumulated: TimeInterval = 0
    @Published private(set) var lastRecording: URL?
    private var segments: [URL] = []
    private var segmentURL: URL?
    private var pausing = false
    func elapsed(at date: Date) -> Int { max(0, Int(accumulated + (startedAt.map { date.timeIntervalSince($0) } ?? 0))) }
    func editLastRecording() {
        if let lastRecording { ShelfSilenceEditor.open(lastRecording); return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { ShelfSilenceEditor.open(url) }
    }
    func togglePause() {
        guard recording, !stopping, !transitioning, let stream else { return }
        transitioning = true
        do {
            if paused {
                guard let destination else { throw failure("Missing recording destination") }
                let url = destination.deletingLastPathComponent().appendingPathComponent("Segment-\(UUID().uuidString).mp4")
                let config = SCRecordingOutputConfiguration(); config.outputURL = url; config.outputFileType = .mp4; config.videoCodecType = .h264
                let next = SCRecordingOutput(configuration: config, delegate: self)
                segmentURL = url; output = next; status = "Resuming…"
                try stream.addRecordingOutput(next)
            } else {
                guard let output else { throw failure("Missing recording output") }
                pausing = true; status = "Pausing…"
                try stream.removeRecordingOutput(output)
            }
        } catch { transitioning = false; pausing = false; status = error.localizedDescription; if paused { output = nil; segmentURL = nil } }
    }
    private var launcher: NSPanel?
    @Published private(set) var startedAt: Date?
    func openLauncher() {
        if let controls { controls.orderFrontRegardless(); return }
        if busy { return }
        if let launcher { launcher.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let panel = CaptureAreaPanel(contentRect: NSRect(x: frame.maxX-364, y: max(frame.minY, frame.maxY-530), width: 360, height: 400), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Capture Studio"; panel.isReleasedWhenClosed = false; panel.level = .floating
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.isMovableByWindowBackground = true
        let host = NSHostingView(rootView: CaptureLauncher(recorder: self))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        launcher = panel; resizeLauncher(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func resizeLauncher() {
        guard let panel = launcher, let host = panel.contentView as? NSHostingView<CaptureLauncher> else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard size.height.isFinite, size.height > 0 else { return }
        let safe = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let height = min(size.height, safe.height - 16)
        let y = max(safe.minY + 8, min(panel.frame.maxY, safe.maxY - 8) - height)
        panel.setFrame(NSRect(x: panel.frame.minX, y: y, width: 360, height: height), display: true)
    }
    func resizeControls() {
        guard let panel = controls, let host = panel.contentView as? NSHostingView<CaptureControlBar> else { return }
        host.layoutSubtreeIfNeeded()
        let height = host.fittingSize.height
        guard height.isFinite, height > 0 else { return }
        let safe = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let y = max(safe.minY + 8, min(panel.frame.maxY, safe.maxY - 8) - height)
        panel.setFrame(NSRect(x: panel.frame.minX, y: y, width: 76, height: height), display: true)
    }
    func closeLauncher() { launcher?.orderOut(nil); launcher = nil }
    func beginFromLauncher() async {
        guard !busy, launcher != nil else { return }
        launcher?.orderOut(nil); launcher = nil
        for window in NSApp.windows where window.isVisible && window.title == "DropShelf Settings" { window.orderOut(nil) }
        status = "Ready"
        showControls()
    }
    func cancelPreparation() {
        guard !busy else { return }
        controls?.orderOut(nil); controls = nil
        status = "Ready"
        openLauncher()
    }
    func start() async {
        guard !busy, controls != nil else { return }
        busy = true
        finishAction = "save"
        status = "Preparing…"
        do {
            let defaults = UserDefaults.standard
            let camera = defaults.bool(forKey: "recorder.camera") && (defaults.string(forKey: "recorder.mode") ?? "Full screen") == "Full screen"
            let mic = defaults.bool(forKey: "recorder.microphone")
            if mic && defaults.bool(forKey: "recorder.speechEnabled") {
                do {
                    let recognizer = try await CaptureSpeech.authorized(locale: defaults.string(forKey: "recorder.speechLocale") ?? "en-IN")
                    speech = recognizer
                } catch {
                    let alert = NSAlert(); alert.messageText = "Live speech unavailable"; alert.informativeText = error.localizedDescription + "\nRecording can continue without transcription."; alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() != .alertFirstButtonReturn { returnToReady("Recording cancelled"); return }
                }
            }
            if camera { guard await AVCaptureDevice.requestAccess(for: .video) else { throw failure("Camera permission denied") } }
            if mic { guard await AVCaptureDevice.requestAccess(for: .audio) else { throw failure("Microphone permission denied") } }
            guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { throw failure("Enable Screen & System Audio Recording in System Settings, then reopen DropShelf.") }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { throw failure("No display available") }
            let mode = defaults.string(forKey: "recorder.mode") ?? "Full screen"
            var selectedWindow: SCWindow?
            var region: CGRect?
            if mode == "Window" {
                let windows = content.windows.filter { $0.isOnScreen && $0.frame.width > 100 && $0.frame.height > 100 && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier && $0.windowLayer == 0 && $0.owningApplication != nil }
                guard !windows.isEmpty else { throw failure("No available windows") }
                controls?.orderOut(nil)
                let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28), pullsDown: false)
                picker.addItems(withTitles: windows.enumerated().map { "\($0.offset + 1). \($0.element.owningApplication?.applicationName ?? "App") — \($0.element.title ?? "Window")" })
                let alert = NSAlert(); alert.messageText = "Choose a window"; alert.accessoryView = picker; alert.addButton(withTitle: "Record"); alert.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn, windows.indices.contains(picker.indexOfSelectedItem) else { returnToReady("Selection cancelled"); return }
                selectedWindow = windows[picker.indexOfSelectedItem]
                controls?.orderFrontRegardless()
            } else if mode == "Area" {
                guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }) else { throw failure("Capture display unavailable") }
                controls?.orderOut(nil)
                guard let rect = await selectArea(on: screen) else { returnToReady("Selection cancelled"); return }
                region = rect
                try await Task.sleep(nanoseconds: 350_000_000)
            }
            if camera && mode != "Full screen" { throw failure("Camera overlay is currently supported only for full-screen capture. Turn it off for Window or Area.") }
            let folder = defaults.string(forKey: "recorder.folder").flatMap { $0.isEmpty ? nil : $0 }.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/DropShelf", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("Recording-\(UUID().uuidString).mp4")
            destination = url
            segmentURL = url.deletingLastPathComponent().appendingPathComponent("Segment-\(UUID().uuidString).mp4")
            controls?.orderFrontRegardless()
            countdownCancelled = false
            if defaults.object(forKey: "recorder.countdownEnabled") == nil || defaults.bool(forKey: "recorder.countdownEnabled") {
                let stored = defaults.integer(forKey: "recorder.countdownSeconds")
                let seconds = Self.countdownDuration(enabled: true, stored: defaults.object(forKey: "recorder.countdownSeconds") == nil ? nil : stored)
                for count in stride(from: seconds, through: 1, by: -1) {
                    countdownRemaining = count
                    status = "Starting in \(count)…"
                    // Check cancellation frequently without starting a stream.
                    for _ in 0..<10 {
                        try await Task.sleep(nanoseconds: 100_000_000)
                        if countdownCancelled {
                            countdownRemaining = 0
                            destination = nil; segmentURL = nil
                            cleanup(); status = "Ready"; showControls()
                            return
                        }
                    }
                }
            }
            countdownRemaining = 0
            if camera { try showCamera() }
            if let speech, defaults.object(forKey: "recorder.speechCaptions") == nil || defaults.bool(forKey: "recorder.speechCaptions") {
                let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
                let width = min(CGFloat(520), frame.width - 40)
                let panel = NSPanel(contentRect: NSRect(x: frame.midX-width/2, y: frame.minY+36, width: width, height: 90), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .floating; panel.hasShadow = true; panel.isMovableByWindowBackground = true
                panel.contentView = NSHostingView(rootView: CaptureSpeechCaption(speech: speech))
                captionPanel = panel; panel.orderFrontRegardless()
            }
            controls?.orderFrontRegardless()
            let filter: SCContentFilter
            if let selectedWindow {
                filter = SCContentFilter(desktopIndependentWindow: selectedWindow)
            } else {
                guard let controls, controls.windowNumber > 0 else {
                    throw failure("Recording controls unavailable. Please retry.")
                }
                let toolbarID = CGWindowID(controls.windowNumber)
                let excludedIDs = [toolbarID] + (captionPanel.map { [CGWindowID($0.windowNumber)] } ?? [])
                var excludedWindows: [SCWindow] = []
                for _ in 0..<20 {
                    let refreshed = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    excludedWindows = refreshed.windows.filter { excludedIDs.contains($0.windowID) }
                    if excludedWindows.count == excludedIDs.count { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard excludedWindows.count == excludedIDs.count else {
                    throw failure("Could not exclude recording controls. Recording was not started. Please retry.")
                }
                filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            }
            let config = SCStreamConfiguration()
            let requested = defaults.integer(forKey: "recorder.height")
            let height = [720, 1080, 1440, 0].contains(requested) && defaults.object(forKey: "recorder.height") != nil ? requested : 1080
            let sourceSize = region?.size ?? filter.contentRect.size
            if let region { config.sourceRect = region }
            let pixelScale = Double(filter.pointPixelScale)
            let pixelWidth = Double(sourceSize.width) * pixelScale
            let pixelHeight = Double(sourceSize.height) * pixelScale
            guard pixelWidth.isFinite, pixelHeight.isFinite, pixelWidth >= 2, pixelHeight >= 2 else { throw failure("Invalid capture dimensions") }
            let scale = height == 0 ? 1.0 : min(Double(height) / pixelHeight, 1.0)
            config.width = max(2, Int(pixelWidth * scale) / 2 * 2)
            config.height = max(2, Int(pixelHeight * scale) / 2 * 2)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.showsCursor = true
            config.capturesAudio = defaults.bool(forKey: "recorder.systemAudio")
            config.captureMicrophone = mic
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            self.stream = stream
            if let speech { try stream.addStreamOutput(speech, type: .microphone, sampleHandlerQueue: .main) }
            let rc = SCRecordingOutputConfiguration()
            guard let segmentURL else { throw failure("Missing segment URL") }
            rc.outputURL = segmentURL
            rc.outputFileType = .mp4
            rc.videoCodecType = .h264
            let output = SCRecordingOutput(configuration: rc, delegate: self)
            self.output = output
            try stream.addRecordingOutput(output)
            status = "Starting recording…"
            try await stream.startCapture()
        } catch { fail(error.localizedDescription) }
    }
    private func selectArea(on screen: NSScreen) async -> CGRect? {
        await withCheckedContinuation { continuation in
            let panel = CaptureAreaPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hasShadow = false; panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = CaptureAreaView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.safeTop = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
            panel.contentView = view
            view.finish = { [weak view] rect in
                view?.finish = nil
                panel.orderOut(nil); panel.close()
                continuation.resume(returning: rect)
            }
            NSApp.activate(ignoringOtherApps: true)
            panel.orderFrontRegardless(); panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(view)
        }
    }
    private func returnToReady(_ message: String) {
        cleanup(); status = message
        openLauncher()
    }
    func confirmFinish(restart: Bool) {
        guard recording, !stopping, !transitioning else { return }
        let alert = NSAlert(); alert.messageText = restart ? "Restart recording?" : "Discard this recording?"
        alert.informativeText = "Only the current take will be discarded. Previously saved videos are preserved."
        alert.addButton(withTitle: restart ? "Restart" : "Discard"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        finishAction = restart ? "restart" : "discard"
        Task { await stop() }
    }
    func stop() async {
        guard busy, recording, !stopping, !transitioning, let stream else { return }
        stopping = true; transitioning = true
        status = "Saving…"
        do { try await stream.stopCapture(); if paused { await finishSegments() } } catch { fail(error.localizedDescription) }
    }
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) { Task { @MainActor in
        guard self.output === recordingOutput else { return }
        self.recording = true; self.paused = false; self.transitioning = false; self.startedAt = Date(); self.status = "Recording"
        self.speech?.begin(offset: self.accumulated)
    } }
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { Task { @MainActor in
        guard self.output === recordingOutput else { return }
        if let url = self.segmentURL { self.segments.append(url) }
        self.segmentURL = nil; self.output = nil
        if let start = self.startedAt { self.accumulated += Date().timeIntervalSince(start) }
        self.startedAt = nil
        self.speech?.end()
        if self.pausing { self.pausing = false; self.paused = true; self.transitioning = false; self.status = "Paused"; return }
        await self.finishSegments()
    } }
    private func finishSegments() async {
        let saved = segments, url = destination, action = finishAction
        status = "Saving…"; transitioning = true
        speech?.end()
        do {
            if action == "save" {
                guard let url, !saved.isEmpty else { throw failure("No recording segments were saved.") }
                if saved.count == 1 { try FileManager.default.moveItem(at: saved[0], to: url) }
                else {
                    let job = Task.detached(priority: .userInitiated) { let parts = try await ShelfRecordingEditor.fullParts(saved); try await ShelfRecordingEditor.export(parts, to: url) }
                    try await job.value
                    for part in saved { try? FileManager.default.removeItem(at: part) }
                }
                var transcriptWarning = ""
                if let speech, UserDefaults.standard.bool(forKey: "recorder.speechEmbed") {
                    do { try await speech.exportCaptionedCopy(of: url) }
                    catch { transcriptWarning += " (Captioned video: \(error.localizedDescription). Original saved.)" }
                }
                if let speech, UserDefaults.standard.object(forKey: "recorder.speechSave") == nil || UserDefaults.standard.bool(forKey: "recorder.speechSave") {
                    do { try speech.save(beside: url) } catch { transcriptWarning += " (Transcript: \(error.localizedDescription))" }
                }
                lastRecording = url; cleanup(); status = "Saved: \(url.lastPathComponent)" + transcriptWarning
                if !transcriptWarning.isEmpty { let alert = NSAlert(); alert.messageText = "Recording saved"; alert.informativeText = transcriptWarning; alert.runModal() }
                let captioned = url.deletingPathExtension().appendingPathExtension("captioned.mp4")
                NSWorkspace.shared.activateFileViewerSelecting(FileManager.default.fileExists(atPath: captioned.path) ? [url, captioned] : [url])
                if UserDefaults.standard.bool(forKey: "recorder.offerSilenceEdit") { ShelfSilenceEditor.open(url) }
            } else {
                for part in saved { try FileManager.default.trashItem(at: part, resultingItemURL: nil) }
                cleanup(); status = "Ready"
                if action == "restart" { showControls(); await start() } else { openLauncher() }
            }
        } catch { let folder = url?.deletingLastPathComponent(); cleanup(); status = "Save failed: \(error.localizedDescription). Segments preserved."; if let folder { NSWorkspace.shared.activateFileViewerSelecting([folder]) }; showControls() }
    }
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) { Task { @MainActor in
        guard self.output === recordingOutput else { return }; self.fail(error.localizedDescription)
    } }
    private func failure(_ message: String) -> NSError { NSError(domain: "DropShelfRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private func fail(_ message: String) {
        let active = stream
        cleanup(); status = message
        openLauncher()
        let alert = NSAlert(); alert.messageText = "Recording could not start or continue"; alert.informativeText = message; alert.runModal()
        if let active { Task { try? await active.stopCapture() } }
    }
    private func cleanup() {
        speech?.end(); speech = nil; captionPanel?.orderOut(nil); captionPanel = nil
        cameraPanel?.orderOut(nil); cameraPanel = nil
        controls?.orderOut(nil); controls = nil
        cameraSession?.stopRunning(); cameraSession = nil
        stream = nil; output = nil; destination = nil; busy = false; recording = false; stopping = false; startedAt = nil
        segments = []; segmentURL = nil; paused = false; pausing = false; transitioning = false; accumulated = 0
        countdownRemaining = 0; countdownCancelled = false
    }
    private func showCamera() throws {
        guard let device = AVCaptureDevice.default(for: .video) else { throw failure("No camera available") }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw failure("Cannot open camera") }
        session.addInput(input)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let prefs = UserDefaults.standard
        let size: CGFloat = ["Small": 100, "Medium": 160, "Large": 220][prefs.string(forKey: "recorder.cameraSize") ?? "Medium"] ?? 160
        let position = prefs.string(forKey: "recorder.cameraPosition") ?? "Bottom left"
        let x = position.contains("right") ? screen.maxX-size-24 : screen.minX+24
        let y = position.contains("Top") ? screen.maxY-size-24 : screen.minY+24
        let panel = NSPanel(contentRect: NSRect(x: x, y: y, width: size, height: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .floating; panel.isMovableByWindowBackground = true
        let view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size)); view.wantsLayer = true
        view.layer?.cornerRadius = prefs.string(forKey: "recorder.cameraShape") == "Square" ? 0 : (prefs.string(forKey: "recorder.cameraShape") == "Rounded" ? 18 : size/2); view.layer?.masksToBounds = true
        let layer = AVCaptureVideoPreviewLayer(session: session); layer.frame = view.bounds; layer.videoGravity = .resizeAspectFill
        view.layer?.addSublayer(layer); panel.contentView = view
        cameraSession = session; cameraPanel = panel; session.startRunning(); panel.orderFrontRegardless()
    }
    private func showControls() {
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let panel = NSPanel(contentRect: NSRect(x: frame.minX+16, y: frame.midY-120, width: 76, height: 264), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.level = .floating; panel.isMovable = true; panel.isMovableByWindowBackground = true
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: CaptureControlBar(recorder: self))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        panel.setFrameAutosaveName("DropShelfCaptureToolbarV3")
        panel.setFrameUsingName("DropShelfCaptureToolbarV3")
        let safe = (NSScreen.screens.first { $0.visibleFrame.contains(NSPoint(x: panel.frame.midX, y: panel.frame.midY)) }?.visibleFrame ?? frame)
        let x = min(max(panel.frame.minX, safe.minX + 8), max(safe.minX + 8, safe.maxX - 84))
        let y = min(max(panel.frame.minY, safe.minY + 8), max(safe.minY + 8, safe.maxY - 272))
        panel.setFrame(NSRect(x: x, y: y, width: 76, height: 264), display: false)
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) { panel.setFrameOrigin(NSPoint(x: frame.minX+16, y: frame.midY-120)) }
        controls = panel; resizeControls(); panel.orderFrontRegardless()
    }
}


struct ShelfRecorderSettings: View {
    var body: some View {
        if #available(macOS 15.0, *) { ShelfRecorderOptions() }
        else { Text("Capture Studio requires macOS 15 or later.").foregroundStyle(.secondary) }
    }
}
@available(macOS 15.0, *)
private struct ShelfRecorderOptions: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var recorder = ShelfScreenRecorder.shared
    @AppStorage("recorder.enabled") private var enabled = false
    @AppStorage("recorder.offerSilenceEdit") private var offerSilenceEdit = false
    @AppStorage("recorder.countdownEnabled") private var countdownEnabled = true
    @AppStorage("recorder.countdownSeconds") private var countdownSeconds = 3
    @AppStorage("recorder.camera") private var camera = false
    @AppStorage("recorder.microphone") private var mic = false
    @AppStorage("recorder.systemAudio") private var audio = false
    @AppStorage("recorder.mode") private var mode = "Full screen"
    @AppStorage("recorder.cameraPosition") private var position = "Bottom left"
    @AppStorage("recorder.cameraSize") private var size = "Medium"
    @AppStorage("recorder.cameraShape") private var shape = "Circle"
    @AppStorage("recorder.height") private var height = 1080
    @AppStorage("recorder.folder") private var folder = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { recorder.openLauncher() } label: { Label("Start Recording…", systemImage: "record.circle").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).controlSize(.large).disabled(recorder.busy)
                if recorder.busy { Button("Stop") { Task { await recorder.stop() } }.disabled(!recorder.recording) }
            }
            section("Capture and audio") {
                toggle("Show in menu bar", $enabled)
                Divider()
                HStack { Text("Capture mode"); Spacer(); ModernSettingsMenu(title: "Capture mode", selection: $mode, options: [("Full screen", "Full screen"), ("Window", "Window"), ("Area", "Area")]) }
                if mode == "Area" {
                    Text("Select the recording area visually from the recording controls.").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                toggle("Camera bubble", $camera).disabled(mode != "Full screen")
                if camera && mode == "Full screen" {
                    picker("Position", $position, ["Bottom left", "Bottom right", "Top left", "Top right"])
                    picker("Size", $size, ["Small", "Medium", "Large"])
                    picker("Shape", $shape, ["Circle", "Rounded", "Square"])
                }
                Divider()
                toggle("Microphone", $mic)
                toggle("System audio", $audio)
            }
            section("Live speech recognition") { CaptureSpeechSettings(microphone: mic) }
            section("Recording countdown") {
                toggle("Enable countdown", $countdownEnabled)
                if countdownEnabled {
                    HStack { Text("Countdown duration"); Spacer(); ModernSettingsMenu(title: "Countdown", selection: $countdownSeconds, options: [(3, "3 seconds"), (5, "5 seconds"), (10, "10 seconds"), (0, "Manual Start")]) }
                }
                Text("The countdown starts only after pressing Record on the floating toolbar. Manual Start records immediately.").font(.caption).foregroundStyle(.secondary)
            }
            section("Output preferences") {
                HStack { Text("Video quality"); Spacer(); ModernSettingsMenu(title: "Video quality", selection: $height, options: [(720, "720p"), (1080, "1080p"), (1440, "1440p"), (0, "Native Retina")]) }
                HStack { Text("Save location"); Spacer(); Button("Choose…") { let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; if p.runModal() == .OK, let url = p.url { folder = url.path } } }
                Text(folder.isEmpty ? "~/Movies/DropShelf" : folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            }
            section("Post-recording tools") {
                HStack(alignment: .center) {
                    Text("Offer Remove Silent Parts after recording").fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Toggle("Offer Remove Silent Parts", isOn: $offerSilenceEdit).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                HStack { Text("Edit a recording"); Spacer(); Button("Remove Silent Parts…") { recorder.editLastRecording() }.buttonStyle(ShelfSmallButton()) }
            }
            Text(recorder.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.frame(maxWidth: .infinity)
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 11, content: content).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(ShelfSettingsPalette.card(colorScheme), in: RoundedRectangle(cornerRadius: 11)).disabled(recorder.busy)
        }
    }
    private func toggle(_ title: String, _ value: Binding<Bool>) -> some View { HStack { Text(title); Spacer(); Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch) } }
    private func picker(_ title: String, _ value: Binding<String>, _ options: [String]) -> some View { HStack { Text(title); Spacer(); ModernSettingsMenu(title: title, selection: value, options: options.map { ($0, $0) }) } }
}
@available(macOS 15.0, *)
private struct CaptureLauncher: View {
    @ObservedObject var recorder: ShelfScreenRecorder
    @AppStorage("recorder.speechEnabled") private var speechEnabled = false
    @AppStorage("recorder.mode") private var mode = "Full screen"
    @AppStorage("recorder.camera") private var camera = false
    @AppStorage("recorder.microphone") private var mic = false
    @AppStorage("recorder.systemAudio") private var audio = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Image(systemName: "video.fill").foregroundStyle(.red); Text("Capture Studio").font(.headline); Spacer(); Button { recorder.closeLauncher() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
            HStack { Label("Capture", systemImage: "display"); Spacer(); ModernSettingsMenu(title: "Capture mode", selection: $mode, options: [("Full screen", "Full screen"), ("Window", "Window"), ("Area", "Area")]) }
            Divider()
            HStack { Label("Camera bubble", systemImage: "video"); Spacer(); Toggle("Camera", isOn: $camera).labelsHidden().toggleStyle(.switch).disabled(mode != "Full screen") }
            HStack { Label("Microphone", systemImage: "mic"); Spacer(); Toggle("Microphone", isOn: $mic).labelsHidden().toggleStyle(.switch) }
            HStack { Label("System audio", systemImage: "speaker.wave.2"); Spacer(); Toggle("Audio", isOn: $audio).labelsHidden().toggleStyle(.switch) }
            Divider()
            HStack { Label("Live speech recognition", systemImage: "waveform"); Spacer(); Toggle("Live speech recognition", isOn: $speechEnabled).labelsHidden().toggleStyle(.switch).disabled(!mic) }
            if speechEnabled && mic { Text("Language, captions and transcript options are in Capture Studio settings.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Divider()
            Text("Continue to the floating toolbar. Press Record when you are ready.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button { Task { await recorder.beginFromLauncher() } } label: { Text("Continue").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
        }.padding(18).font(.system(size: 13)).frame(width: 360).fixedSize(horizontal: false, vertical: true).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .onChange(of: speechEnabled) { _ in DispatchQueue.main.async { recorder.resizeLauncher() } }
            .onChange(of: mic) { _ in DispatchQueue.main.async { recorder.resizeLauncher() } }
    }
}
@available(macOS 15.0, *)
private struct CaptureControlBar: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var recorder: ShelfScreenRecorder
    var body: some View {
        VStack(spacing: 5) {
            CaptureDragHandle().frame(width: 44, height: 16)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = recorder.elapsed(at: context.date)
                Text(recorder.countdownRemaining > 0 ? String(recorder.countdownRemaining) : String(format: "%02d:%02d", seconds / 60, seconds % 60)).monospacedDigit().font(.system(size: recorder.countdownRemaining > 0 ? 26 : 12, weight: .semibold))
            }
            if recorder.countdownRemaining == 0 {
            Button { Task { if recorder.recording { await recorder.stop() } else { await recorder.start() } } } label: {
                Image(systemName: recorder.recording ? "stop.fill" : "record.circle.fill")
                    .font(.system(size: 21)).foregroundStyle(recorder.recording ? Color.primary : Color.red).frame(width: 42, height: 38).background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain).disabled(recorder.transitioning || (recorder.busy && !recorder.recording))
                .help(recorder.recording ? "Stop and save recording" : "Start recording")
                .accessibilityLabel(recorder.recording ? "Stop recording" : "Start recording")
            }
            if recorder.recording {
                Button { recorder.togglePause() } label: { Image(systemName: recorder.paused ? "play.fill" : "pause.fill").font(.system(size: 19)).frame(width: 42, height: 34) }.buttonStyle(.plain).disabled(recorder.transitioning).help(recorder.paused ? "Resume recording" : "Pause recording")
                Button { recorder.confirmFinish(restart: true) } label: { Image(systemName: "arrow.counterclockwise").font(.system(size: 19)).frame(width: 42, height: 34) }.buttonStyle(.plain).disabled(recorder.transitioning).help("Restart recording")
                Button { recorder.confirmFinish(restart: false) } label: { Image(systemName: "trash").font(.system(size: 19)).frame(width: 42, height: 34) }.buttonStyle(.plain).disabled(recorder.transitioning).help("Discard recording")
            }
            if recorder.countdownRemaining > 0 {
                Button { recorder.cancelCountdown() } label: { Image(systemName: "xmark").font(.system(size: 14)) }.buttonStyle(.plain).help("Cancel countdown").accessibilityLabel("Cancel countdown")
            }
            if !recorder.busy {
                Button { recorder.cancelPreparation() } label: { Image(systemName: "xmark").font(.system(size: 11)) }.buttonStyle(.plain).help("Close recording controls")
            }
            Text(recorder.recording ? (recorder.transitioning ? recorder.status : recorder.paused ? "Paused" : "Recording") : (recorder.busy ? (recorder.status.hasPrefix("Starting in") ? recorder.status : "Preparing") : (recorder.status == "Ready" ? "Ready" : recorder.status)))
                .font(.system(size: 9)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(4).help(recorder.status)
        }.padding(8).frame(width: 76).fixedSize(horizontal: false, vertical: true).background(ShelfSettingsPalette.content(colorScheme), in: RoundedRectangle(cornerRadius: 18)).clipShape(RoundedRectangle(cornerRadius: 18))
            .onChange(of: recorder.recording) { _ in DispatchQueue.main.async { recorder.resizeControls() } }
            .onChange(of: recorder.busy) { _ in DispatchQueue.main.async { recorder.resizeControls() } }
            .onChange(of: recorder.countdownRemaining) { _ in DispatchQueue.main.async { recorder.resizeControls() } }
            .onChange(of: recorder.status) { _ in DispatchQueue.main.async { recorder.resizeControls() } }
    }
}


@MainActor
private final class CaptureAreaPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class CaptureAreaView: NSView {
    var finish: ((CGRect?) -> Void)?
    private var selection = CGRect.zero
    private var origin = CGPoint.zero
    private var previous = CGRect.zero
    private var edges = 0
    private var dragging = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    private func clamped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }
    private var valid: Bool { selection.width >= 16 && selection.height >= 16 }
    var safeTop: CGFloat = 0
    private var controlsY: CGFloat { max(16, safeTop + 12) }
    private var confirmRect: CGRect { CGRect(x: bounds.midX - 34, y: controlsY, width: 156, height: 34) }
    private var cancelRect: CGRect { CGRect(x: confirmRect.minX - 88, y: controlsY, width: 80, height: 34) }
    override func mouseDown(with event: NSEvent) {
        let p = clamped(convert(event.locationInWindow, from: nil))
        if cancelRect.contains(p) { finish?(nil); return }
        if valid && confirmRect.contains(p) { finish?(selection); return }
        origin = p; previous = selection; edges = 0
        if valid && selection.insetBy(dx: -9, dy: -9).contains(p) {
            if abs(p.x-selection.minX) <= 9 { edges |= 1 }
            if abs(p.x-selection.maxX) <= 9 { edges |= 2 }
            if abs(p.y-selection.minY) <= 9 { edges |= 4 }
            if abs(p.y-selection.maxY) <= 9 { edges |= 8 }
            if edges == 0 && selection.contains(p) { edges = 16 }
        }
        if edges == 0 { selection = CGRect(origin: p, size: .zero) }
        dragging = true; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let p = clamped(convert(event.locationInWindow, from: nil))
        if edges == 16 {
            selection.origin.x = min(max(previous.minX + p.x-origin.x, 0), bounds.width-previous.width)
            selection.origin.y = min(max(previous.minY + p.y-origin.y, 0), bounds.height-previous.height)
        } else if edges != 0 {
            let l = edges & 1 != 0 ? min(p.x, previous.maxX-16) : previous.minX
            let r = edges & 2 != 0 ? max(p.x, previous.minX+16) : previous.maxX
            let t = edges & 4 != 0 ? min(p.y, previous.maxY-16) : previous.minY
            let b = edges & 8 != 0 ? max(p.y, previous.minY+16) : previous.maxY
            selection = CGRect(x: l, y: t, width: r-l, height: b-t)
        } else {
            selection = CGRect(x: min(origin.x,p.x), y: min(origin.y,p.y), width: abs(p.x-origin.x), height: abs(p.y-origin.y))
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { dragging = false; needsDisplay = true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish?(nil) }
        else if (event.keyCode == 36 || event.keyCode == 76) && valid { finish?(selection) }
        else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); bounds.fill(using: .copy)
        let shade = NSBezierPath(rect: bounds)
        if !selection.isEmpty { shade.appendRect(selection); shade.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(0.48).setFill(); shade.fill()
        if !selection.isEmpty {
            let border = NSBezierPath(rect: selection); border.lineWidth = 2
            NSColor.white.setStroke(); border.stroke()
            for x in [selection.minX, selection.midX, selection.maxX] {
                for y in [selection.minY, selection.midY, selection.maxY] where x != selection.midX || y != selection.midY {
                    NSColor.white.setFill(); NSBezierPath(ovalIn: CGRect(x: x-3, y: y-3, width: 6, height: 6)).fill()
                }
            }
        }
        func button(_ title: String, _ rect: CGRect, _ color: NSColor) {
            color.setFill(); NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
            let text = title as NSString; let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: rect.midX-size.width/2, y: rect.midY-size.height/2), withAttributes: attrs)
        }
        button("Cancel", cancelRect, .darkGray)
        button("Start Recording", confirmRect, valid ? .systemBlue : .darkGray)
        let message = valid ? "\(Int(selection.width)) × \(Int(selection.height)) pt · Drag edges to resize · Return to record" : "Drag to select an area · Esc to cancel"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white, .backgroundColor: NSColor.black.withAlphaComponent(0.75)]
        let text = message as NSString; let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: max(8, bounds.midX-size.width/2), y: controlsY + 44), withAttributes: attrs)
    }
}

private struct CaptureDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> CaptureDragHandleView { CaptureDragHandleView() }
    func updateNSView(_ nsView: CaptureDragHandleView, context: Context) {}
}
private final class CaptureDragHandleView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setStroke()
        let path = NSBezierPath(); path.lineWidth = 1.5
        for offset in [-4.0, 0.0, 4.0] { path.move(to: CGPoint(x: bounds.midX-8, y: bounds.midY+offset)); path.line(to: CGPoint(x: bounds.midX+8, y: bounds.midY+offset)) }
        path.stroke()
    }
}
