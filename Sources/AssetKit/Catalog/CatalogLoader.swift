import Foundation

struct LoadedCatalog: Sendable {
    var url: URL
    var imageSets: [LoadedImageSet]
    var colorSets: [LoadedColorSet]
    var appIcon: LoadedAppIcon?
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

struct CatalogLoader: Sendable {
    init() {}

    func load(catalog url: URL) async throws -> LoadedCatalog {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw XCAssetCompilerError.notADirectory(path: url.path)
        }

        let decoder = JSONDecoder()

        var imageSets: [LoadedImageSet] = []
        var colorSets: [LoadedColorSet] = []
        var appIcons: [LoadedAppIcon] = []

        try walk(url, namespace: "", fileManager: fm, decoder: decoder) { entry, namespace in
            let ext = entry.pathExtension
            let name = namespace + entry.deletingPathExtension().lastPathComponent
            switch ext {
            case "imageset":
                let contents = try decode(ImageSetContents.self, at: entry, decoder: decoder)
                imageSets.append(LoadedImageSet(name: name, directory: entry, contents: contents))
            case "colorset":
                let contents = try decode(ColorSetContents.self, at: entry, decoder: decoder)
                colorSets.append(LoadedColorSet(name: name, directory: entry, contents: contents))
            case "appiconset":
                guard namespace.isEmpty else { throw XCAssetCompilerError.appIconSetInNamespace(name) }
                let contents = try decode(AppIconContents.self, at: entry, decoder: decoder)
                appIcons.append(LoadedAppIcon(name: name, directory: entry, contents: contents))
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
            appIcon: appIcons.first
        )
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

    private func walk(
        _ root: URL,
        namespace: String,
        fileManager fm: FileManager,
        decoder: JSONDecoder,
        visit: (URL, String) throws -> Void
    ) throws {
        let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        for child in children {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            let ext = child.pathExtension
            if ["imageset", "colorset", "appiconset"].contains(ext) {
                try visit(child, namespace)
            } else {
                let hasContents = fm.fileExists(atPath: child.appendingPathComponent("Contents.json").path)
                let folder = hasContents ? try decode(FolderContents.self, at: child, decoder: decoder) : nil
                let providesNamespace = folder?.properties?.providesNamespace == true
                try walk(
                    child,
                    namespace: providesNamespace ? namespace + child.lastPathComponent + "/" : namespace,
                    fileManager: fm,
                    decoder: decoder,
                    visit: visit
                )
            }
        }
    }
}
