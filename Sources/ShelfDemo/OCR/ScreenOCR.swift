import AppKit
import Foundation

/// Captures an interactive screen selection using macOS `screencapture` and
/// recognizes the text using Vision OCR (`ImageOCR`).
enum ScreenOCR {
    /// Launches macOS interactive screen capture (`screencapture -i`).
    /// User drags crosshairs to select a rectangle.
    /// Runs Vision OCR on the captured image.
    /// Copies extracted text to the general pasteboard and returns it.
    /// Returns `nil` if the user cancels (e.g. presses Escape or clicks without dragging).
    @discardableResult
    static func captureAndExtractText() async throws -> ShelfOCRResult? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenOCR-\(UUID().uuidString).png")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        // Brief delay to allow any open popup menus to dismiss cleanly before capture
        try? await Task.sleep(nanoseconds: 150_000_000)

        let success = await Task.detached { () -> Bool in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // -i: interactive marquee selection (drag crosshairs to select rect)
            // -x: silent (no camera shutter sound)
            process.arguments = ["-i", "-x", tempURL.path]
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }.value

        // If the user cancelled with Escape, or single-clicked without dragging a box,
        // no valid image was created.
        guard success,
              FileManager.default.fileExists(atPath: tempURL.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: tempURL.path),
              let size = attrs[.size] as? Int64,
              size > 0
        else {
            return nil
        }

        let text = try await ImageOCR.extractText(source: tempURL)

        let result = await ShelfOCRTranslation.process(text)
        await MainActor.run {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(result.text, forType: .string)
        }
        return result
    }
}
