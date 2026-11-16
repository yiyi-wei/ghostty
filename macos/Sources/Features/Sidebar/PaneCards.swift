import SwiftUI

/// With the sidebar on, every terminal pane is drawn as a rounded card floating on one
/// continuous "floor" (the sidebar's backdrop, which also shows in the gaps between cards).
/// `nil` in the environment means plain, edge-to-edge panes (upstream behaviour).
struct PaneCardStyle: Equatable {
    /// Inset applied on every side of each pane and once more around the whole split tree,
    /// so the gap between two cards equals the margin around them (2 × inset).
    var inset: CGFloat = 3
    var radius: CGFloat = 10
    /// Hairline around each card so its edge reads even where the floor continues the
    /// card's own picture.
    var stroke: Color = Color.white.opacity(0.07)

    static let standard = PaneCardStyle()
}

private struct PaneCardStyleKey: EnvironmentKey {
    static let defaultValue: PaneCardStyle? = nil
}

extension EnvironmentValues {
    var paneCardStyle: PaneCardStyle? {
        get { self[PaneCardStyleKey.self] }
        set { self[PaneCardStyleKey.self] = newValue }
    }
}

/// Bounds of every visible card, reported from the split leaves up to the sidebar root so
/// the floor can continue the picture of the card next to the sidebar and leave the cards
/// themselves alone.
struct PaneCardAnchorsKey: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []

    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

enum PaneCards {
    /// The card the sidebar sits against: leftmost, then topmost.
    static func anchorCard(_ cards: [CGRect]) -> CGRect? {
        cards.min { a, b in
            abs(a.minX - b.minX) > 0.5 ? a.minX < b.minX : a.minY < b.minY
        }
    }
}

/// The whole rect minus every card (even-odd fill): the part of the window floor that is
/// actually visible.
struct PaneCardHoles: Shape {
    let cards: [CGRect]
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        for card in cards {
            path.addRoundedRect(in: card, cornerSize: CGSize(width: radius, height: radius),
                                style: .continuous)
        }
        return path
    }
}
