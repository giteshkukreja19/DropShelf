import AppKit
import SwiftUI
import Translation
import NaturalLanguage

struct ShelfOCRMetadata: Codable, Equatable {
    let original: String
    let source: String
    let target: String
    var targetName: String { Locale.current.localizedString(forIdentifier: target) ?? target }
    var label: String { (Locale.current.localizedString(forIdentifier: source) ?? source) + " → " + targetName }
}

struct ShelfOCRResult {
    let text: String
    var metadata: ShelfOCRMetadata? = nil
    var notice: String? = nil
}

@available(macOS 15.0, *)
struct ShelfOCRTranslationSettings: View {
    @AppStorage("ocr.translation.enabled") private var enabled = false
    @AppStorage("ocr.translation.source") private var source = "auto"
    @AppStorage("ocr.translation.target") private var target = "en"
    @State private var languages: [Locale.Language] = []
    @State private var downloadSource = "en"
    @State private var status = "Choose a language pair."
    @State private var checking = false
    @State private var preparing = false
    @State private var checkGeneration = 0
    @State private var preparation: TranslationSession.Configuration?
    private var options: [(String, String)] {
        languages.map { ($0.minimalIdentifier, Locale.current.localizedString(forIdentifier: $0.minimalIdentifier) ?? $0.minimalIdentifier) }.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }
    private var selectedSource: String { source == "auto" ? downloadSource : source }
    private var downloadOptions: [(String, String)] { options.filter { !OCRTextPreparation.languageMatches($0.0, target) } }
    private var sameLanguage: Bool { OCRTextPreparation.languageMatches(selectedSource, target) }
    private func adjustDownloadSource() {
        if source == "auto", !downloadOptions.contains(where: { $0.0 == downloadSource }) {
            downloadSource = downloadOptions.first?.0 ?? target
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack { Text("Enable OCR Translation"); Spacer(); Toggle("Enable OCR Translation", isOn: $enabled).labelsHidden().toggleStyle(.switch); ShelfSettingsInfo(message: "Only installed language pairs are used during OCR. Prepare missing languages here; OCR always preserves the original text.") }
            if enabled {
                if options.isEmpty { Text("Loading supported languages…").font(.caption) }
                else {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("From").font(.caption).foregroundStyle(.secondary)
                            ModernSettingsMenu(title: "From", selection: $source, options: [("auto", "Auto Detect")] + options).disabled(preparing)
                        }
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("To").font(.caption).foregroundStyle(.secondary)
                            ModernSettingsMenu(title: "To", selection: $target, options: options).disabled(preparing)
                        }
                        Spacer(minLength: 0)
                    }
                    Divider()
                    Text("Language downloads").font(.headline)
                    if source == "auto" {
                        HStack { Text("Prepare source language"); Spacer(); ModernSettingsMenu(title: "Source language", selection: $downloadSource, options: downloadOptions).disabled(downloadOptions.isEmpty || preparing) }
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            if checking || preparing { ProgressView().controlSize(.small) }
                            Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        HStack {
                            Spacer(minLength: 0)
                            Button("Check") { Task { await refreshStatus(manual: true) } }.disabled(checking || preparing)
                            Button("Prepare Languages…") {
                                guard !sameLanguage, !preparing else { return }
                                preparing = true
                                status = "Preparing languages… Follow any macOS download prompt."
                                let pair = TranslationSession.Configuration(source: Locale.Language(identifier: selectedSource), target: Locale.Language(identifier: target))
                                if preparation == pair { preparation?.invalidate() } else { preparation = pair }
                            }.disabled(sameLanguage || checking || preparing || (source == "auto" && downloadOptions.isEmpty))
                        }
                    }
                }
            }
        }
        .task {
            languages = await LanguageAvailability().supportedLanguages
            if !options.isEmpty {
                if source != "auto" && !options.contains(where: { $0.0 == source }) { source = "auto" }
                if !options.contains(where: { $0.0 == target }) { target = options.first(where: { $0.0 == "en" })?.0 ?? options[0].0 }
                adjustDownloadSource()
            }
        }
        .onChange(of: target) { _ in adjustDownloadSource() }
        .onChange(of: source) { _ in adjustDownloadSource() }
        .task(id: selectedSource + "|" + target + "|" + String(enabled)) {
            if enabled && !preparing { await refreshStatus() }
        }
        .translationTask(preparation) { session in
            let a = selectedSource, b = target
            defer { preparing = false }
            do {
                try await session.prepareTranslation()
                guard !Task.isCancelled, a == selectedSource, b == target else { return }
                await refreshStatus(manual: true)
            } catch {
                guard a == selectedSource, b == target else { return }
                status = "Preparation cancelled or unavailable. Check your connection and try again. Original OCR is still available."
            }
        }
        .onDisappear { preparing = false; checking = false; preparation = nil; checkGeneration += 1 }
    }
    @MainActor private func refreshStatus(manual: Bool = false) async {
        let a = selectedSource, b = target
        checkGeneration += 1
        let generation = checkGeneration
        checking = true
        defer { if generation == checkGeneration { checking = false } }
        let prefix = manual ? "Checked: " : ""
        if OCRTextPreparation.languageMatches(a,b) {
            status = prefix + "Same language — no download needed. Choose a different source to prepare translation."
            return
        }
        status = "Checking language availability…"
        let availability = await LanguageAvailability().status(from: Locale.Language(identifier: a), to: Locale.Language(identifier: b))
        guard !Task.isCancelled, generation == checkGeneration, a == selectedSource, b == target else { return }
        switch availability {
        case .installed: status = prefix + "Installed and ready"
        case .supported: status = prefix + "Download required. Select Prepare Languages."
        case .unsupported: status = prefix + "Unsupported language pair. Choose another source."
        @unknown default: status = prefix + "Availability unknown"
        }
    }
}

@MainActor enum ShelfOCRTranslation {
    static func process(_ original: String) async -> ShelfOCRResult {
        let defaults = UserDefaults.standard
        let fallback = ShelfOCRResult(text: original)
        guard defaults.bool(forKey: "ocr.translation.enabled"), #available(macOS 15.0, *) else { return fallback }
        let configured = defaults.string(forKey: "ocr.translation.source") ?? "auto"
        let target = defaults.string(forKey: "ocr.translation.target") ?? "en"
        let prepared = OCRTextPreparation.prepare(original)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(prepared.prefix(8000)))
        let guesses = recognizer.languageHypotheses(withMaximum: 2)
        let detected = recognizer.dominantLanguage
        let source: String
        if configured == "auto" {
            guard let detected, (guesses[detected] ?? 0) >= 0.55 else { return ShelfOCRResult(text: original, notice: "Language uncertain. Choose the source language in Settings.") }
            source = detected.rawValue
        } else { source = configured }
        if OCRTextPreparation.languageMatches(source, target) { return fallback }
        guard !prepared.isEmpty else { return fallback }
        return await OCRTranslationJob(original: original, prepared: prepared, source: source, target: target).run()
    }
}

@available(macOS 15.0, *)
@MainActor private final class OCRTranslationJob {
    let original: String, prepared: String, source: String, target: String
    private var continuation: CheckedContinuation<ShelfOCRResult, Never>?
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var panel: NSPanel?
    init(original: String, prepared: String, source: String, target: String) {
        self.original = original; self.prepared = prepared; self.source = source; self.target = target
    }
    func run() async -> ShelfOCRResult {
        await withCheckedContinuation { c in
            continuation = c
            deadline = Task { [self] in
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                finish(ShelfOCRResult(text: original, notice: "Translation timed out. Original saved."))
            }
            work = Task { [self] in
                let a = Locale.Language(identifier: source), b = Locale.Language(identifier: target)
                let availability = await LanguageAvailability().status(from: a, to: b)
                guard continuation != nil, !Task.isCancelled else { return }
                guard availability == .installed else {
                    finish(ShelfOCRResult(text: original, notice: availability == .supported ? "Prepare translation languages in File & Tools." : "Translation pair unavailable. Original saved.")); return
                }
                if #available(macOS 26.0, *) {
                    await translate(TranslationSession(installedSource: a, target: b))
                } else {
                    // Older OS requires a SwiftUI-hosted session. Non-activating, compact and cancellable.
                    let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 78), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
                    p.isReleasedWhenClosed = false; p.title = "OCR Translation"
                    p.contentView = NSHostingView(rootView: OCRLegacyTranslationView(source: a, target: b, job: self))
                    panel = p; p.center(); p.orderFrontRegardless()
                }
            }
        }
    }
    func translate(_ session: TranslationSession) async {
        guard continuation != nil else { return }
        do {
            // Bound each request. On any failure or timeout preserve the entire original.
            var translated: [String] = []
            var actualSource = source, actualTarget = target
            for chunk in OCRTextPreparation.translationChunks(prepared) {
                guard continuation != nil, !Task.isCancelled else { return }
                if chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { translated.append(chunk); continue }
                let response = try await session.translate(chunk)
                guard continuation != nil, !Task.isCancelled else { return }
                guard !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { cancel(); return }
                translated.append(response.targetText.trimmingCharacters(in: .whitespacesAndNewlines))
                actualSource = response.sourceLanguage.minimalIdentifier
                actualTarget = response.targetLanguage.minimalIdentifier
            }
            finish(ShelfOCRResult(text: translated.joined(separator: "\n"), metadata: ShelfOCRMetadata(original: original, source: actualSource, target: actualTarget)))
        } catch { finish(ShelfOCRResult(text: original, notice: "Translation unavailable. Original saved.")) }
    }
    func cancel() { finish(ShelfOCRResult(text: original)) }
    private func finish(_ result: ShelfOCRResult) {
        guard let c = continuation else { return }
        continuation = nil; deadline?.cancel(); deadline = nil; work?.cancel(); work = nil
        panel?.orderOut(nil); panel?.contentView = nil; panel?.close(); panel = nil
        c.resume(returning: result)
    }
}

@available(macOS 15.0, *)
private struct OCRLegacyTranslationView: View {
    let source: Locale.Language, target: Locale.Language
    let job: OCRTranslationJob
    var body: some View {
        HStack { ProgressView().controlSize(.small); Text("Translating…"); Spacer(); Button("Use Original") { job.cancel() } }.padding(14)
            .translationTask(source: source, target: target) { session in await job.translate(session) }
    }
}
