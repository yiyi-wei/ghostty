import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

/// Agent state of a tab. `nil` on `SidebarItem.status` means a plain shell.
enum AgentStatus: Equatable {
    case working   // agent is busy
    case waiting   // agent is blocked on the user
    case done      // agent finished and the tab has not been looked at yet
}

struct SidebarItem: Identifiable, Equatable {
    let id: String
    var title: String
    /// Already abbreviated (`~/…`). The view truncates the middle when it overflows.
    var directory: String
    var status: AgentStatus?
}

/// Fixed section order: what needs you first, then what is moving, then what finished, then the rest.
enum SidebarSection: CaseIterable, Identifiable {
    case needsYou, inProgress, finished, other

    var id: Self { self }

    var title: String {
        switch self {
        case .needsYou: return "需要你"
        case .inProgress: return "进行中"
        case .finished: return "已完成"
        case .other: return "其他"
        }
    }

    func contains(_ item: SidebarItem) -> Bool {
        switch (self, item.status) {
        case (.needsYou, .waiting?), (.inProgress, .working?), (.finished, .done?), (.other, nil):
            return true
        default:
            return false
        }
    }
}

// MARK: - Palette

/// Colour language taken from Ghostty's own app icon (images/Ghostty.icon):
/// a graphite/silver body (P3 0.88 → 0.40 grey), a deep navy screen (black → indigo),
/// and an ice-blue glowing ghost. No warm or green signal hues anywhere.
enum SidebarVariant: String {
    case ice      // graphite neutrals + ice-blue ghost glow for "needs you"
    case graphite // pure monochrome; "needs you" is simply the brightest thing
    case navy     // ice-blue signal + the icon's navy screen tint on selection

    static let current = SidebarVariant(rawValue: ProcessInfo.processInfo.environment["SIDEBAR_VARIANT"] ?? "") ?? .ice
}

enum SidebarPalette {
    private static let v = SidebarVariant.current

    /// The ghost's glow in the icon, slightly desaturated so it sits on a dark terminal without shouting.
    static let ghost = Color(red: 0.60, green: 0.78, blue: 1.00)
    /// The icon's screen indigo.
    static let navy = Color(red: 0.16, green: 0.24, blue: 0.78)

    static var waiting: Color { v == .graphite ? Color.primary.opacity(0.95) : ghost }
    static var waitingHeader: Color { v == .graphite ? Color.primary.opacity(0.70) : ghost.opacity(0.78) }
    static let done = Color.primary.opacity(0.42)
    static let working = Color.primary.opacity(0.50)

    static let title = Color.primary.opacity(0.90)
    static let titleIdle = Color.primary.opacity(0.70)
    static let directory = Color.primary.opacity(0.38)
    static let sectionHeader = Color.primary.opacity(0.34)
    static let chrome = Color.primary.opacity(0.40)

    static var selectionFill: Color { v == .navy ? navy.opacity(0.17) : Color.primary.opacity(0.085) }
    static var selectionTop: Color { v == .navy ? navy.opacity(0.24) : Color.primary.opacity(0.11) }
    static var selectionEdge: Color { v == .navy ? ghost.opacity(0.10) : Color.primary.opacity(0.07) }
    static let hoverFill = Color.primary.opacity(0.04)
    /// Halo around the waiting dot: a glow, not a pulse ring.
    static var waitingGlow: Double { v == .graphite ? 0.0 : 0.55 }
}

// MARK: - Sidebar

struct SidebarView: View {
    let items: [SidebarItem]
    @Binding var selection: SidebarItem.ID?
    /// Height reserved at the top for the traffic lights (transparent titlebar).
    var titlebarHeight: CGFloat = 28
    /// Collapsed form: glyphs only, so the column still switches tabs without a flyout.
    var isRail: Bool = false
    var onToggleSidebar: () -> Void = {}
    var onNewTab: () -> Void = {}
    var onMoveSplit: @MainActor (Ghostty.SurfaceView, SidebarItem.ID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            titlebarRow
            if isRail {
                railList
            } else {
                fullList
            }
            footer
        }
    }

    private var fullList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(SidebarSection.allCases) { section in
                    let rows = items.filter(section.contains)
                    if !rows.isEmpty {
                        SidebarSectionView(section: section, rows: rows, selection: $selection, onMoveSplit: onMoveSplit)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
    }

    /// Rail: same order as the full list (needs-you first), status carried by the glyph.
    /// Waiting rows keep their glow — that is the whole point of leaving the rail visible.
    private var railList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                ForEach(railItems) { item in
                    SidebarRailRow(item: item, isSelected: item.id == selection)
                        .contentShape(Rectangle())
                        .onTapGesture { selection = item.id }
                        .modifier(WorkspaceDropTarget(enabled: item.id != selection) { onMoveSplit($0, item.id) })
                        .help(item.title)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var railItems: [SidebarItem] {
        SidebarSection.allCases.flatMap { section in items.filter(section.contains) }
    }

    /// Shares the titlebar strip with the traffic lights; only a sidebar toggle at the trailing edge.
    private var titlebarRow: some View {
        HStack {
            Spacer()
            // Collapsed, the trailing edge is where the traffic lights would collide, so the
            // expand affordance moves down to the footer.
            if !isRail {
                ChromeButton(symbol: "sidebar.left", action: onToggleSidebar)
            }
        }
        .frame(height: titlebarHeight)
        .padding(.horizontal, 10)
    }

    private var footer: some View {
        HStack {
            ChromeButton(symbol: isRail ? "sidebar.right" : "plus",
                         action: isRail ? onToggleSidebar : onNewTab)
            if !isRail { Spacer() }
        }
        .frame(maxWidth: .infinity, alignment: isRail ? .center : .leading)
        .padding(.horizontal, isRail ? 0 : 10)
        .padding(.bottom, 10)
    }
}

/// One row of the collapsed rail: status glyph over nothing else, so the column stays a
/// switch and a status light at once.
private struct SidebarRailRow: View {
    let item: SidebarItem
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? SidebarPalette.selectionFill
                      : (isHovered ? SidebarPalette.hoverFill : Color.clear))
                .frame(width: 30, height: 28)
            if let status = item.status {
                StatusGlyph(status: status)
            } else {
                Circle()
                    .fill(SidebarPalette.directory.opacity(isSelected ? 0.9 : 0.55))
                    .frame(width: 5, height: 5)
            }
        }
        .frame(maxWidth: .infinity)
        .onHover { isHovered = $0 }
    }
}

private struct SidebarSectionView: View {
    let section: SidebarSection
    let rows: [SidebarItem]
    @Binding var selection: SidebarItem.ID?
    let onMoveSplit: @MainActor (Ghostty.SurfaceView, SidebarItem.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(section.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(section == .needsYou ? SidebarPalette.waitingHeader : SidebarPalette.sectionHeader)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)

            ForEach(rows) { item in
                SidebarRow(item: item, isSelected: item.id == selection)
                    .contentShape(Rectangle())
                    .onTapGesture { selection = item.id }
                    .modifier(WorkspaceDropTarget(enabled: item.id != selection) { onMoveSplit($0, item.id) })
            }
        }
    }
}

private struct WorkspaceDropTarget: ViewModifier {
    let enabled: Bool
    let onMove: @MainActor (Ghostty.SurfaceView) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if enabled && targeted {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(SidebarPalette.ghost.opacity(0.75), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.ghosttySurfaceId], delegate: WorkspaceDropDelegate(
                enabled: enabled,
                targeted: $targeted,
                onMove: onMove))
    }

    private struct WorkspaceDropDelegate: DropDelegate {
        let enabled: Bool
        @Binding var targeted: Bool
        let onMove: @MainActor (Ghostty.SurfaceView) -> Void

        func validateDrop(info: DropInfo) -> Bool {
            enabled && info.hasItemsConforming(to: [.ghosttySurfaceId])
        }

        func dropEntered(info: DropInfo) { targeted = true }
        func dropExited(info: DropInfo) { targeted = false }
        func dropUpdated(info: DropInfo) -> DropProposal? {
            DropProposal(operation: enabled ? .move : .forbidden)
        }

        func performDrop(info: DropInfo) -> Bool {
            targeted = false
            guard enabled, let provider = info.itemProviders(for: [.ghosttySurfaceId]).first else { return false }
            let move = onMove
            _ = provider.loadTransferable(type: Ghostty.SurfaceView.self) { result in
                guard case .success(let surface) = result else { return }
                DispatchQueue.main.async { move(surface) }
            }
            return true
        }
    }
}

private struct SidebarRow: View {
    let item: SidebarItem
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            StatusGlyph(status: item.status)
                .frame(width: 14, height: 17)   // 17pt = title line box, so the glyph centres on the title
            VStack(alignment: .leading, spacing: 1) {
                titleText
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: 17, alignment: .leading)
                Text(item.directory)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(SidebarPalette.directory)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(background)
        .onHover { isHovered = $0 }
    }

    /// The agent prefix (`π - `) repeats on every agent tab and the glyph already says "agent",
    /// so it is kept but dimmed; the distinctive part of the title carries the row.
    private var titleText: Text {
        let color = item.status == nil && !isSelected ? SidebarPalette.titleIdle : SidebarPalette.title
        let prefix = "π - "
        guard item.title.hasPrefix(prefix) else {
            return Text(item.title).foregroundColor(color)
        }
        return Text("π  ").foregroundColor(SidebarPalette.directory)
            + Text(item.title.dropFirst(prefix.count)).foregroundColor(color)
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if isSelected {
            // Flat: a raised, bevelled pill read as frosted glass over the picture.
            shape.fill(SidebarPalette.selectionFill)
        } else if isHovered {
            shape.fill(SidebarPalette.hoverFill)
        }
    }
}

// MARK: - Status glyphs

struct StatusGlyph: View {
    let status: AgentStatus?

    var body: some View {
        switch status {
        case .working?: WorkingGlyph()
        case .waiting?: WaitingGlyph()
        case .done?: DoneGlyph()
        case nil: Color.clear
        }
    }
}

/// A thin arc that turns slowly — alive, but at the volume of a system spinner.
private struct WorkingGlyph: View {
    private let period: Double = 1.6

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let angle = (t.truncatingRemainder(dividingBy: period) / period) * 360
            ZStack {
                Circle().stroke(SidebarPalette.working.opacity(0.25), lineWidth: 1.4)
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(SidebarPalette.working, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                    .rotationEffect(.degrees(angle))
            }
            .frame(width: 10, height: 10)
        }
    }
}

/// Small dot that glows like the icon's ghost and breathes slowly (brightness only, no expanding ring):
/// the one thing in the sidebar allowed to ask for attention.
private struct WaitingGlyph: View {
    private let period: Double = 3.0

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = (sin(t / period * 2 * .pi) + 1) / 2   // 0…1, smooth
            Circle()
                .fill(SidebarPalette.waiting)
                .frame(width: 7, height: 7)
                .opacity(0.80 + 0.20 * phase)
                .shadow(color: SidebarPalette.waiting.opacity(SidebarPalette.waitingGlow * (0.5 + 0.5 * phase)), radius: 4)
                .frame(width: 14, height: 14)
        }
    }
}

/// Thin check in the same grey as the directory line: finished, not yet seen.
/// Goes back to no glyph once the tab is visited.
private struct DoneGlyph: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(SidebarPalette.done)
    }
}

// MARK: - Chrome

private struct ChromeButton: View {
    let symbol: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(SidebarPalette.chrome)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? SidebarPalette.hoverFill : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
