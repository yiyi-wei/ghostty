import AppKit

/// Trackpad gestures for one terminal window (weihan fork):
///
/// - two-finger swipe left / right: collapse the sidebar to its rail / expand it again;
/// - pinch out over a split: zoom that split (same as `toggle_split_zoom`), pinch in: unzoom.
///
/// Implemented as a local event monitor rather than view overrides, so it works wherever the
/// pointer is (terminal, sidebar, titlebar) without touching the surface's own event code.
/// Each gesture fires at most once, and a gesture that has been claimed is swallowed whole
/// (including its momentum tail), so the terminal never sees half of it.
@MainActor
final class TerminalGestures {
    private weak var controller: BaseTerminalController?
    private weak var sidebar: SidebarModel?

    // nonisolated(unsafe): only touched from init (main) and deinit
    nonisolated(unsafe) private var monitor: Any?

    /// Horizontal travel (points of precise scroll delta) before a swipe counts.
    private let swipeThreshold: CGFloat = 40
    /// Cumulative magnification before a pinch counts.
    private let pinchThreshold: CGFloat = 0.12

    private enum Swipe { case idle, undecided(CGFloat, CGFloat), horizontal(fired: Bool), vertical }
    private var swipe: Swipe = .idle
    /// Momentum events after a claimed swipe also belong to it.
    private var swallowMomentum = false

    private var pinch: CGFloat = 0
    private var pinchFired = false

    init(controller: BaseTerminalController, sidebar: SidebarModel?) {
        self.controller = controller
        self.sidebar = sidebar
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .magnify]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = controller?.window, event.window === window else { return event }
        switch event.type {
        case .scrollWheel: return handleScroll(event)
        case .magnify: return handleMagnify(event)
        default: return event
        }
    }

    // MARK: Swipe

    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        // Mouse wheels have no phases and no horizontal intent worth stealing.
        guard sidebar != nil, event.hasPreciseScrollingDeltas else { return event }

        if event.phase.isEmpty {
            // Momentum (or legacy) events: swallow the tail of a claimed swipe only.
            if !event.momentumPhase.isEmpty, swallowMomentum {
                if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                    swallowMomentum = false
                }
                return nil
            }
            return event
        }

        if event.phase.contains(.mayBegin) || event.phase.contains(.began) {
            swipe = .undecided(0, 0)
            swallowMomentum = false
        }

        // Finger direction: with natural scrolling the delta already follows the fingers.
        let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        let dy = event.scrollingDeltaY

        var result: NSEvent? = event
        switch swipe {
        case .idle, .vertical:
            break
        case .undecided(let x, let y):
            let ax = x + dx, ay = y + dy
            if abs(ax) + abs(ay) < 6 {
                swipe = .undecided(ax, ay)
            } else if abs(ax) > abs(ay) * 2 {
                // Claimed: from here on the terminal sees nothing of this gesture.
                swipe = .horizontal(fired: false)
                swallowMomentum = true
                travel = ax
                fireSwipeIfNeeded()
                result = nil
            } else {
                swipe = .vertical
            }
        case .horizontal(let fired):
            if !fired {
                travel += dx
                fireSwipeIfNeeded()
            }
            result = nil
        }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            swipe = .idle
        }
        return result
    }

    private var travel: CGFloat = 0

    private func fireSwipeIfNeeded() {
        guard abs(travel) >= swipeThreshold, let sidebar else { return }
        swipe = .horizontal(fired: true)
        sidebar.setVisible(travel > 0)
    }

    // MARK: Pinch

    private func handleMagnify(_ event: NSEvent) -> NSEvent? {
        guard let controller else { return event }
        if event.phase.contains(.began) {
            pinch = 0
            pinchFired = false
        }
        pinch += event.magnification
        if !pinchFired, abs(pinch) >= pinchThreshold {
            pinchFired = true
            let tree = controller.surfaceTree
            if pinch > 0 {
                if tree.zoomed == nil, tree.isSplit, let target = surface(under: event, in: controller) {
                    postZoomToggle(target)
                }
            } else if case let .leaf(view)? = tree.zoomed {
                postZoomToggle(view)
            }
        }
        return nil
    }

    private func surface(under event: NSEvent, in controller: BaseTerminalController) -> Ghostty.SurfaceView? {
        for view in controller.surfaceTree {
            let p = view.convert(event.locationInWindow, from: nil)
            if view.bounds.contains(p) { return view }
        }
        return controller.focusedSurface
    }

    private func postZoomToggle(_ view: Ghostty.SurfaceView) {
        NotificationCenter.default.post(name: Ghostty.Notification.didToggleSplitZoom, object: view)
    }
}
