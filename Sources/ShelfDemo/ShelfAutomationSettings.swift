import AppKit
import SwiftUI

// Paths are explicitly selected by the user. No recursive monitoring or
// deletion, and no existing files are collected on first observation.
struct ShelfFolderRule: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var path: String
    var enabled = true
    var filter = "All files"
    var newShelf = false
    var recursive = false
    var delayProcessing = false
    var nameContains = ""
    init(path: String) { self.path = path }
    private enum CodingKeys: String, CodingKey { case id, path, enabled, filter, newShelf, recursive, delayProcessing, nameContains }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        filter = try c.decodeIfPresent(String.self, forKey: .filter) ?? "All files"
        newShelf = try c.decodeIfPresent(Bool.self, forKey: .newShelf) ?? false
        recursive = try c.decodeIfPresent(Bool.self, forKey: .recursive) ?? false
        delayProcessing = try c.decodeIfPresent(Bool.self, forKey: .delayProcessing) ?? false
        nameContains = try c.decodeIfPresent(String.self, forKey: .nameContains) ?? ""
    }
}
struct ShelfFavourite: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
}
enum ShelfAutomationPreferences {
    static let rulesKey = "shelf.monitor.rules.v1"
    static let favouritesKey = "shelf.favourites.v1"
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) -> [T] {
        (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }
    static func rules() -> [ShelfFolderRule] { decode(ShelfFolderRule.self, UserDefaults.standard.data(forKey: rulesKey) ?? Data()) }
    static func favourites() -> [ShelfFavourite] { decode(ShelfFavourite.self, UserDefaults.standard.data(forKey: favouritesKey) ?? Data()) }
}

struct ShelfSmallButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(configuration.isPressed ? 0.17 : 0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ShelfSettingsInfo: View {
    let message: String
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More information")
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            Text(message).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading).padding(16)
        }
    }
}

struct ShelfAutomationSettings: View {
    let monitoring: Bool
    @AppStorage(ShelfAutomationPreferences.rulesKey) private var ruleData = Data()
    @AppStorage(ShelfAutomationPreferences.favouritesKey) private var favouriteData = Data()
    @State private var choosing = false
    @AppStorage("shelf.monitor.status") private var monitorStatus = "Waiting for first scan…"
    private var rules: [ShelfFolderRule] { ShelfAutomationPreferences.decode(ShelfFolderRule.self, ruleData) }
    private var favourites: [ShelfFavourite] { ShelfAutomationPreferences.decode(ShelfFavourite.self, favouriteData) }
    private func update(_ rule: ShelfFolderRule) {
        var rows = rules
        if let index = rows.firstIndex(where: { $0.id == rule.id }) { rows[index] = rule }
        if let data = try? JSONEncoder().encode(rows) { ruleData = data }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if monitoring {
                ForEach(rules) { rule in
                    MonitorFolderRow(rule: rule, update: update, remove: {
                        if let data = try? JSONEncoder().encode(rules.filter { $0.id != rule.id }) { ruleData = data }
                    })
                }
                if rules.isEmpty { Text("Add a folder to begin monitoring.").foregroundStyle(.secondary) }
            } else {
                Text("Saved destinations appear in Copy to and Move to. Files are never overwritten.").font(.caption).foregroundStyle(.secondary)
                ForEach(favourites) { favourite in
                    HStack {
                        Image(systemName: "folder")
                        VStack(alignment: .leading) { Text(URL(fileURLWithPath: favourite.path).lastPathComponent); Text(favourite.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                        Spacer()
                        Button { if let data = try? JSONEncoder().encode(favourites.filter { $0.id != favourite.id }) { favouriteData = data } } label: { Image(systemName: "trash") }.buttonStyle(ShelfSmallButton()).accessibilityLabel("Remove favourite")
                    }
                    Divider()
                }
            }
            HStack { Spacer(); Button(monitoring ? "Add Folder…" : "Add Favourite…") { choose() }.buttonStyle(ShelfSmallButton()).disabled(choosing) }
        }
    }
    private func choose() {
        choosing = true
        ShelfFolderPicker.choose(owner: NSApp.keyWindow, initial: nil) { url in
            choosing = false
            guard let url else { return }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            if monitoring {
                guard !rules.contains(where: { $0.path == path }) else { return }
                if let data = try? JSONEncoder().encode(rules + [ShelfFolderRule(path: path)]) { ruleData = data }
            } else {
                guard !favourites.contains(where: { $0.path == path }) else { return }
                if let data = try? JSONEncoder().encode(favourites + [ShelfFavourite(path: path)]) { favouriteData = data }
            }
        }
    }
}

struct ShelfSettingsCommand {
    let title: String
    var enabled: Bool = true
    let perform: () -> Void
}

@MainActor
private final class ShelfSettingsCommandTarget: NSObject {
    let perform: () -> Void
    init(_ perform: @escaping () -> Void) { self.perform = perform }
    @objc func invoke() { DispatchQueue.main.async { self.perform() } }
}

struct ShelfSettingsActionMenu: View {
    let title: String
    let commands: [ShelfSettingsCommand]
    var body: some View {
        Button {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for command in commands {
                let target = ShelfSettingsCommandTarget(command.perform)
                let item = NSMenuItem(title: command.title, action: #selector(ShelfSettingsCommandTarget.invoke), keyEquivalent: "")
                item.target = target
                item.representedObject = target
                item.isEnabled = command.enabled
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        } label: {
            HStack(spacing: 7) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
        }.buttonStyle(ShelfSmallButton()).fixedSize()
    }
}

@MainActor
enum ShelfFavouriteMenu {
    static func make(title: String, symbol: String, target: AnyObject, selector: Selector, direct: Selector, enabled: Bool) -> NSMenuItem {
        let favourites = ShelfAutomationPreferences.favourites()
        let item = NSMenuItem(title: title, action: direct, keyEquivalent: "")
        item.target = target; item.isEnabled = enabled
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        guard !favourites.isEmpty, enabled else { return item }
        item.action = nil
        let menu = NSMenu()
        for favourite in favourites {
            let url = URL(fileURLWithPath: favourite.path, isDirectory: true)
            let row = NSMenuItem(title: url.lastPathComponent, action: selector, keyEquivalent: "")
            row.target = target; row.representedObject = url; row.toolTip = url.path
            menu.addItem(row)
        }
        menu.addItem(.separator())
        let choose = NSMenuItem(title: "Choose Folder…", action: direct, keyEquivalent: "")
        choose.target = target; menu.addItem(choose)
        item.submenu = menu
        return item
    }
}

private struct MonitorHelp: View {
    let text: String
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: { Image(systemName: "info.circle").foregroundStyle(.secondary) }
            .buttonStyle(.plain).accessibilityLabel("More information")
            .popover(isPresented: $open) { Text(text).frame(width: 270, alignment: .leading).padding(16) }
    }
}
private struct MonitorFolderRow: View {
    let rule: ShelfFolderRule
    let update: (ShelfFolderRule) -> Void
    let remove: () -> Void
    @State private var details = false
    @State private var draft: ShelfFolderRule?
    @State private var status = "Starting…"
    private var name: String { URL(fileURLWithPath: rule.path).lastPathComponent }
    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: rule.path)).resizable().frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 5) {
                    Circle().fill(rule.enabled && status == "Monitoring" ? Color.green : Color.red).frame(width: 7,height: 7)
                    Text(rule.enabled ? status : "Stopped").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { draft = rule; details = true } label: { Image(systemName: "info.circle") }.buttonStyle(.plain).accessibilityLabel("Folder options")
            Toggle("Monitoring", isOn: Binding(get: { rule.enabled }, set: { value in var r = rule; r.enabled = value; update(r) })).labelsHidden().toggleStyle(.switch)
        }
        .padding(10)
        .task(id: rule) {
            while !Task.isCancelled {
                status = UserDefaults.standard.string(forKey: "shelf.monitor.status." + rule.id.uuidString) ?? "Starting…"
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        .sheet(isPresented: $details) {
            if let initial = draft { MonitorFolderDetails(rule: initial, save: { update($0); details = false }, remove: { details = false; remove() }, cancel: { details = false }) }
        }
    }
}
private struct MonitorFolderDetails: View {
    @State var rule: ShelfFolderRule
    let save: (ShelfFolderRule) -> Void
    let remove: () -> Void
    let cancel: () -> Void
    @State private var confirm = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(URL(fileURLWithPath: rule.path).lastPathComponent).font(.headline); Spacer(); Toggle("Monitoring", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch) }
            HStack { Image(systemName: "folder.fill").foregroundStyle(.blue); Text(rule.path).lineLimit(1).truncationMode(.middle); Spacer(); Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rule.path)]) } label: { Image(systemName: "arrow.right.circle.fill") }.buttonStyle(.plain) }
            Divider()
            Text("Options").font(.headline)
            option("Include nested subfolders", $rule.recursive, "Monitor newly added files in nested folders as well.")
            option("Create new shelf for each file", $rule.newShelf, "Place each newly detected file in a separate shelf.")
            option("Delay processing", $rule.delayProcessing, "Wait at least 3 seconds after the last stable file is detected before delivering the batch.")
            Divider()
            Text("Folder Rules").font(.headline)
            Picker("File types", selection: $rule.filter) { ForEach(["All files", "Images", "PDFs", "Documents"], id: \.self) { Text($0).tag($0) } }
            HStack { TextField("Filename contains (optional)", text: $rule.nameContains); MonitorHelp(text: "Only collect files whose names contain this text. Leave empty to accept all names matching the file type.") }
            Divider()
            HStack { Button("Delete", role: .destructive) { confirm = true }; Spacer(); Button("Cancel", action: cancel); Button("Done") { save(rule) }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 480)
        .confirmationDialog("Stop monitoring this folder? Your files will not be deleted.", isPresented: $confirm) { Button("Remove folder", role: .destructive, action: remove); Button("Cancel", role: .cancel) {} }
    }
    private func option(_ title: String, _ value: Binding<Bool>, _ help: String) -> some View {
        HStack { Text(title); Spacer(); Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch); MonitorHelp(text: help) }
    }
}
