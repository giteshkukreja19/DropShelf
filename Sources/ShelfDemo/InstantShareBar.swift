import AppKit
import SwiftUI

// Preferences are scoped to file type. Mixed selections use General sharing.
enum InstantActionCategory: String, CaseIterable {
    case general = "General", pdf = "PDF", image = "Images"
    var actions: [InstantActionKind] {
        switch self {
        case .general: return [.airDrop, .messages, .mail, .whatsApp]
        case .pdf: return [.airDrop, .messages, .mail, .whatsApp, .compressPDF, .mergePDF]
        case .image: return [.airDrop, .messages, .mail, .whatsApp, .enhance]
        }
    }
}
enum InstantActionKind: String, Hashable {
    case airDrop = "AirDrop", messages = "Messages", mail = "Mail", whatsApp = "WhatsApp"
    case compressPDF = "Compress PDF", mergePDF = "Merge PDFs", enhance = "Enhance Image Quality"
    var symbol: String {
        switch self {
        case .airDrop: return "wave.3.right"
        case .messages: return "message"
        case .mail: return "envelope"
        case .whatsApp: return "phone.bubble.left"
        case .compressPDF: return "arrow.down.right.and.arrow.up.left"
        case .mergePDF: return "doc.on.doc"
        case .enhance: return "wand.and.stars"
        }
    }
    var defaultEnabled: Bool { self != .compressPDF && self != .mergePDF }
    func key(_ category: InstantActionCategory) -> String { "shelf.instantAction.\(category.rawValue).\(rawValue)" }
}
enum InstantActionSelection {
    static let maximum = 4
    static func selected(_ category: InstantActionCategory, defaults: UserDefaults = .standard) -> [InstantActionKind] {
        Array(category.actions.filter { defaults.object(forKey: $0.key(category)) as? Bool ?? $0.defaultEnabled }.prefix(maximum))
    }
    static func save(_ selected: Set<InstantActionKind>, category: InstantActionCategory, defaults: UserDefaults = .standard) {
        let allowed = Set(category.actions.filter { selected.contains($0) }.prefix(maximum))
        for action in category.actions { defaults.set(allowed.contains(action), forKey: action.key(category)) }
    }
}
struct InstantActionPreferenceGroup: View {
    let category: InstantActionCategory
    @State private var selected: Set<InstantActionKind>
    init(category: InstantActionCategory) {
        self.category = category
        _selected = State(initialValue: Set(InstantActionSelection.selected(category)))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack { Text("Select up to four actions"); Spacer(); Text("\(selected.count)/4 selected") }.font(.caption).foregroundStyle(.secondary)
            ForEach(category.actions, id: \.self) { action in
                HStack {
                    Label(action.rawValue, systemImage: action.symbol)
                    Spacer(minLength: 8)
                    Toggle(action.rawValue, isOn: Binding(get: { selected.contains(action) }, set: { value in
                        if value { if selected.count < InstantActionSelection.maximum { selected.insert(action) } }
                        else { selected.remove(action) }
                        InstantActionSelection.save(selected, category: category)
                    })).labelsHidden().toggleStyle(.switch)
                        .disabled(!selected.contains(action) && selected.count >= InstantActionSelection.maximum)
                }
            }
        }.onAppear {
            selected = Set(InstantActionSelection.selected(category))
            InstantActionSelection.save(selected, category: category)
        }
    }
}

// A separate transparent panel avoids the shelf's rounded clipping mask.
private final class InstantActionsState: ObservableObject {
    @Published var expanded = false
    @Published var actions: [InstantActionKind] = []
    var values: () -> [Any] = { [] }
    var tool: (InstantActionKind) -> Void = { _ in }
}

private struct InstantShareBar: View {
    @ObservedObject var state: InstantActionsState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            if state.expanded {
                HStack(spacing: 8) {
                    ForEach(state.actions, id: \.self) { action in
                        switch action {
                        case .enhance, .compressPDF, .mergePDF:
                            Button { state.tool(action) } label: {
                                Image(systemName: action.symbol).frame(width: 34, height: 34)
                                    .background(.regularMaterial, in: Circle())
                            }.buttonStyle(.plain).help(action.rawValue).accessibilityLabel(action.rawValue)
                        default:
                            InstantShareButton(name: action.rawValue, symbol: action.symbol, values: state.values)
                        }
                    }
                }.transition(.opacity.combined(with: .scale(scale: 0.7)))
            } else {
                Button { state.expanded = true } label: {
                    Image(systemName: "bolt.fill").frame(width: 34, height: 34)
                        .background(.regularMaterial, in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("Instant Actions")
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: state.expanded)
    }
}

struct InstantActionsAnchor: NSViewRepresentable {
    var enabled: Bool
    var values: () -> [Any]
    var tool: (InstantActionKind) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.anchor = view
        context.coordinator.enabled = enabled
        context.coordinator.setValues(values, tool: tool)
        context.coordinator.start()
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.setValues(values, tool: tool)
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
        private var lastFrame: NSRect?
        private var lastMovement = Date.distantPast
        private var needsFreshHover = true
        private var lastMouse: NSPoint?
        private var lastBarHover = Date.distantPast
        func setValues(_ values: @escaping () -> [Any], tool: @escaping (InstantActionKind) -> Void) { state.values = values; state.tool = tool }
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
            guard enabled, let source = anchor?.window, source.isVisible, !source.isMiniaturized else {
                hide(); lastFrame = nil; lastNear = .distantPast
                needsFreshHover = true; lastMouse = nil
                return
            }
            let shelf = source.frame
            let mouse = NSEvent.mouseLocation
            let movedMouse = lastMouse.map { hypot(mouse.x - $0.x, mouse.y - $0.y) > 0.5 } ?? false
            lastMouse = mouse
            if let old = lastFrame, old != shelf {
                lastFrame = shelf
                lastMovement = Date()
                lastNear = .distantPast
                needsFreshHover = true
                hide()
                return
            }
            lastFrame = shelf
            guard Date().timeIntervalSince(lastMovement) >= 0.25 else { hide(); return }
            guard let screen = source.screen?.visibleFrame else { hide(); return }
            let values = state.values()
            let urls = values.compactMap { $0 as? URL }.filter { $0.isFileURL }
            let allFiles = !urls.isEmpty && urls.count == values.count
            let category: InstantActionCategory = allFiles && urls.allSatisfy(SmartFileActions.image) ? .image : allFiles && urls.allSatisfy(SmartFileActions.pdf) ? .pdf : .general
            let actions = InstantActionSelection.selected(category).filter { action in
                if action == .compressPDF { return urls.count == 1 }
                if action == .mergePDF { return urls.count > 1 }
                return true
            }
            guard !actions.isEmpty else { hide(); needsFreshHover = true; return }
            if state.actions != actions { state.actions = actions }
            let width = CGFloat(max(42, actions.count * 42))
            let x = max(screen.minX, min(shelf.midX - width / 2, screen.maxX - width))
            let below = shelf.minY - 50
            let y = below >= screen.minY ? below : min(shelf.maxY + 8, screen.maxY - 42)
            let frame = NSRect(x: x, y: y, width: width, height: 42)
            let trigger = NSRect(x: frame.midX - 21, y: frame.minY, width: 42, height: 42)
            let overShelf = shelf.insetBy(dx: -6, dy: -6).contains(mouse)
            let hitFrame = state.expanded ? frame : trigger
            let overBar = panel?.isVisible == true && hitFrame.insetBy(dx: -8, dy: -8).contains(mouse)
            if overBar { lastBarHover = Date() }
            if state.expanded && !overBar && Date().timeIntervalSince(lastBarHover) >= 0.20 { state.expanded = false }
            if needsFreshHover {
                guard overShelf && movedMouse else { hide(); return }
                needsFreshHover = false
            }
            if overShelf || overBar { lastNear = Date() }
            guard overShelf || overBar || Date().timeIntervalSince(lastNear) < (state.expanded ? 0.40 : 0.36) else {
                hide(); needsFreshHover = true; return
            }
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
            panel.ignoresMouseEvents = !(state.expanded ? frame : trigger).contains(mouse)
            if trigger.contains(mouse) && !state.expanded { lastBarHover = Date(); state.expanded = true }
        }
    }
}

private struct InstantShareButton: View {
    let name: String
    let symbol: String
    let values: () -> [Any]
    @State private var targeted = false
    @AppStorage("shelf.emailProvider") private var emailProvider = "Gmail"
    @AppStorage("shelf.smartAttach") private var smartAttach = false
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
            .help(name == "Mail" && emailProvider == "Gmail" ? (smartAttach ? "Smart Attach in Gmail (experimental)" : "Open Gmail Compose, then drag files from the shelf to attach") : name)
            .accessibilityLabel(name == "Mail" && emailProvider == "Gmail" ? "Open Gmail Compose" : name)
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
