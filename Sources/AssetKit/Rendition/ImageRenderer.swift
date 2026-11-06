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

    static func appIconRenditions(for appIcon: LoadedAppIcon, files: [IconFile]) throws -> [Rendition] {
        // Decode each source once, keeping its IconFile for index assignment.
        var decoded: [(file: IconFile, rendition: Rendition)] = []
        for file in files {
            let filename = file.sourceURL.lastPathComponent
            guard SourceFormat.detect(filename: filename) == .png else {
                throw XCAssetCompilerError.unsupportedAppIconSource(asset: appIcon.name, filename: filename)
            }
            let bytes = try Data(contentsOf: file.sourceURL)
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
            for rendition in try PNGSource.renditions(bytes: bytes, context: ctx) {
                decoded.append((file, rendition))
            }
        }

        // "Icon Index" = the rank of the rendition's point size among the
        // appiconset's distinct point sizes, ascending; shared across idioms
        // and scales (60 pt @2x and @3x are both index 1; an ipad 20 pt and
        // an iphone 20 pt are also both index 1). Both oracle runs agree.
        //
        // When the set provides an iphone 60 pt @3x source, actool also keys
        // it as the 90 pt large-phone home icon (subtype 1792, scale 2); the
        // 90 pt size then joins the ranking. Without a 60 pt @3x source no
        // 1792 variant is emitted (second oracle run).
        let largePhonePointSize = 90.0
        let hasLargePhoneVariant = files.contains {
            $0.idiom == .iphone && $0.pointSize == 60 && $0.scale == 3
        }
        var sizes = Set(files.map(\.pointSize))
        if hasLargePhoneVariant { sizes.insert(largePhonePointSize) }
        let iconIndexOfSize: [Double: UInt16] = Dictionary(
            uniqueKeysWithValues: sizes.sorted().enumerated().map { ($0.element, UInt16($0.offset + 1)) }
        )

        var out: [Rendition] = []
        // (idiom, subtype) -> point size -> icon index. One MultiSized
        // rendition is emitted per group, mirroring the reference output.
        var groups: [MultiSizedGroup: [UInt32: UInt32]] = [:]
        for (file, rendition) in decoded {
            var icon = rendition
            icon.iconIndex = iconIndexOfSize[file.pointSize]
            out.append(icon)
            addMultiSizedEntry(
                &groups, idiom: file.idiom, subtype: 0,
                pointSize: UInt32(file.pointSize), index: UInt32(icon.iconIndex!)
            )
            if file.idiom == .iphone, file.pointSize == 60, file.scale == 3 {
                // The 90 pt subtype-1792 home icon reuses the 60 pt @3x
                // image verbatim (both are 180 px); only its key differs.
                var large = rendition
                large.scale = .x2
                large.subtype = 1792
                large.iconIndex = iconIndexOfSize[largePhonePointSize]
                out.append(large)
                addMultiSizedEntry(
                    &groups, idiom: .iphone, subtype: 1792,
                    pointSize: UInt32(largePhonePointSize), index: UInt32(large.iconIndex!)
                )
            }
        }
        for (group, entries) in groups {
            out.append(Rendition(
                name: appIcon.name,
                idiom: group.idiom,
                scale: .x1,
                appearance: nil,
                gamut: nil,
                subtype: group.subtype == 0 ? nil : group.subtype,
                body: .multiSized(MultiSizedBody(
                    sizes: entries.sorted { $0.key < $1.key }.map {
                        MultiSizedBody.Size(pointWidth: $0.key, pointHeight: $0.key, iconIndex: $0.value)
                    }
                ))
            ))
        }
        return out
    }

    private struct MultiSizedGroup: Hashable {
        var idiom: Idiom
        var subtype: UInt16
    }

    private static func addMultiSizedEntry(
        _ groups: inout [MultiSizedGroup: [UInt32: UInt32]],
        idiom: Idiom,
        subtype: UInt16,
        pointSize: UInt32,
        index: UInt32
    ) {
        groups[MultiSizedGroup(idiom: idiom, subtype: subtype), default: [:]][pointSize] = index
    }
}
