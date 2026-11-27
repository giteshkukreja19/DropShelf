import AppKit
import SwiftUI

enum ShelfExpiry: Int, CaseIterable, Identifiable {
    case never = 0
    case tenMinutes = -10
    case fifteenMinutes = -15
    case oneHour = -60
    case oneDay = 1
    case sevenDays = 7
    case tenDays = 10
    case thirtyDays = 30

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .never: return L("Never")
        case .tenMinutes: return "After 10 minutes"
        case .fifteenMinutes: return "After 15 minutes"
        case .oneHour: return "After 1 hour"
        case .oneDay: return L("After 1 day")
        case .sevenDays: return L("After 7 days")
        case .tenDays: return L("After 10 days")
        case .thirtyDays: return L("After 30 days")
        }
    }
}

enum ShelfActivation: String, CaseIterable, Identifiable {
    case instant, oneSecond, twoSeconds, dragOnly, shakeOnly, doubleClick, singleClick, halfSecond
    var id: String { rawValue }
    var label: String {
        switch self {
        case .doubleClick: return "Double-click"
        case .singleClick: return "Single-click"
        case .halfSecond: return "Hover for 0.5 seconds"
        case .instant: return "Instant hover"
        case .oneSecond: return "Hover for 1 second"
        case .twoSeconds: return "Hover for 2 seconds"
        case .dragOnly: return "While dragging files only"
        case .shakeOnly: return "Shake / click only"
        }
    }
    var delay: Double? {
        switch self {
        case .halfSecond: return 0.5
        case .instant: return 0
        case .oneSecond: return 1
        case .twoSeconds: return 2
        default: return nil
        }
    }
}

enum ShelfSummon: String, CaseIterable, Identifiable {
    case instant, oneSecond, twoSeconds, shakeOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .instant: return "Immediately while dragging a file"
        case .oneSecond: return "After dragging for 1 second"
        case .twoSeconds: return "After dragging for 2 seconds"
        case .shakeOnly: return "Shake only"
        }
    }
    var delay: Double? {
        switch self {
        case .instant: return 0
        case .oneSecond: return 1
        case .twoSeconds: return 2
        case .shakeOnly: return nil
        }
    }
}

struct SettingsView: View {
    @AppStorage("shelf.intelligentNames") private var intelligentNames = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var showActionPreferences = false
    @State private var showShortcuts = false
    @AppStorage("shelf.shakeSensitivity") private var shakeSensitivity = "Default"
    @AppStorage("shelf.modifierActivation") private var modifierActivation = "Off"
    @AppStorage("shelf.defaultLocation") private var defaultLocation = "Menu bar"
    @AppStorage("shelf.sortOrder") private var sortOrder = "Date Added"
    @AppStorage("shelf.idleCollapseSeconds") private var idleCollapseSeconds = 0
    @AppStorage("shelf.idleDockSeconds") private var idleDockSeconds = 0
    @AppStorage("shelf.idleHideDockedSeconds") private var idleHideDockedSeconds = 0
    @AppStorage("shelf.celebration") private var celebration = true
    @AppStorage("pdf.wordMode") private var pdfWordMode = "automatic"
    @AppStorage("shelf.closeAfterDrag") private var closeAfterDrag = false
    @AppStorage("shelf.edgeDock") private var edgeDock = true
    @AppStorage("shelf.shakeEnabled") private var shakeEnabled = true
    @AppStorage("shelf.handleGlow") private var handleGlow = true
    @AppStorage("shelf.summon") private var summon: ShelfSummon = .instant
    @AppStorage("shelf.activation") private var activation: ShelfActivation = .oneSecond
    @AppStorage("shelf.expiryDays") private var expiryDays: Int = ShelfExpiry.tenDays.rawValue
    @AppStorage("shelf.autoParkTopRight") private var autoParkTopRight: Bool = false
    @AppStorage("shelf.autoParkPosition") private var autoParkPosition = "Top right"
    @AppStorage("shelf.closeOnOutsideClick") private var closeOnOutsideClick: Bool = false
    @AppStorage("SUEnableAutomaticChecks") private var autoCheckUpdates: Bool = true

    /// Source of truth is whether our LaunchAgent plist exists in
    /// `~/Library/LaunchAgents/`. Mirrored into local state so the toggle
    /// stays in sync if the file is removed externally.
    @State private var launchAtLogin: Bool = LaunchAtLoginManager.isEnabled

    @State private var pickedLanguage: AppLanguage = LanguagePreference.current

    @State private var section = "Shelf Activation"
    @State private var hoveredSection: String?
    @AppStorage("shelf.instantActions") private var instantActions = true
    @AppStorage("shelf.emailProvider") private var emailProvider = "Gmail"
    @AppStorage("shelf.smartAttach") private var smartAttach = false
    @AppStorage("shelf.smartAttachStatus") private var smartAttachStatus = "Not attempted yet."
    @AppStorage("shelf.compactSizePercent") private var compactSizePercent = 100
    @AppStorage("shelf.expandedSizePercent") private var expandedSizePercent = 100
    @AppStorage("shelf.fixedExpandedSize") private var fixedExpandedSize = false
    @AppStorage("shelf.fixedExpandedDimensions") private var fixedExpandedDimensions = ""
    @AppStorage("shelf.showInDock") private var showInDock = false
    @AppStorage("shelf.showInMenuBar") private var showInMenuBar = true
    @AppStorage("shelf.menuBarIconStyle") private var menuBarIconStyle = "Traditional"
    private let sections = ["Shelf Activation", "Shelf Interaction", "General", "Cloud Sharing", "Custom Actions", "Instant Actions", "Folder Monitoring", "File & Text Tools", "Capture Studio", "About & Updates"]
    private let symbols = ["cursorarrow", "rectangle.on.rectangle", "gearshape", "cloud", "slider.horizontal.3", "bolt", "folder.badge.plus", "doc.text", "video", "info.circle"]
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {

                Text("SETTINGS")
                    .font(.system(
                        size: 10,
                        weight: .semibold
                    ))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)

                ForEach(sections.indices, id: \.self) { i in
                    Button {
                        withAnimation(
                            NSWorkspace.shared
                                .accessibilityDisplayShouldReduceMotion
                            ? .linear(duration: 0)
                            : .easeInOut(duration: 0.22)
                        ) {
                            section = sections[i]
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: symbols[i])
                                .font(.system(
                                    size: 13,
                                    weight: .semibold
                                ))
                                .foregroundStyle(.white)
                                .frame(width: 19, height: 19)
                                .background(
                                    [
                                        Color.green,
                                        .purple,
                                        .gray,
                                        .blue,
                                        .yellow,
                                        .pink,
                                        .indigo,
                                        .orange,
                                        .red, .cyan
                                    ][i],
                                    in: RoundedRectangle(
                                        cornerRadius: 8
                                    )
                                )

                            Text(sections[i])
                                .foregroundStyle(section == sections[i] ? Color.white : Color.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.88)
                                .font(.system(
                                    size: 13,
                                    weight: section == sections[i]
                                        ? .semibold : .regular
                                ))

                            Spacer(minLength: 0)
                        }
                        .padding(5)
                        .background(
                            section == sections[i]
                                ? ShelfSettingsPalette.accent
                                : hoveredSection == sections[i]
                                    ? Color.primary.opacity(0.06)
                                    : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        hoveredSection = inside
                            ? sections[i] : nil
                    }
                }

                Spacer()

                Divider()

                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 38, height: 38)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("DropShelf")
                            .font(.system(
                                size: 13,
                                weight: .semibold
                            ))

                        Text(
                            Bundle.main.object(
                                forInfoDictionaryKey:
                                    "CFBundleShortVersionString"
                            ) as? String ?? "Development"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(8)
            }
            .padding(14)
            .padding(.top, 22)
            .frame(width: 200)
            .background { ShelfAdaptiveSettingsSidebar().modifier(ShelfSettingsWindowDrag()).ignoresSafeArea(edges: .top) }

            Divider().ignoresSafeArea(edges: .top)

            VStack(spacing: 0) {
                VStack(alignment: .center, spacing: 6) {
                    Text(section)
                        .font(.system(
                            size: 22,
                            weight: .semibold
                        ))

                    Text(sectionDescription)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(
                    maxWidth: .infinity,
                    alignment: .center
                )
                .padding(18)
                .modifier(ShelfSettingsWindowDrag())

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch section {
                        case "Shelf Activation":
                            activationSettings

                        case "Shelf Interaction":
                            interactionSettings

                        case "General":
                            generalSettings

                        case "Cloud Sharing":
                            settingsGroup("Cloud folders") {
                                Text(
                                    "Use Copy to Cloud in the shelf menu to choose an iCloud Drive, Google Drive or OneDrive synced folder."
                                )
                                Text(
                                    "WhatsApp is available when its native sharing service supports the selected items."
                                )
                                .foregroundStyle(.secondary)
                            }

                        case "Custom Actions":
                            settingsGroup("Your presets") { ShelfCustomActionsSettings() }

                        case "Instant Actions":
                            settingsGroup("Sharing shortcuts") {
                                settingsToggle(
                                    "Enable Instant Actions",
                                    isOn: $instantActions
                                )

                                Divider()
                                HStack {
                                    Label("Email provider", systemImage: "envelope")
                                    Spacer(minLength: 8)
                                    ModernSettingsMenu(title: "Email provider", selection: $emailProvider, options: [("Gmail", "Gmail"), ("System Mail", "System Mail")])
                                }
                                HStack {
                                    Text("Sharing help")
                                    Spacer()
                                    ShelfSettingsInfo(message: "The lightning button appears near a shelf. Drop files onto supported destinations. Original files are preserved. Gmail opens a draft; attach files manually. System Mail uses native sharing when available.")
                                }
                            }

                        case "Folder Monitoring":
                            settingsGroup("Monitored folders") { ShelfAutomationSettings(monitoring: true) }

                        case "Capture Studio":
                            ShelfRecorderSettings()

                        case "File & Text Tools":
                            pdfSettings

                        default:
                            updateSettings
                        }
                    }
                    .padding(20)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    .toggleStyle(.switch)
                    .buttonStyle(ShelfSmallButton())
                    .id(section)
                    .transition(.opacity)
                }
            }
            .padding(.top, 22)
            .background(
                ShelfSettingsContentMaterial().modifier(ShelfSettingsWindowDrag()).ignoresSafeArea(edges: .top)
            )
        }
        .frame(
            minWidth: 680,
            idealWidth: 700,
            minHeight: 520,
            idealHeight: 660
        )
        .ignoresSafeArea(.container, edges: .top)
        .font(.system(size: 13))
        .tint(ShelfSettingsPalette.accent)
        .onAppear {
            launchAtLogin = LaunchAtLoginManager.isEnabled
            pickedLanguage = LanguagePreference.current
        }
    }

    private var sectionDescription: String {
        switch section {
        case "Shelf Activation": return "Choose when and where new shelves appear."
        case "Shelf Interaction": return "Customize shelf appearance, behavior and timing."
        case "General": return "Manage storage, language and startup preferences."
        case "Cloud Sharing": return "Manage your existing cloud folder workflow."
        case "Custom Actions": return "Save frequently used image and document action parameters."
        case "Instant Actions": return "Quickly share items directly from a shelf."
        case "Folder Monitoring": return "Collect new files from selected folders."
        case "Capture Studio": return "Record your screen and save videos locally."
        case "File & Text Tools": return "Configure document conversion preferences."
        default: return "Manage DropShelf update preferences."
        }
    }
    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 11) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ShelfSettingsPalette.card(colorScheme), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
    }
    private func settingsToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func choice<T: Hashable>(_ title: String, selection: Binding<T>, options: [(T, String)]) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            ModernSettingsMenu(title: title, selection: selection, options: options)
        }
    }
    private func timerRow(_ title: String, value: Binding<Int>, values: [Int], detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { choice(title, selection: value, options: values.map { ($0, $0 == 0 ? "Never" : "\($0) seconds") }); ShelfSettingsInfo(message: detail) }
        }
    }
    @ViewBuilder private var activationSettings: some View {
        settingsGroup("Drag activation") {
            HStack { choice("Show new shelf", selection: $summon, options: ShelfSummon.allCases.map { ($0, $0.label) }); ShelfSettingsInfo(message: "Drag a file from Finder or the desktop to summon a shelf.") }
            Divider()
            settingsToggle("Shake to show shelf during file drag", isOn: $shakeEnabled).disabled(summon == .shakeOnly)
            choice("Shake sensitivity", selection: $shakeSensitivity, options: ["Low", "Default", "High"].map { ($0, $0) })
        }
        settingsGroup("Modifier key") {
            HStack { choice("Activate while dragging with", selection: $modifierActivation, options: ["Off", "Shift", "Option", "Control"].map { ($0, $0) }); ShelfSettingsInfo(message: "Hold the selected modifier key while dragging.") }
        }
        settingsGroup("Placement") {
            choice("Default shelf location", selection: $defaultLocation, options: (["Menu bar"] + ShelfScreenPosition.allCases.map { $0.rawValue }).map { ($0, $0) })
        }
    }
    @ViewBuilder private var interactionSettings: some View {
        settingsGroup("Appearance and sorting") {
            choice("Default file sorting", selection: $sortOrder, options: ["Date Added", "Name", "Size"].map { ($0, $0) })
            Divider()
            HStack { Text("Compact shelf size"); Spacer(); Text("\(compactSizePercent)%").monospacedDigit() }
            Slider(value: Binding(get: { Double(compactSizePercent) }, set: { compactSizePercent = Int($0) }), in: 90...150)
            HStack { note("Compact shelves keep this size."); Spacer(); Button("Reset") { compactSizePercent = 100 } }
            Divider()
            HStack { Text("Expanded shelf size"); Spacer(); Text("\(expandedSizePercent)%").monospacedDigit() }
            Slider(value: Binding(get: { Double(expandedSizePercent) }, set: {
                fixedExpandedDimensions = ""
                expandedSizePercent = Int($0.rounded())
            }), in: 70...150)
            HStack {
                HStack { Spacer(); ShelfSettingsInfo(message: "Controls width and adaptive maximum height. Reset restores the compact v1.7.0 layout and clears any saved fixed dimensions.") }
                Spacer()
                Button("Reset") { fixedExpandedDimensions = ""; expandedSizePercent = 100 }
            }
            settingsToggle("Keep expanded shelf size fixed", isOn: Binding(
                get: { fixedExpandedSize },
                set: { enabled in
                    if enabled && !fixedExpandedSize {
                        fixedExpandedDimensions = (NSApp.delegate as? AppDelegate)?.currentExpandedShelfDimensions() ?? ""
                    }
                    fixedExpandedSize = enabled
                }
            ))
            if fixedExpandedSize, let size = ShelfExpandedGeometry.decode(fixedExpandedDimensions) {
                HStack {
                    HStack { Spacer(); ShelfSettingsInfo(message: "Saved window size: \(Int(size.width)) × \(Int(size.height)) pt") }
                    Spacer()
                    Button("Use slider size") { fixedExpandedDimensions = "" }
                }
            }
            HStack { Spacer(); ShelfSettingsInfo(message: "When enabled, the current expanded window size is saved. If no expanded shelf is visible, a compact preset is used. Resize manually to remember a new size, or use the slider to choose a preset. Overflow scrolls inside the shelf.") }
            Divider()
            HStack { choice("Expand existing shelf", selection: $activation, options: ShelfActivation.allCases.map { ($0, $0.label) }); ShelfSettingsInfo(message: "Double-click the file stack to expand, or drag files directly from it.") }
        }
        settingsGroup("Inactivity") {
            timerRow("Collapse expanded shelf", value: $idleCollapseSeconds, values: [0, 3, 5, 10, 15, 30, 60], detail: "When inactive and the pointer is outside.")
            Divider()
            timerRow("Dock compact shelf", value: $idleDockSeconds, values: [0, 3, 5, 10, 15, 30, 60], detail: "Pinned shelves are excluded.")
            Divider()
            timerRow("Hide docked shelf", value: $idleHideDockedSeconds, values: [0, 5, 10, 15, 30, 60, 300], detail: "Items remain in Recent Shelves. Pinned shelves are excluded.")
        }
        settingsGroup("Shelf behavior") {
            settingsToggle("Close shelf after dragging out", isOn: $closeAfterDrag)
            Divider()
            settingsToggle("Automatically dock at the right screen edge", isOn: $edgeDock)
            Divider()
            settingsToggle("Automatically move shelf after first drop", isOn: $autoParkTopRight)
            choice("Move shelf to", selection: $autoParkPosition, options: ShelfScreenPosition.allCases.map { ($0.rawValue, $0.rawValue) })
                .disabled(!autoParkTopRight)
            HStack { Spacer(); ShelfSettingsInfo(message: "Glide to the selected position on the current display after the first file is added. Existing shelves stay in place.") }
            Divider()
            HStack { settingsToggle(L("Collapse expanded shelf when clicking outside"), isOn: $closeOnOutsideClick); ShelfSettingsInfo(message: L("settings.collapse.description")) }
        }
        settingsGroup("Visual effects") {
            settingsToggle("Glow on shelf handle hover", isOn: $handleGlow)
            Divider()
            settingsToggle("Celebration animation after dragging out files", isOn: $celebration)
        }
    }
    @ViewBuilder private var generalSettings: some View {
        settingsGroup("Shelf preferences") {
            HStack { settingsToggle("Intelligent Shelf Names", isOn: $intelligentNames); ShelfSettingsInfo(message: "Automatically name shelves using file types. Manually assigned names are always preserved.") }
        }
        settingsGroup("Action menu") {
            HStack { Text("Customize action menu"); Spacer(); Button("Edit…") { showActionPreferences = true } }
            HStack { Spacer(); ShelfSettingsInfo(message: "Choose which actions appear in the main menu or submenu.") }
        }.sheet(isPresented: $showActionPreferences) { ShelfActionPreferencesView() }
        settingsGroup("Keyboard shortcuts") {
            HStack { Text("Customize keyboard shortcuts"); Spacer(); Button("Edit…") { showShortcuts = true } }
        }.sheet(isPresented: $showShortcuts) { ShelfShortcutSettings() }
        settingsGroup("Application appearance") {
            settingsToggle("Show in menu bar", isOn: Binding(get: { showInMenuBar }, set: { value in
                showInMenuBar = value
                (NSApp.delegate as? AppDelegate)?.applyGeneralAppearance()
            })).disabled(!showInDock)
            HStack { Spacer(); ShelfSettingsInfo(message: "Keep the menu bar enabled when the Dock icon is hidden.") }
            Divider()
            choice("Menu bar icon", selection: $menuBarIconStyle, options: ["Traditional", "Stack", "Filled"].map { ($0, $0) })
                .onChange(of: menuBarIconStyle) { _ in (NSApp.delegate as? AppDelegate)?.applyGeneralAppearance() }
            Divider()
            settingsToggle("Show in Dock", isOn: Binding(get: { showInDock }, set: { value in
                showInDock = value
                if !value { showInMenuBar = true }
                (NSApp.delegate as? AppDelegate)?.applyGeneralAppearance()
            }))
            Divider()
            ShelfDataLocationSettings()
        }
        settingsGroup("Favourite items") { ShelfFavouriteSettings() }
        settingsGroup("Favourite locations") { ShelfAutomationSettings(monitoring: false) }
        settingsGroup("Storage and preferences") {
            VStack(alignment: .leading, spacing: 6) {
                choice(L("Auto-delete shelves"), selection: $expiryDays, options: ShelfExpiry.allCases.map { ($0.rawValue, $0.label) })
                .id(pickedLanguage)

                Text(L("settings.expiry.description"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {

                // Custom binding so the LanguagePreference write happens
                // synchronously inside the Picker's setter, before SwiftUI
                // tears down anything in response to the @State change.
                // .onChange is unreliable here — when the surrounding view
                // gets re-identified by a peer Picker's .id(), the handler
                // can be discarded before it runs.
                choice(L("Language"), selection: Binding(
                    get: { pickedLanguage },
                    set: { newValue in
                        pickedLanguage = newValue
                        LanguagePreference.current = newValue
                    }
                ), options: AppLanguage.allCases.map { ($0, $0.displayName) })

                Text(L("settings.language.description"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                settingsToggle(L("Launch at login"), isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in applyLaunchAtLogin(newValue) }
                ))
                .toggleStyle(.switch)
                Text(L("settings.launch.description"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }


        }
    }
    @ViewBuilder private var pdfSettings: some View {
        settingsGroup("OCR Translation") {
            if #available(macOS 15.0, *) {
                ShelfOCRTranslationSettings()
            } else {
                note("Screen translation requires macOS 15 or later. OCR remains available.")
            }
        }
        settingsGroup("Document conversion") {
            choice("PDF to Word mode", selection: $pdfWordMode, options: [("automatic", "Automatic"), ("editable", "Editable Word"), ("appearance", "Preserve appearance")])
            Text("Automatic uses editable layout for text PDFs and preserves page images for scanned or mixed PDFs. Preserve appearance keeps fonts, borders and graphics visually but is not editable. Editable Word uses OCR for scans; complex formatting may be lost.")
                .font(.caption)
                .foregroundStyle(.secondary)

        }
    }
    @ViewBuilder private var updateSettings: some View {
        settingsGroup("Software updates") {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Updates"))
                    .font(.system(size: 13, weight: .medium))
                settingsToggle(L("Automatically check for updates"), isOn: $autoCheckUpdates)
                    .toggleStyle(.switch)
                Text(L("settings.updates.description"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func applyLaunchAtLogin(_ enable: Bool) {
        do {
            try LaunchAtLoginManager.setEnabled(enable)
            launchAtLogin = LaunchAtLoginManager.isEnabled
        } catch {
            NSLog("Shelf: launch-at-login toggle failed — \(error)")
            launchAtLogin = LaunchAtLoginManager.isEnabled
            let alert = NSAlert()
            alert.messageText = L("Couldn't Update Login Items")
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("OK"))
            alert.runModal()
        }
    }
}

/// Writes a LaunchAgent plist to `~/Library/LaunchAgents/` so launchd will
/// start Shelf at the next login. Works for both `.app` bundles (uses
/// `/usr/bin/open -a` so the app activates with the right policy) and raw
/// SwiftPM debug binaries (executes them directly). Toggling off just
/// removes the plist — already-running processes keep running until the
/// user logs out, which is fine because the user is editing settings inside
/// that running process.
enum LaunchAtLoginManager {
    static let label = "com.shelf.ShelfDemo.LaunchAgent"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enable: Bool) throws {
        if enable {
            try install()
        } else {
            try uninstall()
        }
    }

    private static func install() throws {
        let dir = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )

        let arguments: [String]
        if let appURL = appBundleURL() {
            // Activation through `open -a` — launchd execs the binary directly
            // otherwise, which doesn't give a `.app` its expected activation
            // policy and would cause a duplicate process.
            arguments = ["/usr/bin/open", "-a", appURL.path]
        } else {
            // Dev / raw executable — launch it directly. Path is captured at
            // toggle time, so if the user later moves the binary they need
            // to re-toggle.
            arguments = [Bundle.main.executablePath ?? CommandLine.arguments[0]]
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments,
            "RunAtLoad": true,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: plistURL, options: .atomic)
    }

    private static func uninstall() throws {
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    private static func appBundleURL() -> URL? {
        let path = Bundle.main.bundlePath
        return path.hasSuffix(".app") ? URL(fileURLWithPath: path) : nil
    }
}

// Native menu with a lightweight, appearance-aware settings label.

struct ModernSettingsMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]

    @State private var hovering = false

    private var selectedTitle: String {
        options.first {
            $0.0 == selection
        }?.1 ?? String(describing: selection)
    }

    var body: some View {
        Button {
            let menu = NSMenu()

            for (value, label) in options {
                let item = NSMenuItem(
                    title: label,
                    action: nil,
                    keyEquivalent: ""
                )

                let target = ShelfPopupTarget {
                    selection = value
                }

                item.target = target
                item.action = #selector(
                    ShelfPopupTarget.invoke
                )
                item.representedObject = target
                item.state = selection == value
                    ? .on : .off

                menu.addItem(item)
            }

            let location = NSEvent.mouseLocation

            menu.popUp(
                positioning: nil,
                at: location,
                in: nil
            )
        } label: {
            HStack(spacing: 8) {
                Text(selectedTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(
                        size: 10,
                        weight: .semibold
                    ))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(
                        Color.primary.opacity(0.08),
                        in: Circle()
                    )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Color.primary.opacity(
                    hovering ? 0.10 : 0.035
                ),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(selectedTitle))
    }
}

private final class ShelfPopupTarget: NSObject {
    let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func invoke() {
        handler()
    }
}

private struct ShelfSettingsContentMaterial: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        (colorScheme == .dark ? Color(white: 0.125) : Color(nsColor: .windowBackgroundColor))
            .opacity(reduceTransparency ? 1 : (colorScheme == .dark ? 0.92 : 0.94))
    }
}

private struct ShelfAdaptiveSettingsSidebar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        (colorScheme == .dark ? Color(white: 0.16) : Color(nsColor: .windowBackgroundColor))
            .opacity(reduceTransparency ? 1 : 0)
    }
}

private struct ShelfSettingsSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct ShelfDataLocationSettings: View {
    @State private var pending = ShelfDataLocation.pendingParent
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Application data"); Spacer()
                ShelfSettingsActionMenu(title: "Manage…", commands: [
                    ShelfSettingsCommand(title: "Show in Finder…") { NSWorkspace.shared.open(ShelfDataLocation.root) },
                    ShelfSettingsCommand(title: "Change Location…") {
                        ShelfFolderPicker.choose(owner: NSApp.keyWindow, initial: ShelfDataLocation.root.deletingLastPathComponent()) { url in
                            if let url { schedule(url) }
                        }
                    },
                    ShelfSettingsCommand(title: "Use Application Support") { schedule(ShelfDataLocation.defaultParent) }
                ] + (pending == nil ? [] : [ShelfSettingsCommand(title: "Cancel pending change") { ShelfDataLocation.cancel(); pending = nil }]))
            }
            Text(ShelfDataLocation.root.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            if let pending {
                Text("Next launch: copy data into \(pending). Quit normally and reopen DropShelf. The previous directory is retained as a backup.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func schedule(_ url: URL) {
        do { try ShelfDataLocation.schedule(parent: url); pending = ShelfDataLocation.pendingParent }
        catch { ShelfDataLocation.alert("Cannot change location", error.localizedDescription) }
    }
}

private struct ShelfSettingsWindowDrag: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.contentShape(Rectangle()).gesture(WindowDragGesture())
        } else {
            content
        }
    }
}
