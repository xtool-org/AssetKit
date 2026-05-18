import Foundation
import PNG

/// In-memory adapter for swift-png's `PNG.BytestreamSource`. Lets us decode
/// PNG bytes that come from a `Data` buffer (e.g. fresh output from an
/// SVG rasteriser) without round-tripping through a temp file.
private struct MemoryBytestream: PNG.BytestreamSource {
    var bytes: [UInt8]
    var offset: Int = 0
    mutating func read(count: Int) -> [UInt8]? {
        guard offset + count <= bytes.count else { return nil }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }
}

enum ImageRenderer {
    static func renditions(
        for set: LoadedImageSet,
        svgRasterizer: any SVGRasterizer
    ) throws -> [Rendition] {
        var out: [Rendition] = []
        for image in set.contents.images {
            guard let filename = image.filename, !filename.isEmpty else { continue }
            let src = set.directory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: src.path) else {
                throw XCAssetCompilerError.missingReferencedFile(asset: set.name, filename: filename)
            }
            let appearance = image.appearances?.first { $0.darkLuminosity }
            switch sourceFormat(of: filename) {
            case .png:
                let (width, height, bgra) = try decodeBGRAPremultiplied(data: try Data(contentsOf: src))
                let gamut = image.displayGamut ?? .sRGB
                out.append(Rendition(
                    name: set.name,
                    idiom: image.idiom,
                    scale: image.scale,
                    appearance: appearance,
                    gamut: gamut,
                    body: .bitmap(BitmapBody(
                        width: width,
                        height: height,
                        pixelsBGRA: bgra,
                        colorSpaceID: gamut.colorSpaceID,
                        kind: .image,
                        renditionName: filename
                    ))
                ))
            case .svg:
                let data = try Data(contentsOf: src)
                // 1. Vector source rendition (forward-friendly; small bytes;
                //    matches actool's output). UIImage(named:) on shipping
                //    iOS doesn't read this slot for image lookups — it reads
                //    the rasterised bitmap variants below — but the vector
                //    rendition is still load-bearing for any consumer that
                //    asks CoreUI for the underlying vector data, and it's
                //    cheap to emit.
                out.append(Rendition(
                    name: set.name,
                    idiom: image.idiom,
                    // Reference packs the vector source into the scale=1
                    // slot regardless of file naming; see ADR 0002 and
                    // docs/coreui-970-format.md §7.
                    scale: .x1,
                    appearance: appearance,
                    gamut: nil,
                    body: .preservedSource(PreservedSourceBody(
                        format: .svg,
                        sourceData: data,
                        renditionName: filename
                    ))
                ))
                // 2. Rasterised bitmap fallbacks at 1x / 2x / 3x. UIImage(named:)
                //    resolves to these. Pixel dimensions = intrinsic SVG size
                //    × scale factor; the rasteriser produces PNG bytes at the
                //    requested size and we decode straight to BGRA.
                let intrinsic = try SVGDimensions.read(data, asset: set.name, filename: filename)
                // SVG entries in Contents.json may declare a `scale` field,
                // but the vector-source semantic is scale-free; we always
                // emit at 1x/2x/3x and ignore `image.scale` for SVG inputs.
                // Same hardcoded sRGB caveat as below.
                for scale: Scale in [.x1, .x2, .x3] {
                    let factor = UInt32(scale.factor)
                    let (rw, rh, rgba): (UInt32, UInt32, [UInt8])
                    do {
                        let pngData = try svgRasterizer.rasterize(
                            svgData: data,
                            pixelWidth: intrinsic.width * factor,
                            pixelHeight: intrinsic.height * factor
                        )
                        // Decode is inside the catch so a rasteriser that
                        // returns garbage (non-PNG bytes, truncated stream)
                        // surfaces as svgRasterizationFailed rather than a
                        // raw swift-png error the user has no context for.
                        (rw, rh, rgba) = try decodeBGRAPremultiplied(data: pngData)
                    } catch {
                        throw XCAssetCompilerError.svgRasterizationFailed(
                            asset: set.name,
                            filename: filename,
                            underlying: String(describing: error)
                        )
                    }
                    out.append(Rendition(
                        name: set.name,
                        idiom: image.idiom,
                        scale: scale,
                        appearance: appearance,
                        // Hardcoded sRGB: rsvg-convert (and most rasterisers)
                        // produce sRGB pixels regardless of the imageset's
                        // declared `display-gamut`. Tagging the bitmap as
                        // display-P3 when the underlying pixels are sRGB
                        // would mislead CoreUI's colour-management. If
                        // P3-faithful SVG rendering matters, that's a
                        // rasteriser-level concern handled by injection.
                        gamut: .sRGB,
                        body: .bitmap(BitmapBody(
                            width: rw,
                            height: rh,
                            pixelsBGRA: rgba,
                            colorSpaceID: Gamut.sRGB.colorSpaceID,
                            kind: .image,
                            derivedFromVector: true,
                            // Reference uses the source SVG filename for
                            // every variant (vector + raster), not a
                            // synthetic per-scale name.
                            renditionName: filename
                        ))
                    ))
                }
            case .jpeg:
                let data = try Data(contentsOf: src)
                let dims = try JPEGDimensions.read(data)
                out.append(Rendition(
                    name: set.name,
                    idiom: image.idiom,
                    scale: image.scale,
                    appearance: appearance,
                    gamut: nil,
                    body: .preservedSource(PreservedSourceBody(
                        format: .jpeg(width: dims.width, height: dims.height),
                        sourceData: data,
                        renditionName: filename
                    ))
                ))
            case .unsupported:
                throw XCAssetCompilerError.unsupportedAssetType(filename)
            }
        }
        return out
    }

    enum SourceFormat {
        case png
        case svg
        case jpeg
        case unsupported
    }

    static func sourceFormat(of filename: String) -> SourceFormat {
        switch (filename as NSString).pathExtension.lowercased() {
        case "png": return .png
        case "svg": return .svg
        case "jpg", "jpeg": return .jpeg
        default: return .unsupported
        }
    }

    static func appIconRenditions(for appIcon: LoadedAppIcon, files: [IconFile]) throws -> [Rendition] {
        var out: [Rendition] = []
        for file in files {
            let filename = file.sourceURL.lastPathComponent
            guard sourceFormat(of: filename) == .png else {
                throw XCAssetCompilerError.unsupportedAppIconSource(asset: appIcon.name, filename: filename)
            }
            let (width, height, bgra) = try decodeBGRAPremultiplied(data: try Data(contentsOf: file.sourceURL))
            let scale: Scale = {
                switch file.scale {
                case 1: return .x1
                case 2: return .x2
                case 3: return .x3
                default: return .x1
                }
            }()
            // Use the appiconset's basename ("AppIcon") for the rendition name
            // so it matches the reference; the per-file outputName
            // ("AppIcon60x60") is only used for CFBundleIconFiles in Info.plist.
            out.append(Rendition(
                name: appIcon.name,
                idiom: file.idiom,
                scale: scale,
                appearance: nil,
                gamut: .sRGB,
                body: .bitmap(BitmapBody(
                    width: width,
                    height: height,
                    pixelsBGRA: bgra,
                    colorSpaceID: Gamut.sRGB.colorSpaceID,
                    kind: .appIcon,
                    renditionName: file.sourceURL.lastPathComponent
                ))
            ))
        }
        return out
    }

    static func decodeBGRAPremultiplied(data: Data) throws -> (UInt32, UInt32, [UInt8]) {
        var blob = MemoryBytestream(bytes: [UInt8](data))
        let image = try PNG.Image.decompress(stream: &blob)
        let rgba: [PNG.RGBA<UInt8>] = image.unpack(as: PNG.RGBA<UInt8>.self)
        let width = UInt32(image.size.x)
        let height = UInt32(image.size.y)
        var out = [UInt8](repeating: 0, count: rgba.count * 4)
        for i in 0..<rgba.count {
            let px = rgba[i]
            let a = UInt16(px.a)
            let r = UInt8((UInt16(px.r) * a + 127) / 255)
            let g = UInt8((UInt16(px.g) * a + 127) / 255)
            let b = UInt8((UInt16(px.b) * a + 127) / 255)
            let base = i * 4
            out[base + 0] = b
            out[base + 1] = g
            out[base + 2] = r
            out[base + 3] = px.a
        }
        return (width, height, out)
    }
}
