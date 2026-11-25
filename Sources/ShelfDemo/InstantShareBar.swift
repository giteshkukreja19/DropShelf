import AppKit
import SwiftUI

// A separate transparent panel avoids the shelf's rounded clipping mask.
private final class InstantActionsState: ObservableObject {
    @Published var expanded = false
    var values: () -> [Any] = { [] }
}

private struct InstantShareBar: View {
    @ObservedObject var state: InstantActionsState
    var body: some View {
        HStack(spacing: 8) {
            if state.expanded {
                InstantShareButton(name: "AirDrop", symbol: "wave.3.right", values: state.values)
                InstantShareButton(name: "Messages", symbol: "message", values: state.values)
                InstantShareButton(name: "Mail", symbol: "envelope", values: state.values)
                InstantShareButton(name: "WhatsApp", symbol: "phone.bubble.left", values: state.values)
            } else {
                Image(systemName: "bolt.fill")
                    .frame(width: 34, height: 34)
                    .background(.regularMaterial, in: Circle())
                    .onHover { if $0 { state.expanded = true } }
            }
        }
        .frame(width: 168, height: 42)
        .animation(.easeInOut(duration: 0.15), value: state.expanded)
    }
}

struct InstantActionsAnchor: NSViewRepresentable {
    var enabled: Bool
    var values: () -> [Any]
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.anchor = view
        context.coordinator.enabled = enabled
        context.coordinator.setValues(values)
        context.coordinator.start()
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.setValues(values)
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }
    @MainActor final class Coordinator {
        weak var anchor: NSView?
        var enabled = false
        private let state = InstantActionsState()
        private var timer: Timer?
        private var panel: NSPanel?
        private var lastNear = Date.distantPast
        func setValues(_ values: @escaping () -> [Any]) { state.values = values }
        func start() {
            let t = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer = t
            RunLoop.main.add(t, forMode: .common)
            RunLoop.main.add(t, forMode: .eventTracking)
        }
        func stop() {
            timer?.invalidate(); timer = nil
            hide(); panel = nil
        }
        private func hide() {
            panel?.orderOut(nil)
            if state.expanded { state.expanded = false }
        }
        private func tick() {
            guard enabled, let source = anchor?.window, source.isVisible, !source.isMiniaturized else { hide(); return }
            let shelf = source.frame
            let screen = source.screen?.visibleFrame ?? shelf
            let x = max(screen.minX, min(shelf.midX - 84, screen.maxX - 168))
            let below = shelf.minY - 50
            // Flip above the shelf only when there is no usable space below.
            let y = below >= screen.minY ? below : min(shelf.maxY + 8, screen.maxY - 42)
            let frame = NSRect(x: x, y: y, width: 168, height: 42)
            let mouse = NSEvent.mouseLocation
            let near = shelf.union(frame).insetBy(dx: -22, dy: -22).contains(mouse)
            if near { lastNear = Date() }
            guard near || Date().timeIntervalSince(lastNear) < 0.35 else { hide(); return }
            if panel == nil {
                let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
                p.isReleasedWhenClosed = false; p.hidesOnDeactivate = false
                p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                p.contentView = NSHostingView(rootView: InstantShareBar(state: state))
                panel = p
            }
            guard let panel else { return }
            panel.level = source.level
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            if !panel.isVisible { panel.orderFrontRegardless() }
            let trigger = NSRect(x: frame.midX - 25, y: frame.midY - 25, width: 50, height: 50)
            if trigger.contains(mouse) && !state.expanded { state.expanded = true }
        }
    }
}

private struct InstantShareButton: View {
    let name: String
    let symbol: String
    let values: () -> [Any]
    @State private var targeted = false
    var body: some View {
        Button {
            _ = ShareCoordinator.shared.performInstant(name, values: values())
        } label: {
            Image(systemName: symbol)
            .frame(width: 34, height: 34)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().strokeBorder(targeted ? Color.accentColor : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
            .overlay(ShelfDropTarget(isTargeted: $targeted, allowDrop: { true }, preferredOperation: .copy, onDrop: perform))
            .help(name)
            .accessibilityLabel(name)
    }
    private func perform(_ pb: NSPasteboard) -> Bool {
        var values: [Any] = []
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            values = urls
        } else if let links = WebDragLinks.read(pb).first {
            values = [links]
        } else if let text = pb.string(forType: .string), !text.isEmpty {
            values = [text]
        } else { return false }
        return ShareCoordinator.shared.performInstant(name, values: values)
    }
}
