import AppKit
import QuartzCore

/// Detects a horizontal "shake" gesture during a left-mouse drag anywhere on the system.
/// Works while the user is actively dragging files out of Finder (or anything else).
///
/// Note: macOS may prompt for accessibility permission the first time a global monitor is
/// installed in some environments. Mouse-drag monitoring generally works without it, but
/// if shakes aren't detected, grant the app access under System Settings → Privacy &
/// Security → Accessibility.
final class ShakeDetector {
    var onShake: (() -> Void)?
    var shouldSuppress: (() -> Bool)?
    var shouldSuppressAutomatic: (() -> Bool)?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private struct Sample {
        let time: CFTimeInterval
        let x: CGFloat
    }

    private var samples: [Sample] = []
    private var dragSummoned = false
    private var dragTimer: Timer?
    private var dragStarted: CFTimeInterval?
    private var lastShakeTime: CFTimeInterval = 0

    // Tunables
    private let window: CFTimeInterval = 0.8
    private var minReversals: Int { UserDefaults.standard.string(forKey: "shelf.shakeSensitivity") == "Low" ? 4 : 3 }
    private var minTravelPerLeg: CGFloat {
        switch UserDefaults.standard.string(forKey: "shelf.shakeSensitivity") {
        case "Low": return 18
        case "High": return 7
        default: return 12
        }
    }
    private let cooldown: CFTimeInterval = 0.8

    private var baseline: Int?
    private var gesture = 0
    private var downPoint: NSPoint?

    func start() {
        stop()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in self?.handle(event) }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            self?.resetGesture()
            return event
        }
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        resetGesture()
    }

    private func resetGesture() {
        gesture += 1
        baseline = nil
        downPoint = nil
        dragTimer?.invalidate()
        dragTimer = nil
        dragStarted = nil
        samples.removeAll()
        dragSummoned = false
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            resetGesture()
            baseline = NSPasteboard(name: .drag).changeCount
            downPoint = NSEvent.mouseLocation
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                self?.checkFileDrag()
            }
            dragTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        case .leftMouseUp:
            resetGesture()
        case .leftMouseDragged:
            checkFileDrag()
        default: break
        }
    }

    private func validFileDrag() -> Bool {
        guard let baseline, let downPoint,
              NSEvent.pressedMouseButtons & 1 != 0,
              shouldSuppress?() != true,
              !DragInitiatorView.hasActiveDrag else { return false }
        let point = NSEvent.mouseLocation
        guard hypot(point.x - downPoint.x, point.y - downPoint.y) > 4 else { return false }
        let board = NSPasteboard(name: .drag)
        guard board.changeCount != baseline else { return false }
        return board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ||
            !WebDragLinks.read(board).isEmpty ||
            board.availableType(from: [.png, .tiff]) != nil ||
            board.availableType(from: NSFilePromiseReceiver.readableDraggedTypes.map(NSPasteboard.PasteboardType.init(rawValue:))) != nil
    }

    private func checkFileDrag() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { resetGesture(); return }
        guard !dragSummoned, validFileDrag() else {
            dragStarted = nil
            samples.removeAll()
            return
        }
        let now = CACurrentMediaTime()
        if dragStarted == nil { dragStarted = now }
        samples.append(Sample(time: now, x: NSEvent.mouseLocation.x))
        samples.removeAll { now - $0.time > window }
        let mode = ShelfSummon(rawValue: UserDefaults.standard.string(forKey: "shelf.summon") ?? "instant") ?? .instant
        let timed = shouldSuppressAutomatic?() != true && (mode.delay.map { now - (dragStarted ?? now) >= $0 } ?? false)
        let shaken = mode == .shakeOnly || (UserDefaults.standard.object(forKey: "shelf.shakeEnabled") as? Bool ?? true)
        let flags = NSEvent.modifierFlags
        let modifier = UserDefaults.standard.string(forKey: "shelf.modifierActivation")
        let modified = (modifier == "Shift" && flags.contains(.shift)) || (modifier == "Option" && flags.contains(.option)) || (modifier == "Control" && flags.contains(.control))
        guard timed || modified || (shaken && detectShake() && now - lastShakeTime > cooldown) else { return }
        dragSummoned = true
        lastShakeTime = now
        let token = gesture
        DispatchQueue.main.async { [weak self] in
            guard let self, self.gesture == token, self.validFileDrag() else { return }
            self.onShake?()
        }
    }

    private func detectShake() -> Bool {
        guard samples.count >= 4 else { return false }

        var reversals = 0
        var legTravel: CGFloat = 0
        var lastDir: Int = 0

        for i in 1..<samples.count {
            let dx = samples[i].x - samples[i - 1].x
            let dir = dx > 0.5 ? 1 : (dx < -0.5 ? -1 : 0)
            if dir == 0 { continue }

            if dir == lastDir {
                legTravel += abs(dx)
            } else {
                if lastDir != 0 && legTravel >= minTravelPerLeg {
                    reversals += 1
                }
                legTravel = abs(dx)
                lastDir = dir
            }
        }
        return reversals >= minReversals
    }
}
