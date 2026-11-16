import AppKit
import Combine
import SwiftUI

/// Keeps one `SidebarBackdrop` in step with the app config and shares it with every window.
///
/// The sidebar is chrome, but it sits inside the window the terminal paints its
/// `background-color` / `background-image` onto, so a flat grey column reads as a foreign
/// panel glued to the side. Every window shows the same config, so one store owns the
/// decoded image: a config reload re-reads the values, and a `background-image` file that
/// changes content in place (the wallpaper rotator rewrites the same path) is picked up by
/// comparing path + mtime.
@MainActor
final class SidebarBackdropStore: ObservableObject {
    static let shared = SidebarBackdropStore()

    @Published private(set) var backdrop = SidebarBackdrop()

    private var loadedPath: String?
    private var loadedStamp: Date?
    /// Decodes are async; a config change while one is in flight must not land late.
    private var generation = 0

    private init() {}

    /// Called on window creation and on every app-level config reload (ghostty-bg rewrites
    /// the same file, then reloads). Decoding only happens when the picture actually changed.
    func sync(config: Ghostty.Config) {
        var next = backdrop
        next.baseColor = NSColor(config.backgroundColor)
        next.baseOpacity = config.backgroundOpacity
        next.imageOpacity = config.backgroundImageOpacity
        next.fit = SidebarBackdrop.Fit(rawValue: config.backgroundImageFit) ?? .contain
        next.position = config.backgroundImagePosition

        guard let path = config.backgroundImage?.path else {
            loadedPath = nil
            loadedStamp = nil
            generation += 1
            next.image = nil
            next.imagePixelSize = .zero
            if next != backdrop { backdrop = next }
            return
        }

        let stamp = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        if path != loadedPath || stamp != loadedStamp {
            loadedPath = path
            loadedStamp = stamp
            generation += 1
            let gen = generation
            DispatchQueue.global(qos: .utility).async {
                let loaded = SidebarImageLoader.load(path: path)
                DispatchQueue.main.async { [weak self] in
                    guard let self, gen == self.generation else { return }
                    var done = self.backdrop
                    done.image = loaded?.0
                    done.imagePixelSize = loaded?.1 ?? .zero
                    self.backdrop = done
                }
            }
        }

        if next != backdrop { backdrop = next }
    }
}
