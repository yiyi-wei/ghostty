import AppKit
import IOSurface
import QuartzCore
import SwiftUI

/// Zooming a split (cmd+shift+z or a pinch) swaps the whole split tree in one SwiftUI update
/// and the terminal reflows at its new size a frame or two later. On screen that reads as a
/// jump plus a blink. This plays the change as motion instead.
///
/// Just before the swap every visible pane is frozen into a layer holding a copy of the frame
/// its renderer last presented. After the swap the zoomed pane's frozen copy glides from its
/// old card rect to its new one while the panes that leave fade out (and the ones that come
/// back fade in), then the live surface — already reflowed underneath — crossfades in.
///
/// Nothing is rendered per animation frame: the terminal still resizes exactly once, exactly as
/// it would without this.
@MainActor
final class PaneZoomTransition {
    private static let moveDuration: CFTimeInterval = 0.32
    private static let settleDuration: CFTimeInterval = 0.14
    private static let moveCurve = CAMediaTimingFunction(controlPoints: 0.22, 0.9, 0.1, 1)
    /// Upper bound on waiting for SwiftUI to publish the new card rect, in 8ms steps.
    private static let maxLayoutSteps = 40

    /// The transition currently on screen; starting a new one tears the old one down so live
    /// panes are never left invisible.
    private static var running: PaneZoomTransition?

    private struct Frozen {
        let surface: Ghostty.SurfaceView
        let layer: CALayer
        /// The unfocused-split dim, animated away while the pane grows into focus.
        let dim: CALayer?
        let rect: CGRect
    }

    private let overlay: OverlayView
    private let target: Frozen
    private let leaving: [Frozen]
    private let oldVisible: Set<ObjectIdentifier>
    /// Live surfaces we made transparent; every one is restored in `finish`.
    private var hiddenLive: [Ghostty.SurfaceView] = []
    private var finished = false
    private var strongSelf: PaneZoomTransition?

    /// Call immediately *before* the tree is swapped. Returns nil when there is nothing
    /// sensible to animate (no window, renderer has not presented a frame yet, ...).
    static func capture(
        tree: SplitTree<Ghostty.SurfaceView>,
        target: Ghostty.SurfaceView,
        focused: Ghostty.SurfaceView?,
        config: Ghostty.Config
    ) -> PaneZoomTransition? {
        running?.finish()
        running = nil

        guard let window = target.window, let content = window.contentView else { return nil }
        let visible: [Ghostty.SurfaceView] = (tree.zoomed ?? tree.root)?.leaves() ?? []
        guard visible.contains(where: { $0 === target }) else { return nil }
        let dimmed = tree.zoomed == nil && tree.isSplit

        let overlay = OverlayView(frame: content.bounds)
        overlay.autoresizingMask = [.width, .height]
        let root = CALayer()
        root.contentsScale = window.backingScaleFactor
        overlay.layer = root
        overlay.wantsLayer = true
        content.addSubview(overlay, positioned: .above, relativeTo: nil)

        var frozen: [Frozen] = []
        for surface in visible {
            guard let rect = cardRect(of: surface, in: overlay),
                  let image = snapshot(surface) else { continue }
            let layer = makeCard(
                image: image,
                rect: rect,
                radius: container(of: surface)?.cardCornerRadius ?? 0,
                scale: window.backingScaleFactor)

            var dim: CALayer?
            if dimmed, surface !== focused {
                let opacity = config.unfocusedSplitOpacity
                if opacity > 0 {
                    let d = CALayer()
                    d.frame = layer.bounds
                    d.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
                    d.backgroundColor = NSColor(config.unfocusedSplitFill).cgColor
                    d.opacity = Float(opacity)
                    withoutActions { layer.addSublayer(d) }
                    dim = d
                }
            }
            frozen.append(Frozen(surface: surface, layer: layer, dim: dim, rect: rect))
        }

        guard let mine = frozen.first(where: { $0.surface === target }) else {
            overlay.removeFromSuperview()
            return nil
        }

        withoutActions {
            // Everything that stays or leaves sits below the one that moves.
            for f in frozen where f.surface !== target { root.addSublayer(f.layer) }
            root.addSublayer(mine.layer)
        }

        let transition = PaneZoomTransition(
            overlay: overlay,
            target: mine,
            leaving: frozen.filter { $0.surface !== target },
            oldVisible: Set(visible.map(ObjectIdentifier.init)))
        // Hide the live zoom target until its frozen copy has landed.
        transition.hideLive(target)
        running = transition
        return transition
    }

    private init(overlay: OverlayView, target: Frozen, leaving: [Frozen], oldVisible: Set<ObjectIdentifier>) {
        self.overlay = overlay
        self.target = target
        self.leaving = leaving
        self.oldVisible = oldVisible
        strongSelf = self
    }

    /// Call immediately *after* the tree was swapped, with the new tree.
    func run(tree: SplitTree<Ghostty.SurfaceView>) {
        guard !finished else { return }
        // Panes that come back on unzoom start transparent and fade in with the motion.
        let appearing = ((tree.zoomed ?? tree.root)?.leaves() ?? [])
            .filter { !oldVisible.contains(ObjectIdentifier($0)) }
        appearing.forEach(hideLive)
        waitForLayout(attempt: 0, appearing: appearing)
    }

    // MARK: Layout hand-off

    /// The swap lands in SwiftUI's next update, so poll briefly for the target's new card rect.
    private func waitForLayout(attempt: Int, appearing: [Ghostty.SurfaceView]) {
        guard !finished else { return }
        overlay.window?.contentView?.layoutSubtreeIfNeeded()
        if let rect = Self.cardRect(of: target.surface, in: overlay),
           rect.width > 1, rect.height > 1,
           !Self.same(rect, target.rect) {
            animate(to: rect, appearing: appearing)
            return
        }
        guard attempt < Self.maxLayoutSteps else {
            // The pane never moved; show everything as it is rather than nothing at all.
            finish()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { [weak self] in
            self?.waitForLayout(attempt: attempt + 1, appearing: appearing)
        }
    }

    // MARK: Animation

    private func animate(to rect: CGRect, appearing: [Ghostty.SurfaceView]) {
        guard !finished else { return }
        let from = target.rect
        let layer = target.layer

        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.moveDuration)
        CATransaction.setAnimationTimingFunction(Self.moveCurve)
        CATransaction.setCompletionBlock { [weak self] in
            DispatchQueue.main.async { self?.settle() }
        }

        layer.add(Self.basic("bounds",
                             from: CGRect(origin: .zero, size: from.size),
                             to: CGRect(origin: .zero, size: rect.size)),
                  forKey: "bounds")
        layer.add(Self.basic("position",
                             from: CGPoint(x: from.midX, y: from.midY),
                             to: CGPoint(x: rect.midX, y: rect.midY)),
                  forKey: "position")
        if let dim = target.dim {
            dim.add(Self.basic("opacity", from: dim.opacity, to: 0), forKey: "opacity")
        }
        Self.withoutActions {
            layer.frame = rect
            target.dim?.opacity = 0
        }

        for f in leaving {
            let fade = Self.basic("opacity", from: 1, to: 0)
            fade.duration = Self.moveDuration * 0.7
            f.layer.add(fade, forKey: "opacity")
            Self.withoutActions { f.layer.opacity = 0 }
        }

        let appearStart = CACurrentMediaTime() + Self.moveDuration * 0.2
        for surface in appearing {
            guard let live = surface.layer else { continue }
            let fade = Self.basic("opacity", from: 0, to: 1)
            fade.beginTime = appearStart
            fade.duration = Self.moveDuration * 0.8
            fade.fillMode = .backwards
            live.add(fade, forKey: "paneZoomFade")
            Self.withoutActions { live.opacity = 1 }
            hiddenLive.removeAll { $0 === surface }
        }

        CATransaction.commit()
    }

    /// The frozen copy has landed on the live pane's rect: hand over to the live one.
    private func settle() {
        guard !finished else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.settleDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setCompletionBlock { [weak self] in
            DispatchQueue.main.async { self?.finish() }
        }
        target.layer.add(Self.basic("opacity", from: 1, to: 0), forKey: "opacity")
        Self.withoutActions { target.layer.opacity = 0 }
        if let live = target.surface.layer {
            live.add(Self.basic("opacity", from: 0, to: 1), forKey: "paneZoomFade")
            Self.withoutActions { live.opacity = 1 }
            hiddenLive.removeAll { $0 === target.surface }
        }
        CATransaction.commit()
    }

    /// Ends everything at once (also used when another zoom starts mid-flight): live panes fully
    /// visible again, frozen copies gone.
    func finish() {
        guard !finished else { return }
        finished = true
        Self.withoutActions {
            for surface in hiddenLive { surface.layer?.opacity = 1 }
        }
        hiddenLive.removeAll()
        overlay.removeFromSuperview()
        strongSelf = nil
        if Self.running === self { Self.running = nil }
    }

    private func hideLive(_ surface: Ghostty.SurfaceView) {
        guard let live = surface.layer else { return }
        Self.withoutActions { live.opacity = 0 }
        hiddenLive.append(surface)
    }

    // MARK: Helpers

    /// The pane's card on screen: its scroll container, which carries the rounded mask.
    private static func cardRect(of surface: Ghostty.SurfaceView, in overlay: NSView) -> CGRect? {
        guard surface.window != nil, surface.window === overlay.window else { return nil }
        let view: NSView = container(of: surface) ?? surface
        return view.convert(view.bounds, to: overlay)
    }

    private static func container(of surface: Ghostty.SurfaceView) -> SurfaceScrollView? {
        var view = surface.superview
        while let v = view {
            if let scroll = v as? SurfaceScrollView { return scroll }
            view = v.superview
        }
        return nil
    }

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1
            && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    private static func makeCard(image: CGImage, rect: CGRect, radius: CGFloat, scale: CGFloat) -> CALayer {
        let layer = CALayer()
        layer.frame = rect
        layer.contents = image
        layer.contentsScale = scale
        // Stretch the frozen frame into the growing/shrinking card: a brief scale reads as
        // motion, and it crossfades into crisp reflowed text a third of a second later.
        layer.contentsGravity = .resize
        let backdrop = SidebarBackdropStore.shared.backdrop
        layer.backgroundColor = backdrop.baseColor.withAlphaComponent(backdrop.baseOpacity).cgColor
        layer.masksToBounds = true
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        if radius > 0 {
            layer.borderWidth = 1
            layer.borderColor = NSColor(PaneCardStyle.standard.stroke).cgColor
        }
        return layer
    }

    /// A copy of the frame the surface's renderer last presented. Its layer contents is an
    /// IOSurface the renderer keeps reusing, so the pixels must be copied, not referenced.
    private static func snapshot(_ surface: Ghostty.SurfaceView) -> CGImage? {
        guard let raw = surface.layer?.contents else { return nil }
        let object = raw as CFTypeRef
        guard CFGetTypeID(object) == IOSurfaceGetTypeID() else { return nil }
        let io = unsafeBitCast(object, to: IOSurfaceRef.self)

        guard IOSurfaceLock(io, .readOnly, nil) == KERN_SUCCESS else { return nil }
        defer { _ = IOSurfaceUnlock(io, .readOnly, nil) }
        let width = IOSurfaceGetWidth(io)
        let height = IOSurfaceGetHeight(io)
        let bytesPerRow = IOSurfaceGetBytesPerRow(io)
        guard width > 0, height > 0, bytesPerRow > 0 else { return nil }
        let data = Data(bytes: IOSurfaceGetBaseAddress(io), count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData),
              // Sampled the way the renderer writes it (src/renderer/metal/Target.zig:
              // 32BGRA in Display P3), so colours match the live pane.
              let space = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func basic(_ keyPath: String, from: Any, to: Any) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        return a
    }

    private static func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// Never takes clicks or the cursor; it only exists for half a second.
    private final class OverlayView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
