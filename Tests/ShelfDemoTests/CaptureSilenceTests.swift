import XCTest
import AVFoundation
@testable import ShelfDemo

final class CaptureSilenceTests: XCTestCase {
    func testSilencePlanWithSyntheticAudio() async throws {
        guard #available(macOS 15, *) else { throw XCTSkip("Requires macOS 15") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64000))
        buffer.frameLength = 64000
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<64000 { samples[i] = (i < 16000 || (i >= 32000 && i < 48000)) ? Float(sin(Double(i) * 0.1) * 0.5) : 0 }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let plan = try await ShelfRecordingEditor.analyze(url, threshold: -40, minimum: 0.8)
        XCTAssertEqual(plan.duration, 4, accuracy: 0.1)
        XCTAssertEqual(plan.parts.count, 2)
        XCTAssertEqual(plan.kept, 2.45, accuracy: 0.25)
    }
    func testCountdownPreferences() throws {
        guard #available(macOS 15, *) else { throw XCTSkip("Requires macOS 15") }
        XCTAssertEqual(ShelfScreenRecorder.countdownDuration(enabled: false, stored: 10), 0)
        XCTAssertEqual(ShelfScreenRecorder.countdownDuration(enabled: true, stored: 0), 0)
        XCTAssertEqual(ShelfScreenRecorder.countdownDuration(enabled: true, stored: nil), 3)
        for seconds in [3, 5, 10] { XCTAssertEqual(ShelfScreenRecorder.countdownDuration(enabled: true, stored: seconds), seconds) }
        XCTAssertEqual(ShelfScreenRecorder.countdownDuration(enabled: true, stored: -1), 3)
    }
    func testSubtitleTimestamp() throws {
        guard #available(macOS 15, *) else { throw XCTSkip("Requires macOS 15") }
        XCTAssertEqual(CaptureSpeech.stamp(3661.25), "01:01:01,250")
    }
}
