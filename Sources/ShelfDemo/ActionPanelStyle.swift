import AppKit
import SwiftUI

struct ActionPanelHeader: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 19, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(Color.primary.opacity(0.07), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 44)
        .overlay {
            ShelfWindowDragHandle()
        }
    }
}

struct ActionPanelGroup<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ActionPanelFooter: View {
    let title: String
    let busy: Bool
    let valid: Bool
    let close: () -> Void
    let run: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            if busy { ProgressView().controlSize(.small); Text("Processing…").foregroundStyle(.secondary).font(.caption) }
            Spacer()
            Button(action: close) {
                Label("Back", systemImage: "chevron.left")
            }
                .buttonStyle(ShelfGlassButton())
                .keyboardShortcut(.cancelAction).disabled(busy)
            Button("Continue", action: run)
                .buttonStyle(ShelfGlassButton(prominent: true))
                .keyboardShortcut(.defaultAction).disabled(busy || !valid)
        }.controlSize(.large)
    }
}

struct ActionPanelSafety: View {
    var body: some View {
        Label("Original files are preserved", systemImage: "checkmark.shield")
            .font(.subheadline).foregroundStyle(.secondary)
    }
}

struct ActionPanelError: View {
    let message: String
    var body: some View {
        if !message.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                Text(message).font(.caption).foregroundStyle(.primary).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(10).background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        }
    }
}

// Measure the actual intrinsic content, not the scroll viewport. The parent
// window caps the requested height to the screen and leaves scrolling intact.
struct ToolHeightPreference: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
extension View {
    func measureToolHeight(_ part: String) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: ToolHeightPreference.self, value: [part: geometry.size.height])
        })
    }
}


struct ActionOutputPicker: View {
    let label: String
    @Binding var destination: ShelfOutputDestination
    let folder: URL?
    let choose: () -> Void

    var body: some View {
        HStack {
            Text(label); Spacer(minLength: 8)
            ModernSettingsMenu(title: label, selection: $destination,
                options: ShelfOutputDestination.allCases.map { ($0, $0.rawValue) })
        }
        if destination == .folder {
            Divider()
            HStack(spacing: 10) {
                Text(folder?.path ?? "No folder selected")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                Spacer(minLength: 6)
                Button("Choose…", action: choose).buttonStyle(.bordered)
            }
        }
    }
}
