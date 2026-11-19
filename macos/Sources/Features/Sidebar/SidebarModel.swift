import AppKit
import Combine
import SwiftUI

/// Per-window model behind the vertical tab sidebar.
///
/// Native macOS tabs stay the source of truth (each tab is still its own NSWindow in a
/// tab group); the sidebar only *renders* `window.tabGroup.windows` and selects among them.
/// The native tab bar is hidden via `TerminalWindow.sidebarActive`.
@MainActor
final class SidebarModel: ObservableObject {
    @Published private(set) var items: [SidebarItem] = []
    @Published var selection: SidebarItem.ID?
    @Published private(set) var isVisible: Bool = true

    nonisolated static let width: CGFloat = 232
    /// Collapsed: a rail wide enough to clear the traffic lights and still hold the status
    /// glyph of every tab, so switching tabs — and seeing which one is waiting — keeps working.
    nonisolated static let railWidth: CGFloat = 40

    /// Column width in the current state, for anything that has to reserve layout space.
    var currentWidth: CGFloat { isVisible ? Self.width : Self.railWidth }

    /// On by default with the transparent titlebar; `GHOSTTY_SIDEBAR=0` turns it off.
    static func isEnabled(config: Ghostty.Config) -> Bool {
        if ProcessInfo.processInfo.environment["GHOSTTY_SIDEBAR"] == "0" { return false }
        return config.macosTitlebarStyle == .transparent
    }

    /// The sidebar's surface: the terminal's own background colour and background image,
    /// so the column reads as part of the window rather than a panel on top of it.
    @Published private(set) var backdrop = SidebarBackdrop()

    /// Hiding never removes the column: it collapses to the rail. Tabs therefore always stay
    /// reachable, and the native tab bar stays hidden in both states.
    /// Visibility is app-wide: every tab is its own window with its own model, and a
    /// sidebar that reappeared when switching tabs would be wrong.
    func toggle() {
        Self.globalVisible.toggle()
        NotificationCenter.default.post(name: Self.visibilityDidChange, object: nil)
    }

    /// Swipe gestures ask for a state rather than a flip: swiping left on a rail is a no-op.
    func setVisible(_ visible: Bool) {
        guard visible != Self.globalVisible else { return }
        toggle()
    }
    private static var globalVisible = true
    private static let visibilityDidChange = Notification.Name("GhosttySidebarVisibilityDidChange")

    /// Splits reflow while the sidebar slides; their "cols ⨯ rows" resize overlay should
    /// not flash for that. Read by `SurfaceResizeOverlay`. Main thread only.
    nonisolated(unsafe) static var resizeOverlayQuietUntil: ContinuousClock.Instant?

    private func applyVisibility(animated: Bool) {
        guard isVisible != Self.globalVisible else { return }
        // Animation length plus slack for the last layout pass to land.
        Self.resizeOverlayQuietUntil = ContinuousClock.now + .milliseconds(600)
        if animated {
            withAnimation(.easeInOut(duration: 0.16)) { isVisible = Self.globalVisible }
        } else {
            isVisible = Self.globalVisible
        }
    }

    private weak var window: NSWindow?
    // nonisolated(unsafe): only touched from init (main) and deinit
    nonisolated(unsafe) private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    /// Last time each tab (by item id) was the selected tab. A `done` older than this was seen.
    private static var lastSeen: [String: Date] = [:]

    init(window: NSWindow, config: Ghostty.Config) {
        self.window = window

        SidebarBackdropStore.shared.sync(config: config)
        backdrop = SidebarBackdropStore.shared.backdrop

        SidebarBackdropStore.shared.$backdrop
            .receive(on: DispatchQueue.main)
            .sink { [weak self] next in self?.backdrop = next }
            .store(in: &cancellables)

        AgentStatusStore.shared.$entries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &cancellables)

        // Titles and pwd change without a single notification we can hook for every tab
        // in the group, so poll cheaply; the list is a handful of windows.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }

        let nc = NotificationCenter.default
        nc.publisher(for: .ghosttyConfigDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                // App-level reloads only; per-surface overrides do not restyle the chrome.
                guard note.object == nil, let config = note.userInfo?[
                    Notification.Name.GhosttyConfigChangeKey
                ] as? Ghostty.Config else { return }
                self?.configChanged(config)
            }
            .store(in: &cancellables)

        nc.publisher(for: Self.visibilityDidChange)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyVisibility(animated: true) } }
            .store(in: &cancellables)
        isVisible = Self.globalVisible

        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            nc.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    // tab group membership settles one runloop later
                    DispatchQueue.main.async { self?.refresh() }
                }
                .store(in: &cancellables)
        }

        refresh()
    }

    deinit {
        timer?.invalidate()
    }

    /// Split out so the closure above stays a one-liner: a config reload restyles the
    /// sidebar's backdrop, and can turn the sidebar itself off.
    private func configChanged(_ config: Ghostty.Config) {
        SidebarBackdropStore.shared.sync(config: config)
        if !Self.isEnabled(config: config) {
            (window as? TerminalWindow)?.sidebarActive = false
        }
    }

    static func id(for window: NSWindow) -> String {
        String(UInt(bitPattern: ObjectIdentifier(window).hashValue))
    }

    func refresh() {
        guard let window else { return }
        let windows = window.tabGroup?.windows ?? [window]
        let selected = window.tabGroup?.selectedWindow ?? window
        let selectedID = Self.id(for: selected)
        let now = Date()
        Self.lastSeen[selectedID] = now

        let statuses = AgentStatusStore.shared.entries
        let next: [SidebarItem] = windows.compactMap { w in
            guard let controller = w.windowController as? TerminalController else { return nil }
            let id = Self.id(for: w)
            let leaves = controller.surfaceTree.root?.leaves() ?? []
            let focused = controller.focusedSurface ?? leaves.first

            var status: AgentStatus?
            var doneAt: Date?
            for leaf in leaves {
                guard let key = AgentStatusStore.key(forTTY: leaf.surfaceModel?.ttyName),
                      let entry = statuses[key] else { continue }
                status = Self.merge(status, entry.status)
                if entry.status == .done { doneAt = max(doneAt ?? .distantPast, entry.changedAt) }
            }
            // "done" means finished and not yet looked at.
            if status == .done, let doneAt {
                if id == selectedID || (Self.lastSeen[id] ?? .distantPast) > doneAt {
                    status = nil
                }
            }

            return SidebarItem(
                id: id,
                title: w.title.isEmpty ? "Ghostty" : w.title,
                directory: Self.abbreviate(focused?.pwd),
                status: status)
        }

        if next != items { items = next }
        if selection != selectedID { selection = selectedID }
    }

    /// The tab (in this window's tab group) a sidebar row currently stands for.
    /// Resolved against the live group, so a row id that has gone away yields nothing.
    private func window(forRow id: SidebarItem.ID) -> NSWindow? {
        guard let window else { return nil }
        let windows = window.tabGroup?.windows ?? [window]
        return windows.first { Self.id(for: $0) == id }
    }

    func move(_ source: Ghostty.SurfaceView, to id: SidebarItem.ID) {
        guard let target = window(forRow: id),
              let controller = target.windowController as? TerminalController,
              controller.moveSplitToWorkspace(source) else { return }
        target.makeKeyAndOrderFront(nil)
        refresh()
    }

    /// Selects the tab with the given id inside this window's tab group.
    func select(_ id: SidebarItem.ID?) {
        guard let id, let target = window(forRow: id) else { return }
        if target != window?.tabGroup?.selectedWindow {
            target.makeKeyAndOrderFront(nil)
        }
    }

    /// waiting > working > done: the most urgent state of any split wins.
    private static func merge(_ a: AgentStatus?, _ b: AgentStatus) -> AgentStatus {
        func rank(_ s: AgentStatus?) -> Int {
            switch s {
            case .waiting?: return 3
            case .working?: return 2
            case .done?: return 1
            case nil: return 0
            }
        }
        return rank(b) > rank(a) ? b : (a ?? b)
    }

    private static func abbreviate(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "" }
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

/// The sidebar column, either full or collapsed to a rail. Both states are the tab chrome,
/// so the native tab bar stays hidden in both and the column itself is what changes width.
/// It paints nothing behind itself: the window floor (`SidebarColumns`) shows through.
struct SidebarHost: View {
    @ObservedObject var model: SidebarModel
    var onNewTab: () -> Void

    private var selection: Binding<SidebarItem.ID?> {
        Binding(get: { model.selection }, set: { model.select($0) })
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            SidebarView(
                items: model.items,
                selection: selection,
                titlebarHeight: 28,
                onToggleSidebar: { model.toggle() },
                onNewTab: onNewTab,
                onMoveSplit: model.move)
            .allowsHitTesting(model.isVisible)
            .frame(width: SidebarModel.width, alignment: .topLeading)
            .opacity(model.isVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.16), value: model.isVisible)

            SidebarView(
                items: model.items,
                selection: selection,
                titlebarHeight: 28,
                isRail: true,
                onToggleSidebar: { model.toggle() },
                onNewTab: onNewTab,
                onMoveSplit: model.move)
            .allowsHitTesting(!model.isVisible)
            .frame(width: SidebarModel.railWidth, alignment: .topLeading)
            .opacity(model.isVisible ? 0 : 1)
            .animation(.easeInOut(duration: 0.16), value: model.isVisible)
        }
        // Width is not animated: every frame of it would resize the Metal surface, which
        // snaps rather than glides. One clean reflow, with the content cross-fading.
        .frame(width: model.isVisible ? SidebarModel.width : SidebarModel.railWidth,
               alignment: .topLeading)
        .transaction { $0.animation = nil }
        .clipped()
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// Window content root: sidebar column (reaching up under the traffic lights) + terminal.
struct SidebarTerminalRoot<Content: View>: View {
    let model: SidebarModel?
    var onNewTab: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        if let model {
            SidebarColumns(model: model, onNewTab: onNewTab, content: content)
        } else {
            content()
        }
    }
}

private struct SidebarColumns<Content: View>: View {
    @ObservedObject var model: SidebarModel
    var onNewTab: () -> Void
    @ViewBuilder var content: () -> Content
    /// Height of the titlebar strip above the terminal (the terminal starts below it).
    @State private var safeTop: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            SidebarHost(model: model, onNewTab: onNewTab)
            content()
                .environment(\.paneCardStyle, .standard)
        }
        .backgroundPreferenceValue(PaneCardAnchorsKey.self) { anchors in
            // One floor under the whole window: the sidebar and the gaps between the cards
            // are the same picture, placed exactly as the card next to the sidebar places it,
            // so the sidebar runs straight into that card.
            GeometryReader { geo in
                let canvas = geo.size
                let cards = anchors.map { geo[$0] }
                let card = PaneCards.anchorCard(cards)
                    ?? CGRect(x: model.currentWidth, y: safeTop,
                              width: max(canvas.width - model.currentWidth, 0),
                              height: max(canvas.height - safeTop, 0))
                SidebarBackdropView(
                    backdrop: model.backdrop,
                    canvas: canvas,
                    anchor: card,
                    imageTop: safeTop)
                // The cards draw their own (translucent) picture; the floor must not show
                // through them a second time.
                .mask(PaneCardHoles(cards: cards, radius: PaneCardStyle.standard.radius)
                    .fill(style: FillStyle(eoFill: true)))
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { safeTop = geo.safeAreaInsets.top }
                    .onChange(of: geo.safeAreaInsets.top) { safeTop = $0 }
            }
        )
    }
}
