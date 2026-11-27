import AppKit
import SwiftUI

@MainActor
enum ShelfActionPreferences {
    static let groups: [(String, [String])] = [
        ("General Actions", ["Get Info", "Rename…", "Batch Rename…", "Create ZIP Archive…", "Copy Path", "Copy to…", "Move to…", "Move to Trash", "Duplicate"]),
        ("Image Actions", ["Resize Images…", "Convert Image Format…", "Compress Images…", "Remove Image Metadata", "Stitch Images…", "Create PDF…"]),
        ("Document Actions", ["Merge PDFs…", "Split PDF into Pages…", "Extract / Reorder PDF Pages…", "Delete PDF Pages…", "Compress PDF…", "Password Protect PDF…", "Convert PDF to Word (.docx)…", "Convert Word to PDF…", "Create Combined PDF…", "Merge Word Documents…", "Rotate PDF Pages 90°…", "Extract PDF Text…", "Extract Word Text…"])
    ]
    static func key(_ name: String) -> String { "shelf.actionPlacement." + name }
    static func defaultValue(_ name: String) -> String {
        ["Copy to…", "Move to…"].contains(name) ? "main" : "sub"
    }
    static func value(_ name: String) -> String { UserDefaults.standard.string(forKey: key(name)) ?? defaultValue(name) }
    static func apply(to menu: NSMenu, submenu entry: NSMenuItem) {
        guard let sub = entry.submenu else { return }
        for (_, names) in groups {
            for name in names {
                let matches = { (item: NSMenuItem) in
                    if let raw = item.representedObject as? String, UUID(uuidString: raw) != nil { return false }
                    return item.title == name || item.title == L(name)
                }
                let rootItems = menu.items.filter(matches)
                let subItems = sub.items.filter(matches)
                for item in rootItems + subItems {
                    let placement = value(name)
                    if placement == "hidden" { item.menu?.removeItem(item) }
                    else if placement == "main", item.menu === sub {
                        sub.removeItem(item)
                        menu.insertItem(item, at: menu.items.firstIndex(of: entry) ?? menu.items.count)
                    } else if placement == "sub", item.menu === menu {
                        menu.removeItem(item); sub.addItem(item)
                    }
                }
            }
        }
        for target in [menu, sub] {
            for item in target.items.reversed() where item.isSeparatorItem {
                guard let index = target.items.firstIndex(of: item) else { continue }
                if index == 0 || index == target.items.count - 1 || target.items[index + 1].isSeparatorItem { target.removeItem(item) }
            }
        }
    }
}

struct ShelfActionPreferencesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var revision = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Customize Action Menu").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(ShelfActionPreferences.groups.indices, id: \.self) { index in
                        let group = ShelfActionPreferences.groups[index]
                        Text(group.0).font(.headline)
                        VStack(spacing: 0) {
                            ForEach(group.1, id: \.self) { name in
                                HStack {
                                    Text(name); Spacer()
                                    ModernSettingsMenu(title: name, selection: Binding(get: { ShelfActionPreferences.value(name) }, set: { UserDefaults.standard.set($0, forKey: ShelfActionPreferences.key(name)); revision += 1 }), options: [("main", "Show in Main Menu"), ("sub", "Show in Submenu"), ("hidden", "Hidden")])
                                }.padding(10)
                                if name != group.1.last { Divider() }
                            }
                        }.background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                }.id(revision == -1 ? 1 : 0)
            }
            HStack {
                Button("Restore Defaults") {
                    for (_, names) in ShelfActionPreferences.groups { for name in names { UserDefaults.standard.removeObject(forKey: ShelfActionPreferences.key(name)) } }
                    revision += 1
                }
                Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 600, height: 560)
    }
}
