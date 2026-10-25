import Foundation

public struct CompileResult: Sendable {
    /// The compiled `Assets.car` bytes. Always present, even if the catalog
    /// contained no assets (callers receive a structurally valid empty CAR).
    public var carData: Data

    /// Bundle metadata for the selected platform's app icon. iOS uses an
    /// `.appiconset`; tvOS uses the primary stack in a `.brandassets` bundle.
    /// `nil` when the catalog has no icon for the selected platform.
    public var appIconBundle: AppIconBundle?

    public init(carData: Data, appIconBundle: AppIconBundle? = nil) {
        self.carData = carData
        self.appIconBundle = appIconBundle
    }
}

/// Platform-specific app icon and Top Shelf bundle metadata. iOS additionally
/// needs loose PNGs for SpringBoard's icon-render fallback path.
public struct AppIconBundle: Sendable {
    /// The selected icon asset name, such as an iOS `.appiconset` basename
    /// or the small tvOS image stack's name.
    public var primaryIconName: String

    /// Plist keys to merge into the app's `Info.plist`. iOS emits its icon
    /// fallback keys; tvOS emits `CFBundleIcons` and `TVTopShelfImage` roles.
    public var infoPlistAdditions: [String: any Sendable]

    /// Loose PNG files that must be copied into the app bundle root
    /// alongside `Assets.car`, named per `CFBundleIconFiles` entries (e.g.
    /// `AppIcon60x60@2x.png`). SpringBoard's icon-rendering pipeline reads
    /// these directly when CoreUI's rendition lookup misses (which happens
    /// when our CRC32-derived NameIdentifier differs from actool's hash) --
    /// without these files, home-screen icons fail to render. Empty for tvOS.
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

public struct XCAssetCompiler: Sendable {
    public enum Platform: String, Sendable {
        case iOS = "ios"
        case tvOS = "atv"
    }

    public var deploymentTarget: String
    public var platform: Platform
    /// Strategy used to rasterise `.svg` sources to PNG bytes. Defaults to
    /// `RsvgConvertRasterizer`, which shells out to `rsvg-convert`. Replace
    /// when you need a different rasteriser (no PATH dep, different
    /// performance profile, sandbox restrictions, etc).
    public var svgRasterizer: any SVGRasterizer

    public init(
        deploymentTarget: String,
        platform: Platform = .iOS,
        svgRasterizer: any SVGRasterizer = RsvgConvertRasterizer()
    ) {
        self.deploymentTarget = deploymentTarget
        self.platform = platform
        self.svgRasterizer = svgRasterizer
    }

    public func compile(catalog catalogURL: URL) async throws -> CompileResult {
        let loader = CatalogLoader()
        let loaded = try await loader.load(catalog: catalogURL, platform: platform)

        if let stack = loaded.imageStacks.first {
            throw XCAssetCompilerError.unsupportedAssetType("\(stack.name).imagestack")
        }

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
        if platform == .iOS, let appIcon = loaded.appIcon {
            let plist = try AppIconPlistEmitter.emit(appIcon)
            renditions.append(contentsOf: try ImageRenderer.appIconRenditions(for: appIcon, files: plist.iconFiles))

            var looseFiles: [LooseFile] = []
            for file in plist.iconFiles {
                let suffix = file.scale == 1 ? "" : "@\(file.scale)x"
                let target = "\(file.outputName)\(suffix).png"
                let data = try Data(contentsOf: file.sourceURL)
                looseFiles.append(LooseFile(name: target, data: data))
            }

            appIconBundle = AppIconBundle(
                primaryIconName: plist.iconName,
                infoPlistAdditions: plist.infoPlistAdditions,
                looseFiles: looseFiles
            )
        }

        if platform == .tvOS {
            guard loaded.brandAssets.count <= 1 else {
                throw XCAssetCompilerError.multipleBrandAssetSets(loaded.brandAssets.map(\.name))
            }
            if let brand = loaded.brandAssets.first {
                let output = try BrandAssetsRenderer.render(brand, svgRasterizer: svgRasterizer)
                renditions.append(contentsOf: output.renditions)
                appIconBundle = output.appIconBundle
            }
            try validateFacetIdentifiers(renditions)
        }

        let writer = CARWriter(deploymentTarget: deploymentTarget, renditions: renditions, platform: platform)
        let bytes = try writer.write()

        return CompileResult(carData: bytes, appIconBundle: appIconBundle)
    }

    private func validateFacetIdentifiers(_ renditions: [Rendition]) throws {
        var namesByIdentifier: [UInt16: String] = [:]
        for name in Set(renditions.map(\.name)).sorted() {
            let identifier = UInt16(FacetKeys.nameHash(name) & 0xFFFF)
            if let other = namesByIdentifier[identifier] {
                throw XCAssetCompilerError.assetIdentifierCollision(first: other, second: name, identifier: identifier)
            }
            namesByIdentifier[identifier] = name
        }
    }
}
