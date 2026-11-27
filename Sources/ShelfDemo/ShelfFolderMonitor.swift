import Foundation
import UniformTypeIdentifiers

// The monitor deliberately ignores existing files and incomplete downloads.
// A new file must have unchanged size and modification date on two scans.
@MainActor
final class ShelfFolderMonitor {
    private struct Stamp: Equatable, Sendable { let bytes: Int; let date: Date }
    private struct State { let rule: ShelfFolderRule; var known: [URL: Stamp]; var pending: [URL: Stamp] = [:]; var queued: [URL: Date] = [:]; var lastDetection = Date.distantPast }
    private var states: [UUID: State] = [:]
    private var task: Task<Void, Never>?
    func start(deliver: @escaping (ShelfFolderRule, [URL]) -> Void) {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let rules = ShelfAutomationPreferences.rules().filter(\.enabled)
                let ids = Set(rules.map(\.id))
                self.states = self.states.filter { ids.contains($0.key) }
                if !rules.isEmpty {
                    let scanned = await Task.detached(priority: .utility) {
                        rules.map { ($0, Self.scan($0)) }
                    }.value
                    guard !Task.isCancelled else { return }
                    for (rule, result) in scanned {
                        guard ShelfAutomationPreferences.rules().contains(rule) else { self.states.removeValue(forKey: rule.id); continue }
                        guard let files = result else { UserDefaults.standard.set("Cannot read folder", forKey: "shelf.monitor.status." + rule.id.uuidString); continue }
                        guard var state = self.states[rule.id], state.rule == rule else { self.states[rule.id] = State(rule: rule, known: files); UserDefaults.standard.set("Monitoring", forKey: "shelf.monitor.status." + rule.id.uuidString); continue }
                        state.known = state.known.filter { files[$0.key] != nil }
                        state.pending = state.pending.filter { files[$0.key] != nil }
                        UserDefaults.standard.set("Monitoring", forKey: "shelf.monitor.status." + rule.id.uuidString)
                        var ready: [URL] = []
                        for (url, stamp) in files where state.known[url] == nil {
                            if state.pending[url] == stamp {
                                state.known[url] = stamp; state.pending.removeValue(forKey: url)
                                if Self.matches(url, filter: rule.filter) && (rule.nameContains.isEmpty || url.lastPathComponent.localizedCaseInsensitiveContains(rule.nameContains)) { ready.append(url) }
                            } else { state.pending[url] = stamp }
                        }
                        if !ready.isEmpty { state.lastDetection = Date(); for url in ready { state.queued[url] = Date() } }
                        state.queued = state.queued.filter { files[$0.key] != nil }
                        if !rule.delayProcessing || Date().timeIntervalSince(state.lastDetection) >= 3 {
                            let batch = state.queued.keys.sorted { $0.path < $1.path }
                            state.queued.removeAll()
                            if rule.newShelf { for url in batch { deliver(rule, [url]) } }
                            else if !batch.isEmpty { deliver(rule, batch) }
                        }
                        self.states[rule.id] = state
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
    func stop() { task?.cancel(); task = nil; states.removeAll() }
    nonisolated private static func scan(_ rule: ShelfFolderRule) -> [URL: Stamp]? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        let root = URL(fileURLWithPath: rule.path, isDirectory: true)
        let fm = FileManager.default
        guard let direct = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return nil }
        var entries = direct
        if rule.recursive {
            var failed = false
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in failed = true; return false }) else { return nil }
            entries = []
            for case let url as URL in walker { entries.append(url); if entries.count > 10000 { return nil } }
            if failed { return nil }
        }
        guard entries.count <= 10000 else { return nil }
        var result: [URL: Stamp] = [:]
        for url in entries {
            guard !["download", "crdownload", "part", "tmp"].contains(url.pathExtension.lowercased()), let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true, v.isSymbolicLink != true, let size = v.fileSize, size >= 0, let date = v.contentModificationDate else { continue }
            result[url] = Stamp(bytes: size, date: date)
        }
        return result
    }
    nonisolated private static func matches(_ url: URL, filter: String) -> Bool {
        let type = UTType(filenameExtension: url.pathExtension)
        switch filter {
        case "Images": return type?.conforms(to: .image) == true
        case "PDFs": return type?.conforms(to: .pdf) == true
        case "Documents": return type?.conforms(to: .text) == true || ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "pdf", "rtf", "pages", "numbers", "key"].contains(url.pathExtension.lowercased())
        default: return true
        }
    }
}
