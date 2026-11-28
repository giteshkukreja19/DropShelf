import AppKit
import SwiftUI

enum ShelfShortcut: String, CaseIterable, Identifiable {
    case new, clipboard, capture, recordingControls, stopRecording, pauseRecording, keyboardCleaning
    var id: String { rawValue }
    static var recording = false
    static let mask: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
    var title: String {
        switch self { case .new: return "New Shelf"; case .clipboard: return "Clipboard Shelf"; case .capture: return "Capture Screen Text"; case .recordingControls: return "Open Capture Studio"; case .stopRecording: return "Stop Screen Recording"; case .pauseRecording: return "Pause / Resume Recording"; case .keyboardCleaning: return "Keyboard Cleaning" }
    }
    var defaultKey: String { switch self { case .new: return "n"; case .clipboard: return "a"; case .capture: return "c"; case .recordingControls: return "r"; case .stopRecording: return "s"; case .pauseRecording: return "p"; case .keyboardCleaning: return "k" } }
    var prefix: String { "shortcut." + rawValue }
    var enabled: Bool {
        if self == .keyboardCleaning && !KeyboardCleaningController.enabled { return false }
        return UserDefaults.standard.object(forKey: prefix + ".enabled") as? Bool ?? true
    }
    var key: String { UserDefaults.standard.string(forKey: prefix + ".key") ?? defaultKey }
    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: UInt(UserDefaults.standard.object(forKey: prefix + ".flags") as? Int ?? Int((self == .recordingControls || self == .stopRecording || self == .pauseRecording ? NSEvent.ModifierFlags([.command, .option, .shift]) : NSEvent.ModifierFlags([.option, .shift])).rawValue))) }
    var label: String { (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + key.uppercased() }
    func matches(_ event: NSEvent) -> Bool { enabled && event.modifierFlags.intersection(Self.mask) == flags && event.charactersIgnoringModifiers?.lowercased() == key }
    func configure(_ item: NSMenuItem) { item.keyEquivalent = enabled ? key : ""; item.keyEquivalentModifierMask = flags }
}

struct ShelfShortcutSettings: View {
    @Environment(\.dismiss) private var dismiss
    @State private var revision = 0
    @State private var active: ShelfShortcut?
    @State private var monitor: Any?
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard Shortcuts").font(.title2.bold())
            Text("Click a shortcut and press a new combination. Escape cancels.").foregroundStyle(.secondary)
            ForEach(ShelfShortcut.allCases.filter { $0 != .keyboardCleaning || KeyboardCleaningController.enabled }) { shortcut in
                HStack {
                    Toggle(shortcut.title, isOn: Binding(get: { shortcut.enabled }, set: { value in
                        UserDefaults.standard.set(value, forKey: shortcut.prefix + ".enabled"); revision += 1
                    }))
                    Spacer()
                    Button(active == shortcut ? "Press shortcut…" : shortcut.label) { record(shortcut) }
                }
            }.id(revision)
            Text(message).foregroundStyle(.secondary)
            HStack {
                Button("Restore Defaults") {
                    stop()
                    for shortcut in ShelfShortcut.allCases { for suffix in [".key", ".flags", ".enabled"] { UserDefaults.standard.removeObject(forKey: shortcut.prefix + suffix) } }
                    revision += 1; message = ""
                }
                Spacer()
                Button("Done") { stop(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 510).onDisappear { stop() }
    }
    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; active = nil; ShelfShortcut.recording = false
    }
    private func record(_ shortcut: ShelfShortcut) {
        stop(); active = shortcut; ShelfShortcut.recording = true; message = ""
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            let flags = event.modifierFlags.intersection(ShelfShortcut.mask)
            guard !flags.intersection([.command,.control,.option]).isEmpty, let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1, key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else { message = "Use a modifier and a letter or number."; return nil }
            guard !ShelfShortcut.allCases.contains(where: { $0 != shortcut && $0.key == key && $0.flags == flags }), !(flags == .command && ["q","w","a","v","c","x"].contains(key)) else { message = "That shortcut is already reserved."; return nil }
            UserDefaults.standard.set(key, forKey: shortcut.prefix + ".key")
            UserDefaults.standard.set(Int(flags.rawValue), forKey: shortcut.prefix + ".flags")
            stop(); revision += 1; return nil
        }
    }
}
