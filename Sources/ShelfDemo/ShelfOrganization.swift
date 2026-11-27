import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShelfOrganizationRule: Codable, Equatable, Sendable {
    var action = "Collect only"
    var destination = ""
    var group = "None"
    var prefix = ""
    var extensionFilter = ""
    var minimumMB = 0.0
    var maximumMB = 0.0
    var minimumAgeDays = 0.0
}
struct ShelfOrganizationEvent: Codable, Identifiable, Sendable {
    var id = UUID(); var date = Date(); var source: URL; var output: URL?; var action: String; var message: String
    var bytes: Int?; var modified: Date?; var identity: String?; var undone = false
}
struct ShelfOrganizationResult: Sendable { var urls: [URL] = []; var events: [ShelfOrganizationEvent] = [] }

enum ShelfOrganization {
    static let historyKey = "shelf.organization.history.v1"
    static func category(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased(), type = UTType(filenameExtension: ext)
        if ["dmg","pkg"].contains(ext) { return "Installers" }
        if ["zip","rar","7z","tar","gz"].contains(ext) { return "Archives" }
        if type?.conforms(to: .image) == true { return "Images" }
        if type?.conforms(to: .movie) == true { return "Videos" }
        if type?.conforms(to: .audio) == true { return "Audio" }
        if ["pdf","doc","docx","xls","xlsx","ppt","pptx","txt","rtf","md","csv","pages","numbers","key"].contains(ext) { return "Documents" }
        return "Other"
    }
    static func matches(_ url: URL, _ r: ShelfOrganizationRule) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey,.contentModificationDateKey,.isRegularFileKey,.isSymbolicLinkKey]), v.isRegularFile == true, v.isSymbolicLink != true, let size = v.fileSize else { return false }
        let exts = r.extensionFilter.lowercased().split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        let mb = Double(size)/1_000_000
        return (exts.isEmpty || exts.contains(url.pathExtension.lowercased())) && mb >= r.minimumMB && (r.maximumMB == 0 || mb <= r.maximumMB) && (r.minimumAgeDays == 0 || (v.contentModificationDate.map { Date().timeIntervalSince($0) >= r.minimumAgeDays*86400 } ?? false))
    }
    static func organize(_ urls: [URL], rule: ShelfOrganizationRule, monitors: [ShelfFolderRule]) -> ShelfOrganizationResult {
        if rule.action == "Collect only" { return ShelfOrganizationResult(urls: urls) }
        var result = ShelfOrganizationResult()
        for url in urls {
            if Task.isCancelled { break }
            guard matches(url, rule) else { continue }
            do {
                let out = try process(url, rule, monitors: monitors)
                let v = try out.resourceValues(forKeys: [.fileSizeKey,.contentModificationDateKey,.fileResourceIdentifierKey])
                result.urls.append(out)
                result.events.append(ShelfOrganizationEvent(source: url, output: out, action: rule.action, message: "Completed", bytes: v.fileSize, modified: v.contentModificationDate, identity: v.fileResourceIdentifier.map { String(describing: $0) }))
            } catch { result.events.append(ShelfOrganizationEvent(source: url, output: nil, action: rule.action, message: error.localizedDescription)) }
        }
        return result
    }
    private static func process(_ source: URL, _ r: ShelfOrganizationRule, monitors: [ShelfFolderRule]) throws -> URL {
        let fm = FileManager.default
        guard !r.destination.isEmpty, ["Move","Copy","Rename and move","Create ZIP","Convert to PDF"].contains(r.action) else { throw ShelfPhaseWorker.error("Choose a valid action and destination.") }
        guard !r.prefix.contains("/"), !r.prefix.contains(":"), !r.prefix.contains("\u{0}"), !r.prefix.hasPrefix(".") else { throw ShelfPhaseWorker.error("Invalid filename prefix.") }
        let base = URL(fileURLWithPath: r.destination, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        var folder = base
        if r.group == "File type" { folder.appendPathComponent(category(source), isDirectory: true) }
        if r.group == "Year / month" { let d = DateFormatter(); d.dateFormat = "yyyy-MM"; folder.appendPathComponent(d.string(from: Date()), isDirectory: true) }
        folder = folder.resolvingSymlinksInPath().standardizedFileURL
        for monitor in monitors where monitor.enabled {
            let root = URL(fileURLWithPath: monitor.path).resolvingSymlinksInPath().standardizedFileURL.path
            if folder.path == root || (monitor.recursive && folder.path.hasPrefix(root + "/")) { throw ShelfPhaseWorker.error("Destination is monitored. Choose a folder outside recursive monitoring to avoid loops.") }
        }
        guard folder != source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL else { throw ShelfPhaseWorker.error("Destination equals source folder.") }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = (r.action == "Rename and move" ? r.prefix : "") + source.lastPathComponent
        var dest = folder.appendingPathComponent(name)
        if r.action == "Create ZIP" { dest = folder.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".zip") }
        if r.action == "Convert to PDF" { dest = folder.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".pdf") }
        dest = UniqueDestination.url(preferred: dest, fileManager: fm)
        try Task.checkCancellation()
        if r.action == "Move" || r.action == "Rename and move" { try fm.moveItem(at: source, to: dest) }
        else if r.action == "Copy" {
            let temp = folder.appendingPathComponent(".DropShelf-\(UUID().uuidString).partial"); defer { try? fm.removeItem(at: temp) }
            try fm.copyItem(at: source, to: temp); try Task.checkCancellation(); try fm.moveItem(at: temp, to: dest)
        } else {
            let temp = folder.appendingPathComponent(".DropShelf-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: temp, withIntermediateDirectories: false); defer { try? fm.removeItem(at: temp) }
            if r.action == "Create ZIP" {
                let zip = temp.appendingPathComponent("output.zip")
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); process.arguments = ["-c","-k","--keepParent",source.path,zip.path]; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw ShelfPhaseWorker.error("ZIP creation failed.") }; try Task.checkCancellation(); try fm.moveItem(at: zip, to: dest)
            } else {
                guard let pdf = try ShelfPhaseWorker.process("Convert Document to PDF…", url: source, folder: temp).first else { throw ShelfPhaseWorker.error("Conversion failed.") }; try Task.checkCancellation(); try fm.moveItem(at: pdf, to: dest)
            }
        }
        return dest
    }
    @MainActor static func history() -> [ShelfOrganizationEvent] { (try? JSONDecoder().decode([ShelfOrganizationEvent].self, from: UserDefaults.standard.data(forKey: historyKey) ?? Data())) ?? [] }
    @MainActor static func record(_ events: [ShelfOrganizationEvent]) { if let data = try? JSONEncoder().encode(Array((Array(events.reversed()) + history()).prefix(100))) { UserDefaults.standard.set(data, forKey: historyKey) } }
    @MainActor static func undo(_ event: ShelfOrganizationEvent) throws {
        var events = history(); guard let i = events.firstIndex(where: { $0.id == event.id }), !events[i].undone, let out = event.output, let identity = event.identity else { throw ShelfPhaseWorker.error("This operation cannot be undone.") }
        let fm = FileManager.default, v = try out.resourceValues(forKeys: [.fileSizeKey,.contentModificationDateKey,.fileResourceIdentifierKey,.isSymbolicLinkKey])
        guard v.isSymbolicLink != true, v.fileSize == event.bytes, v.contentModificationDate == event.modified, v.fileResourceIdentifier.map({ String(describing: $0) }) == identity else { throw ShelfPhaseWorker.error("Output has changed. Undo refused to protect your files.") }
        if ["Move","Rename and move"].contains(event.action) {
            guard !fm.fileExists(atPath: event.source.path) else { throw ShelfPhaseWorker.error("Original path is occupied.") }; try fm.moveItem(at: out, to: event.source)
        } else { try fm.trashItem(at: out, resultingItemURL: nil) }
        events[i].undone = true; UserDefaults.standard.set(try JSONEncoder().encode(events), forKey: historyKey)
    }
}

struct ShelfOrganizationSettings: View {
    @Binding var rule: ShelfFolderRule
    @State private var showing = false
    @State private var history = false
    @State private var message = ""
    private var config: Binding<ShelfOrganizationRule> { Binding(get: { rule.organization ?? ShelfOrganizationRule() }, set: { rule.organization = $0 }) }
    var body: some View {
        HStack { Text("Automatic organization"); Spacer(); Button((rule.organization?.action ?? "Collect only") + "…") { showing = true }.buttonStyle(ShelfSmallButton()); Button { history = true } label: { Image(systemName: "clock.arrow.circlepath") }.buttonStyle(.plain).help("Organization history") }
            .sheet(isPresented: $showing) { VStack(alignment: .leading, spacing: 13) {
                Text("Folder Rules").font(.headline)
                Picker("Action", selection: config.action) { ForEach(["Collect only","Move","Copy","Rename and move","Create ZIP","Convert to PDF"], id: \.self) { Text($0).tag($0) } }
                if config.wrappedValue.action != "Collect only" {
                    HStack { Text(config.wrappedValue.destination.isEmpty ? "Choose destination" : config.wrappedValue.destination).lineLimit(1).truncationMode(.middle); Spacer(); Button("Choose…") { ShelfFolderPicker.choose(owner: NSApp.keyWindow, initial: nil) { url in if let url { config.destination.wrappedValue = url.path } } } }
                    Picker("Group by", selection: config.group) { ForEach(["None","File type","Year / month"], id: \.self) { Text($0).tag($0) } }
                    if config.wrappedValue.action == "Rename and move" { TextField("Filename prefix", text: config.prefix) }
                    TextField("Extensions (e.g. pdf, png)", text: config.extensionFilter)
                    HStack { Text("Size (MB)"); TextField("Min", value: config.minimumMB, format: .number); TextField("Max (0 = any)", value: config.maximumMB, format: .number) }
                    HStack { Text("Minimum age (days)"); TextField("0", value: config.minimumAgeDays, format: .number) }
                    Text("Only newly detected stable files are processed. Move changes the original location; other actions preserve it.").font(.caption).foregroundStyle(.secondary)
                    Button("Preview matching files") { let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: rule.path), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []; let matches = urls.filter { ShelfOrganization.matches($0, config.wrappedValue) }; message = "\(matches.count) matches in the top-level folder. Preview only: " + matches.prefix(5).map(\.lastPathComponent).joined(separator: ", ") }
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                }
                HStack { Spacer(); Button("Done") { showing = false }.keyboardShortcut(.defaultAction).disabled(config.wrappedValue.action != "Collect only" && config.wrappedValue.destination.isEmpty) }
            }.padding(22).frame(width: 420) }
            .sheet(isPresented: $history) { ShelfOrganizationHistory() }
    }
}
private struct ShelfOrganizationHistory: View {
    @Environment(\.dismiss) private var dismiss
    @State private var events = ShelfOrganization.history()
    @State private var message = ""
    @State private var selected: ShelfOrganizationEvent?
    var body: some View {
        VStack(alignment: .leading) { Text("Organization Activity").font(.headline); ScrollView { ForEach(events) { event in HStack { VStack(alignment: .leading) { Text(event.source.lastPathComponent); Text(event.undone ? "Undone" : event.action + " · " + event.message).font(.caption).foregroundStyle(.secondary) }; Spacer(); if event.output != nil && !event.undone { Button("Undo") { selected = event } } }; Divider() } }; Text(message).font(.caption); HStack { Spacer(); Button("Done") { dismiss() } } }.padding(20).frame(width: 480,height: 330)
            .alert("Undo this operation?", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) { Button("Cancel", role: .cancel) { selected = nil }; Button("Undo") { if let event = selected { do { try ShelfOrganization.undo(event); events = ShelfOrganization.history(); message = "Undone" } catch { message = error.localizedDescription } }; selected = nil } } message: { Text("Moved files return to their original path. Generated copies are moved to Trash only if unchanged.") }
    }
}
