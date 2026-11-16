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

    /// On by default with the transparent titlebar; `GHOSTTY_SIDEBAR=0` turns it off.
    static func isEnabled(config: Ghostty.Config) -> Bool {
        if ProcessInfo.processInfo.environment["GHOSTTY_SIDEBAR"] == "0" { return false }
        return config.macosTitlebarStyle == .transparent
    }

    /// Hiding the sidebar brings the native tab bar back, so tabs are never invisible.
    /// Visibility is app-wide: every tab is its own window with its own model, and a
    /// sidebar that reappears when switching tabs would be wrong.
    func toggle() {
        Self.globalVisible.toggle()
        NotificationCenter.default.post(name: Self.visibilityDidChange, object: nil)
    }

    private static var globalVisible = true
    private static let visibilityDidChange = Notification.Name("GhosttySidebarVisibilityDidChange")

    private func applyVisibility(animated: Bool) {
        guard isVisible != Self.globalVisible else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.18)) { isVisible = Self.globalVisible }
        } else {
            isVisible = Self.globalVisible
        }
        (window as? TerminalWindow)?.sidebarActive = isVisible
    }

    private weak var window: NSWindow?
    // nonisolated(unsafe): only touched from init (main) and deinit
    nonisolated(unsafe) private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    /// Last time each tab (by item id) was the selected tab. A `done` older than this was seen.
    private static var lastSeen: [String: Date] = [:]

    init(window: NSWindow) {
        self.window = window

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

    /// Selects the tab with the given id inside this window's tab group.
    func select(_ id: SidebarItem.ID?) {
        guard let id, let window else { return }
        let windows = window.tabGroup?.windows ?? [window]
        guard let target = windows.first(where: { Self.id(for: $0) == id }) else { return }
        if target != window.tabGroup?.selectedWindow {
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

/// The sidebar placed next to the terminal content, sharing the titlebar strip.
struct SidebarHost: View {
    @ObservedObject var model: SidebarModel
    var onNewTab: () -> Void

    var body: some View {
        SidebarView(
            items: model.items,
            selection: Binding(
                get: { model.selection },
                set: { model.select($0) }),
            titlebarHeight: 28,
            onToggleSidebar: { model.toggle() },
            onNewTab: onNewTab)
        .frame(width: SidebarModel.width)
        .background(SidebarBackground())
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

    var body: some View {
        HStack(spacing: 0) {
            if model.isVisible {
                SidebarHost(model: model, onNewTab: onNewTab)
                    .ignoresSafeArea(.container, edges: .top)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            content()
        }
    }
}

/// Slightly darker than the terminal so the sidebar reads as chrome, not content, while
/// the window's own background-opacity/blur still shows through.
private struct SidebarBackground: View {
    var body: some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.18)
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 0.5)
        }
        .ignoresSafeArea()
    }
}
