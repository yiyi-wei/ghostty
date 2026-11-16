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
/// old card rect to its new one over the panes that leave (on unzoom it shrinks to uncover the
/// ones that come back), then the live surface, already reflowed underneath, is revealed.
///
/// Nothing is rendered per animation frame: the terminal still resizes exactly once, exactly as
/// it would without this.
@MainActor
final class PaneZoomTransition {
    private static let moveDuration: CFTimeInterval = 0.32
    private static let settleDuration: CFTimeInterval = 0.14
    /// How fast the copied text leaves the moving card (it comes back live in `settle`).
    private static let textFadeDuration: CFTimeInterval = 0.09
    private static let moveCurve = CAMediaTimingFunction(controlPoints: 0.22, 0.9, 0.1, 1)
    /// Upper bound on waiting for SwiftUI to publish the new card rect, in 8ms steps.
    private static let maxLayoutSteps = 40

    /// The transition currently on screen; starting a new one tears the old one down so live
    /// panes are never left invisible.
    private static var running: PaneZoomTransition?

    private struct Frozen {
        let surface: Ghostty.SurfaceView
        /// The card: background colour, rounded mask and hairline. Holds `wallpaper` and `frame`.
        let layer: CALayer
        /// `background-image` placed the way the renderer places it, re-fitted while the card
        /// changes size so the picture is never squashed. Nil without a background image.
        let wallpaper: CALayer?
        /// The copied frame (text plus the picture it was rendered on), never resized.
        let frame: CALayer
        /// The unfocused-split dim, animated away while the pane grows into focus.
        let dim: CALayer?
        let rect: CGRect
    }

    private let overlay: OverlayView
    private let target: Frozen
    private let leaving: [Frozen]
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
            let card = makeCard(
                image: image,
                rect: rect,
                radius: container(of: surface)?.cardCornerRadius ?? 0,
                scale: window.backingScaleFactor)
            let layer = card.layer

            var dim: CALayer?
            if dimmed, surface !== focused {
                let opacity = config.unfocusedSplitOpacity
                if opacity > 0 {
                    let d = CALayer()
                    d.frame = layer.bounds
                    d.backgroundColor = NSColor(config.unfocusedSplitFill).cgColor
                    d.opacity = Float(opacity)
                    withoutActions { layer.addSublayer(d) }
                    dim = d
                }
            }
            frozen.append(Frozen(surface: surface, layer: layer, wallpaper: card.wallpaper,
                                 frame: card.frame, dim: dim, rect: rect))
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
            leaving: frozen.filter { $0.surface !== target })
        // Hide the live zoom target until its frozen copy has landed.
        transition.hideLive(target)
        running = transition
        return transition
    }

    private init(overlay: OverlayView, target: Frozen, leaving: [Frozen]) {
        self.overlay = overlay
        self.target = target
        self.leaving = leaving
        strongSelf = self
    }

    /// Call immediately *after* the tree was swapped, with the new tree.
    func run(tree: SplitTree<Ghostty.SurfaceView>) {
        guard !finished else { return }
        // Panes that come back on unzoom stay fully visible: they sit under the shrinking card
        // and are uncovered by it. Fading them in would let the window's own (black) backing
        // show through for a moment.
        waitForLayout(attempt: 0)
    }

    // MARK: Layout hand-off

    /// The swap lands in SwiftUI's next update, so poll briefly for the target's new card rect.
    private func waitForLayout(attempt: Int) {
        guard !finished else { return }
        overlay.window?.contentView?.layoutSubtreeIfNeeded()
        if let rect = Self.cardRect(of: target.surface, in: overlay),
           rect.width > 1, rect.height > 1,
           !Self.same(rect, target.rect) {
            animate(to: rect)
            return
        }
        guard attempt < Self.maxLayoutSteps else {
            // The pane never moved; show everything as it is rather than nothing at all.
            finish()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { [weak self] in
            self?.waitForLayout(attempt: attempt + 1)
        }
    }

    // MARK: Animation

    private func animate(to rect: CGRect) {
        guard !finished else { return }
        let from = target.rect
        let layer = target.layer

        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.moveDuration)
        CATransaction.setAnimationTimingFunction(Self.moveCurve)
        CATransaction.setCompletionBlock { [weak self] in
            DispatchQueue.main.async { self?.settle() }
        }

        let fromLocal = CGRect(origin: .zero, size: from.size)
        let toLocal = CGRect(origin: .zero, size: rect.size)
        Self.move(layer, from: from, to: rect)

        // The picture is re-placed for the card's size at both ends; in between it moves on a
        // straight line between the two placements. Both ends have the picture's own aspect
        // ratio, so every frame in between has it too (no stretching), and both ends cover
        // their card, so every frame in between covers it too.
        if let wallpaper = target.wallpaper,
           let a = Self.wallpaperRect(cardSize: from.size, scale: layer.contentsScale),
           let b = Self.wallpaperRect(cardSize: rect.size, scale: layer.contentsScale) {
            Self.move(wallpaper, from: a, to: b)
        }

        // The copied frame keeps its pixel size and stays pinned to the card's top-left corner
        // (terminal text is laid out from there), and fades out early: past the first few
        // frames its own baked-in picture would drift against the re-fitted one.
        let f = target.frame
        Self.move(f,
                  from: CGRect(x: 0, y: from.height - f.bounds.height,
                               width: f.bounds.width, height: f.bounds.height),
                  to: CGRect(x: 0, y: rect.height - f.bounds.height,
                             width: f.bounds.width, height: f.bounds.height))
        let textOut = Self.basic("opacity", from: 1, to: 0)
        textOut.duration = Self.textFadeDuration
        textOut.timingFunction = CAMediaTimingFunction(name: .easeOut)
        f.add(textOut, forKey: "opacity")
        Self.withoutActions { f.opacity = 0 }

        if let dim = target.dim {
            Self.move(dim, from: fromLocal, to: toLocal)
            let out = Self.basic("opacity", from: dim.opacity, to: 0)
            out.duration = Self.moveDuration
            dim.add(out, forKey: "opacity")
            Self.withoutActions { dim.opacity = 0 }
        }

        // Panes that leave on zoom stay opaque under the growing card (which ends up covering
        // all of them) and are dropped in `settle`. Fading them out would uncover the window's
        // black backing before the card got there.

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
        // The live pane comes back at full opacity *under* the card, then only the card fades.
        // Crossfading both (card 1→0 while live 0→1) leaves the pair a quarter transparent
        // halfway through, which read as a black blink.
        Self.withoutActions {
            target.surface.layer?.opacity = 1
            for f in leaving { f.layer.removeFromSuperlayer() }
        }
        hiddenLive.removeAll { $0 === target.surface }
        target.layer.add(Self.basic("opacity", from: 1, to: 0), forKey: "opacity")
        Self.withoutActions { target.layer.opacity = 0 }
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

    /// A card painted like the pane's own background (colour, then `background-image` at its
    /// opacity, placed as the renderer places it), with the copied frame on top at 1:1.
    private static func makeCard(
        image: CGImage, rect: CGRect, radius: CGFloat, scale: CGFloat
    ) -> (layer: CALayer, wallpaper: CALayer?, frame: CALayer) {
        let backdrop = SidebarBackdropStore.shared.backdrop
        let layer = CALayer()
        layer.frame = rect
        layer.contentsScale = scale
        layer.backgroundColor = backdrop.baseColor.withAlphaComponent(backdrop.baseOpacity).cgColor
        layer.masksToBounds = true
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        if radius > 0 {
            layer.borderWidth = 1
            layer.borderColor = NSColor(PaneCardStyle.standard.stroke).cgColor
        }

        var wallpaper: CALayer?
        if let picture = backdrop.image, backdrop.imageOpacity > 0,
           let placed = wallpaperRect(cardSize: rect.size, scale: scale) {
            let w = CALayer()
            w.frame = placed
            w.contents = picture
            w.contentsGravity = .resize
            w.contentsScale = scale
            w.opacity = Float(backdrop.imageOpacity)
            w.minificationFilter = .trilinear
            layer.addSublayer(w)
            wallpaper = w
        }

        let frame = CALayer()
        frame.frame = CGRect(origin: .zero, size: rect.size)
        frame.contents = image
        frame.contentsGravity = .resize
        frame.contentsScale = scale
        layer.addSublayer(frame)

        return (layer, wallpaper, frame)
    }

    /// Where the renderer puts `background-image` in a pane of `cardSize`, in the card layer's
    /// own coordinates (origin bottom-left; `SidebarBackdrop.imageRect` measures from the top).
    private static func wallpaperRect(cardSize: CGSize, scale: CGFloat) -> CGRect? {
        let backdrop = SidebarBackdropStore.shared.backdrop
        guard backdrop.image != nil,
              let r = backdrop.imageRect(in: CGRect(origin: .zero, size: cardSize),
                                         backingScale: scale) else { return nil }
        return CGRect(x: r.minX, y: cardSize.height - r.maxY, width: r.width, height: r.height)
    }

    /// Animates `layer` from frame `from` to frame `to` on the zoom's curve, and leaves it there.
    private static func move(_ layer: CALayer, from: CGRect, to: CGRect) {
        let bounds = basic("bounds",
                           from: CGRect(origin: .zero, size: from.size),
                           to: CGRect(origin: .zero, size: to.size))
        let position = basic("position",
                             from: CGPoint(x: from.midX, y: from.midY),
                             to: CGPoint(x: to.midX, y: to.midY))
        for a in [bounds, position] {
            a.duration = moveDuration
            a.timingFunction = moveCurve
        }
        layer.add(bounds, forKey: "bounds")
        layer.add(position, forKey: "position")
        withoutActions { layer.frame = to }
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
