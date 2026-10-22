import UIKit
import Accelerate

// Shrinking with Lanczos (vImage's high-quality resampling) instead of letting the GPU squash a big
// image with its bilinear filter (jaggies, shimmer, and the full bitmap held in memory). Images are
// decoded at full size, shrunk to the pixels they fill on screen, and only that copy is kept.
// Never enlarges; animated images are left alone. Call off the main thread (or use `async`).
enum Lanczos {
    static func shrink(_ image: UIImage, toPoints points: CGSize, scale: CGFloat) -> UIImage {
        guard image.images == nil, let cg = image.cgImage else { return image }
        // cgImage is unrotated; an EXIF-rotated image needs the target turned the same way.
        let sideways = [.left, .right, .leftMirrored, .rightMirrored].contains(image.imageOrientation)
        var w = Int((points.width * scale).rounded()), h = Int((points.height * scale).rounded())
        if sideways { swap(&w, &h) }
        guard w > 0, h > 0, w < cg.width || h < cg.height else { return image }
        w = min(w, cg.width); h = min(h, cg.height)

        let space = cg.colorSpace?.model == .rgb ? cg.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: space, bitmapInfo: info),
              var src = try? vImage_Buffer(cgImage: cg, format: format) else { return image }
        defer { src.free() }
        guard var dst = try? vImage_Buffer(width: w, height: h, bitsPerPixel: 32) else { return image }
        defer { dst.free() }
        guard vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError,
              let out = try? dst.createCGImage(format: format) else { return image }
        return UIImage(cgImage: out, scale: scale, orientation: image.imageOrientation)
    }

    static func shrink(_ image: UIImage, toPoints points: CGSize, scale: CGFloat) async -> UIImage {
        await Task.detached(priority: .userInitiated) { shrink(image, toPoints: points, scale: scale) }.value
    }

    /// The smallest size with the image's aspect that covers `box` (what a scaledToFill frame shows).
    static func fill(_ size: CGSize, covering box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return box }
        let k = max(box.width / size.width, box.height / size.height)
        return CGSize(width: (size.width * k).rounded(.up), height: (size.height * k).rounded(.up))
    }
}
