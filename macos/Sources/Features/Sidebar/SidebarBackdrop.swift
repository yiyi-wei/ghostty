import AppKit
import ImageIO
import SwiftUI

/// What the sidebar paints behind itself so it reads as part of the same window as the
/// terminal: the terminal's own background colour and, when `background-image` is set,
/// the same picture at the same opacity, placed exactly where the renderer would put it
/// if the terminal reached under the sidebar. The strip is then simply more of the same
/// picture, with no blur and no tint. Pure data, no Ghostty types, so a standalone preview
/// harness can use it too.
struct SidebarBackdrop: Equatable {
    enum Fit: String { case contain, cover, stretch, none }

    var baseColor: NSColor = NSColor(red: 0x28 / 255, green: 0x2c / 255, blue: 0x34 / 255, alpha: 1)
    /// `background-opacity`; below 1 the window blur shows through, as it does for the terminal.
    var baseOpacity: Double = 1
    /// Decoded `background-image` (downsampled only when larger than any screen needs).
    var image: CGImage?
    /// Pixel size of the file itself; `none` fit places the picture at this size.
    var imagePixelSize: CGSize = .zero
    /// `background-image-opacity` (mix ratio of the image over `baseColor`).
    var imageOpacity: Double = 0
    var fit: Fit = .contain
    /// `background-image-position`, e.g. `top-left`; `center` means `center-center`.
    var position: String = "center"

    static func == (a: Self, b: Self) -> Bool {
        a.baseColor == b.baseColor && a.baseOpacity == b.baseOpacity
            && a.image === b.image && a.imagePixelSize == b.imagePixelSize
            && a.imageOpacity == b.imageOpacity && a.fit == b.fit && a.position == b.position
    }

    /// Same placement as `bg_image_vertex` in shaders.metal, in points, for a terminal
    /// occupying `screen`. Returns the image rect in the same coordinate space as `screen`.
    func imageRect(in screen: CGRect, backingScale: CGFloat) -> CGRect? {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0,
              screen.width > 0, screen.height > 0 else { return nil }
        let tex = imagePixelSize
        let dest: CGSize
        switch fit {
        case .contain:
            let s = min(screen.width / tex.width, screen.height / tex.height)
            dest = CGSize(width: tex.width * s, height: tex.height * s)
        case .cover:
            let s = max(screen.width / tex.width, screen.height / tex.height)
            dest = CGSize(width: tex.width * s, height: tex.height * s)
        case .stretch:
            dest = screen.size
        case .none:
            dest = CGSize(width: tex.width / backingScale, height: tex.height / backingScale)
        }

        let free = CGSize(width: screen.width - dest.width, height: screen.height - dest.height)
        let parts = position == "center" ? ["center", "center"] : position.split(separator: "-").map(String.init)
        func offset(_ word: String, _ room: CGFloat, start: String, end: String) -> CGFloat {
            word == start ? 0 : (word == end ? room : room / 2)
        }
        let y = offset(parts.first ?? "center", free.height, start: "top", end: "bottom")
        let x = offset(parts.last ?? "center", free.width, start: "left", end: "right")
        return CGRect(x: screen.minX + x, y: screen.minY + y, width: dest.width, height: dest.height)
    }
}

/// Paints a `SidebarBackdrop` across `canvas` (the whole window content, titlebar included,
/// top-left origin). `terminal` is the rect the terminal occupies in that space; the picture
/// is placed relative to it, so the part that falls under the sidebar continues the
/// terminal's picture across the seam.
struct SidebarBackdropView: View {
    let backdrop: SidebarBackdrop
    let canvas: CGSize
    let terminal: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: backdrop.baseColor)
            if let image = backdrop.image,
               let rect = backdrop.imageRect(
                   in: terminal,
                   backingScale: NSScreen.main?.backingScaleFactor ?? 2) {
                // The terminal's picture starts below the titlebar strip (which stays the flat
                // background colour across the whole window), so the sidebar's does too.
                Color.clear
                    .frame(width: max(canvas.width, 1), height: max(terminal.height, 1))
                    .overlay(alignment: .topLeading) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY - terminal.minY)
                    }
                    .clipped()
                    .offset(y: terminal.minY)
                    .opacity(backdrop.imageOpacity)
                    .transition(.opacity)
            }
        }
        .opacity(backdrop.baseOpacity)
        .animation(.easeInOut(duration: 0.6), value: backdrop)
        .frame(width: max(canvas.width, 1), height: max(canvas.height, 1), alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

enum SidebarImageLoader {
    /// Decodes `path`, capped at `maxPixel` on the long side (a 5K picture shown on one
    /// window never needs more). Returns the image plus the file's own pixel size. Run off
    /// the main thread.
    static func load(path: String, maxPixel: Int = 4096) -> (CGImage, CGSize)? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        // No EXIF transform: the renderer decodes raw pixels, and the strip must match it.
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let size = w > 0 && h > 0 ? CGSize(width: w, height: h)
            : CGSize(width: image.width, height: image.height)
        return (image, size)
    }
}
