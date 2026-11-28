import CoreImage
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// ImageIO-only operations: no NSImage focus, Retina points, or main-thread drawing.
/// Each operation produces a new, verified file and never overwrites its input.
enum ImageActions {
    static func error(_ message: String) -> NSError {
        NSError(domain: "DropShelf.Image", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func orientedSize(of source: CGImageSource) -> ShelfPixelSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return [5, 6, 7, 8].contains(orientation)
            ? ShelfPixelSize(width: height, height: width)
            : ShelfPixelSize(width: width, height: height)
    }

    static func open(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw error("Cannot decode \(url.lastPathComponent).")
        }
        return source
    }

    /// ImageIO applies EXIF orientation while downsampling. Exact pixel sizing
    /// is verified and a final high-quality draw handles rounding/upscaling.
    static func normalizedImage(_ source: CGImageSource, target: ShelfPixelSize) throws -> CGImage {
        guard target.isSafeToRender, let original = orientedSize(of: source) else {
            throw error("Image dimensions are invalid or exceed the 40 megapixel processing limit.")
        }
        let maxPixel = min(max(original.width, original.height), max(target.width, target.height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw error("Image decoder could not render the pixels.")
        }
        if image.width == target.width && image.height == target.height { return image }
        guard let context = CGContext(data: nil, width: target.width, height: target.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw error("Not enough memory to resize this image.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(target.width), height: CGFloat(target.height)))
        guard let result = context.makeImage() else { throw error("Could not render resized image.") }
        return result
    }

    static func fullImage(_ url: URL) throws -> CGImage {
        let source = try open(url)
        guard let size = orientedSize(of: source) else { throw error("Cannot read image dimensions.") }
        return try normalizedImage(source, target: size)
    }

    /// Conservative local sharpening; no invented detail or pixel enlargement.
    static func enhanced(_ image: CGImage, enabled: Bool, strength: Double = 0.45) throws -> CGImage {
        guard enabled, strength > 0 else { return image }
        guard ShelfPixelSize(width: image.width, height: image.height).isSafeToRender else { throw error("Image exceeds enhancement size limit.") }
        let input = CIImage(cgImage: image)
        let result = input.clampedToExtent().applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: max(0, min(1, strength))]).cropped(to: input.extent)
        guard let output = CIContext().createCGImage(result, from: input.extent) else { throw error("Unable to enhance image.") }
        return output
    }

    static func enhance(url: URL, format: String, quality: Double, folder: URL, strength: Double = 0.45) throws -> URL {
        let source = try open(url)
        let type: UTType
        if format == "original" { type = originalFormat(source, url: url) }
        else if let selected = UTType(filenameExtension: format), [.png, .jpeg, .heic, .tiff].contains(selected) { type = selected }
        else { throw error("Unsupported output format.") }
        return try write(try enhanced(fullImage(url), enabled: true, strength: strength), source: url, suffix: " (enhanced)", type: type, folder: folder, properties: encodingProperties(type, quality))
    }

    static func encodingProperties(_ type: UTType, _ quality: Double) -> [CFString: Any]? {
        [.jpeg, .heic].contains(type) ? [kCGImageDestinationLossyCompressionQuality: max(0.1, min(1, quality))] : nil
    }

    private static func originalFormat(_ source: CGImageSource, url: URL) -> UTType {
        guard let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String),
              (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(type.identifier),
              type.preferredFilenameExtension != nil else { return .png }
        return type
    }

    static func resize(url: URL, width: Int, height: Int, allowEnlargement: Bool = false, folder: URL, enhance: Bool = false, quality: Double = 1) throws -> URL {
        let source = try open(url)
        guard let size = orientedSize(of: source),
              let target = size.fitted(maxWidth: width, maxHeight: height, allowEnlargement: allowEnlargement) else {
            throw error("Enter dimensions between 1 and 16000 pixels.")
        }
        let image = try enhanced(normalizedImage(source, target: target), enabled: enhance)
        let type = originalFormat(source, url: url)
        return try write(image, source: url, suffix: " (resized)", type: type, folder: folder, properties: encodingProperties(type, quality))
    }

    static func convert(url: URL, format: String, folder: URL, quality: Double = 1, enhance: Bool = false) throws -> URL {
        guard let type = UTType(filenameExtension: format), [.png, .jpeg, .heic, .tiff].contains(type) else {
            throw error("Unsupported output format.")
        }
        return try write(enhanced(fullImage(url), enabled: enhance), source: url, suffix: " (converted)", type: type, folder: folder, properties: [.jpeg, .heic].contains(type) ? [kCGImageDestinationLossyCompressionQuality: max(0.1, min(1, quality))] : nil)
    }

    static func compress(url: URL, quality: Double, folder: URL, enhance: Bool = false) throws -> URL {
        guard quality.isFinite, (0.1...1).contains(quality) else { throw error("Invalid JPEG quality.") }
        let image = try enhanced(fullImage(url), enabled: enhance)
        return try write(image, source: url, suffix: " (compressed)", type: .jpeg, folder: folder,
                         properties: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    static func removeMetadata(url: URL, folder: URL) throws -> URL {
        let source = try open(url)
        guard let size = orientedSize(of: source) else { throw error("Cannot read image dimensions.") }
        let image = try normalizedImage(source, target: size)
        return try write(image, source: url, suffix: " (no metadata)", type: originalFormat(source, url: url), folder: folder)
    }

    static func write(_ image: CGImage, source: URL, suffix: String, type: UTType,
                              folder: URL, properties: [CFString: Any]? = nil) throws -> URL {
        let ext = type.preferredFilenameExtension ?? "png"
        let preferred = folder.appendingPathComponent(source.deletingPathExtension().lastPathComponent + suffix).appendingPathExtension(ext)
        let final = UniqueDestination.url(preferred: preferred)
        let temporary = ShelfWritableStorage.temporarySibling(of: final)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let encoder = CGImageDestinationCreateWithURL(temporary as CFURL, type.identifier as CFString, 1, nil) else {
            throw error("Cannot create the image encoder. Check the output folder and format.")
        }
        let encoded: CGImage
        if type == .jpeg, let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            let rect = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(rect); ctx.draw(image, in: rect)
            guard let flattened = ctx.makeImage() else { throw error("Cannot render JPEG output.") }; encoded = flattened
        } else { encoded = image }
        CGImageDestinationAddImage(encoder, encoded, properties as CFDictionary?)
        guard CGImageDestinationFinalize(encoder) else { throw error("The image encoder could not save the file.") }
        guard let verification = CGImageSourceCreateWithURL(temporary as CFURL, nil),
              let pixels = orientedSize(of: verification), pixels.width == image.width, pixels.height == image.height else {
            throw error("The generated file did not pass pixel-size verification.")
        }
        try FileManager.default.moveItem(at: temporary, to: final)
        return final
    }
}
