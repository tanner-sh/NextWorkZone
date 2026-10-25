import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 图片的编码、缩放和取色。只用 CoreGraphics 和 ImageIO，不依赖 AppKit。
public enum ClipImages {
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let rgbaInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

    /// 把任意格式的图片数据（PNG、TIFF 等）解码为 RGBA 像素。
    public static func decode(_ data: Data) -> RGBAImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return rgba(image)
    }

    /// 把 CGImage 画到 RGBA 缓冲区中：剪贴板中同一张图可能以不同的像素格式出现，统一后才能比较是否相同。
    public static func rgba(_ image: CGImage) -> RGBAImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = Data(count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: rgbaInfo) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? RGBAImage(width: width, height: height, pixels: pixels) : nil
    }

    static func cgImage(_ image: RGBAImage) -> CGImage? {
        guard image.pixels.count == image.width * image.height * 4, let provider = CGDataProvider(data: image.pixels as CFData) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: rgbaInfo), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    public static func png(_ image: RGBAImage) -> Data? { cgImage(image).flatMap(png) }

    /// 按比例缩小到 `max` 以内。
    public static func fit(width: Int, height: Int, max: Int) -> (Int, Int) {
        guard width > max || height > max else { return (width, height) }
        let scale = Double(max) / Double(Swift.max(width, height))
        return (Swift.max(1, Int((Double(width) * scale).rounded())), Swift.max(1, Int((Double(height) * scale).rounded())))
    }

    static func scaled(_ image: CGImage, max: Int) -> CGImage? {
        let (w, h) = fit(width: image.width, height: image.height, max: max)
        guard (w, h) != (image.width, image.height) else { return image }
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: rgbaInfo) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    /// 把 PNG 等图片缩小到 `max` 以内并编码为 PNG（拖动时显示的预览图）。
    public static func shrinkPNG(_ data: Data, max: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return scaled(image, max: max).flatMap(png)
    }

    /// 图标的主色：不透明且有一定饱和度的像素的平均色；图标几乎是灰色时返回 nil。
    public static func dominantColor(_ image: RGBAImage) -> String? {
        var r = 0.0, g = 0.0, b = 0.0, weight = 0.0, opaque = 0
        image.pixels.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            for offset in stride(from: 0, to: bytes.count - 3, by: 4) {
                let pr = bytes[offset], pg = bytes[offset + 1], pb = bytes[offset + 2], pa = bytes[offset + 3]
                guard pa >= 200 else { continue }
                opaque += 1
                let high = Double(Swift.max(pr, pg, pb)), low = Double(Swift.min(pr, pg, pb))
                let saturation = high == 0 ? 0 : (high - low) / high
                // 很亮或很暗的像素（白底、描边）不计入
                guard saturation >= 0.25, high >= 40 else { continue }
                let w = saturation * saturation
                r += Double(pr) * w; g += Double(pg) * w; b += Double(pb) * w; weight += w
            }
        }
        guard weight >= Double(Swift.max(opaque, 1)) * 0.02 else { return nil }
        return String(format: "#%02x%02x%02x", Int(r / weight), Int(g / weight), Int(b / weight))
    }
}
