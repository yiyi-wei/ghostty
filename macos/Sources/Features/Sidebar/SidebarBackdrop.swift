import AppKit
import CoreImage
import ImageIO
import SwiftUI

/// What the sidebar paints behind itself so it reads as part of the same window as the
/// terminal: the terminal's own background colour and, when `background-image` is set,
/// the same picture mixed in at the same opacity, frosted. Pure data, no Ghostty types,
/// so a standalone preview harness can use it too.
struct SidebarBackdrop: Equatable {
    var baseColor: NSColor = NSColor(red: 0x28 / 255, green: 0x2c / 255, blue: 0x34 / 255, alpha: 1)
    /// `background-opacity`; below 1 the window blur shows through, as it does for the terminal.
    var baseOpacity: Double = 1
    /// Downsampled + blurred copy of `background-image`.
    var image: CGImage?
    /// `background-image-opacity` (mix ratio of the image over `baseColor`).
    var imageOpacity: Double = 0

    static func == (a: Self, b: Self) -> Bool {
        a.baseColor == b.baseColor && a.baseOpacity == b.baseOpacity
            && a.image === b.image && a.imageOpacity == b.imageOpacity
    }

    /// Blurring flattens the picture's contrast, so the frosted copy carries a little more
    /// of it than the terminal does; the overall tone stays the same.
    var frostedOpacity: Double { min(1, imageOpacity * 1.35) }
}

/// Paints a `SidebarBackdrop` as if it covered `canvas` (the whole window content, titlebar
/// included), anchored top-leading, so the sidebar strip shows the left edge of the same
/// picture the terminal shows, frosted and a step darker.
struct SidebarBackdropView: View {
    let backdrop: SidebarBackdrop
    let canvas: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: backdrop.baseColor)
            if let image = backdrop.image, canvas.width > 0, canvas.height > 0 {
                let w = CGFloat(image.width), h = CGFloat(image.height)
                let scale = max(canvas.width / w, canvas.height / h)
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: w * scale, height: h * scale)
                    .offset(x: (canvas.width - w * scale) / 2, y: (canvas.height - h * scale) / 2)
                    .opacity(backdrop.frostedOpacity)
                    .transition(.opacity)
            }
            // Chrome sits a step below the content it frames.
            Color.black.opacity(0.16)
        }
        .opacity(backdrop.baseOpacity)
        .animation(.easeInOut(duration: 0.6), value: backdrop)
        .frame(width: max(canvas.width, 1), height: max(canvas.height, 1), alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

enum SidebarImageLoader {
    /// Decodes `path` at a small size and blurs it. ~10 ms for a 4K JPEG; run off the main thread.
    static func frosted(path: String, maxPixel: Int = 640, blurRadius: Double = 12) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let input = CIImage(cgImage: thumb)
        let blurred = input.clampedToExtent()
            .applyingGaussianBlur(sigma: blurRadius)
            .cropped(to: input.extent)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        return ctx.createCGImage(blurred, from: input.extent)
    }
}
