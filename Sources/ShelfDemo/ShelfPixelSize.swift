import Foundation

struct ShelfPixelSize: Equatable {
    let width: Int
    let height: Int

    func fitted(maxWidth: Int, maxHeight: Int, allowEnlargement: Bool = false) -> ShelfPixelSize? {
        guard width > 0, height > 0, (1...16000).contains(maxWidth), (1...16000).contains(maxHeight) else { return nil }
        let scale = min(Double(maxWidth) / Double(width), Double(maxHeight) / Double(height))
        let factor = allowEnlargement ? scale : min(1, scale)
        return ShelfPixelSize(
            width: min(maxWidth, max(1, Int((Double(width) * factor).rounded()))),
            height: min(maxHeight, max(1, Int((Double(height) * factor).rounded())))
        )
    }

    var isSafeToRender: Bool {
        width > 0 && height > 0 && width <= 16000 && height <= 16000 && width <= 40_000_000 / height
    }
}
