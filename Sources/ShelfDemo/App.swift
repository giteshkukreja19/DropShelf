import AppKit
import Combine
import IOKit.pwr_mgt
import Sparkle
import SwiftUI

@main
struct ShelfDemoApp {
    @MainActor static func main() {
        // Must run before any localized lookup — NSBundle reads
        // AppleLanguages once at first resolution.
        LanguagePreference.applyAtLaunch()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        guard ShelfDataLocation.prepare() else { return }
        let delegate = AppDelegate()
        app.delegate = delegate

        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let manager = ShelfManager()
    private let folderMonitor = ShelfFolderMonitor()
    private var monitoredShelves: [UUID: UUID] = [:]
    private let shakeDetector = ShakeDetector()

    // One panel per shelf.
    private var panels: [UUID: FloatingPanel<ShelfContainerView>] = [:]
    private var expandedShelfIDs: Set<UUID> = []

    private var shakeReleaseGlobalMonitor: Any?
    private var shakeReleaseLocalMonitor: Any?
    private var pendingShelfID: UUID?
    private var itemCountOnShakeOpen: Int = 0

    // Shelves created via shake auto-close when emptied; menu-created shelves don't.
    private var ephemeralShelfIDs: Set<UUID> = []
    private var shelvesCancellable: AnyCancellable?

    // Conversion service — owns all in-progress format conversions.
    private let conversionService = ConversionService()
    private var conversionCompletedCancellable: AnyCancellable?
    private var conversionFailedCancellable: AnyCancellable?

    // OCR service — owns all in-progress OCR jobs.
    private let ocrService = OCRService()
    private var ocrCompletedSearchableCancellable: AnyCancellable?
    private var ocrCompletedExtractedCancellable: AnyCancellable?
    private var ocrFailedCancellable: AnyCancellable?

    // Sparkle-driven auto-update — owns SPUStandardUpdaterController.
    private let updateController = UpdateController()

    // Duplicate-drop toast.
    private var duplicateToastCancellable: AnyCancellable?
    private var toastPanel: NSPanel?
    private var toastHideTimer: Timer?
    private let toastVisibleDuration: TimeInterval = 2.5

    // Settings window (accessory app — created lazily, reused).
    private var settingsWindow: NSWindow?

    // Hourly check that prunes shelves whose last activity is older than the
    // user's configured retention duration (in @AppStorage as `shelf.expiryDays`).
    private var expiryTimer: Timer?

    // Polls for files that disappeared (e.g. moved to Trash from Finder) so
    // ghost entries vanish from the shelf without requiring user interaction.
    private var missingFileSweepTimer: Timer?

    private var statusItemIconCancellable: AnyCancellable?

    // Caffeine-style "Keep Mac Awake" — holds an IOKit power assertion that
    // blocks user-idle display sleep (which also blocks idle system sleep
    // and screen-saver activation as a side effect).
    private var keepAwakeAssertion: IOPMAssertionID = 0
    private var isKeepAwake: Bool = false
    // nil while indefinite or off; the original duration (in seconds) when
    // a timed activation is in flight, used both for the auto-off timer and
    // to checkmark the right item under "Activate for".
    private var keepAwakeDuration: TimeInterval?
    private var keepAwakeTimer: Timer?
    private var dropTargetActive: Bool = false

    // Auto-park only on the first empty-to-populated transition.
    private var lastItemCounts: [UUID: Int] = [:]
    private var parkedShelfIDs: Set<UUID> = []
    private var parkJobs: [UUID: Task<Void, Never>] = [:]
    private var parkTokens: [UUID: UUID] = [:]

    // Outside-click watcher: a single global mouse-down monitor that's
    // always installed; the "shelf.closeOnOutsideClick" flag is checked
    // inside the handler so toggling the setting takes effect immediately
    // without needing to install/uninstall the monitor.
    private var outsideClickMonitor: Any?
    private var shortcutGlobalMonitor: Any?
    private var shortcutLocalMonitor: Any?
    private var pasteMonitor: Any?
    private var screenCaptureActive = false

    private func applyStatusIcon(dropping: Bool? = nil, awake: Bool? = nil) {
        if let dropping { dropTargetActive = dropping }
        if let awake { isKeepAwake = awake }
        guard let button = statusItem?.button else { return }
        let isDropping = dropTargetActive
        let isAwake = isKeepAwake
        let style = UserDefaults.standard.string(forKey: "shelf.menuBarIconStyle") ?? "Traditional"
        if !isDropping && !isAwake && style != "Traditional",
           let image = NSImage(systemSymbolName: style == "Stack" ? "square.stack" : "square.fill", accessibilityDescription: "DropShelf") {
            image.isTemplate = true
            button.image = image
            return
        }
        // Custom-drawn glyph: rounded-square outline with the dot fully
        // inside the frame at the top-right (the SF `app.badge` symbol
        // parks the dot at the corner so it pokes out of the outline).
        // When keep-awake is on, the body fills solid and the corner dot
        // becomes a knockout so the icon clearly reads as "active".
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let bodyRect = rect.insetBy(dx: 1.75, dy: 1.75)
            let body = NSBezierPath(roundedRect: bodyRect, xRadius: 4, yRadius: 4)
            if isAwake {
                NSColor.black.setFill()
                body.fill()
            } else {
                body.lineWidth = 1.6
                NSColor.black.setStroke()
                body.stroke()
            }

            // Slightly larger dot when a drop is active for visual emphasis.
            let dotSize: CGFloat = isDropping ? 5 : 4
            let inset: CGFloat = 3.5
            let dotRect = NSRect(
                x: rect.maxX - inset - dotSize,
                y: rect.maxY - inset - dotSize,
                width: dotSize,
                height: dotSize
            )
            let dotPath = NSBezierPath(ovalIn: dotRect)
            if isAwake {
                // Punch the corner dot out of the filled body so the awake
                // state still has a recognizable top-right pip silhouette.
                NSGraphicsContext.current?.compositingOperation = .clear
                dotPath.fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            } else {
                NSColor.black.setFill()
                dotPath.fill()
            }
            return true
        }
        image.isTemplate = true
        button.image = image
    }

    func applyGeneralAppearance() {
        let defaults = UserDefaults.standard
        let dock = defaults.bool(forKey: "shelf.showInDock")
        let menu = defaults.object(forKey: "shelf.showInMenuBar") as? Bool ?? true
        if !dock { statusItem?.isVisible = true }
        NSApp.setActivationPolicy(dock ? .regular : .accessory)
        statusItem?.isVisible = menu || !dock
        applyStatusIcon()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettingsAction()
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Settings…", action: #selector(openSettingsAction), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    private var collapsedSize: NSSize {
        let stored = UserDefaults.standard.object(forKey: "shelf.compactSizePercent") as? Int ?? 100
        let scale = CGFloat(min(150, max(90, stored))) / 100
        return NSSize(width: 210 * scale, height: 210 * scale)
    }
    private let dockedSize = NSSize(width: 44, height: 150)
    private let dockedOffscreen: CGFloat = 18

    /// Capture the frontmost visible expanded shelf before changing the lock.
    /// Never capture a docked window or the temporary tool panel dimensions.
    func currentExpandedShelfDimensions() -> String? {
        for window in NSApp.orderedWindows {
            guard let entry = panels.first(where: { $0.value === window }),
                  window.isVisible, expandedShelfIDs.contains(entry.key),
                  !dockedShelfIDs.contains(entry.key),
                  !ShelfToolRouter.activeShelves.contains(entry.key) else { continue }
            let size = window.frame.size
            let encoded = ShelfExpandedGeometry.encode(size)
            if ShelfExpandedGeometry.decode(encoded) != nil { return encoded }
        }
        return nil
    }

    private func expandedSize(for shelfID: UUID) -> NSSize {
        let defaults = UserDefaults.standard
        let percent = defaults.object(forKey: "shelf.expandedSizePercent") as? Int ?? 100
        let fixed = defaults.bool(forKey: "shelf.fixedExpandedSize")
        let screen = panels[shelfID]?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        let preferred = ShelfExpandedGeometry.preferred(percent: percent, fixed: fixed,
            custom: defaults.string(forKey: ShelfExpandedGeometry.dimensionsKey) ?? "", visible: visible)
        if fixed { return preferred }
        let count = manager.items(of: shelfID).count
        let isList = defaults.string(forKey: "shelf.viewMode") == "list"
        let width = ShelfExpandedGeometry.adaptiveWidth(maximum: preferred.width, count: count, isList: isList)
        let height = ShelfExpandedGeometry.adaptiveHeight(width: width, count: count, isList: isList, maximum: preferred.height)
        return NSSize(width: width, height: height)
    }

    // Docked-to-edge state.
    private var dockedShelfIDs: Set<UUID> = []
    private var preDockFrames: [UUID: NSRect] = [:]
    private var dockedFrames: [UUID: NSRect] = [:]
    private var windowMoveObserver: NSObjectProtocol?
    private var suppressMoveCheck = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        folderMonitor.start { [weak self] rule, urls in
            guard let self else { return }
            let existing = self.monitoredShelves[rule.id]
            let id: UUID
            if !rule.newShelf, let existing, self.manager.shelf(id: existing) != nil { id = existing }
            else { id = self.manager.createShelf(); self.monitoredShelves[rule.id] = id; self.manager.renameShelf(id: id, to: URL(fileURLWithPath: rule.path).lastPathComponent) }
            for url in urls where !self.manager.containsFile(url: url, in: id) { _ = self.manager.addFile(url: url, to: id) }
            if !self.manager.items(of: id).isEmpty, self.panels[id]?.isVisible != true { self.openPanel(for: id, nearCursor: false) }
        }
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "shelf.compactLayoutMigration2") {
            if defaults.string(forKey: ShelfExpandedGeometry.dimensionsKey) == "520,340" {
                defaults.removeObject(forKey: ShelfExpandedGeometry.dimensionsKey)
            }
            defaults.set(true, forKey: "shelf.compactLayoutMigration2")
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyStatusIcon(dropping: false)
        // Flip the glyph while any panel is being targeted by a drop so the
        // menubar mirrors the "ready to receive" state visually.
        statusItemIconCancellable = manager.$isAnyShelfDropTarget
            .removeDuplicates()
            .sink { [weak self] dropping in
                self?.applyStatusIcon(dropping: dropping)
            }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        applyGeneralAppearance()

        shakeDetector.shouldSuppress = { [weak self] in self?.manager.isDragging == true }
        shakeDetector.shouldSuppressAutomatic = { [weak self] in
            self?.panels.values.contains(where: { $0.isVisible }) ?? false
        }
        shakeDetector.onShake = { [weak self] in self?.handleShake() }
        shakeDetector.start()

        QuickLookController.shared.urlsProvider = { [weak self] in
            self?.urlsForKeyPanel() ?? []
        }

        installPasteShortcut()
        installShelfShortcuts()

        shelvesCancellable = manager.$shelves
            .sink { [weak self] shelves in
                self?.reconcileEmptyEphemeralShelves(shelves)
                self?.checkAutoPark(shelves)
            }

        installOutsideClickWatcher()

        duplicateToastCancellable = manager.duplicateRejected
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] shelfID in
                self?.showDuplicateToast(for: shelfID)
            }

        conversionCompletedCancellable = conversionService.completed
            .sink { [weak self] (url, shelfID) in
                guard let self else { return }
                self.manager.addFile(url: url, to: shelfID)
            }

        conversionFailedCancellable = conversionService.failed
            .sink { [weak self] error in
                // .cancelled is silent — the user initiated it, no toast needed.
                guard error != .cancelled else { return }
                self?.showConversionFailureToast(message: error.displayMessage)
            }

        ocrCompletedSearchableCancellable = ocrService.completedSearchable
            .sink { [weak self] (url, shelfID) in
                self?.manager.addFile(url: url, to: shelfID)
            }

        ocrCompletedExtractedCancellable = ocrService.completedExtracted
            .sink { [weak self] (text, shelfID) in
                self?.manager.addText(text, to: shelfID)
            }

        ocrFailedCancellable = ocrService.failed
            .sink { [weak self] error in
                guard error != .cancelled else { return }
                self?.showConversionFailureToast(message: error.displayMessage)
            }

        runShelfExpiryPrune()
        expiryTimer = Timer.scheduledTimer(
            withTimeInterval: 60, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.runShelfExpiryPrune() }
        }

        // Sweep stale entries (files trashed from Finder while we were idle).
        // App activation isn't reliable for an accessory app, so back it up
        // with a low-frequency timer that runs unconditionally — fileExists
        // is cheap and the worst case is a few dozen stat calls per tick.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppOrFocusChange),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        manager.scheduleMissingFileSweep()
        missingFileSweepTimer = Timer.scheduledTimer(
            withTimeInterval: 2.0, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.manager.scheduleMissingFileSweep() }
        }
    }

    @objc private func handleAppOrFocusChange() {
        manager.scheduleMissingFileSweep()
    }

    private func runShelfExpiryPrune() {
        let days = UserDefaults.standard.integer(forKey: "shelf.expiryDays")
        guard days != 0, !manager.isDragging, !screenCaptureActive else { return }
        let removed = manager.pruneShelves(olderThanDays: days)
        for shelfID in removed {
            panels[shelfID]?.orderOut(nil)
            panels.removeValue(forKey: shelfID)
            ephemeralShelfIDs.remove(shelfID)
        }
        if manager.shelves.isEmpty {
            _ = manager.createShelf()
        }
    }

    private func urlsForKeyPanel() -> [URL] {
        guard let (shelfID, _) = panels.first(where: { $0.value.isKeyWindow })
                ?? panels.first(where: { $0.value.isVisible })
        else { return [] }
        guard !ShelfToolRouter.activeShelves.contains(shelfID) else { return [] }
        return manager.items(of: shelfID).compactMap { $0.fileURL }
    }

    // MARK: - Status menu

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            self.rebuildStatusMenu(menu)
        }
    }

    @objc private func toggleScreenRecording() {
        if #available(macOS 15.0, *) {
            Task { @MainActor in
                let recorder = ShelfScreenRecorder.shared
                if recorder.recording { await recorder.stop() } else if !recorder.busy { recorder.openLauncher() }
            }
        }
    }

    private func rebuildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let keepAwake = NSMenuItem(
            title: L("Keep Mac Awake"),
            action: #selector(toggleKeepAwakeAction),
            keyEquivalent: ""
        )
        keepAwake.target = self
        keepAwake.state = isKeepAwake ? .on : .off
        menu.addItem(keepAwake)

        let activateFor = NSMenuItem(title: L("Activate for"), action: nil, keyEquivalent: "")
        activateFor.submenu = buildKeepAwakeDurationsMenu()
        menu.addItem(activateFor)

        menu.addItem(.separator())

        let newShelf = NSMenuItem(
            title: L("New Shelf"),
            action: #selector(newShelfAction),
            keyEquivalent: "n"
        )
        newShelf.target = self
        ShelfShortcut.new.configure(newShelf)
        menu.addItem(newShelf)

        let newFromClip = NSMenuItem(
            title: L("New Shelf From Clipboard"),
            action: #selector(newShelfFromClipboardAction),
            keyEquivalent: "a"
        )
        newFromClip.target = self
        ShelfShortcut.clipboard.configure(newFromClip)
        menu.addItem(newFromClip)

        let captureScreen = NSMenuItem(
            title: L("Capture Screen Text…"),
            action: #selector(captureScreenTextAction),
            keyEquivalent: "c"
        )
        captureScreen.target = self
        ShelfShortcut.capture.configure(captureScreen)
        menu.addItem(captureScreen)
        if #available(macOS 15.0, *) {
            let recorder = ShelfScreenRecorder.shared
            if UserDefaults.standard.bool(forKey: "recorder.enabled") || recorder.busy {
                let item = NSMenuItem(title: recorder.busy ? "Stop Screen Recording" : "Record Screen…", action: #selector(toggleScreenRecording), keyEquivalent: "")
                (recorder.busy ? ShelfShortcut.stopRecording : ShelfShortcut.recordingControls).configure(item)
                item.target = self
                item.isEnabled = !recorder.busy || recorder.recording
                menu.addItem(item)
            }
        }

        let recent = NSMenuItem(title: L("Recent Shelves"), action: nil, keyEquivalent: "")
        recent.submenu = buildRecentShelvesMenu()
        menu.addItem(recent)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: L("Settings…"),
            action: #selector(openSettingsAction),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        // Wire the menu item directly to SPUStandardUpdaterController so AppKit's
        // responder chain calls its `validateMenuItem(_:)` — the item auto-grays
        // out while a check or download is already in flight.
        let checkUpdates = NSMenuItem(
            title: L("Check for Updates…"),
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkUpdates.target = updateController.updaterController
        menu.addItem(checkUpdates)

        let quit = NSMenuItem(
            title: L("Quit"),
            action: #selector(NSApp.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)
    }

    @objc private func toggleKeepAwakeAction() {
        setKeepAwake(!isKeepAwake)
    }

    @objc private func keepAwakeForAction(_ sender: NSMenuItem) {
        // representedObject carries the duration in seconds; nil = indefinite.
        let duration = sender.representedObject as? TimeInterval
        setKeepAwake(true, duration: duration)
    }

    /// Holds (or releases) an IOKit power-management assertion that prevents
    /// idle display sleep — which transitively blocks idle system sleep and
    /// the screen saver, matching Caffeine's behavior. When `duration` is
    /// non-nil, schedules an auto-off timer for that many seconds.
    private func setKeepAwake(_ enabled: Bool, duration: TimeInterval? = nil) {
        keepAwakeTimer?.invalidate()
        keepAwakeTimer = nil

        if enabled {
            if !isKeepAwake {
                var assertion: IOPMAssertionID = 0
                let result = IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    "DropShelf keep-awake" as CFString,
                    &assertion
                )
                guard result == kIOReturnSuccess else { return }
                keepAwakeAssertion = assertion
                applyStatusIcon(awake: true)
            }
            keepAwakeDuration = duration
            if let duration {
                keepAwakeTimer = Timer.scheduledTimer(
                    withTimeInterval: duration, repeats: false
                ) { [weak self] _ in
                    Task { @MainActor in self?.setKeepAwake(false) }
                }
            }
        } else if isKeepAwake {
            IOPMAssertionRelease(keepAwakeAssertion)
            keepAwakeAssertion = 0
            keepAwakeDuration = nil
            applyStatusIcon(awake: false)
        }
    }

    private func buildKeepAwakeDurationsMenu() -> NSMenu {
        let submenu = NSMenu()
        // (title, duration in seconds; nil = indefinite)
        let options: [(String, TimeInterval?)] = [
            (L("Indefinitely"), nil),
            (L("5 minutes"),  5 * 60),
            (L("10 minutes"), 10 * 60),
            (L("15 minutes"), 15 * 60),
            (L("20 minutes"), 20 * 60),
            (L("1 hour"),     60 * 60),
            (L("2 hours"),    2 * 60 * 60),
            (L("3 hours"),    3 * 60 * 60),
            (L("5 hours"),    5 * 60 * 60),
        ]
        for (title, duration) in options {
            let item = NSMenuItem(
                title: title,
                action: #selector(keepAwakeForAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = duration
            // Tick the row that matches the current state. "Indefinitely"
            // matches when keep-awake is on with no auto-off timer.
            if isKeepAwake, duration == keepAwakeDuration {
                item.state = .on
            }
            submenu.addItem(item)
        }
        return submenu
    }

    @objc private func openSettingsAction() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 660), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            // Set once at creation; the title doesn't refresh on language
            // change. Pre-existing accepted limitation from v1.4.
            window.title = "DropShelf Settings"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
            window.isMovable = true
            window.isMovableByWindowBackground = true
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.toolbar = nil
            window.appearance = nil
            window.backgroundColor = .clear
            window.isOpaque = false
            // The hosting view fills a native material container, including
            // the titlebar. A transparent titlebar alone leaves the backing
            // window surface visible above SwiftUI's safe area.
            let container = NSVisualEffectView(frame: hosting.view.frame)
            container.material = .sidebar
            container.blendingMode = .behindWindow
            container.state = .followsWindowActiveState
            let controller = NSViewController()
            controller.view = container
            controller.addChild(hosting)
            hosting.view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(hosting.view)
            NSLayoutConstraint.activate([
                hosting.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                hosting.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                hosting.view.topAnchor.constraint(equalTo: container.topAnchor),
                hosting.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            window.contentViewController = controller
            window.contentMinSize = NSSize(width: 680, height: 520)
            window.setContentSize(NSSize(width: 700, height: 660))
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("DropShelfSettingsWindowCompactV4")
            settingsWindow = window
        }
        // Accessory app: temporarily bring to front so the window receives focus.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func buildRecentShelvesMenu() -> NSMenu {
        let submenu = NSMenu()

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true

        // Pinned shelves float to the top; remaining shelves stay in
        // most-recent-first order (the tail of the array is newest).
        let nonEmpty = manager.shelves.filter { !$0.items.isEmpty }
        let pinned = nonEmpty.filter { $0.pinned }.reversed()
        let rest = nonEmpty.filter { !$0.pinned }.reversed()
        let ordered = Array(pinned) + Array(rest)

        var shown = 0
        for shelf in ordered {
            shown += 1
            let item = NSMenuItem(
                title: "",
                action: #selector(openShelfAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = shelf.id

            let title: String
            let displayName = shelf.displayShelfName(intelligent: UserDefaults.standard.bool(forKey: "shelf.intelligentNames"))
            if let n = displayName {
                title = n
            } else if shelf.items.count == 1 {
                title = shelf.items[0].displayName
            } else {
                title = String(format: L("%lld Files"), shelf.items.count)
            }
            var subtitle = formatter.string(from: shelf.createdAt)
            if displayName != nil {
                let count = shelf.items.count == 1
                    ? L("1 file")
                    : String(format: L("%lld files"), shelf.items.count)
                subtitle = "\(count) · \(subtitle)"
            }

            let attr = NSMutableAttributedString()
            if shelf.pinned {
                let pin = NSTextAttachment()
                pin.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
                attr.append(NSAttributedString(attachment: pin))
                attr.append(NSAttributedString(string: " "))
            }
            attr.append(NSAttributedString(string: title + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ]))
            attr.append(NSAttributedString(string: subtitle, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            item.attributedTitle = attr

            if let accentImage = recentMenuIcon(for: shelf) {
                item.image = accentImage
            } else if let first = shelf.items.first, let url = first.fileURL {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 28, height: 28)
                item.image = icon
            }
            submenu.addItem(item)
        }

        if shown == 0 {
            let empty = NSMenuItem(title: L("No Recent Shelves"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            submenu.addItem(.separator())
            let clear = NSMenuItem(
                title: L("Clear Recent Shelves"),
                action: #selector(clearAllShelvesAction),
                keyEquivalent: ""
            )
            clear.target = self
            submenu.addItem(clear)
        }

        return submenu
    }

    /// When the shelf has an accent (color or emoji), render a 28×28 swatch
    /// for the menu item icon so the accent dominates the visual identity.
    /// Returns nil when no accent is set, letting the caller fall back to
    /// the file icon.
    private func recentMenuIcon(for shelf: Shelf) -> NSImage? {
        guard let accent = shelf.accent else { return nil }
        let size = NSSize(width: 28, height: 28)
        switch accent {
        case .color(let hex):
            return NSImage(size: size, flipped: false) { rect in
                let path = NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4))
                (NSColor(hex: hex) ?? .systemGray).setFill()
                path.fill()
                NSColor.black.withAlphaComponent(0.15).setStroke()
                path.lineWidth = 0.5
                path.stroke()
                return true
            }
        case .emoji(let glyph):
            return NSImage(size: size, flipped: false) { rect in
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 18)
                ]
                let s = (glyph as NSString)
                let measured = s.size(withAttributes: attrs)
                let origin = NSPoint(
                    x: rect.midX - measured.width / 2,
                    y: rect.midY - measured.height / 2
                )
                s.draw(at: origin, withAttributes: attrs)
                return true
            }
        }
    }

    @objc private func newShelfAction() {
        let shelfID = manager.createShelf()
        openPanel(for: shelfID, nearCursor: false)
    }

    @objc private func newShelfFromClipboardAction() {
        let shelfID = manager.createShelf()
        _ = manager.addFromClipboard(to: shelfID)
        openPanel(for: shelfID, nearCursor: false)
    }

    @objc private func captureScreenTextAction() {
        guard !screenCaptureActive else { return }
        screenCaptureActive = true
        Task { @MainActor in
            defer { screenCaptureActive = false }
            do {
                guard let text = try await ScreenOCR.captureAndExtractText() else { return }
                let shelfID = activeOrNewShelfID()
                manager.addText(text, to: shelfID)
                openPanel(for: shelfID, nearCursor: false)
                if let panel = panels[shelfID] {
                    if dockedShelfIDs.contains(shelfID) {
                        setPanelDocked(shelfID, docked: false)
                        manager.undockRequested.send(shelfID)
                    }
                    manager.revealRequested.send(shelfID)
                    panel.orderFrontRegardless()
                    showToast(L("Text copied to clipboard"), near: panel)
                }
            } catch let error as OCRError {
                guard error != .cancelled else { return }
                showConversionFailureToast(message: error.displayMessage)
            } catch {
                showConversionFailureToast(message: error.localizedDescription)
            }
        }
    }

    private func activeOrNewShelfID() -> UUID {
        if let keyID = panels.first(where: { $0.value.isKeyWindow })?.key {
            return keyID
        }
        if let visibleID = panels.first(where: { $0.value.isVisible })?.key {
            return visibleID
        }
        if let lastID = manager.shelves.last?.id {
            return lastID
        }
        return manager.createShelf()
    }

    @objc private func openShelfAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        openPanel(for: id, nearCursor: false)
    }

    @objc private func clearAllShelvesAction() {
        // Pinned shelves are deliberately preserved — the pin is the user's
        // signal to keep that shelf around regardless of cleanup actions, and
        // matches the auto-expiry behavior (which also skips pinned shelves).
        for shelf in manager.shelves where !shelf.pinned && !ShelfToolRouter.activeShelves.contains(shelf.id) {
            panels[shelf.id]?.orderOut(nil)
            panels.removeValue(forKey: shelf.id)
            manager.removeShelf(id: shelf.id)
            ephemeralShelfIDs.remove(shelf.id)
        }
        if manager.shelves.isEmpty {
            _ = manager.createShelf()
        }
    }

    // MARK: - Shake

    private func handleShake() {
        guard !manager.isDragging, !DragInitiatorView.hasActiveDrag else { return }
        // Ignore further shakes while a shake-created shelf is still pending.
        // Otherwise rapid shakes pile up panels and only the latest one's
        // release watcher survives, leaving earlier empties on screen.
        if let pending = pendingShelfID,
           let panel = panels[pending], panel.isVisible {
            return
        }
        let shelfID = manager.createShelf()
        ephemeralShelfIDs.insert(shelfID)
        pendingShelfID = shelfID
        itemCountOnShakeOpen = 0
        openPanel(for: shelfID, nearCursor: true)
        armShakeReleaseWatcher(for: shelfID)
    }

    private func armShakeReleaseWatcher(for shelfID: UUID) {
        disarmShakeReleaseWatcher()

        let handle: (NSEvent) -> Void = { [weak self] _ in
            guard let self else { return }
            self.disarmShakeReleaseWatcher()
            // Drop handlers run asynchronously after mouseUp — NSItemProvider
            // load + temp-file write + MainActor hop. 1.2s gives the chain
            // time to land before we decide whether to close the shelf.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                if self.manager.items(of: shelfID).count == self.itemCountOnShakeOpen,
                   let panel = self.panels[shelfID], panel.isVisible {
                    panel.orderOut(nil)
                    self.manager.removeShelf(id: shelfID)
                    self.panels.removeValue(forKey: shelfID)
                    self.ephemeralShelfIDs.remove(shelfID)
                }
                self.pendingShelfID = nil
            }
        }

        shakeReleaseGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .leftMouseUp
        ) { event in
            handle(event)
        }
        shakeReleaseLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .leftMouseUp
        ) { event in
            handle(event)
            return event
        }
    }

    // MARK: - Auto-close on empty

    private func reconcileEmptyEphemeralShelves(_ shelves: [Shelf]) {
        let existingIDs = Set(shelves.map { $0.id })

        // Drop tracking for shelves that no longer exist.
        ephemeralShelfIDs.formIntersection(existingIDs)
        dockedShelfIDs.formIntersection(existingIDs)
        preDockFrames = preDockFrames.filter { existingIDs.contains($0.key) }
        // A populated shelf stays open until explicitly dismissed.
        expandedShelfIDs.formIntersection(existingIDs)
        dockedFrames = dockedFrames.filter { existingIDs.contains($0.key) }
        ShelfToolRouter.activeShelves.formIntersection(existingIDs)
    }

    private func disarmShakeReleaseWatcher() {
        if let m = shakeReleaseGlobalMonitor { NSEvent.removeMonitor(m) }
        if let m = shakeReleaseLocalMonitor { NSEvent.removeMonitor(m) }
        shakeReleaseGlobalMonitor = nil
        shakeReleaseLocalMonitor = nil
    }

    // MARK: - Panel management

    private func openPanel(for shelfID: UUID, nearCursor: Bool) {
        // Drop any items whose files have disappeared since we last looked,
        // so a freshly-opened panel never shows ghost entries.
        manager.scheduleMissingFileSweep()

        let panel: FloatingPanel<ShelfContainerView>
        if let existing = panels[shelfID] {
            panel = existing
        } else {
            panel = makePanel(for: shelfID)
            panels[shelfID] = panel
        }

        let expanded = expandedShelfIDs.contains(shelfID)
        let size = expanded ? expandedSize(for: shelfID) : collapsedSize

        if ShelfToolRouter.activeShelves.contains(shelfID) {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        if nearCursor {
            cancelPark(shelfID)
            positionPanelNearCursor(panel, size: size)
        } else if panel.frame.size == .zero || !panel.isVisible {
            positionPanelBelowStatusItem(panel, size: size)
        }

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func hideIdleDockedPanel(for shelfID: UUID) {
        guard let panel = panels[shelfID], panel.isVisible,
              dockedShelfIDs.contains(shelfID),
              manager.shelf(id: shelfID)?.pinned != true,
              !manager.items(of: shelfID).isEmpty else { return }
        // Keep the shelf model; discard only the window so reopening starts clean.
        panel.orderOut(nil)
        panels.removeValue(forKey: shelfID)
        dockedShelfIDs.remove(shelfID)
        dockedFrames.removeValue(forKey: shelfID)
        preDockFrames.removeValue(forKey: shelfID)
        expandedShelfIDs.remove(shelfID)
        if dockedShelfIDs.isEmpty { removeWindowMoveObserver() }
    }

    private func hidePanel(for shelfID: UUID) {
        cancelPark(shelfID)
        panels[shelfID]?.orderOut(nil)
        // Empty shelves are invisible in Recent Shelves, so dismissing them
        // would otherwise leave a zombie behind. Tear them down completely
        // when the user clicks X on an empty shelf.
        if manager.items(of: shelfID).isEmpty {
            panels.removeValue(forKey: shelfID)
            ephemeralShelfIDs.remove(shelfID)
            manager.removeShelf(id: shelfID)
        }
    }

    private func makePanel(for shelfID: UUID) -> FloatingPanel<ShelfContainerView> {
        let rect = NSRect(origin: .zero, size: collapsedSize)
        let isEphemeral = ephemeralShelfIDs.contains(shelfID)
        return FloatingPanel(contentRect: rect) { [weak self, manager, conversionService, ocrService] in
            ShelfContainerView(
                manager: manager,
                conversionService: conversionService,
                ocrService: ocrService,
                shelfID: shelfID,
                isEphemeral: isEphemeral,
                onClose: { self?.hidePanel(for: shelfID) },
                onIdleHideDocked: { self?.hideIdleDockedPanel(for: shelfID) },
                onResize: { expanded in self?.setPanelExpanded(shelfID, expanded: expanded) },
                onDockChanged: { docked in self?.setPanelDocked(shelfID, docked: docked) },
                sizeForShelf: { expanded in
                    guard let self else { return .zero }
                    return expanded ? self.expandedSize(for: shelfID) : self.collapsedSize
                }
            )
        }
    }

    private func setPanelExpanded(_ shelfID: UUID, expanded: Bool) {
        if expanded { expandedShelfIDs.insert(shelfID) } else { expandedShelfIDs.remove(shelfID) }
        guard !ShelfToolRouter.activeShelves.contains(shelfID), !dockedShelfIDs.contains(shelfID), let panel = panels[shelfID] else { return }

        guard !panel.inLiveResize else { return }
        let newSize = expanded ? expandedSize(for: shelfID) : collapsedSize
        guard abs(panel.frame.width - newSize.width) > 1 || abs(panel.frame.height - newSize.height) > 1 else { return }
        let shouldRepark = parkJobs[shelfID] != nil
        if shouldRepark { cancelPark(shelfID) }

        let currentFrame = panel.frame
        let topY = currentFrame.maxY
        let centerX = currentFrame.midX

        var originX = centerX - newSize.width / 2
        var originY = topY - newSize.height

        if let screenFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            originX = max(screenFrame.minX + 8,
                          min(originX, screenFrame.maxX - newSize.width - 8))
            originY = max(screenFrame.minY + 8, min(originY, screenFrame.maxY - newSize.height - 8))
        }

        let newFrame = NSRect(x: originX, y: originY,
                              width: newSize.width, height: newSize.height)

        if abs(panel.frame.width - newFrame.width) > 1 || abs(panel.frame.height - newFrame.height) > 1 {
            animate(panel: panel, to: newFrame)
        }
        if shouldRepark { schedulePark(shelfID, delay: 520_000_000) }
    }

    private func setPanelDocked(_ shelfID: UUID, docked: Bool) {
        guard !ShelfToolRouter.activeShelves.contains(shelfID), let panel = panels[shelfID] else { return }

        cancelPark(shelfID)
        if docked {
            let frame = panel.frame
            let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
            preDockFrames[shelfID] = NSRect(x: max(visible.minX, min(frame.minX, visible.maxX - frame.width)),
                                           y: max(visible.minY, min(frame.minY, visible.maxY - frame.height)),
                                           width: frame.width, height: frame.height)
            dockedShelfIDs.insert(shelfID)
            installWindowMoveObserverIfNeeded()

            let currentFrame = panel.frame
            let screenFrame = panel.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? currentFrame
            // Position so the right-side curve sits past the screen edge,
            // giving a flat flush-to-edge look on the visible side.
            let originX = screenFrame.maxX - dockedSize.width + dockedOffscreen
            var originY = currentFrame.midY - dockedSize.height / 2
            originY = max(screenFrame.minY + 4,
                          min(originY, screenFrame.maxY - dockedSize.height - 4))
            let newFrame = NSRect(
                x: originX, y: originY,
                width: dockedSize.width, height: dockedSize.height
            )
            dockedFrames[shelfID] = newFrame
            animate(panel: panel, to: newFrame)
        } else {
            dockedShelfIDs.remove(shelfID)
            dockedFrames.removeValue(forKey: shelfID)
            if dockedShelfIDs.isEmpty { removeWindowMoveObserver() }
            let size = expandedShelfIDs.contains(shelfID) ? expandedSize(for: shelfID) : collapsedSize
            var restore: NSRect
            if let saved = preDockFrames.removeValue(forKey: shelfID) {
                restore = NSRect(x: saved.midX - size.width / 2, y: saved.maxY - size.height,
                                 width: size.width, height: size.height)
            } else {
                let currentFrame = panel.frame
                let screenFrame = panel.screen?.visibleFrame
                    ?? NSScreen.main?.visibleFrame
                    ?? currentFrame
                let originX = max(screenFrame.minX + 8,
                                  screenFrame.maxX - size.width - 8)
                let originY = max(screenFrame.minY + 8,
                                  currentFrame.midY - size.height / 2)
                restore = NSRect(origin: NSPoint(x: originX, y: originY), size: size)
            }
            if let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
                restore = ShelfExpandedGeometry.clampedFrame(restore, in: visible)
            }
            animate(panel: panel, to: restore)
        }
    }

    // MARK: - Auto-park

    private func checkAutoPark(_ shelves: [Shelf]) {
        let live = Set(shelves.map(\.id))
        for id in Array(parkJobs.keys) where !live.contains(id) { cancelPark(id) }
        parkedShelfIDs.formIntersection(live)
        lastItemCounts = lastItemCounts.filter { live.contains($0.key) }
        let enabled = UserDefaults.standard.bool(forKey: "shelf.autoParkTopRight")
        for shelf in shelves {
            let previous = lastItemCounts[shelf.id]
            let prev = previous ?? 0
            let now = shelf.items.count
            lastItemCounts[shelf.id] = now
            if now == 0 { cancelPark(shelf.id) }
            if enabled, previous != nil, prev == 0, now > 0, !parkedShelfIDs.contains(shelf.id) {
                parkedShelfIDs.insert(shelf.id)
                schedulePark(shelf.id)
            }
        }
    }

    private func cancelPark(_ id: UUID) {
        parkJobs.removeValue(forKey: id)?.cancel()
        parkTokens.removeValue(forKey: id)
    }

    private func schedulePark(_ id: UUID, delay: UInt64 = 180_000_000) {
        cancelPark(id)
        let token = UUID()
        parkTokens[id] = token
        parkJobs[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.parkTokens[id] == token {
                    self.parkJobs.removeValue(forKey: id)
                    self.parkTokens.removeValue(forKey: id)
                }
            }
            do {
                try await Task.sleep(nanoseconds: delay)
                // Let the drag finish before moving its destination.
                for _ in 0..<40 {
                    if !self.manager.isDragging && !DragInitiatorView.hasActiveDrag && NSEvent.pressedMouseButtons == 0 { break }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                guard !Task.isCancelled, !self.manager.isDragging,
                      !DragInitiatorView.hasActiveDrag, NSEvent.pressedMouseButtons == 0,
                      UserDefaults.standard.bool(forKey: "shelf.autoParkTopRight"),
                      let panel = self.panels[id], panel.isVisible, !panel.inLiveResize,
                      !self.dockedShelfIDs.contains(id), !ShelfToolRouter.activeShelves.contains(id),
                      !self.manager.items(of: id).isEmpty else { return }
                let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
                let position = ShelfScreenPosition(rawValue: UserDefaults.standard.string(forKey: "shelf.autoParkPosition") ?? "") ?? .topRight
                let occupied = self.panels.compactMap { entry -> NSRect? in
                    guard entry.key != id, entry.value.isVisible, entry.value.frame.intersects(screen) else { return nil }
                    return entry.value.frame
                }
                let start = panel.frame.origin
                let target = position.origin(for: panel.frame.size, in: screen, avoiding: occupied)
                let distance = hypot(target.x - start.x, target.y - start.y)
                guard distance > 1 else { return }
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    panel.setFrameOrigin(target)
                    return
                }
                // Animate only the origin, never rebuild the shelf or resize its
                // content on every frame. Time-based interpolation avoids jumps
                // when a frame is delayed. User input can interrupt the glide.
                let duration = min(0.85, max(0.35, Double(distance) / 1450 + 0.20))
                let began = ProcessInfo.processInfo.systemUptime
                while true {
                    try Task.checkCancellation()
                    guard panel.isVisible, self.panels[id] === panel, !panel.inLiveResize,
                          !self.dockedShelfIDs.contains(id), !ShelfToolRouter.activeShelves.contains(id),
                          !self.manager.isDragging, !DragInitiatorView.hasActiveDrag,
                          NSEvent.pressedMouseButtons == 0,
                          UserDefaults.standard.bool(forKey: "shelf.autoParkTopRight"),
                          !self.manager.items(of: id).isEmpty else { return }
                    let elapsed = ProcessInfo.processInfo.systemUptime - began
                    let t = ShelfScreenPosition.progress(elapsed / duration)
                    panel.setFrameOrigin(NSPoint(x: start.x + (target.x - start.x) * t,
                                                 y: start.y + (target.y - start.y) * t))
                    if elapsed >= duration { break }
                    try await Task.sleep(nanoseconds: 16_666_667)
                }
            } catch { /* Cancelled by a new resize, user action or shutdown. */ }
        }
    }

    // MARK: - Close on outside click

    private func installOutsideClickWatcher() {
        guard outsideClickMonitor == nil else { return }
        // Global monitor only fires for clicks NOT in our app, so clicks on
        // the panels themselves (and on our menu bar item) don't trigger
        // this — exactly the semantics we want.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleOutsideClick()
            }
        }
    }

    private func handleOutsideClick() {
        guard UserDefaults.standard.bool(forKey: "shelf.closeOnOutsideClick") else { return }
        let visible = panels.filter { $0.value.isVisible }
        guard !visible.isEmpty else { return }
        let location = NSEvent.mouseLocation
        // Inside-panel safety net: a click that lands on a panel's frame is
        // treated as inside even if the global monitor still routed it to
        // us (e.g. the panel is non-activating and the OS counted the click
        // as "outside the app").
        let inside = visible.contains { $0.value.frame.contains(location) }
        guard !inside else { return }
        // Only collapse panels that are currently in expanded mode — the
        // user wants the detail view to fold back to the pill, not for the
        // whole shelf to disappear.
        for shelfID in expandedShelfIDs where visible.keys.contains(shelfID) {
            manager.collapseRequested.send(shelfID)
        }
    }

    private func animate(panel: NSPanel, to frame: NSRect) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(frame, display: true)
            return
        }
        suppressMoveCheck = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.9, 0.3, 1.0)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            self?.suppressMoveCheck = false
        })
    }

    // MARK: - Docked drag-off detection

    private func installWindowMoveObserverIfNeeded() {
        guard windowMoveObserver == nil else { return }
        windowMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSPanel else { return }
            Task { @MainActor in self.handleDockedPanelMoved(window) }
        }
    }

    private func removeWindowMoveObserver() {
        if let obs = windowMoveObserver {
            NotificationCenter.default.removeObserver(obs)
            windowMoveObserver = nil
        }
    }

    private func handleDockedPanelMoved(_ window: NSPanel) {
        if suppressMoveCheck { return }
        guard let (shelfID, _) = panels.first(where: { $0.value === window }) else { return }
        guard dockedShelfIDs.contains(shelfID) else { return }
        guard let anchored = dockedFrames[shelfID] else { return }

        let dx = abs(window.frame.minX - anchored.minX)
        let dy = abs(window.frame.minY - anchored.minY)
        guard dx > 4 || dy > 4 else { return }

        undockInPlace(shelfID: shelfID, fromFrame: window.frame)
    }

    private func undockInPlace(shelfID: UUID, fromFrame: NSRect) {
        guard let panel = panels[shelfID] else { return }
        dockedShelfIDs.remove(shelfID)
        dockedFrames.removeValue(forKey: shelfID)
        preDockFrames.removeValue(forKey: shelfID)
        if dockedShelfIDs.isEmpty { removeWindowMoveObserver() }

        let size = expandedShelfIDs.contains(shelfID) ? expandedSize(for: shelfID) : collapsedSize
        // Keep the current top-left roughly where the user let go.
        let topY = fromFrame.maxY
        let newFrame = NSRect(
            x: fromFrame.minX,
            y: topY - size.height,
            width: size.width,
            height: size.height
        )
        animate(panel: panel, to: newFrame)
        manager.undockRequested.send(shelfID)
    }

    // MARK: - Positioning

    private func positionPanelNearCursor(_ panel: NSPanel, size: NSSize) {
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = ShelfExpandedGeometry.fit(size, within: frame.size, margin: 12)

        let edgeMargin: CGFloat = 12
        let dockThreshold: CGFloat = 72
        let cursorGap: CGFloat = 16

        let distLeft = cursor.x - frame.minX
        let distRight = frame.maxX - cursor.x
        let distTop = frame.maxY - cursor.y
        let distBottom = cursor.y - frame.minY

        var originX: CGFloat
        if distRight < dockThreshold {
            originX = frame.maxX - size.width - edgeMargin
        } else if distLeft < dockThreshold {
            originX = frame.minX + edgeMargin
        } else {
            let rightCandidate = cursor.x + cursorGap
            originX = rightCandidate + size.width <= frame.maxX - edgeMargin
                ? rightCandidate
                : cursor.x - size.width - cursorGap
        }

        var originY: CGFloat
        if distTop < dockThreshold {
            originY = frame.maxY - size.height - edgeMargin
        } else if distBottom < dockThreshold {
            originY = frame.minY + edgeMargin
        } else {
            let belowCandidate = cursor.y - size.height - cursorGap
            originY = belowCandidate >= frame.minY + edgeMargin
                ? belowCandidate
                : cursor.y + cursorGap
        }

        originX = max(frame.minX + edgeMargin,
                      min(originX, frame.maxX - size.width - edgeMargin))
        originY = max(frame.minY + edgeMargin,
                      min(originY, frame.maxY - size.height - edgeMargin))

        panel.setFrame(
            NSRect(origin: NSPoint(x: originX, y: originY), size: size),
            display: true
        )
    }

    private func positionPanelBelowStatusItem(_ panel: NSPanel, size: NSSize) {
        let location = UserDefaults.standard.string(forKey: "shelf.defaultLocation") ?? "Menu bar"
        if let position = ShelfScreenPosition(rawValue: location),
           let frame = (statusItem.button?.window?.screen ?? NSScreen.main)?.visibleFrame {
            let fitted = NSSize(width: min(size.width, max(1, frame.width - 24)), height: min(size.height, max(1, frame.height - 24)))
            panel.setFrame(NSRect(origin: position.origin(for: fitted, in: frame), size: fitted), display: true)
            return
        }
        guard
            let button = statusItem.button,
            let buttonWindow = button.window
        else {
            if let frame = NSScreen.main?.visibleFrame {
                let fitted = ShelfExpandedGeometry.fit(size, within: frame.size)
                panel.setFrame(NSRect(origin: ShelfScreenPosition.topRight.origin(for: fitted, in: frame), size: fitted), display: true)
            }
            return
        }

        let buttonFrameOnScreen = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil)
        )
        let screenFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let size = ShelfExpandedGeometry.fit(size, within: screenFrame.size)
        let gap: CGFloat = 8

        var originX = buttonFrameOnScreen.midX - size.width / 2
        originX = max(screenFrame.minX + 8,
                      min(originX, screenFrame.maxX - size.width - 8))
        let originY = max(screenFrame.minY + 8, buttonFrameOnScreen.minY - size.height - gap)

        panel.setFrame(NSRect(origin: NSPoint(x: originX, y: originY), size: size),
                       display: true)
    }

    // MARK: - Duplicate toast

    private func showDuplicateToast(for shelfID: UUID) {
        guard let shelfPanel = panels[shelfID], shelfPanel.isVisible else { return }
        showToast(L("toast.duplicate"), near: shelfPanel)
    }

    private func showConversionFailureToast(message: String) {
        // Reuse the toast panel infrastructure with custom text. If no shelf
        // panel is currently visible, fall back to a banner attached to the
        // first available shelf, or no-op (we'd rather drop the toast than
        // pop a modal).
        guard let firstVisible = panels.first(where: { $0.value.isVisible }) else {
            NSLog("Shelf: \(message) (no visible panel for toast)")
            return
        }
        showToast(message, near: firstVisible.value)
    }

    private func showToast(_ message: String, near shelfPanel: NSPanel) {
        let panel = makeToastPanel(message: message)
        toastPanel?.orderOut(nil)
        toastPanel = panel

        let shelfFrame = shelfPanel.frame
        let size = NSSize(width: shelfFrame.width, height: 56)
        let gap: CGFloat = 10
        var originX = shelfFrame.midX - size.width / 2
        var originY = shelfFrame.minY - size.height - gap

        if let screenFrame = shelfPanel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            originX = max(screenFrame.minX + 8,
                          min(originX, screenFrame.maxX - size.width - 8))
            if originY < screenFrame.minY + 8 {
                // Not enough room below; show above the shelf instead.
                originY = shelfFrame.maxY + gap
            }
        }

        panel.setFrame(
            NSRect(origin: NSPoint(x: originX, y: originY), size: size),
            display: true
        )
        panel.orderFront(nil)

        toastHideTimer?.invalidate()
        toastHideTimer = Timer.scheduledTimer(
            withTimeInterval: toastVisibleDuration,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.toastPanel?.orderOut(nil)
            }
        }
    }

    private func makeToastPanel(message: String) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .utilityWindow

        let hosting = NSHostingView(rootView: ToastView(message: message))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: panel.contentView?.bounds ?? .zero)
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container
        return panel
    }

    // MARK: - Quit

    func applicationWillTerminate(_ notification: Notification) {
        folderMonitor.stop()
        for id in Array(parkJobs.keys) { cancelPark(id) }
        if let monitor = shortcutGlobalMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = shortcutLocalMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = pasteMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        missingFileSweepTimer?.invalidate()
        expiryTimer?.invalidate()
        manager.flushStore()
        conversionService.cancelAll()
        ocrService.cancelAll()
    }

    private func installShelfShortcuts() {
        shortcutGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in _ = self?.handleShelfShortcut(event) }
        }
        shortcutLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleShelfShortcut(event) == true ? nil : event
        }
    }

    private func handleShelfShortcut(_ event: NSEvent) -> Bool {
        guard !ShelfShortcut.recording, let shortcut = ShelfShortcut.allCases.first(where: { $0.matches(event) }) else { return false }
        if !event.isARepeat {
            switch shortcut {
            case .new: newShelfAction()
            case .clipboard: newShelfFromClipboardAction()
            case .capture: captureScreenTextAction()
            case .recordingControls:
                if #available(macOS 15.0, *) { ShelfScreenRecorder.shared.openLauncher() }
            case .stopRecording:
                if #available(macOS 15.0, *) { Task { await ShelfScreenRecorder.shared.stop() } }
            }
        }
        return true
    }

    // MARK: - Paste shortcut

    private func installPasteShortcut() {
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard let (shelfID, _) = self.panels.first(where: { $0.value.isKeyWindow }) else {
                return event
            }
            if ShelfToolRouter.activeShelves.contains(shelfID) {
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if event.keyCode == 53 || (modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "w") {
                    NotificationCenter.default.post(name: .shelfToolBackRequested, object: shelfID)
                    return nil
                }
                // Do not steal Cmd-A/C/V/Z from an action panel's text fields.
                return event
            }
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
                return event
            }
            switch event.charactersIgnoringModifiers {
            case "v":
                let added = self.manager.addFromClipboard(to: shelfID)
                return added > 0 ? nil : event
            case "a":
                // Forward to the expanded view via Combine; it owns the
                // selection state and decides what "all" means in the
                // current view (shelf root vs folder browse).
                self.manager.selectAllRequested.send(shelfID)
                return nil
            case "c":
                self.manager.copyRequested.send(shelfID)
                return nil
            case "z":
                guard self.manager.canUndo else { return event }
                self.manager.performUndo()
                return nil
            default:
                return event
            }
        }
    }
}

private struct ToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.85))
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.92))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        )
    }
}
