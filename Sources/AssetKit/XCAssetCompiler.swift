import Foundation

public struct CompileResult: Sendable {
    /// The compiled `Assets.car` bytes. Always present, even if the catalog
    /// contained no assets (callers receive a structurally valid empty CAR).
    public var carData: Data

    /// Glue needed to ship an `.appiconset` as part of an iOS app bundle.
    /// `nil` if the catalog contained no `.appiconset`. Present iff the
    /// catalog contained exactly one `.appiconset`.
    public var appIconBundle: AppIconBundle?

    public init(carData: Data, appIconBundle: AppIconBundle? = nil) {
        self.carData = carData
        self.appIconBundle = appIconBundle
    }
}

/// iOS-app-bundle glue derived from the catalog's `.appiconset`. The .car
/// alone is not enough to ship an iOS app icon: SpringBoard's icon-render
/// pipeline falls back to a set of loose PNGs in the bundle root, and the
/// `Info.plist` must declare them.
public struct AppIconBundle: Sendable {
    /// The basename of the `.appiconset` (e.g. "AppIcon"), used as the
    /// `CFBundleIconName` value.
    public var primaryIconName: String

    /// Plist keys to merge into the app's `Info.plist`. Includes
    /// `CFBundleIconName`, `CFBundleIcons`, `CFBundleIcons~ipad`, and the
    /// flat `CFBundleIconFiles` fallback list.
    public var infoPlistAdditions: [String: any Sendable]

    /// Loose PNG files that must be copied into the app bundle root
    /// alongside `Assets.car`, named per `CFBundleIconFiles` entries (e.g.
    /// `AppIcon60x60@2x.png`). SpringBoard's icon-rendering pipeline reads
    /// these directly when CoreUI's rendition lookup misses (which happens
    /// when our CRC32-derived NameIdentifier differs from actool's hash) --
    /// without these files, home-screen icons fail to render.
    public var looseFiles: [LooseFile]

    public init(
        primaryIconName: String,
        infoPlistAdditions: [String: any Sendable],
        looseFiles: [LooseFile]
    ) {
        self.primaryIconName = primaryIconName
        self.infoPlistAdditions = infoPlistAdditions
        self.looseFiles = looseFiles
    }
}

public struct LooseFile: Sendable {
    /// Filename relative to the app bundle root (e.g. "AppIcon60x60@2x.png").
    public var name: String
    public var data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

/// Where the output departs from the minimal CoreUI 970 shape this library
/// first shipped, to look like what Xcode 26.5's actool writes. App Store
/// Connect leaves an upload in processing forever for an `Assets.car` it
/// cannot read, so each difference is individually switchable while it is
/// being narrowed down.
public struct OutputOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Ten-attribute `KEYFORMAT` with `Dimension1`, a matching slot in every
    /// rendition key, and the matching `BITMAPKEYS` descriptor size.
    public static let dimension1Key = OutputOptions(rawValue: 1 << 0)
    /// Tool mimicry, off by default: CoreUI 975 and the Xcode 26.5 tool strings
    /// in `CARHEADER` and `EXTENDED_METADATA`, which claim the file was
    /// written by Xcode's actool. Only useful to test whether a consumer
    /// checks them; by default the header names AssetKit.
    public static let actoolVersionStrings = OutputOptions(rawValue: 1 << 1)
    /// The app icon "multisize" index records (part 218), the extra
    /// iPhone 60pt@3x rendition actool stores at subtype 1792, and
    /// `BITMAPKEYS` idiom / icon-index masks.
    public static let multisizeIcons = OutputOptions(rawValue: 1 << 2)
    /// The `NameIdentifier` actool computes for `AppIcon` (6849) instead of
    /// the CRC32-based one used for other names.
    public static let actoolIdentifiers = OutputOptions(rawValue: 1 << 3)

    /// The original output of this library.
    public static let legacy: OutputOptions = []
    /// The structure of actool 26.5's output, without claiming to be it.
    public static let actoolStructure: OutputOptions = [.dimension1Key, .multisizeIcons, .actoolIdentifiers]
    /// Everything, including the tool strings.
    public static let actool26_5: OutputOptions = actoolStructure.union(.actoolVersionStrings)
}

public struct XCAssetCompiler: Sendable {
    public var deploymentTarget: String
    /// Strategy used to rasterise `.svg` sources to PNG bytes. Defaults to
    /// `RsvgConvertRasterizer`, which shells out to `rsvg-convert`. Replace
    /// when you need a different rasteriser (no PATH dep, different
    /// performance profile, sandbox restrictions, etc).
    public var svgRasterizer: any SVGRasterizer
    public var options: OutputOptions

    public init(
        deploymentTarget: String,
        svgRasterizer: any SVGRasterizer = RsvgConvertRasterizer(),
        options: OutputOptions = .actoolStructure
    ) {
        self.deploymentTarget = deploymentTarget
        self.svgRasterizer = svgRasterizer
        self.options = options
    }

    public func compile(catalog catalogURL: URL) async throws -> CompileResult {
        let loader = CatalogLoader()
        let loaded = try await loader.load(catalog: catalogURL)

        var renditions: [Rendition] = []

        for imageSet in loaded.imageSets {
            renditions.append(contentsOf: try ImageRenderer.renditions(
                for: imageSet,
                svgRasterizer: svgRasterizer
            ))
        }
        for colorSet in loaded.colorSets {
            renditions.append(contentsOf: try ColorRenderer.renditions(for: colorSet))
        }

        var appIconBundle: AppIconBundle?
        if let appIcon = loaded.appIcon {
            let plist = try AppIconPlistEmitter.emit(appIcon)
            renditions.append(contentsOf: try ImageRenderer.appIconRenditions(
                for: appIcon,
                files: plist.iconFiles,
                options: options
            ))

            var looseFiles: [LooseFile] = []
            var seen: Set<String> = []
            for file in plist.iconFiles {
                let suffix = file.scale == 1 ? "" : "@\(file.scale)x"
                let target = "\(file.outputName)\(suffix).png"
                // iPhone and iPad entries can share a name (and, when generated, pixels).
                if seen.insert(target).inserted {
                    looseFiles.append(LooseFile(name: target, data: file.data))
                }
            }

            appIconBundle = AppIconBundle(
                primaryIconName: plist.iconName,
                infoPlistAdditions: plist.infoPlistAdditions,
                looseFiles: looseFiles
            )
        }

        let writer = CARWriter(deploymentTarget: deploymentTarget, renditions: renditions, options: options)
        let bytes = try writer.write()

        return CompileResult(carData: bytes, appIconBundle: appIconBundle)
    }
}
