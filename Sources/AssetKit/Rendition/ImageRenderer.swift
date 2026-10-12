import Foundation

/// Dispatches each source file in an asset to the matching source-format
/// handler (`PNGSource`, `SVGSource`, `JPEGSource`). Owns filesystem I/O,
/// missing-file detection, and the imageset / appiconset iteration; the
/// handlers own per-format rendition construction.
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
            guard let format = SourceFormat.detect(filename: filename) else {
                throw XCAssetCompilerError.unsupportedAssetType(filename)
            }
            let bytes = try Data(contentsOf: src)
            let appearance = image.appearances?.first { $0.darkLuminosity }
            switch format {
            case .png:
                let ctx = PNGSource.Context(
                    assetName: set.name,
                    idiom: image.idiom,
                    scale: image.scale,
                    appearance: appearance,
                    gamut: image.displayGamut ?? .sRGB,
                    filename: filename,
                    kind: .image
                )
                out.append(contentsOf: try PNGSource.renditions(bytes: bytes, context: ctx))
            case .svg:
                let ctx = SVGSource.Context(
                    assetName: set.name,
                    idiom: image.idiom,
                    appearance: appearance,
                    filename: filename
                )
                out.append(contentsOf: try SVGSource.renditions(
                    bytes: bytes,
                    context: ctx,
                    rasteriser: svgRasterizer
                ))
            case .jpeg:
                let ctx = JPEGSource.Context(
                    assetName: set.name,
                    idiom: image.idiom,
                    scale: image.scale,
                    appearance: appearance,
                    filename: filename
                )
                out.append(contentsOf: try JPEGSource.renditions(bytes: bytes, context: ctx))
            }
        }
        return out
    }

    static func appIconRenditions(
        for appIcon: LoadedAppIcon,
        files: [IconFile],
        options: OutputOptions = .legacy
    ) throws -> [Rendition] {
        var out: [Rendition] = []
        for file in files {
            let filename = file.sourceName
            guard SourceFormat.detect(filename: filename) == .png else {
                throw XCAssetCompilerError.unsupportedAppIconSource(asset: appIcon.name, filename: filename)
            }
            let bytes = file.data
            let scale: Scale = {
                switch file.scale {
                case 1: return .x1
                case 2: return .x2
                case 3: return .x3
                default: return .x1
                }
            }()
            // The appiconset's basename ("AppIcon") is the rendition name in
            // the CSI header for the reference; the per-file outputName
            // ("AppIcon60x60") is only used for CFBundleIconFiles in
            // Info.plist. We pass the source filename through as renditionName
            // because actool uses the filename (not the asset name) here.
            let ctx = PNGSource.Context(
                assetName: appIcon.name,
                idiom: file.idiom,
                scale: scale,
                appearance: nil,
                gamut: .sRGB,
                filename: filename,
                kind: .appIcon
            )
            var renditions = try PNGSource.renditions(bytes: bytes, context: ctx)
            for i in renditions.indices {
                if case .bitmap(var body) = renditions[i].body {
                    body.iconIndex = iconIndex(idiom: file.idiom, pointSize: file.pointSize)
                    body.iconPoints = file.pointSize
                    renditions[i].body = .bitmap(body)
                }
            }
            out.append(contentsOf: renditions)
            // actool also stores the iPhone 60pt@3x icon as a 2x rendition at
            // subtype 1792 (an iPhone 6 Plus class display that scales 3x down
            // to 2x), with 90pt, i.e. 1.5x of 60, as its size.
            if options.contains(.multisizeIcons), file.idiom == .iphone, file.pointSize == 60, file.scale == 3 {
                for var copy in renditions {
                    copy.scale = .x2
                    if case .bitmap(var body) = copy.body {
                        body.subtype = 1792
                        body.iconIndex = 7
                        body.iconPoints = 90
                        copy.body = .bitmap(body)
                    }
                    out.append(copy)
                }
            }
        }
        return out
    }

    /// See `BitmapBody.iconIndex`.
    private static func iconIndex(idiom: Idiom, pointSize: Double) -> UInt16 {
        if idiom == .marketing { return 8 }
        switch pointSize {
        case 20: return 1
        case 29: return 2
        case 40: return 3
        case 60: return 4
        case 76: return 5
        case 83.5: return 6
        default: return 1
        }
    }
}
