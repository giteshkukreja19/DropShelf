import Foundation

/// Screen-relative placement, using AppKit's bottom-left coordinate system.
enum ShelfScreenPosition: String, CaseIterable {
    case topLeft = "Top left", topCenter = "Top center", topRight = "Top right"
    case centerLeft = "Center left", center = "Center", centerRight = "Center right"
    case bottomLeft = "Bottom left", bottomCenter = "Bottom center", bottomRight = "Bottom right"

    func origin(for size: CGSize, in screen: CGRect, avoiding occupied: [CGRect] = [], margin: CGFloat = 12) -> CGPoint {
        let left = screen.minX + margin
        let right = max(left, screen.maxX - size.width - margin)
        let bottom = screen.minY + margin
        let top = max(bottom, screen.maxY - size.height - margin)
        let middleX = (left + right) / 2, middleY = (bottom + top) / 2
        let x: CGFloat, y: CGFloat
        switch self {
        case .topLeft, .centerLeft, .bottomLeft: x = left
        case .topRight, .centerRight, .bottomRight: x = right
        default: x = middleX
        }
        switch self {
        case .topLeft, .topCenter, .topRight: y = top
        case .bottomLeft, .bottomCenter, .bottomRight: y = bottom
        default: y = middleY
        }
        let preferred = CGPoint(x: x, y: y)
        // Try nearby free slots before overlapping another shelf. No existing
        // window is moved to make room for the new one.
        var candidates = [preferred]
        let stepX = max(1, size.width + margin), stepY = max(1, size.height + margin)
        for row in -4...4 {
            for column in -4...4 where row != 0 || column != 0 {
                let point = CGPoint(x: x + CGFloat(column) * stepX, y: y + CGFloat(row) * stepY)
                if point.x >= left, point.x <= right, point.y >= bottom, point.y <= top { candidates.append(point) }
            }
        }
        candidates.sort { hypot($0.x - x, $0.y - y) < hypot($1.x - x, $1.y - y) }
        return candidates.first { point in
            !occupied.contains { $0.insetBy(dx: -margin / 2, dy: -margin / 2).intersects(CGRect(origin: point, size: size)) }
        } ?? preferred
    }

    static func progress(_ value: Double) -> CGFloat {
        let t = min(1, max(0, value))
        // Quintic smoothstep: zero velocity and acceleration at both ends.
        return CGFloat(t * t * t * (10 + t * (-15 + 6 * t)))
    }
}

/// One preference owns expanded-window dimensions. A user-resized fixed
/// window stores points, not a file-count-dependent percentage.
enum ShelfExpandedGeometry {
    static let dimensionsKey = "shelf.fixedExpandedDimensions"

    static func encode(_ size: CGSize) -> String {
        "\(Int(size.width.rounded())),\(Int(size.height.rounded()))"
    }

    static func decode(_ value: String) -> CGSize? {
        let parts = value.split(separator: ",")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]),
              w.isFinite, h.isFinite, (340...4000).contains(w), (280...4000).contains(h) else { return nil }
        return CGSize(width: w, height: h)
    }

    static func fit(_ size: CGSize, within visible: CGSize, margin: CGFloat = 8) -> CGSize {
        CGSize(width: min(size.width, max(1, visible.width - margin * 2)),
               height: min(size.height, max(1, visible.height - margin * 2)))
    }

    static func preferred(percent: Int, fixed: Bool, custom: String, visible: CGSize) -> CGSize {
        let scale = CGFloat(min(150, max(70, percent))) / 100
        let preset = CGSize(width: 520 * scale, height: 560 * scale)
        let compactPreset = CGSize(width: 420 * scale, height: max(280, 284 * scale))
        return fit(fixed ? (decode(custom) ?? compactPreset) : preset, within: visible)
    }

    static func adaptiveWidth(maximum: CGFloat, count: Int, isList: Bool) -> CGFloat {
        guard !isList, count <= 2 else { return maximum }
        return min(maximum, max(340, maximum * 420 / 520))
    }

    // Match the v1.7.0 one-row height while keeping the tile's full
    // 100-point preview and 8-point padding on each side.
    static let tileWidth: CGFloat = 116
    static let columnSpacing: CGFloat = 12
    static let rowSpacing: CGFloat = 18

    static func columns(contentWidth: CGFloat, count: Int) -> Int {
        let capacity = max(1, Int((max(0, contentWidth) + columnSpacing) / (tileWidth + columnSpacing)))
        return max(1, min(max(1, count), capacity))
    }

    static func adaptiveHeight(width: CGFloat, count: Int, isList: Bool, maximum: CGFloat) -> CGFloat {
        let items = max(1, count)
        let cols = columns(contentWidth: width - 20, count: items)
        let rows = (items + cols - 1) / cols
        let content = isList ? CGFloat(items) * 30 : CGFloat(rows) * 154 + CGFloat(rows - 1) * rowSpacing
        return min(maximum, max(280, 130 + content))
    }

    static func clampedFrame(_ frame: CGRect, in visible: CGRect) -> CGRect {
        let size = fit(frame.size, within: visible.size)
        return CGRect(x: max(visible.minX + 8, min(frame.minX, visible.maxX - size.width - 8)),
                      y: max(visible.minY + 8, min(frame.minY, visible.maxY - size.height - 8)),
                      width: size.width, height: size.height)
    }
}

/// Center the toolbar under its shelf, keeping the hover target stable when expanding.
enum ShelfInstantGeometry {
    static func width(expanded: Bool, hasImages: Bool) -> CGFloat {
        expanded ? (hasImages ? 190 : 168) : 42
    }
    static func frame(shelf: CGRect, screen: CGRect, width: CGFloat, hasImages: Bool) -> CGRect {
        let w = min(width, screen.width)
        let full = min(Self.width(expanded: true, hasImages: hasImages), screen.width)
        let center = max(screen.minX + full / 2, min(shelf.midX, screen.maxX - full / 2))
        let x = max(screen.minX, min(center - w / 2, screen.maxX - w))
        let below = shelf.minY - 50
        let y = below >= screen.minY ? below : max(screen.minY, min(shelf.maxY + 8, screen.maxY - 42))
        return CGRect(x: x, y: y, width: w, height: 42)
    }
}
