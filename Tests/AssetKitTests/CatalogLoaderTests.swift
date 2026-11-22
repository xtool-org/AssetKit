import Foundation
import Testing
@testable import AssetKit

@Suite("CatalogLoader")
struct CatalogLoaderTests {
    @Test("Rejects more than one appiconset")
    func multipleAppIconSets() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-\(UUID().uuidString).xcassets", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rootContents = """
        { "info": { "version": 1, "author": "xcode" } }
        """
        try Data(rootContents.utf8).write(to: tmp.appendingPathComponent("Contents.json"))

        let appIconJSON = """
        { "images": [], "info": { "version": 1, "author": "xcode" } }
        """

        for name in ["AppIcon.appiconset", "AltIcon.appiconset"] {
            let dir = tmp.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(appIconJSON.utf8).write(to: dir.appendingPathComponent("Contents.json"))
        }

        let loader = CatalogLoader()
        await #expect(throws: XCAssetCompilerError.self) {
            _ = try await loader.load(catalog: tmp)
        }
    }

    @Test("Loads empty catalog")
    func empty() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).xcassets", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let rootContents = """
        { "info": { "version": 1, "author": "xcode" } }
        """
        try Data(rootContents.utf8).write(to: tmp.appendingPathComponent("Contents.json"))

        let loader = CatalogLoader()
        let loaded = try await loader.load(catalog: tmp)
        #expect(loaded.imageSets.isEmpty)
        #expect(loaded.colorSets.isEmpty)
        #expect(loaded.appIcon == nil)
    }

    @Test("Prefixes names inside provides-namespace folders with the folder path")
    func namespaces() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ns-\(UUID().uuidString).xcassets", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let info = #""info": { "version": 1, "author": "xcode" }"#
        let namespace = "{ \(info), \"properties\": { \"provides-namespace\": true } }"
        let folders = [
            "Icons": namespace,
            "Icons/Small": namespace,
            "Icons/Plain": "{ \(info) }",
            "Loose": "{ \(info) }",
        ]
        try Data("{ \(info) }".utf8).write(to: tmp.appendingPathComponent("Contents.json"))
        for (path, contents) in folders {
            let dir = tmp.appendingPathComponent(path, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: dir.appendingPathComponent("Contents.json"))
        }
        for path in ["Top", "Icons/Star", "Icons/Small/Dot", "Icons/Plain/Square", "Loose/Circle"] {
            let dir = tmp.appendingPathComponent(path + ".colorset", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{ \"colors\": [], \(info) }".utf8).write(to: dir.appendingPathComponent("Contents.json"))
        }

        let loaded = try await CatalogLoader().load(catalog: tmp)
        #expect(Set(loaded.colorSets.map(\.name)) == ["Top", "Icons/Star", "Icons/Small/Dot", "Icons/Square", "Circle"])
    }
}
