import Foundation
import PNG

enum ImageRenderer {
    static func renditions(for set: LoadedImageSet) throws -> [Rendition] {
        var out: [Rendition] = []
        for image in set.contents.images {
            guard let filename = image.filename, !filename.isEmpty else { continue }
            let src = set.directory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: src.path) else {
                throw XCAssetCompilerError.missingReferencedFile(asset: set.name, filename: filename)
            }
            let appearance = image.appearances?.first { $0.darkLuminosity }
            let body: Rendition.Body
            let gamut: Gamut?
            let renditionScale: Scale?
            switch sourceFormat(of: filename) {
            case .png:
                let (width, height, bgra) = try decodeBGRAPremultiplied(at: src)
                let g = image.displayGamut ?? .sRGB
                gamut = g
                renditionScale = image.scale
                body = .bitmap(BitmapBody(
                    width: width,
                    height: height,
                    pixelsBGRA: bgra,
                    colorSpaceID: g.colorSpaceID,
                    kind: .image,
                    renditionName: filename
                ))
            case .svg:
                let data = try Data(contentsOf: src)
                gamut = nil
                // SVG renditions are scale-free in concept, but the reference
                // CoreUI 970 catalog keys the SVG source rendition with
                // scale=1 (so it lives in the "1x slot" of the rendition
                // tree). Encoding scale=0 leaves the rendition orphaned from
                // CoreUI's scale-based lookups.
                renditionScale = .x1
                body = .preservedSource(PreservedSourceBody(
                    format: .svg,
                    sourceData: data,
                    renditionName: filename
                ))
            case .jpeg:
                let data = try Data(contentsOf: src)
                let dims = try JPEGDimensions.read(data)
                gamut = nil
                renditionScale = image.scale
                body = .preservedSource(PreservedSourceBody(
                    format: .jpeg(width: dims.width, height: dims.height),
                    sourceData: data,
                    renditionName: filename
                ))
            case .unsupported:
                throw XCAssetCompilerError.unsupportedAssetType(filename)
            }
            out.append(Rendition(
                name: set.name,
                idiom: image.idiom,
                scale: renditionScale,
                appearance: appearance,
                gamut: gamut,
                body: body
            ))
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
            let (width, height, bgra) = try decodeBGRAPremultiplied(at: file.sourceURL)
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

    private static func decodeBGRAPremultiplied(at url: URL) throws -> (UInt32, UInt32, [UInt8]) {
        guard let image = try PNG.Image.decompress(path: url.path) else {
            throw XCAssetCompilerError.missingReferencedFile(asset: url.lastPathComponent, filename: url.lastPathComponent)
        }
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
