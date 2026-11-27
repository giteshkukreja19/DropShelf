import AppKit
import Combine
import CryptoKit
import QuickLookThumbnailing
import SwiftUI

// MARK: - Progress overlay (conversion & OCR)

private struct ProgressOverlay: View {
    let progress: Double?
    let onCancel: () -> Void

    var body: some View {
        if let progress {
            ZStack {
                Color.black.opacity(0.45)
                    .allowsHitTesting(false)
                VStack(spacing: 6) {
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)
                        .frame(width: 76)
                        .tint(.white)
                    Button {
                        onCancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .transition(.opacity)
        }
    }
}

struct ShelfContainerView: View {
    @ObservedObject var manager: ShelfManager
    var conversionService: ConversionService
    var ocrService: OCRService
    let shelfID: UUID
    /// True for shake-created shelves, which auto-close via the shake-release
    /// watcher and shouldn't show an X in their fresh-empty state. Menu-created
    /// shelves have no auto-close path, so they always need the X.
    var isEphemeral: Bool = false
    var onClose: () -> Void = {}
    var onIdleHideDocked: () -> Void = {}
    var onResize: (_ expanded: Bool) -> Void = { _ in }
    var onDockChanged: (_ docked: Bool) -> Void = { _ in }
    var sizeForShelf: (Bool) -> NSSize = { _ in .zero }

    @AppStorage("shelf.activation") private var activation: ShelfActivation = .oneSecond
    @AppStorage("shelf.idleCollapseSeconds") private var idleCollapseSeconds = 0
    @AppStorage("shelf.idleDockSeconds") private var idleDockSeconds = 0
    @AppStorage("shelf.idleHideDockedSeconds") private var idleHideDockedSeconds = 0
    @State private var idleSince = ProcessInfo.processInfo.systemUptime
    @State private var lastIdleTick = ProcessInfo.processInfo.systemUptime
    @State private var shelfHovered = false
    private let idleTimer = Timer.publish(every: 0.25, on: .main, in: .default).autoconnect()
    @Namespace private var ns
    @State private var isExpanded = false
    @State private var toolRequest: ShelfToolRequest?
    @State private var toolBusy = false
    @State private var windowReference = ShelfWindowReference()
    private var shelfWindow: NSWindow? { windowReference.window }
    @State private var savedShelfFrame: NSRect?
    @State private var toolOpeningFrame: NSRect?
    @State private var toolResizeTask: Task<Void, Never>?
    @State private var toolMeasuredHeight: CGFloat?
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    @State private var isDocked = false
    @AppStorage("shelf.instantActions") private var instantActions = true
    @AppStorage("shelf.compactSizePercent") private var compactSizePercent = 100
    @AppStorage("shelf.expandedSizePercent") private var expandedSizePercent = 100
    @AppStorage("shelf.fixedExpandedSize") private var fixedExpandedSize = false
    @AppStorage("shelf.fixedExpandedDimensions") private var fixedExpandedDimensions = ""
    @AppStorage("shelf.intelligentNames") private var intelligentNames = false
    @AppStorage("shelf.viewMode") private var shelfViewMode = "grid"
    @State private var dropTargeted = false
    @State private var lastArrivalCount = 0
    @State private var arrivalPulse = false
    @State private var arrivalTask: Task<Void, Never>?
    @State private var selection: Set<UUID> = []
    // Sticky once true: lets the collapsed view show its X close button
    // after the user empties a populated shelf, but stays hidden while a
    // shake gesture is mid-flight (shelf created empty, no items yet).
    @State private var hasEverHadItems = false

    private var items: [ShelfItem] { manager.items(of: shelfID) }

    private var transitionAnimation: Animation {
        reduceMotion
            ? .linear(duration: 0)
            : .easeInOut(duration: 0.32)
    }

    var body: some View {
        ZStack {
            if isDocked {
                DockedTabView(
                    onExpand: { toggleDock(to: false) },
                    dropTargeted: dropTargeted
                )
                .transition(.opacity)
            } else if isExpanded {
                ExpandedShelfView(
                    namespace: ns,
                    manager: manager,
                    shelfID: shelfID,
                    selection: $selection,
                    onCollapse: { toggle(to: false) },
                    onClose: onClose,
                    onDock: { toggleDock(to: true) }
                )
                .padding(10)
                .transition(.opacity)
            } else {
                CollapsedShelfView(
                    namespace: ns,
                    manager: manager,
                    shelfID: shelfID,
                    items: items,
                    isDragging: manager.isDragging,
                    showCloseWhenEmpty: hasEverHadItems || !isEphemeral,
                    onClose: onClose,
                    onOpenDocuments: { toggle(to: true) },
                    onDock: { toggleDock(to: true) },
                    onDragStart: { manager.isDragging = true },
                    onDragEnd: { manager.isDragging = false }
                )
                .padding(10)
                .transition(.opacity)
            }
        }
        .opacity(toolRequest == nil ? 1 : 0)
        .allowsHitTesting(toolRequest == nil)
        .accessibilityHidden(toolRequest != nil)
        .overlay {
            if let request = toolRequest {
                toolContent(request)
                    .id(request.id)
                    .transition(.opacity)
                    .onPreferenceChange(ToolHeightPreference.self) { sizes in
                        guard let header = sizes["header"], let body = sizes["body"], let footer = sizes["footer"], header > 0, body > 0, footer > 0 else { return }
                        toolMeasuredHeight = ceil(header + body + footer + 69)
                        scheduleToolResize()
                    }
                    .clipped()
            }
        }
        .background(
            ShelfWindowReader { window in
                windowReference.window = window
            }
        )
        .onReceive(
            NotificationCenter.default.publisher(
                for: .shelfToolRequested
            )
        ) { notification in
            guard let request =
                notification.object as? ShelfToolRequest,
                request.shelfID == shelfID
            else { return }

            openTool(request)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay {
            if !isDocked && toolRequest == nil {
                DropTargetOverlay(active: dropTargeted && !manager.isDragging)
            }
        }
        // AppKit-level drop target — keeps the green "+" copy badge from
        // showing up on the cursor (SwiftUI's `.onDrop` always negotiates as
        // `.copy`, which paints the badge; we want a clean cursor instead).
        .overlay {
            if toolRequest == nil {
                ShelfDropTarget(isTargeted: $dropTargeted,
                    allowDrop: { !manager.isDragging }, onDrop: handleDrop)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(arrivalPulse ? 0.72 : 0), lineWidth: 2)
                .padding(1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .background(InstantActionsAnchor(enabled: instantActions && !items.isEmpty && !isDocked && !isExpanded && toolRequest == nil, values: {
            items.compactMap { item -> Any? in
                if let url = item.fileURL { return url }
                return item.textContent
            }
        }))
        .onHover { inside in
            shelfHovered = inside
            resetIdleClock()
        }
        .onReceive(idleTimer) { _ in checkIdleShelf() }
        .onChange(of: compactSizePercent) { _ in refreshPreferredSize() }
        .onChange(of: expandedSizePercent) { _ in if isExpanded { refreshPreferredSize() } }
        .onChange(of: fixedExpandedSize) { _ in if isExpanded { refreshPreferredSize() } }
        .onChange(of: fixedExpandedDimensions) { _ in if isExpanded && fixedExpandedSize { refreshPreferredSize() } }
        .onChange(of: shelfViewMode) { _ in if isExpanded && !fixedExpandedSize { refreshPreferredSize() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification)) { notification in
            guard fixedExpandedSize, isExpanded, !isDocked, toolRequest == nil,
                  let window = notification.object as? NSWindow, window === shelfWindow else { return }
            let requested = CGSize(width: max(340, window.frame.width), height: max(280, window.frame.height))
            if requested.width <= 4000, requested.height <= 4000 {
                fixedExpandedDimensions = ShelfExpandedGeometry.encode(requested)
                refreshPreferredSize()
            }
        }
        .onChange(of: isExpanded) { _ in resetIdleClock() }
        .onChange(of: isDocked) { _ in resetIdleClock() }
        .onChange(of: idleCollapseSeconds) { _ in resetIdleClock() }
        .onChange(of: idleDockSeconds) { _ in resetIdleClock() }
        .onChange(of: idleHideDockedSeconds) { _ in resetIdleClock() }
        .onChange(of: manager.isDragging) { _ in resetIdleClock() }
        .onReceive(manager.revealRequested) { id in
            if id == shelfID { resetIdleClock() }
        }
        .onReceive(manager.dockRequested) { id in
            if id == shelfID { toggleDock(to: true) }
        }
        .onReceive(manager.undockRequested) { id in
            guard id == shelfID, isDocked else { return }
            withAnimation(transitionAnimation) { isDocked = false }
        }
        .onReceive(manager.collapseRequested) { id in
            // External nudge (e.g. outside-click setting) — only act if the
            // signal is for our shelf and we're currently expanded. Going
            // through the normal toggle path keeps the panel resize +
            // SwiftUI animation in lockstep.
            guard id == shelfID, isExpanded else { return }
            toggle(to: false)
        }
        // Empty-but-expanded is a dead-end UX (nothing to do, nothing to
        // show), so fall back to collapsed and let that view handle the
        // empty case.
        .onChange(of: items.count) { newCount in
            resetIdleClock()
            selection.formIntersection(Set(items.map(\.id)))
            if newCount > 0 { hasEverHadItems = true }
            let added = newCount > lastArrivalCount
            lastArrivalCount = newCount
            guard toolRequest == nil else { return }
            if added { pulseArrival() }
            if newCount == 0, isExpanded {
                toggle(to: false)
            } else if isExpanded && !isDocked && !fixedExpandedSize {
                onResize(true)
            }
            if activation == .dragOnly, newCount > 0, !isDocked, !isExpanded {
                toggle(to: true)
            }
        }
        .onChange(of: dropTargeted) { newValue in
            manager.setDropTargeted(shelfID: shelfID, newValue)
        }
        .onAppear {
            lastArrivalCount = items.count
            if !items.isEmpty { hasEverHadItems = true }
        }
        .onDisappear {
            ShelfToolRouter.activeShelves.remove(shelfID)
            // Make sure a panel that closes mid-drop doesn't leave its
            // shelf marked as a drop target forever.
            manager.setDropTargeted(shelfID: shelfID, false)
            toolResizeTask?.cancel()
            arrivalTask?.cancel()
        }
        .environmentObject(conversionService)
        .environmentObject(ocrService)
    }

    @ViewBuilder
    private func toolContent(
        _ request: ShelfToolRequest
    ) -> some View {
        if [.resize, .compress, .convertImage, .metadata]
            .contains(request.action) {
            ImageToolPanel(
                action: request.action,
                urls: request.urls,
                manager: manager,
                shelfID: shelfID,
                close: { closeTool() },
                setBusy: { toolBusy = $0; if !$0 { scheduleToolResize() } }, owner: windowReference, preset: request.preset
            )
        } else {
            DocumentToolPanel(
                action: request.action,
                urls: request.urls,
                manager: manager,
                shelfID: shelfID,
                close: { closeTool() },
                setBusy: { toolBusy = $0; if !$0 { scheduleToolResize() } }, owner: windowReference, preset: request.preset
            )
        }
    }

    private func openTool(_ request: ShelfToolRequest) {
        guard toolRequest == nil, !ShelfToolRouter.activeShelves.contains(shelfID),
              !isDocked,
              let window = shelfWindow
        else { return }

        toolResizeTask?.cancel()
        toolMeasuredHeight = nil
        savedShelfFrame = window.frame
        dropTargeted = false
        ShelfToolRouter.activeShelves.insert(shelfID)

        let imageTool = [
            SmartFileActions.Action.resize,
            .compress, .convertImage, .metadata
        ].contains(request.action)

        let screen = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? window.frame

        let width = min(
            imageTool ? CGFloat(460) : CGFloat(520),
            screen.width - 16
        )

        let height = min(
            imageTool ? (request.action == .resize ? CGFloat(355) : CGFloat(315)) : CGFloat(min(540, 270 + 53 * min(request.urls.count, 5))),
            screen.height - 16
        )

        let old = window.frame

        let target = NSRect(
            x: max(
                screen.minX + 8,
                min(old.midX - width / 2,
                    screen.maxX - width - 8)
            ),
            y: max(
                screen.minY + 8,
                min(old.maxY - height,
                    screen.maxY - height - 8)
            ),
            width: width,
            height: height
        )

        toolOpeningFrame = target
        window.makeKeyAndOrderFront(nil)

        withAnimation(transitionAnimation) {
            toolRequest = request
        }

        animateToolWindow(window, to: target)
    }

    private func closeTool() {
        guard !toolBusy, toolRequest != nil else { return }
        toolResizeTask?.cancel()
        toolMeasuredHeight = nil
        if items.isEmpty && isExpanded {
            isExpanded = false
            onResize(false) // update the app's expanded-state bookkeeping while tool resizing is guarded
        }
        withAnimation(transitionAnimation) {
            toolRequest = nil
        }

        if let window = shelfWindow,
           var frame = savedShelfFrame {

            if let opening = toolOpeningFrame {
                frame.origin.x +=
                    window.frame.midX - opening.midX

                frame.origin.y +=
                    window.frame.maxY - opening.maxY
            }

            let size = sizeForShelf(isExpanded && !items.isEmpty)
            if size.width > 0, size.height > 0 {
                frame.origin.x += (frame.width - size.width) / 2
                frame.origin.y += frame.height - size.height
                frame.size = size
            }
            if let visible = window.screen?.visibleFrame {
                frame = ShelfExpandedGeometry.clampedFrame(frame, in: visible)
            }

            animateToolWindow(window, to: frame)
        }

        toolOpeningFrame = nil

        savedShelfFrame = nil
        ShelfToolRouter.activeShelves.remove(shelfID)
        resetIdleClock()

    }

    private func scheduleToolResize() {
        toolResizeTask?.cancel()
        guard toolRequest != nil, !toolBusy, toolMeasuredHeight != nil else { return }
        toolResizeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 360_000_000)
            guard !Task.isCancelled, toolRequest != nil, !toolBusy,
                  let window = shelfWindow, window.attachedSheet == nil,
                  let measured = toolMeasuredHeight, let previous = toolOpeningFrame else { return }
            let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
            let height = min(max(200, measured), max(200, screen.height - 16))
            guard abs(previous.height - height) > 2 else { return }
            let current = window.frame
            if var saved = savedShelfFrame {
                saved.origin.x += current.midX - previous.midX
                saved.origin.y += current.maxY - previous.maxY
                savedShelfFrame = saved
            }
            var next = current
            next.size.height = height
            next.origin.y = max(screen.minY + 8, min(current.maxY - height, screen.maxY - height - 8))
            toolOpeningFrame = next
            animateToolWindow(window, to: next)
        }
    }

    private func animateToolWindow(
        _ window: NSWindow,
        to frame: NSRect
    ) {
        if reduceMotion {
            window.setFrame(frame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
                context.allowsImplicitAnimation = true
                window.animator().setFrame(
                    frame, display: true
                )
            }
        }
    }

    private func pulseArrival() {
        guard !reduceMotion, !isDocked else { return }
        arrivalTask?.cancel()
        withAnimation(.easeOut(duration: 0.12)) { arrivalPulse = true }
        arrivalTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.32)) { arrivalPulse = false }
        }
    }

    private func handleDrop(_ pasteboard: NSPasteboard) -> Bool {
        if manager.isDragging || toolRequest != nil { return false }
        let target = shelfID

        // 1. File URLs — covers both files and folders. Finder always vends
        // `.fileURL` for folders to AppKit destinations, so we don't need the
        // separate `public.folder` branch the SwiftUI version had to carry.
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            for url in urls {
                manager.addFile(url: url, to: target)
            }
            return true
        }

        // Explicit web links before promises, unless actual image bytes are offered.
        if pasteboard.availableType(from: [.png, .tiff]) == nil {
            // Explicit browser URL payloads are saved as text links, without fetching remote content.
            let links = WebDragLinks.read(pasteboard)
            if !links.isEmpty {
                for link in links { manager.addText(link.absoluteString, to: target) }
                return true
            }
        }

        // 2. File promises — sources like Mail, Photos, and some browsers
        // vend the file lazily via NSFilePromiseReceiver. The receiver writes
        // the real bytes into our temp dir, then we add it to the shelf.
        if let receivers = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self], options: nil
        ) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            let queue = OperationQueue()
            queue.qualityOfService = .userInitiated
            for receiver in receivers {
                let dest: URL
                do { dest = try ShelfWritableStorage.newFolder("Imports") }
                catch { NSLog("DropShelf import directory: \(error)"); continue }
                receiver.receivePromisedFiles(
                    atDestination: dest,
                    options: [:],
                    operationQueue: queue
                ) { url, error in
                    if let error {
                        NSLog("Shelf: file promise failed — \(error)")
                        return
                    }
                    Task { @MainActor in manager.addFile(url: url, to: target) }
                }
            }
            return true
        }

        // 3. Image data without a fileURL — e.g. dragging an image straight
        // out of a webpage. Stage as PNG with a content-hash filename so a
        // repeat drop hits the shelf's duplicate guard.
        if let images = pasteboard.readObjects(
            forClasses: [NSImage.self], options: nil
        ) as? [NSImage], !images.isEmpty {
            var staged = false
            for image in images {
                guard
                    let tiff = image.tiffRepresentation,
                    let bitmap = NSBitmapImageRep(data: tiff),
                    let png = bitmap.representation(using: .png, properties: [:])
                else { continue }
                let hash = SHA256.hash(data: png)
                    .map { String(format: "%02x", $0) }
                    .joined().prefix(16)
                do {
                    let tmp = try ShelfWritableStorage.stagingDirectory().appendingPathComponent("Shelf-\(hash).png")
                    if !FileManager.default.fileExists(atPath: tmp.path) {
                        try png.write(to: tmp)
                    }
                    manager.addFile(url: tmp, to: target)
                    staged = true
                } catch {
                    NSLog("Shelf: failed to write dropped image: \(error)")
                }
            }
            if staged { return true }
        }

        // Explicit browser URL payloads are saved as text links, without fetching remote content.
        let links = WebDragLinks.read(pasteboard)
        if !links.isEmpty {
            for link in links { manager.addText(link.absoluteString, to: target) }
            return true
        }

        // 4. Plain text — pasted/dragged snippets. addText takes care of
        // staging a backing temp .txt so Open / Reveal work.
        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            manager.addText(text, to: target)
            return true
        }

        return false
    }

    private func resetIdleClock() {
        idleSince = ProcessInfo.processInfo.systemUptime
    }

    private func refreshPreferredSize() {
        guard toolRequest == nil, !isDocked, shelfWindow?.inLiveResize != true else { return }
        onResize(isExpanded)
    }

    private func checkIdleShelf() {
        guard toolRequest == nil else {
            resetIdleClock()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let gap = now - lastIdleTick
        lastIdleTick = now
        // Default run-loop mode pauses during native menu tracking.
        // Also avoid counting sleep or other long main-thread interruptions.
        let pointerOnShelf = NSApp.windows.contains { window in
            window is ShelfPanelMarker && window.isVisible &&
                window.frame.contains(NSEvent.mouseLocation)
        }
        guard gap < 1, !items.isEmpty,
              manager.shelf(id: shelfID)?.pinned != true,
              !pointerOnShelf, !dropTargeted,
              !manager.isDragging, !DragInitiatorView.hasActiveDrag,
              NSEvent.pressedMouseButtons == 0,
              conversionService.progress.isEmpty, ocrService.progress.isEmpty,
              !NSApp.windows.contains(where: { $0.isVisible && ($0 is NSOpenPanel || $0 is NSSavePanel || $0.attachedSheet != nil) }) else {
            resetIdleClock()
            return
        }
        let delay = isDocked ? idleHideDockedSeconds : (isExpanded ? idleCollapseSeconds : idleDockSeconds)
        guard delay > 0, now - idleSince >= Double(delay) else { return }
        resetIdleClock()
        if isDocked { onIdleHideDocked() }
        else if isExpanded { toggle(to: false) }
        else { toggleDock(to: true) }
    }

    private func toggle(to expanded: Bool) {
        guard toolRequest == nil, expanded != isExpanded else { return }
        onResize(expanded)
        withAnimation(transitionAnimation) {
            isExpanded = expanded
        }
    }

    private func toggleDock(to docked: Bool) {
        guard toolRequest == nil, docked != isDocked else { return }
        onDockChanged(docked)
        withAnimation(transitionAnimation) {
            isDocked = docked
        }
    }
}

private struct DockedTabView: View {
    let onExpand: () -> Void
    let dropTargeted: Bool

    @State private var hovering = false

    var body: some View {
        Color.clear
            .overlay {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        Color.primary.opacity(dropTargeted ? 1 : (hovering ? 0.95 : 0.65))
                    )
                    // Nudge the chevron to match the visible portion of the
                    // panel (right side is clipped past the screen edge).
                    .offset(x: -6)
            }
            .contentShape(Rectangle())
            // Trace the panel's actual outer corner radius (22, set on the
            // FloatingPanel rootLayer) so the highlight hugs the visible
            // capsule instead of an inset rectangle. Negative padding pulls
            // the stroke flush with the panel's outline; the right edge is
            // clipped offscreen by the dock offset and never shows anyway.
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(
                        Color.accentColor.opacity(dropTargeted ? 1 : 0),
                        lineWidth: 2
                    )
                    .allowsHitTesting(false)
            )
            .onHover { hovering = $0 }
            .onTapGesture(perform: onExpand)
            .animation(.easeOut(duration: 0.15), value: dropTargeted)
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

enum ShelfViewMode: String {
    case grid
    case list
}

private struct ExpandedShelfView: View {
    @AppStorage("shelf.intelligentNames") private var intelligentNames = false
    let namespace: Namespace.ID
    @ObservedObject var manager: ShelfManager
    let shelfID: UUID
    @Binding var selection: Set<UUID>
    let onCollapse: () -> Void
    let onClose: () -> Void
    let onDock: () -> Void

    @AppStorage("shelf.viewMode") private var viewModeRaw: String = ShelfViewMode.grid.rawValue
    @State private var draggingIDs: Set<UUID> = []
    @EnvironmentObject private var conversionService: ConversionService
    @EnvironmentObject private var ocrService: OCRService

    // Folder navigation: empty stack = shelf root (showing ShelfItems);
    // non-empty stack's `last` is the currently-displayed folder, with its
    // children cached in `folderContents`. The cache survives pop/push so
    // navigating back is instant.
    @State private var folderStack: [URL] = []
    @State private var folderContents: [URL: [FolderEntry]] = [:]
    @State private var loadingFolders: Set<URL> = []
    @State private var navDirection: NavDirection = .forward
    /// Selection inside the folder browser — keyed by `FolderEntry.id`.
    /// Cleared on push/pop because each level renders a fresh entry list
    /// with new UUIDs, so carrying selection across levels would just hold
    /// stale identifiers.
    @State private var folderSelection: Set<UUID> = []
    @State private var selectionAnchor: UUID?
    @State private var folderSelectionAnchor: UUID?

    private var viewMode: ShelfViewMode {
        get { ShelfViewMode(rawValue: viewModeRaw) ?? .grid }
    }

    private var items: [ShelfItem] { manager.items(of: shelfID) }

    // Use the same column capacity as the window height calculation.
    // A short first row is centered, rather than reserving empty columns.
    private func columns(width: CGFloat, count: Int) -> [GridItem] {
        Array(repeating: GridItem(.fixed(ShelfExpandedGeometry.tileWidth),
            spacing: ShelfExpandedGeometry.columnSpacing, alignment: .top),
            count: ShelfExpandedGeometry.columns(contentWidth: width, count: count))
    }

    private var shelf: Shelf? { manager.shelf(id: shelfID) }

    private var currentFolderURL: URL? { folderStack.last }
    private var inFolder: Bool { !folderStack.isEmpty }
    private var currentEntries: [FolderEntry] {
        currentFolderURL.flatMap { folderContents[$0] } ?? []
    }
    private var isCurrentFolderLoading: Bool {
        guard let url = currentFolderURL else { return false }
        return folderContents[url] == nil && loadingFolders.contains(url)
    }

    private var countTitle: String {
        items.count == 1
            ? L("1 File")
            : String(format: L("%lld Files"), items.count)
    }

    private var headerPrimary: String {
        if let url = currentFolderURL { return url.lastPathComponent }
        if let n = shelf?.displayShelfName(intelligent: intelligentNames) { return n }
        return countTitle
    }

    private var headerSubtitle: String {
        if inFolder {
            let shelfTitle = shelf?.displayShelfName(intelligent: intelligentNames) ?? L("shelf.default-name")
            let parents = folderStack.dropLast().map(\.lastPathComponent)
            let crumbs = ([shelfTitle] + parents).joined(separator: " › ")
            let countLabel: String
            if isCurrentFolderLoading {
                countLabel = L("Loading…")
            } else {
                let n = currentEntries.count
                countLabel = n == 1
                    ? L("1 file")
                    : String(format: L("%lld files"), n)
            }
            return "\(crumbs) · \(countLabel)"
        }
        let chosen = items.filter { selection.contains($0.id) }
        if !chosen.isEmpty {
            let sizes = chosen.compactMap { $0.byteSize }
            let count = "\(chosen.count) selected"
            return sizes.count == chosen.count ? "\(count) · \(ShelfItem.format(bytes: sizes.reduce(0, +)))" : count
        }
        let size = manager.displayTotalSize(of: shelfID)
        if shelf?.displayShelfName(intelligent: intelligentNames) != nil {
            return size == "—" ? countTitle : "\(countTitle) · \(size)"
        }
        return size
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            content
            revealButton
        }
        .task(id: currentFolderURL) {
            guard let url = currentFolderURL else { return }
            while !Task.isCancelled {
                loadFolderIfNeeded(url, refresh: true)
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { return }
            }
        }
        // Native tile overlays own selection. A parent SwiftUI tap gesture
        // can also fire for those clicks and erase the existing selection.
        .onReceive(manager.selectAllRequested) { id in
            // Cmd-A from the app-level key monitor. Routes to the right
            // selection set depending on what the user is actually looking at.
            guard id == shelfID else { return }
            if inFolder {
                folderSelection = Set(currentEntries.map(\.id))
            } else {
                selection = Set(items.map(\.id))
            }
        }
        .onReceive(manager.copyRequested) { id in
            // Cmd-C: write the URLs of the current selection to the
            // pasteboard. Empty selection is a no-op so we don't accidentally
            // clobber the user's clipboard.
            guard id == shelfID else { return }
            let urls: [URL]
            if inFolder {
                urls = currentEntries
                    .filter { folderSelection.contains($0.id) }
                    .map(\.url)
            } else {
                urls = items
                    .filter { selection.contains($0.id) }
                    .compactMap(\.fileURL)
            }
            guard !urls.isEmpty else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(urls.map { $0 as NSURL })
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            CircularIconButton(systemName: "chevron.left", action: handleBack)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if inFolder {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.7))
                    } else if let accent = shelf?.accent {
                        ShelfAccentBadge(accent: accent, size: 10)
                    }
                    Text(headerPrimary)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !inFolder, shelf?.pinned == true {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.7))
                    }
                }
                Text(headerSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .overlay { ShelfWindowDragHandle(
                    onDoubleTap: onCollapse,
                    onEdge: onDock
                ) }
            Color.clear
                .frame(minWidth: 20)
                .frame(height: 36)
                .frame(maxWidth: .infinity)
                .overlay { ShelfWindowDragHandle(
                    onDoubleTap: onCollapse,
                    onEdge: onDock
                ) }
            // Quick-dock to the right edge — same animation as the grab
            // handle in the collapsed view, surfaced here so the user
            // doesn't need to collapse first to park the panel. Sized
            // smaller than the primary back button so it sits comfortably
            // alongside the view-mode toggle.
            CircularIconButton(
                systemName: "arrow.right.to.line",
                action: onDock,
                size: 22,
                iconSize: 9
            )
            ViewModeToggle(
                mode: Binding(
                    get: { viewMode },
                    set: { viewModeRaw = $0.rawValue }
                )
            )
            if !inFolder {
                ShelfActionMenu(manager: manager, shelfID: shelfID, selection: selection)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            if inFolder {
                folderContentBody
                    .id(currentFolderURL?.path ?? "folder-root")
                    .transition(navTransition)
            } else {
                shelfContentBody
                    .id("shelf-root")
                    .transition(navTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ShelfWindowDragHandle(onDoubleTap: onCollapse, onEdge: onDock)
        }
        .clipped()
    }

    private var navTransition: AnyTransition {
        switch navDirection {
        case .forward:
            return .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        case .back:
            return .asymmetric(
                insertion: .move(edge: .leading).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            )
        }
    }

    @ViewBuilder
    private var shelfContentBody: some View {
        switch viewMode {
        case .grid: shelfGrid
        case .list: shelfList
        }
    }

    @ViewBuilder
    private var folderContentBody: some View {
        if isCurrentFolderLoading {
            VStack(spacing: 10) {
                ProgressView().progressViewStyle(.circular)
                Text(L("Loading…"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(0.55))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if currentEntries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.primary.opacity(0.38))
                Text(L("Empty folder"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primary.opacity(0.55))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch viewMode {
            case .grid: folderGrid
            case .list: folderList
            }
        }
    }

    private func dragSet(for itemID: UUID) -> Set<UUID> {
        if selection.contains(itemID) && selection.count > 1 {
            return selection
        }
        return [itemID]
    }

    // MARK: - Folder navigation

    private func handleBack() {
        if inFolder {
            popFolder()
        } else {
            onCollapse()
        }
    }

    private func enterFolder(_ url: URL) {
        guard folderStack.last != url else { return }
        navDirection = .forward
        loadFolderIfNeeded(url)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
            folderStack.append(url)
            selection.removeAll()
            folderSelection.removeAll()
        }
    }

    private func popFolder() {
        guard !folderStack.isEmpty else { return }
        navDirection = .back
        withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
            _ = folderStack.removeLast()
            folderSelection.removeAll()
        }
    }

    private func handleEntryActivation(_ entry: FolderEntry) {
        if entry.isDirectory { enterFolder(entry.url) }
    }

    private func handleEntryDoubleClick(_ entry: FolderEntry) {
        if entry.isDirectory {
            enterFolder(entry.url)
        } else {
            NSWorkspace.shared.open(entry.url)
        }
    }

    private func loadFolderIfNeeded(_ url: URL, refresh: Bool = false) {
        if (!refresh && folderContents[url] != nil) || loadingFolders.contains(url) { return }
        loadingFolders.insert(url)
        Task.detached(priority: .userInitiated) {
            let entries = readDirectory(url: url)
            await MainActor.run {
                loadingFolders.remove(url)
                guard let entries else { return }
                let old = folderContents[url] ?? []
                let ids = Dictionary(old.map { ($0.url, $0.id) }, uniquingKeysWith: { first, _ in first })
                let stable = entries.map { entry in
                    FolderEntry(id: ids[entry.url] ?? entry.id, url: entry.url,
                                isDirectory: entry.isDirectory, displayName: entry.displayName,
                                byteSize: entry.byteSize, pixelSize: entry.pixelSize)
                }
                if folderContents[url] != stable {
                    folderContents[url] = stable
                    if currentFolderURL == url { folderSelection.formIntersection(stable.map(\.id)) }
                }
            }
        }
    }

    @AppStorage("shelf.sortOrder") private var sortOrder = "Date Added"
    private var sortedItems: [ShelfItem] {
        switch sortOrder {
        case "Name": return items.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case "Size": return items.sorted { ($0.byteSize ?? 0) > ($1.byteSize ?? 0) }
        default: return Array(items.reversed())
        }
    }

    private var shelfGrid: some View {
        let target = shelfID
        let sel = $selection
        // Newest-first in the expanded view so the just-dropped tile lands at
        // the top of the grid where the user is looking. Storage order stays
        // append-at-end (the collapsed stack still puts the newest tile on top).
        let displayed = sortedItems
        return GeometryReader { geometry in
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: columns(width: geometry.size.width, count: displayed.count), alignment: .center, spacing: ShelfExpandedGeometry.rowSpacing) {
                ForEach(displayed) { item in
                    DocumentGridItem(
                        item: item,
                        manager: manager,
                        shelfID: target,
                        isSelected: sel.wrappedValue.contains(item.id),
                        isBeingDragged: draggingIDs.contains(item.id),
                        selectedURLsProvider: {
                            // If clicked tile is part of a multi-selection, drag all.
                            let selectedIDs = sel.wrappedValue
                            if selectedIDs.contains(item.id) && selectedIDs.count > 1 {
                                return manager.items(of: target)
                                    .filter { selectedIDs.contains($0.id) }
                                    .compactMap { $0.fileURL }
                            }
                            return item.fileURL.map { [$0] } ?? []
                        },
                        contextMenuBuilder: {
                            let selectedIDs = sel.wrappedValue
                            let selectedShelfItems: [ShelfItem]
                            if selectedIDs.contains(item.id), selectedIDs.count > 1 {
                                selectedShelfItems = manager.items(of: target)
                                    .filter { selectedIDs.contains($0.id) }
                            } else {
                                selectedShelfItems = [item]
                            }
                            return ShelfContextMenu.make(
                                for: item,
                                selectedItems: selectedShelfItems,
                                shelfID: target,
                                manager: manager,
                                conversionService: conversionService,
                                ocrService: ocrService
                            )
                        },
                        onRemove: { manager.removeItem(id: item.id, from: target, recordUndo: true) },
                        onClick: { modifiers in handleClick(itemID: item.id, modifiers: modifiers) },
                        onDragStart: {
                            manager.isDragging = true
                            draggingIDs = dragSet(for: item.id)
                        },
                        onDragEnd: {
                            manager.isDragging = false
                            draggingIDs.removeAll()
                        },
                        onNavigateInto: {
                            if let url = item.fileURL { enterFolder(url) }
                        }
                    )
                }
            }
            .padding(.vertical, 4)
            .frame(minHeight: geometry.size.height, alignment: .top)
            .background { ShelfWindowDragHandle(onDoubleTap: onCollapse, onEdge: onDock) }
        }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.clear)
                .matchedGeometryEffect(id: ShelfMatchedGeometry.card, in: namespace)
        )
        .environmentObject(conversionService)
        .environmentObject(ocrService)
    }

    private var shelfList: some View {
        let target = shelfID
        let sel = $selection
        let displayed = sortedItems
        return GeometryReader { geometry in
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 2) {
                ForEach(displayed) { item in
                    DocumentListItem(
                        item: item,
                        manager: manager,
                        shelfID: target,
                        isSelected: sel.wrappedValue.contains(item.id),
                        isBeingDragged: draggingIDs.contains(item.id),
                        selectedURLsProvider: {
                            let selectedIDs = sel.wrappedValue
                            if selectedIDs.contains(item.id) && selectedIDs.count > 1 {
                                return manager.items(of: target)
                                    .filter { selectedIDs.contains($0.id) }
                                    .compactMap { $0.fileURL }
                            }
                            return item.fileURL.map { [$0] } ?? []
                        },
                        contextMenuBuilder: {
                            let selectedIDs = sel.wrappedValue
                            let selectedShelfItems: [ShelfItem]
                            if selectedIDs.contains(item.id), selectedIDs.count > 1 {
                                selectedShelfItems = manager.items(of: target)
                                    .filter { selectedIDs.contains($0.id) }
                            } else {
                                selectedShelfItems = [item]
                            }
                            return ShelfContextMenu.make(
                                for: item,
                                selectedItems: selectedShelfItems,
                                shelfID: target,
                                manager: manager,
                                conversionService: conversionService,
                                ocrService: ocrService
                            )
                        },
                        onRemove: { manager.removeItem(id: item.id, from: target, recordUndo: true) },
                        onClick: { modifiers in handleClick(itemID: item.id, modifiers: modifiers) },
                        onDragStart: {
                            manager.isDragging = true
                            draggingIDs = dragSet(for: item.id)
                        },
                        onDragEnd: {
                            manager.isDragging = false
                            draggingIDs.removeAll()
                        },
                        onNavigateInto: {
                            if let url = item.fileURL { enterFolder(url) }
                        }
                    )
                }
            }
            .padding(.vertical, 4)
            .frame(minHeight: geometry.size.height, alignment: .top)
            .background { ShelfWindowDragHandle(onDoubleTap: onCollapse, onEdge: onDock) }
        }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environmentObject(conversionService)
        .environmentObject(ocrService)
    }

    private var folderGrid: some View {
        GeometryReader { geometry in
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: columns(width: geometry.size.width, count: currentEntries.count), alignment: .center, spacing: ShelfExpandedGeometry.rowSpacing) {
                ForEach(currentEntries) { entry in
                    FolderEntryGridCell(
                        entry: entry,
                        isSelected: folderSelection.contains(entry.id),
                        onClick: { modifiers in handleFolderClick(entry: entry, modifiers: modifiers) },
                        onDoubleClick: { handleEntryDoubleClick(entry) },
                        onNavigateInto: { enterFolder(entry.url) },
                        urlsProvider: { selectedFolderURLs(draggedEntry: entry) }
                    )
                }
            }
            .padding(.vertical, 4)
            .frame(minHeight: geometry.size.height, alignment: .top)
            .background { ShelfWindowDragHandle(onDoubleTap: onCollapse, onEdge: onDock) }
        }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var folderList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 2) {
                ForEach(currentEntries) { entry in
                    FolderEntryListItem(
                        entry: entry,
                        isSelected: folderSelection.contains(entry.id),
                        onClick: { modifiers in handleFolderClick(entry: entry, modifiers: modifiers) },
                        onDoubleClick: { handleEntryDoubleClick(entry) },
                        onNavigateInto: { enterFolder(entry.url) },
                        urlsProvider: { selectedFolderURLs(draggedEntry: entry) }
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleFolderClick(entry: FolderEntry, modifiers: NSEvent.ModifierFlags) {
        let ordered = currentEntries.map(\.id)
        if modifiers.contains(.shift), let anchor = folderSelectionAnchor,
           let start = ordered.firstIndex(of: anchor), let end = ordered.firstIndex(of: entry.id) {
            let range = Set(ordered[min(start, end)...max(start, end)])
            folderSelection.formUnion(range)
        } else {
            if folderSelection.contains(entry.id) { folderSelection.remove(entry.id) }
            else { folderSelection.insert(entry.id) }
            folderSelectionAnchor = entry.id
        }
    }

    /// URLs to drag when the user starts a drag from `draggedEntry`. If the
    /// drag started on a tile that's part of a multi-selection, all selected
    /// entries ride along; otherwise just the single dragged entry.
    private func selectedFolderURLs(draggedEntry: FolderEntry) -> [URL] {
        if folderSelection.contains(draggedEntry.id) && folderSelection.count > 1 {
            return currentEntries
                .filter { folderSelection.contains($0.id) }
                .map { $0.url }
        }
        return [draggedEntry.url]
    }

    private func handleClick(itemID: UUID, modifiers: NSEvent.ModifierFlags) {
        // Card clicks always go to selection. Folders are entered via the
        // inline chevron button rendered next to their name — that's the
        // only navigation affordance, so a stray card click can't accidentally
        // descend into a folder while the user is just trying to select it.
        let ordered = Array(items.reversed()).map(\.id)
        if modifiers.contains(.shift), let anchor = selectionAnchor,
           let start = ordered.firstIndex(of: anchor), let end = ordered.firstIndex(of: itemID) {
            let range = Set(ordered[min(start, end)...max(start, end)])
            selection.formUnion(range)
        } else {
            if selection.contains(itemID) { selection.remove(itemID) }
            else { selection.insert(itemID) }
            selectionAnchor = itemID
        }
    }

    private var revealButton: some View {
        return HStack(spacing: 8) {
            Spacer()
            if inFolder {
                let allSelected = !currentEntries.isEmpty
                    && folderSelection.count == currentEntries.count
                let someSelected = !folderSelection.isEmpty
                SelectAllButton(
                    allSelected: allSelected,
                    someSelected: someSelected,
                    enabled: !currentEntries.isEmpty,
                    action: {
                        if allSelected {
                            folderSelection.removeAll()
                        } else {
                            folderSelection = Set(currentEntries.map(\.id))
                        }
                    }
                )
            } else {
                let allSelected = !items.isEmpty && selection.count == items.count
                let someSelected = !selection.isEmpty
                SelectAllButton(
                    allSelected: allSelected,
                    someSelected: someSelected,
                    enabled: !items.isEmpty,
                    action: {
                        if allSelected {
                            selection.removeAll()
                        } else {
                            selection = Set(items.map(\.id))
                        }
                    }
                )
            }
            RevealInFinderButton(enabled: revealEnabled, action: revealAction)
            Spacer()
        }
    }

    private var revealEnabled: Bool {
        if inFolder { return currentFolderURL != nil }
        return !items.isEmpty
    }

    private func revealAction() {
        if let url = currentFolderURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        let urls = items.filter { selection.isEmpty || selection.contains($0.id) }.compactMap { $0.fileURL }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

private enum NavDirection {
    case forward, back
}

/// Small circular chevron button rendered next to a folder name in the grid
/// label area (below the card). Clicking it descends into the folder; the
/// surrounding card click is reserved for selection so users can pick up a
/// folder without accidentally navigating into it.
private struct InlineNavigateChevron: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.primary.opacity(hovering ? 1.0 : 0.85))
                .frame(width: 14, height: 14)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(hovering ? 0.22 : 0.12))
                )
                .overlay(
                    Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Lightweight description of a single child inside a folder being browsed.
/// Created on-demand when the user navigates into a folder; not persisted.
struct FolderEntry: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let isDirectory: Bool
    let displayName: String
    let byteSize: Int64?
    let pixelSize: CGSize?

    init(
        id: UUID = UUID(),
        url: URL,
        isDirectory: Bool,
        displayName: String,
        byteSize: Int64? = nil,
        pixelSize: CGSize? = nil
    ) {
        self.id = id
        self.url = url
        self.isDirectory = isDirectory
        self.displayName = displayName
        self.byteSize = byteSize
        self.pixelSize = pixelSize
    }
}

/// Synchronously enumerates the immediate children of `url`. Intended to be
/// called from a detached task — it's blocking I/O. Hidden files are skipped
/// to match Finder's default view. We deliberately don't pass
/// `.skipsPackageDescendants` because the user explicitly clicked the
/// chevron to descend; macOS would otherwise return `[]` for any directory
/// it considers a package (`.app`, `.bundle`, but also some user-named dirs
/// with extensions registered as packages — e.g. a folder called `dist.js`
/// shows zero children even when it has gigabytes of content).
private func readDirectory(url: URL) -> [FolderEntry]? {
    let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentTypeKey]
    let urls: [URL]
    do {
        urls = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
    } catch {
        NSLog("Shelf: readDirectory failed for %@ — %@",
              url.path as NSString, error as NSError)
        return nil
    }
    let entries = urls.map { childURL -> FolderEntry in
        let values = try? childURL.resourceValues(forKeys: Set(keys))
        let isDir = values?.isDirectory ?? false
        let bytes: Int64? = isDir ? nil : values?.fileSize.map(Int64.init)
        // Pull pixel dimensions for image children so the grid cell can pre-size
        // itself before the QL thumbnail arrives — keeps the layout from
        // jumping when previews crossfade in.
        let pixelSize: CGSize? = {
            guard !isDir,
                  let type = values?.contentType,
                  type.conforms(to: .image)
            else { return nil }
            return ShelfItem.readImagePixelSize(url: childURL)
        }()
        return FolderEntry(
            url: childURL,
            isDirectory: isDir,
            displayName: childURL.lastPathComponent,
            byteSize: bytes,
            pixelSize: pixelSize
        )
    }
    return entries.sorted { lhs, rhs in
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }
}

/// Grid cell for a single child inside a folder being browsed. Mirrors
/// DocumentGridItem's visual language (card shadow, hover lift, label below)
/// but loads its thumbnail lazily and has no shelf-specific affordances
/// (no remove button, no shelf context menu).
private struct FolderEntryGridCell: View {
    let entry: FolderEntry
    let isSelected: Bool
    /// Receives the click's modifier flags so the caller can implement
    /// cmd-click toggling. Plain click selects only this entry; navigating
    /// into a folder requires the inline chevron next to the name.
    let onClick: (NSEvent.ModifierFlags) -> Void
    let onDoubleClick: () -> Void
    let onNavigateInto: () -> Void
    /// Resolved at drag-start time. When this entry is part of a multi-selection,
    /// returns every selected entry's URL so the drag carries them all.
    let urlsProvider: () -> [URL]

    @State private var hovering = false
    @State private var thumbnail: NSImage?
    @State private var thumbnailIsIcon = true

    private static let cardLongSide: CGFloat = 100
    private static let labelMinWidth: CGFloat = 90

    private var cardSize: CGSize {
        if let s = entry.pixelSize, s.width > 0, s.height > 0 {
            let aspect = s.width / s.height
            if aspect.isFinite, aspect > 0 {
                if aspect >= 1 {
                    return CGSize(width: Self.cardLongSide, height: Self.cardLongSide / aspect)
                } else {
                    return CGSize(width: Self.cardLongSide * aspect, height: Self.cardLongSide)
                }
            }
        }
        return CGSize(width: 78, height: 100)
    }

    var body: some View {
        let size = cardSize
        VStack(spacing: 8) {
            cardFace(size: size)
                .frame(width: size.width, height: size.height)
                .shadow(color: .black.opacity(hovering ? 0.22 : 0.14),
                        radius: hovering ? 18 : 12, x: 0, y: hovering ? 10 : 6)
                .shadow(color: .black.opacity(0.06), radius: 2, x: 0, y: 1)
                .scaleEffect(hovering ? 1.03 : 1.0)
                .offset(y: hovering ? -3 : 0)
                .overlay(
                    ShelfDragOverlay(
                        provider: urlsProvider,
                        onStart: {},
                        onEnd: {},
                        onClick: onClick,
                        onDoubleClick: onDoubleClick,
                        visibleCardSize: { size }
                    )
                )
                .animation(.spring(response: 0.32, dampingFraction: 0.72), value: hovering)
                .onHover { hovering = $0 }
                .frame(height: Self.cardLongSide, alignment: .bottom)

            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if entry.isDirectory {
                        InlineNavigateChevron(action: onNavigateInto)
                    }
                }
                Text(metaText)
                    .font(.system(size: 10))
                    .foregroundStyle((isSelected ? Color.white.opacity(0.85) : Color.secondary))
                    .lineLimit(1)
            }
            .frame(width: max(size.width, Self.labelMinWidth))
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(isSelected ? 1 : 0))
        )
        .onAppear { loadThumbnailIfNeeded() }
    }

    private var metaText: String {
        if entry.isDirectory {
            if let bytes = entry.byteSize { return ShelfItem.format(bytes: bytes) }
            return L("Folder")
        }
        if let bytes = entry.byteSize { return ShelfItem.format(bytes: bytes) }
        let ext = entry.url.pathExtension
        return ext.isEmpty ? L("File") : ext.uppercased()
    }

    @ViewBuilder
    private func cardFace(size: CGSize) -> some View {
        let isImageEntry = !entry.isDirectory && entry.pixelSize != nil
        if let thumb = thumbnail {
            if isImageEntry, !thumbnailIsIcon {
                // Real photo preview: fill the whole card, rounded corners.
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
                    )
            } else {
                // Everything else (folder icon, app icon, document preview) —
                // render flush against the panel without a white "paper"
                // backdrop, matching the rest of the shelf's visual language.
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
            }
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                )
        }
    }

    private func loadThumbnailIfNeeded() {
        if thumbnail != nil { return }
        // Workspace icon shows up immediately so the cell isn't a blank
        // square while QL renders. For images we then upgrade to QL's
        // photo thumbnail; for everything else we ask QL only for the
        // higher-resolution icon representation — otherwise QL renders
        // the file's contents on a white "page", which leaks into the
        // shelf's dark UI as a paper-like backdrop.
        thumbnail = NSWorkspace.shared.icon(forFile: entry.url.path)
        thumbnailIsIcon = true
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let isImageEntry = !entry.isDirectory && entry.pixelSize != nil
        let reprTypes: QLThumbnailGenerator.Request.RepresentationTypes =
            isImageEntry ? .all : .icon
        let request = QLThumbnailGenerator.Request(
            fileAt: entry.url,
            size: CGSize(width: 256, height: 320),
            scale: scale,
            representationTypes: reprTypes
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            guard let rep else { return }
            let image = rep.nsImage
            let isIcon = (rep.type == .icon)
            DispatchQueue.main.async {
                self.thumbnail = image
                self.thumbnailIsIcon = isIcon
            }
        }
    }
}

/// List-view counterpart to FolderEntryGridCell.
private struct FolderEntryListItem: View {
    let entry: FolderEntry
    let isSelected: Bool
    let onClick: (NSEvent.ModifierFlags) -> Void
    let onDoubleClick: () -> Void
    let onNavigateInto: () -> Void
    let urlsProvider: () -> [URL]

    @State private var hovering = false
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            thumbnailView
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            Text(entry.displayName)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 6)

            Text(metaText)
                .font(.system(size: 10))
                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                .lineLimit(1)

            if entry.isDirectory {
                InlineNavigateChevron(action: onNavigateInto)
                    .frame(width: 16, height: 16)
            } else {
                Color.clear.frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected
                      ? Color.accentColor
                      : Color.primary.opacity(hovering ? 0.06 : 0))
        )
        .overlay(
            ShelfDragOverlay(
                provider: urlsProvider,
                onStart: {},
                onEnd: {},
                onClick: onClick,
                onDoubleClick: onDoubleClick
            )
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onAppear { loadThumbnail() }
    }

    private var metaText: String {
        if entry.isDirectory {
            if let bytes = entry.byteSize { return ShelfItem.format(bytes: bytes) }
            return L("Folder")
        }
        if let bytes = entry.byteSize { return ShelfItem.format(bytes: bytes) }
        let ext = entry.url.pathExtension
        return ext.isEmpty ? L("File") : ext.uppercased()
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumb = thumbnail {
            ZStack {
                Color.white.opacity(0.97)
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(2)
            }
        } else {
            ZStack {
                Color.primary.opacity(0.10)
                Image(systemName: entry.isDirectory ? "folder" : "doc")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.primary.opacity(0.7))
            }
        }
    }

    private func loadThumbnail() {
        thumbnail = NSWorkspace.shared.icon(forFile: entry.url.path)
    }
}

/// Pill that toggles selection across every item in the shelf. Once items
/// are selected, dragging any tile drags the whole selection (existing
/// behavior in DocumentGridItem / DocumentListItem).
private struct SelectAllButton: View {
    let allSelected: Bool
    let someSelected: Bool
    let enabled: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                // Hide the leading glyph entirely when nothing is selected —
                // the pill reads as a neutral "Select All" affordance until
                // the user picks at least one item.
                if someSelected {
                    Image(systemName: allSelected
                          ? "checkmark.circle.fill"
                          : "circle.dashed")
                        .font(.system(size: 11, weight: .medium))
                }
                Text(allSelected ? L("Deselect All") : L("Select All"))
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.primary.opacity(enabled ? 0.92 : 0.4))
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(hovering && enabled ? 0.16 : 0.09))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5)
            )
            .scaleEffect(hovering && enabled ? 1.03 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: hovering)
        .onHover { hovering = $0 }
    }
}

private struct DocumentGridItem: View {
    let item: ShelfItem
    let manager: ShelfManager
    let shelfID: UUID
    let isSelected: Bool
    let isBeingDragged: Bool
    let selectedURLsProvider: () -> [URL]
    let contextMenuBuilder: () -> NSMenu
    let onRemove: () -> Void
    let onClick: (NSEvent.ModifierFlags) -> Void
    let onDragStart: () -> Void
    let onDragEnd: () -> Void
    /// Invoked when the user taps the inline chevron next to a directory's
    /// name. Plain card clicks do not trigger this — the chevron is the
    /// only navigation affordance.
    let onNavigateInto: () -> Void

    @EnvironmentObject var conversionService: ConversionService
    @EnvironmentObject var ocrService: OCRService
    @State private var hovering = false

    private static let defaultCardSize = CGSize(width: 78, height: 100)
    private static let cardLongSide: CGFloat = 100
    private static let labelMinWidth: CGFloat = 90

    private var cardSize: CGSize {
        guard item.type == .image else { return Self.defaultCardSize }
        // Prefer the file's own pixel dimensions — set synchronously in
        // ShelfManager.addFile — so the card lands at the right aspect on
        // the very first render. The thumbnail-derived aspect was wrong
        // until QL replaced the placeholder icon, causing a visible
        // resize/jitter mid-drop.
        let aspectFromMeta: CGFloat? = {
            guard let s = item.pixelSize, s.width > 0, s.height > 0 else { return nil }
            return s.width / s.height
        }()
        let aspect = aspectFromMeta
            ?? item.thumbnail.flatMap(Self.aspectRatio(of:))
            ?? 1
        guard aspect.isFinite, aspect > 0 else { return Self.defaultCardSize }
        if aspect >= 1 {
            return CGSize(width: Self.cardLongSide, height: Self.cardLongSide / aspect)
        } else {
            return CGSize(width: Self.cardLongSide * aspect, height: Self.cardLongSide)
        }
    }

    var body: some View {
        let size = cardSize
        VStack(spacing: 8) {
            cardFace(size: size)
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(hovering ? 0.22 : 0.14),
                    radius: hovering ? 18 : 12, x: 0, y: hovering ? 10 : 6)
            .shadow(color: .black.opacity(0.06), radius: 2, x: 0, y: 1)
            .scaleEffect(hovering ? 1.03 : 1.0)
            .offset(y: hovering ? -3 : 0)
            .overlay(
                ShelfDragOverlay(
                    provider: selectedURLsProvider,
                    onStart: onDragStart,
                    onEnd: onDragEnd,
                    menuBuilder: contextMenuBuilder,
                    onClick: onClick,
                    onDoubleClick: {
                        if !WebDragLinks.open(item), let url = item.fileURL {
                            NSWorkspace.shared.open(url)
                        }
                    },
                    visibleCardSize: { size },
                    coversWholeShelf: { selectedURLsProvider().count == manager.items(of: shelfID).count }
                )
            )
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.black.opacity(0.6), Color.white)
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                }
            }
            .overlay {
                ProgressOverlay(
                    progress: ocrService.progress[item.id]
                        ?? conversionService.progress[item.id],
                    onCancel: {
                        ocrService.cancel(itemID: item.id)
                        conversionService.cancel(itemID: item.id)
                    }
                )
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: hovering)
            .onHover { hovering = $0 }
            // Uniform vertical slot equal to the long-side cap so short
            // (landscape) cards sit on the same baseline as tall (portrait)
            // ones — that keeps the title/meta labels aligned across the row.
            .frame(height: Self.cardLongSide, alignment: .bottom)

            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.isDirectory {
                        InlineNavigateChevron(action: onNavigateInto)
                    }
                }
                Text(item.displayMeta)
                    .font(.system(size: 10))
                    .foregroundStyle((isSelected ? Color.white.opacity(0.85) : Color.secondary))
                    .lineLimit(1)
            }
            .frame(width: max(size.width, Self.labelMinWidth))
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(isSelected ? 1 : 0))
        )
        .opacity(isBeingDragged ? 0 : 1)
        .animation(.easeOut(duration: 0.15), value: isBeingDragged)
    }

    @ViewBuilder
    private func cardFace(size: CGSize) -> some View {
        if item.type == .image, item.thumbnailIsIcon {
            // Real photo preview is still being rendered by QL. Showing the
            // generic JPEG/HEIC type icon stretched into the photo's frame
            // looks like a flash of a different image, so render a quiet
            // skeleton instead and crossfade to the real thumbnail when it
            // arrives.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .frame(width: size.width, height: size.height)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                )
                .transition(.opacity)
        } else if renderFlush, let thumb = item.thumbnail {
            if item.type == .image {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .transition(.opacity)
            } else {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.97))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
                    )
                previewContent
                    .padding(12)
            }
        }
    }

    private static func aspectRatio(of image: NSImage) -> CGFloat? {
        if let rep = image.representations.first {
            let w = CGFloat(rep.pixelsWide)
            let h = CGFloat(rep.pixelsHigh)
            if w > 0, h > 0 { return w / h }
        }
        let s = image.size
        if s.width > 0, s.height > 0 { return s.width / s.height }
        return nil
    }

    private var renderFlush: Bool {
        if item.type == .image { return true }
        return item.thumbnailIsIcon
    }

    @ViewBuilder
    private var previewContent: some View {
        if let thumbnail = item.thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else if item.type == .text, let text = item.textContent {
            Text(text)
                .font(.system(size: 7, design: .monospaced))
                .foregroundStyle(Color.black.opacity(0.78))
                .multilineTextAlignment(.leading)
                .lineSpacing(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .mask(
                    LinearGradient(
                        colors: [.black, .black, .black.opacity(0)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
        } else {
            Image(systemName: "doc")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.black.opacity(0.35))
        }
    }
}

private struct ViewModeToggle: View {
    @Binding var mode: ShelfViewMode

    var body: some View {
        HStack(spacing: 2) {
            ViewModeSegment(target: .grid, systemName: "square.grid.2x2.fill", mode: $mode)
            ViewModeSegment(target: .list, systemName: "list.bullet", mode: $mode)
        }
        .padding(2)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.10))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

private struct ViewModeSegment: View {
    let target: ShelfViewMode
    let systemName: String
    @Binding var mode: ShelfViewMode

    @State private var hovering = false

    var body: some View {
        let active = mode == target
        // contentShape() on the label is what makes the whole 26×22 area
        // hit-testable — without it, only the icon glyph itself catches
        // clicks and the list icon "feels dead" until hovered.
        Button {
            mode = target
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(active ? 0.98 : (hovering ? 0.85 : 0.55)))
                .frame(width: 26, height: 22)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            Color.primary.opacity(
                                active ? 0.20 : (hovering ? 0.10 : 0)
                            )
                        )
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: active)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

private struct DocumentListItem: View {
    let item: ShelfItem
    let manager: ShelfManager
    let shelfID: UUID
    let isSelected: Bool
    let isBeingDragged: Bool
    let selectedURLsProvider: () -> [URL]
    let contextMenuBuilder: () -> NSMenu
    let onRemove: () -> Void
    let onClick: (NSEvent.ModifierFlags) -> Void
    let onDragStart: () -> Void
    let onDragEnd: () -> Void
    let onNavigateInto: () -> Void

    @EnvironmentObject var conversionService: ConversionService
    @EnvironmentObject var ocrService: OCRService
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            thumbnail
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            Text(item.displayName)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 6)

            Text(item.displayMeta)
                .font(.system(size: 10))
                .foregroundStyle((isSelected ? Color.white.opacity(0.85) : Color.secondary))
                .lineLimit(1)

            ZStack {
                if hovering {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.black.opacity(0.5), Color.white.opacity(0.95))
                    }
                    .buttonStyle(.plain)
                } else if item.isDirectory {
                    InlineNavigateChevron(action: onNavigateInto)
                } else {
                    Color.clear
                }
            }
            .frame(width: 16, height: 16)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.accentColor.opacity(isSelected ? 1 : 0))
        )
        .overlay(
            ShelfDragOverlay(
                provider: selectedURLsProvider,
                onStart: onDragStart,
                onEnd: onDragEnd,
                menuBuilder: contextMenuBuilder,
                onClick: onClick,
                onDoubleClick: {
                    if !WebDragLinks.open(item), let url = item.fileURL {
                        NSWorkspace.shared.open(url)
                    }
                },
                coversWholeShelf: { selectedURLsProvider().count == manager.items(of: shelfID).count }
            )
        )
        .overlay {
            ProgressOverlay(
                progress: ocrService.progress[item.id]
                    ?? conversionService.progress[item.id],
                onCancel: {
                    ocrService.cancel(itemID: item.id)
                    conversionService.cancel(itemID: item.id)
                }
            )
        }
        .onHover { hovering = $0 }
        .opacity(isBeingDragged ? 0 : 1)
        .animation(.easeOut(duration: 0.15), value: isBeingDragged)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let thumb = item.thumbnail {
            if item.type == .image {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    Color.white.opacity(0.97)
                    Image(nsImage: thumb)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(2)
                }
            }
        } else if item.type == .text {
            ZStack {
                Color.primary.opacity(0.10)
                Image(systemName: "text.alignleft")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.primary.opacity(0.7))
            }
        } else {
            ZStack {
                Color.primary.opacity(0.10)
                Image(systemName: "doc")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.primary.opacity(0.7))
            }
        }
    }
}

enum ShelfDragProvider {
    static func make(for item: ShelfItem) -> NSItemProvider {
        if let url = item.fileURL {
            if FileManager.default.fileExists(atPath: url.path),
               let provider = NSItemProvider(contentsOf: url) {
                provider.suggestedName = url.lastPathComponent
                return provider
            }
            let fallback = NSItemProvider(object: url as NSURL)
            fallback.suggestedName = url.lastPathComponent
            return fallback
        }
        if let text = item.textContent {
            return NSItemProvider(object: text as NSString)
        }
        return NSItemProvider()
    }
}

private struct DropTargetOverlay: View {
    let active: Bool

    var body: some View {
        // Trace the panel's outer rounded shape directly. Earlier this
        // overlay used `.padding(-10)` to push out past FloatingPanelContent's
        // 10pt margin, but that padding has since moved into each shelf
        // branch — extending here would just clip beyond the panel bounds.
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(active ? 1 : 0), lineWidth: 3)
            .animation(.easeOut(duration: 0.15), value: active)
            .allowsHitTesting(false)
    }
}

struct ShelfAccentBadge: View {
    let accent: ShelfAccent
    var size: CGFloat = 10

    var body: some View {
        switch accent {
        case .color(let hex):
            Circle()
                .fill(Color(nsColor: NSColor(hex: hex) ?? .systemGray))
                .frame(width: size, height: size)
                .overlay(
                    Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
                )
        case .emoji(let glyph):
            Text(glyph)
                .font(.system(size: size + 2))
                .frame(width: size + 4, height: size + 4)
        }
    }
}

private struct RevealInFinderButton: View {
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .medium))
                Text(L("Reveal in Finder"))
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.primary.opacity(enabled ? 0.92 : 0.4))
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(hovering && enabled ? 0.16 : 0.09))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5)
            )
            .scaleEffect(hovering && enabled ? 1.03 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: hovering)
        .onHover { hovering = $0 }
    }
}
