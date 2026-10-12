import Foundation
import PNG

/// Area-averaging PNG downscaler, used to expand a single-size app icon
/// master into the sizes the home screen, Spotlight and Settings need.
///
/// Averaging is done on premultiplied alpha so transparent pixels don't bleed
/// their (meaningless) colour into the edges.
enum PNGResizer {
    struct Decoded {
        var width: Int
        var height: Int
        /// Premultiplied RGBA, 0...255 as Float.
        var pixels: [Float]
    }

    private struct MemoryStream: PNG.BytestreamSource {
        var bytes: [UInt8]
        var offset = 0
        mutating func read(count: Int) -> [UInt8]? {
            guard offset + count <= bytes.count else { return nil }
            defer { offset += count }
            return Array(bytes[offset..<offset + count])
        }
    }

    private struct MemoryDestination: PNG.BytestreamDestination {
        var bytes: [UInt8] = []
        mutating func write(_ data: [UInt8]) -> Void? {
            bytes.append(contentsOf: data)
            return ()
        }
    }

    static func decode(_ data: Data) throws -> Decoded {
        var stream = MemoryStream(bytes: [UInt8](data))
        let image = try PNG.Image.decompress(stream: &stream)
        let rgba: [PNG.RGBA<UInt8>] = image.unpack(as: PNG.RGBA<UInt8>.self)
        var pixels = [Float](repeating: 0, count: rgba.count * 4)
        for (i, px) in rgba.enumerated() {
            let a = Float(px.a) / 255
            pixels[i * 4 + 0] = Float(px.r) * a
            pixels[i * 4 + 1] = Float(px.g) * a
            pixels[i * 4 + 2] = Float(px.b) * a
            pixels[i * 4 + 3] = Float(px.a)
        }
        return Decoded(width: image.size.x, height: image.size.y, pixels: pixels)
    }

    /// Returns PNG bytes of `source` scaled to `width` x `height`.
    static func resize(_ source: Decoded, width: Int, height: Int) throws -> Data {
        // Horizontal pass: `source.height` rows, each shrunk to `width` pixels.
        let horizontal = resample(
            source.pixels, outer: source.height, srcCount: source.width, dstCount: width,
            srcStep: 4, srcOuterStep: source.width * 4, dstStep: 4, dstOuterStep: width * 4
        )
        // Vertical pass: `width` columns, each shrunk to `height` pixels.
        let scaled = resample(
            horizontal, outer: width, srcCount: source.height, dstCount: height,
            srcStep: width * 4, srcOuterStep: 4, dstStep: width * 4, dstOuterStep: 4
        )

        var rgba = [PNG.RGBA<UInt8>](repeating: PNG.RGBA<UInt8>(0, 0, 0, 0), count: width * height)
        for i in 0..<(width * height) {
            let a = scaled[i * 4 + 3]
            guard a > 0 else { continue }
            let k = 255 / a
            rgba[i] = PNG.RGBA<UInt8>(
                clamp(scaled[i * 4 + 0] * k), clamp(scaled[i * 4 + 1] * k), clamp(scaled[i * 4 + 2] * k), clamp(a)
            )
        }
        let image = PNG.Image(
            packing: rgba,
            size: (x: width, y: height),
            layout: PNG.Layout(format: .rgba8(palette: [], fill: nil))
        )
        var out = MemoryDestination()
        try image.compress(stream: &out)
        return Data(out.bytes)
    }

    private static func clamp(_ v: Float) -> UInt8 {
        UInt8(max(0, min(255, v.rounded())))
    }

    /// One separable pass of box (area) resampling along an axis. Steps are in `Float` units.
    private static func resample(
        _ src: [Float], outer: Int, srcCount: Int, dstCount: Int,
        srcStep: Int, srcOuterStep: Int, dstStep: Int, dstOuterStep: Int
    ) -> [Float] {
        var dst = [Float](repeating: 0, count: outer * dstCount * 4)
        let ratio = Double(srcCount) / Double(dstCount)
        src.withUnsafeBufferPointer { src in
            dst.withUnsafeMutableBufferPointer { dst in
                for d in 0..<dstCount {
                    let start = Double(d) * ratio
                    let end = start + ratio
                    let first = Int(start)
                    let last = min(srcCount - 1, Int(end.nextDown))
                    for line in 0..<outer {
                        var r = 0.0, g = 0.0, b = 0.0, a = 0.0
                        for s in first...last {
                            let weight = min(end, Double(s + 1)) - max(start, Double(s))
                            let base = line * srcOuterStep + s * srcStep
                            r += Double(src[base]) * weight
                            g += Double(src[base + 1]) * weight
                            b += Double(src[base + 2]) * weight
                            a += Double(src[base + 3]) * weight
                        }
                        let out = line * dstOuterStep + d * dstStep
                        dst[out] = Float(r / ratio)
                        dst[out + 1] = Float(g / ratio)
                        dst[out + 2] = Float(b / ratio)
                        dst[out + 3] = Float(a / ratio)
                    }
                }
            }
        }
        return dst
    }
}
