import Foundation

struct LoadedCatalog: Sendable {
    var url: URL
    var imageSets: [LoadedImageSet]
    var colorSets: [LoadedColorSet]
    var appIcon: LoadedAppIcon?
    var brandAssets: [LoadedBrandAssets] = []
    var imageStacks: [LoadedImageStack] = []
}

struct LoadedImageSet: Sendable {
    var name: String
    var directory: URL
    var contents: ImageSetContents
}

struct LoadedColorSet: Sendable {
    var name: String
    var directory: URL
    var contents: ColorSetContents
}

struct LoadedAppIcon: Sendable {
    var name: String
    var directory: URL
    var contents: AppIconContents
}

struct LoadedBrandAssets: Sendable {
    struct Element: Sendable {
        enum Content: Sendable {
            case imageStack(LoadedImageStack)
            case imageSet(LoadedImageSet)
        }

        var definition: BrandAssetsContents.Asset
        var content: Content
    }

    var name: String
    var directory: URL
    var elements: [Element]
}

struct LoadedImageStack: Sendable {
    var name: String
    var directory: URL
    var contents: ImageStackContents
    var layers: [LoadedImageStackLayer]
}

struct LoadedImageStackLayer: Sendable {
    enum Content: Sendable {
        case imageSet(LoadedImageSet)
        case reference(String)
    }

    var name: String
    var properties: ImageStackLayerContents.Properties?
    var content: Content
}

struct CatalogLoader: Sendable {
    init() {}

    func load(catalog url: URL, platform: XCAssetCompiler.Platform = .iOS) async throws -> LoadedCatalog {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw XCAssetCompilerError.notADirectory(path: url.path)
        }

        let decoder = JSONDecoder()

        var imageSets: [LoadedImageSet] = []
        var colorSets: [LoadedColorSet] = []
        var appIcons: [LoadedAppIcon] = []
        var brandAssets: [LoadedBrandAssets] = []
        var imageStacks: [LoadedImageStack] = []

        try walk(url, fileManager: fm) { entry in
            let ext = entry.pathExtension
            let name = entry.deletingPathExtension().lastPathComponent
            switch ext {
            case "imageset":
                let contents = try decode(ImageSetContents.self, at: entry, decoder: decoder)
                imageSets.append(LoadedImageSet(name: name, directory: entry, contents: contents))
            case "colorset":
                let contents = try decode(ColorSetContents.self, at: entry, decoder: decoder)
                colorSets.append(LoadedColorSet(name: name, directory: entry, contents: contents))
            case "appiconset":
                guard platform == .iOS else { return }
                let contents = try decode(AppIconContents.self, at: entry, decoder: decoder)
                appIcons.append(LoadedAppIcon(name: name, directory: entry, contents: contents))
            case "brandassets":
                guard platform == .tvOS else { return }
                brandAssets.append(try loadBrandAssets(at: entry, decoder: decoder))
            case "imagestack":
                imageStacks.append(try loadImageStack(at: entry, decoder: decoder))
            default:
                if !ext.isEmpty {
                    throw XCAssetCompilerError.unsupportedAssetType("\(name).\(ext)")
                }
            }
        }

        guard appIcons.count <= 1 else {
            throw XCAssetCompilerError.multipleAppIconSets(appIcons.map(\.name))
        }

        return LoadedCatalog(
            url: url,
            imageSets: imageSets,
            colorSets: colorSets,
            appIcon: appIcons.first,
            brandAssets: brandAssets,
            imageStacks: imageStacks
        )
    }

    private func loadBrandAssets(at directory: URL, decoder: JSONDecoder) throws -> LoadedBrandAssets {
        let name = directory.deletingPathExtension().lastPathComponent
        let contents = try decode(BrandAssetsContents.self, at: directory, decoder: decoder)
        let elements = try contents.assets.map { asset -> LoadedBrandAssets.Element in
            guard asset.idiom == .tv else {
                throw XCAssetCompilerError.invalidBrandAsset(asset: name, reason: "The idiom must be tv")
            }
            let assetURL = try referencedDirectory(asset.filename, within: directory, asset: name)
            switch asset.role {
            case .primaryAppIcon:
                guard assetURL.pathExtension == "imagestack" else {
                    throw XCAssetCompilerError.invalidBrandAsset(
                        asset: name, reason: "A primary app icon must reference an .imagestack"
                    )
                }
                return LoadedBrandAssets.Element(
                    definition: asset,
                    content: .imageStack(try loadImageStack(at: assetURL, decoder: decoder))
                )
            case .topShelfImage, .topShelfImageWide:
                guard assetURL.pathExtension == "imageset" else {
                    throw XCAssetCompilerError.invalidBrandAsset(
                        asset: name, reason: "A Top Shelf image must reference an .imageset"
                    )
                }
                let imageSet = LoadedImageSet(
                    name: assetURL.deletingPathExtension().lastPathComponent,
                    directory: assetURL,
                    contents: try decode(ImageSetContents.self, at: assetURL, decoder: decoder)
                )
                return LoadedBrandAssets.Element(definition: asset, content: .imageSet(imageSet))
            }
        }
        return LoadedBrandAssets(name: name, directory: directory, elements: elements)
    }

    private func loadImageStack(at directory: URL, decoder: JSONDecoder) throws -> LoadedImageStack {
        let name = directory.deletingPathExtension().lastPathComponent
        let contents = try decode(ImageStackContents.self, at: directory, decoder: decoder)
        guard !contents.layers.isEmpty else {
            throw XCAssetCompilerError.invalidImageStack(asset: name, reason: "The stack has no layers")
        }
        let layers = try contents.layers.map { layer -> LoadedImageStackLayer in
            let layerURL = try referencedDirectory(layer.filename, within: directory, asset: name)
            guard layerURL.pathExtension == "imagestacklayer" else {
                throw XCAssetCompilerError.invalidImageStack(
                    asset: name, reason: "A layer must reference an .imagestacklayer"
                )
            }
            let layerName = layerURL.deletingPathExtension().lastPathComponent
            let metadataURL = layerURL.appendingPathComponent("Contents.json")
            let metadata: ImageStackLayerContents
            if FileManager.default.fileExists(atPath: metadataURL.path) {
                metadata = try decode(ImageStackLayerContents.self, at: layerURL, decoder: decoder)
            } else {
                metadata = ImageStackLayerContents(info: nil, properties: nil)
            }
            let images = try FileManager.default.contentsOfDirectory(
                at: layerURL, includingPropertiesForKeys: [.isDirectoryKey]
            ).filter { url in
                guard url.pathExtension == "imageset" else { return false }
                return try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            }
            if let reference = metadata.properties?.contentReference {
                guard images.isEmpty,
                      reference.type == "image-set",
                      reference.matchingStyle == "fully-qualified-name",
                      !reference.name.isEmpty else {
                    throw XCAssetCompilerError.invalidImageStack(
                        asset: name, reason: "Layer '\(layerName)' has an invalid image-set reference"
                    )
                }
                return LoadedImageStackLayer(
                    name: layerName, properties: metadata.properties, content: .reference(reference.name)
                )
            }
            guard images.count == 1, let imageURL = images.first else {
                throw XCAssetCompilerError.invalidImageStack(
                    asset: name, reason: "Layer '\(layerName)' must contain exactly one .imageset"
                )
            }
            let imageSet = LoadedImageSet(
                name: imageURL.deletingPathExtension().lastPathComponent,
                directory: imageURL,
                contents: try decode(ImageSetContents.self, at: imageURL, decoder: decoder)
            )
            return LoadedImageStackLayer(name: layerName, properties: metadata.properties, content: .imageSet(imageSet))
        }
        return LoadedImageStack(name: name, directory: directory, contents: contents, layers: layers)
    }

    private func referencedDirectory(_ filename: String, within directory: URL, asset: String) throws -> URL {
        let child = directory.appendingPathComponent(filename, isDirectory: true)
        guard !filename.isEmpty,
              filename != ".", filename != "..",
              !filename.contains("/"),
              !filename.contains("\\"),
              (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw XCAssetCompilerError.missingReferencedFile(asset: asset, filename: filename)
        }
        return child
    }

    private func decode<T: Decodable>(_ type: T.Type, at directory: URL, decoder: JSONDecoder) throws -> T {
        let contentsURL = directory.appendingPathComponent("Contents.json")
        guard FileManager.default.fileExists(atPath: contentsURL.path) else {
            throw XCAssetCompilerError.missingContentsJSON(path: directory.path)
        }
        do {
            let data = try Data(contentsOf: contentsURL)
            return try decoder.decode(T.self, from: data)
        } catch let error as XCAssetCompilerError {
            throw error
        } catch {
            throw XCAssetCompilerError.malformedContentsJSON(
                path: contentsURL.path,
                underlying: String(describing: error)
            )
        }
    }

    private func walk(_ root: URL, fileManager fm: FileManager, visit: (URL) throws -> Void) throws {
        let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        for child in children {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            let ext = child.pathExtension
            if ["imageset", "colorset", "appiconset", "brandassets", "imagestack"].contains(ext) {
                try visit(child)
            } else {
                try walk(child, fileManager: fm, visit: visit)
            }
        }
    }
}
