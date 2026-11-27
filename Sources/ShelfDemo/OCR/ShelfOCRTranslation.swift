import AppKit
import SwiftUI
import Translation

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
}

@available(macOS 15.0, *)
struct ShelfOCRTranslationSettings: View {
    @AppStorage("ocr.translation.enabled") private var enabled = false
    @AppStorage("ocr.translation.source") private var source = "auto"
    @AppStorage("ocr.translation.target") private var target = "en"
    @State private var languages: [Locale.Language] = []
    private var options: [(String, String)] {
        languages.map { ($0.minimalIdentifier, Locale.current.localizedString(forIdentifier: $0.minimalIdentifier) ?? $0.minimalIdentifier) }.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Toggle("Enable OCR Translation", isOn: $enabled).toggleStyle(.switch)
            if enabled {
                if options.isEmpty {
                    Text("Loading supported languages…").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("From").font(.caption).foregroundStyle(.secondary)
                            ModernSettingsMenu(title: "From", selection: $source, options: [("auto", "Auto Detect")] + options)
                        }
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("To").font(.caption).foregroundStyle(.secondary)
                            ModernSettingsMenu(title: "To", selection: $target, options: options)
                        }
                        Spacer(minLength: 0)
                    }
                }
                Text("Translate captured screen text automatically. The original remains available in the shelf menu.").font(.caption).foregroundStyle(.secondary)
            }
        }.task {
            languages = await LanguageAvailability().supportedLanguages
            if !options.isEmpty {
                if source != "auto" && !options.contains(where: { $0.0 == source }) { source = "auto" }
                if !options.contains(where: { $0.0 == target }) { target = options.first(where: { $0.0 == "en" })?.0 ?? options[0].0 }
            }
        }
    }
}

@MainActor enum ShelfOCRTranslation {
    private static var window: NSWindow?
    static func process(_ original: String) async -> ShelfOCRResult {
        let defaults = UserDefaults.standard
        let fallback = ShelfOCRResult(text: original)
        guard defaults.bool(forKey: "ocr.translation.enabled"), #available(macOS 15.0, *) else { return fallback }
        guard window == nil else { return fallback }
        let source = defaults.string(forKey: "ocr.translation.source") ?? "auto"
        let target = defaults.string(forKey: "ocr.translation.target") ?? "en"
        if source == target { return fallback }
        return await withCheckedContinuation { continuation in
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.title = "OCR Translation"
            var finished = false
            let finish: @MainActor (ShelfOCRResult) -> Void = { [weak panel] result in
                guard !finished else { return }
                finished = true
                panel?.close()
                ShelfOCRTranslation.window = nil
                continuation.resume(returning: result)
            }
            panel.contentView = NSHostingView(rootView: ShelfOCRProgress(original: original, source: source, target: target, finish: finish))
            window = panel
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@available(macOS 15.0, *)
@MainActor private struct ShelfOCRProgress: View {
    let original: String
    let source: String
    let target: String
    let finish: @MainActor (ShelfOCRResult) -> Void
    @State private var failureMessage = ""
    @State private var completed = false
    @State private var configuration: TranslationSession.Configuration?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ActionPanelHeader(title: "OCR Translation", subtitle: "Your original text is preserved", symbol: "globe")
            if failureMessage.isEmpty { ProgressView("Translating captured text…").controlSize(.small) }
            else { Text(failureMessage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Use Original") { completed = true; finish(ShelfOCRResult(text: original)) }.keyboardShortcut(.cancelAction)
            }
        }.padding(16).frame(minWidth: 400, minHeight: 150)
        .onAppear {
            configuration = .init(source: source == "auto" ? nil : Locale.Language(identifier: source), target: Locale.Language(identifier: target))
        }
        .translationTask(configuration) { session in
            await performTranslation(session)
        }
    }

    private func performTranslation(_ session: TranslationSession) async {
        do {
            let response = try await session.translate(original)
            guard !completed else { return }
            guard !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                failureMessage = "Translation returned no text. Use the original instead."
                return
            }
            completed = true
            let metadata = ShelfOCRMetadata(original: original, source: response.sourceLanguage.minimalIdentifier, target: response.targetLanguage.minimalIdentifier)
            finish(ShelfOCRResult(text: response.targetText, metadata: metadata))
        } catch let translationError {
            guard !completed else { return }
            failureMessage = "Translation unavailable: " + translationError.localizedDescription
        }
    }
}
