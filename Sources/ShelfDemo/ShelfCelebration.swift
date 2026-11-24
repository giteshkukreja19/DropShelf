import AppKit
import QuartzCore

/// Break the rendered shelf into image tiles, without capturing other apps.
enum ShelfCelebration {
    static func show(around source: NSWindow, close: Bool) {
        guard let content = source.contentView else {
            if close { source.orderOut(nil) }; return
        }
        let bounds = content.bounds
        guard bounds.width > 0, bounds.height > 0,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: bounds) else {
            if close { source.orderOut(nil) }; return
        }
        content.cacheDisplay(in: bounds, to: bitmap)
        guard let snapshot = bitmap.cgImage else {
            if close { source.orderOut(nil) }; return
        }
        let shelf = source.convertToScreen(content.convert(bounds, to: nil))
        let frame = shelf.insetBy(dx: -160, dy: -160)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: source.level.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        panel.contentView = view
        guard let root = view.layer else {
            if close { source.orderOut(nil) }; return
        }
        let center = CGPoint(x: frame.width / 2, y: frame.height / 2)
        let columns = max(5, min(16, Int(shelf.width / 22)))
        let rows = max(3, min(12, Int(shelf.height / 22)))
        var pieces: [(CALayer, CGPoint)] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for row in 0..<rows {
            for col in 0..<columns {
                let x0 = col * snapshot.width / columns
                let x1 = (col + 1) * snapshot.width / columns
                let y0 = row * snapshot.height / rows
                let y1 = (row + 1) * snapshot.height / rows
                guard let tile = snapshot.cropping(to: CGRect(x: x0, y: y0, width: x1-x0, height: y1-y0)) else { continue }
                let w = shelf.width * CGFloat(x1-x0) / CGFloat(snapshot.width)
                let h = shelf.height * CGFloat(y1-y0) / CGFloat(snapshot.height)
                let start = CGPoint(x: 160 + shelf.width * CGFloat(x0+x1) / (2 * CGFloat(snapshot.width)), y: 160 + shelf.height * (1 - CGFloat(y0+y1) / (2 * CGFloat(snapshot.height))))
                let piece = CALayer()
                piece.contents = tile
                piece.contentsGravity = .resize
                piece.bounds = CGRect(x: 0, y: 0, width: w, height: h)
                piece.position = start
                root.addSublayer(piece)
                pieces.append((piece, start))
            }
        }
        CATransaction.commit()
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        if close { source.orderOut(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
            for (piece, start) in pieces {
                let dx = start.x - center.x
                let dy = start.y - center.y
                let angle = atan2(dy, dx) + CGFloat.random(in: -0.35...0.35)
                let distance = CGFloat.random(in: 45...125)
                let end = CGPoint(x: start.x + cos(angle)*distance, y: start.y + sin(angle)*distance - 18)
                let move = CAKeyframeAnimation(keyPath: "position")
                move.values = [NSValue(point: start), NSValue(point: CGPoint(x: center.x + dx*0.92, y: center.y + dy*0.92)), NSValue(point: end)]
                move.keyTimes = [0, 0.13, 1]
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = CGFloat.random(in: -1.8...1.8)
                let shrink = CABasicAnimation(keyPath: "transform.scale")
                shrink.fromValue = 1
                shrink.toValue = 0.25
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [1, 1, 0]
                fade.keyTimes = [0, 0.22, 1]
                for animation in [move, spin, shrink, fade] { animation.duration = 0.55 }
                let group = CAAnimationGroup()
                group.animations = [move, spin, shrink, fade]
                group.duration = 0.55
                group.timingFunction = CAMediaTimingFunction(name: .easeOut)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                piece.opacity = 0
                piece.add(group, forKey: "shatter")
                CATransaction.commit()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { panel.orderOut(nil) }
    }
}
