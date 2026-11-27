
import AppKit
import SwiftUI

struct ShelfToolRequest: Identifiable {
    let id = UUID()
    let shelfID: UUID
    let action: SmartFileActions.Action
    let urls: [URL]
    let preset: ShelfCustomAction?
}

extension Notification.Name {
    static let shelfToolRequested =
        Notification.Name("DropShelf.ToolRequested")
    static let shelfToolBackRequested = Notification.Name("DropShelf.ToolBackRequested")
}

@MainActor
enum ShelfToolRouter {
    static var activeShelves = Set<UUID>()

    static func open(
        action: SmartFileActions.Action,
        urls: [URL],
        shelfID: UUID, preset: ShelfCustomAction? = nil
    ) {
        guard !urls.isEmpty else { return }
        let request = ShelfToolRequest(
            shelfID: shelfID,
            action: action,
            urls: urls, preset: preset
        )

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .shelfToolRequested,
                object: request
            )
        }
    }
}

final class ShelfWindowReference {
    weak var window: NSWindow?
}

struct ShelfWindowReader: NSViewRepresentable {
    let update: (NSWindow?) -> Void

    final class ReaderView: NSView {
        var callback: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            DispatchQueue.main.async {
                self.callback?(window)
            }
        }
    }

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.callback = update
        return view
    }

    func updateNSView(
        _ nsView: ReaderView,
        context: Context
    ) {
        nsView.callback = update
    }
}

struct ShelfGlassButton: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 17)
            .padding(.vertical, 9)
            .foregroundStyle(
                prominent ? Color.white : Color.primary
            )
            .background {
                Capsule().fill(
                    prominent
                    ? Color.accentColor
                    : Color.primary.opacity(0.09)
                )
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
