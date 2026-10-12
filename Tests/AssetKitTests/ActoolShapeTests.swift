import Foundation
import PNG
import Testing
@testable import AssetKit

@Suite("actool 26.5 output shape")
struct ActoolShapeTests {
    /// iPhone 20/29/40/60, iPad 20/29/40/76/83.5 and the store icon, like Tauri's catalog.
    private func makeCatalog() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Shape-\(UUID().uuidString).xcassets", isDirectory: true)
        let set = root.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        let png = tinyPNG()
        try png.write(to: set.appendingPathComponent("icon.png"))
        func entry(_ idiom: String, _ size: String, _ scale: String) -> String {
            #"{ "filename": "icon.png", "idiom": "\#(idiom)", "scale": "\#(scale)", "size": "\#(size)" }"#
        }
        let images = [
            entry("iphone", "20x20", "2x"), entry("iphone", "20x20", "3x"),
            entry("iphone", "29x29", "2x"), entry("iphone", "29x29", "3x"),
            entry("iphone", "40x40", "2x"), entry("iphone", "40x40", "3x"),
            entry("iphone", "60x60", "2x"), entry("iphone", "60x60", "3x"),
            entry("ipad", "20x20", "1x"), entry("ipad", "29x29", "1x"), entry("ipad", "40x40", "1x"),
            entry("ipad", "76x76", "1x"), entry("ipad", "76x76", "2x"), entry("ipad", "83.5x83.5", "2x"),
            entry("ios-marketing", "1024x1024", "1x"),
        ]
        let json = #"{ "images": [\#(images.joined(separator: ","))], "info": { "author": "xcode", "version": 1 } }"#
        try Data(json.utf8).write(to: set.appendingPathComponent("Contents.json"))
        return root
    }

    private func compile(_ options: OutputOptions) async throws -> CARInspector {
        let catalog = try makeCatalog()
        defer { try? FileManager.default.removeItem(at: catalog) }
        let result = try await XCAssetCompiler(deploymentTarget: "17.0", options: options).compile(catalog: catalog)
        return CARInspector(result.carData)
    }

    @Test("legacy output keeps the nine-attribute key format")
    func legacy() async throws {
        let car = try await compile(.legacy)
        #expect(car.keyFormat == [7, 13, 12, 15, 16, 9, 17, 1, 2])
        #expect(car.renditions.allSatisfy { $0.key.count == 9 })
        #expect(car.header?.coreUI == 970)
        #expect(car.renditions.allSatisfy { $0.layout == 12 })
    }

    @Test("Dimension1 adds a tenth attribute to the key format and every key")
    func dimension1() async throws {
        let car = try await compile(.dimension1Key)
        #expect(car.keyFormat == [7, 13, 12, 15, 16, 9, 8, 17, 1, 2])
        #expect(car.renditions.allSatisfy { $0.key.count == 10 && $0.key[6] == 0 })
        #expect(car.header?.coreUI == 970)
        let bitmapKeys = car.treeEntries("BITMAPKEYS")
        #expect(bitmapKeys.count == 1)
        #expect(bitmapKeys[0].value.count == 56)
        #expect(u32(bitmapKeys[0].value, 8) == 0x2c && u32(bitmapKeys[0].value, 12) == 10)
    }

    @Test("Version strings follow Xcode 26.5")
    func versionStrings() async throws {
        let car = try await compile(.actoolVersionStrings)
        let header = try #require(car.header)
        #expect(header.coreUI == 975)
        #expect(header.main == "@(#)PROGRAM:CoreUI  PROJECT:CoreUI-975")
        #expect(header.version == "Xcode 26.5 (17F42) via AssetCatalogSimulatorAgent")
        let metadata = try #require(car.variable("EXTENDED_METADATA"))
        #expect(String(decoding: metadata, as: UTF8.self).contains("CoreThemeDefinition-653.4"))
    }

    @Test("The default does not claim to be Xcode")
    func defaultIsHonest() async throws {
        let catalog = try makeCatalog()
        defer { try? FileManager.default.removeItem(at: catalog) }
        let result = try await XCAssetCompiler(deploymentTarget: "17.0").compile(catalog: catalog)
        let car = CARInspector(result.carData)
        let header = try #require(car.header)
        #expect(header.coreUI == 970)
        #expect(header.version == "AssetKit")
        #expect(car.keyFormat.count == 10)
        #expect(car.renditions.contains { $0.key[9] == 218 })
        let metadata = try #require(car.variable("EXTENDED_METADATA"))
        #expect(!String(decoding: metadata, as: UTF8.self).contains("Xcode"))
    }

    @Test("Full actool shape: size index records, subtype 1792 copy, masks, AppIcon identifier")
    func fullShape() async throws {
        let car = try await compile(.actoolStructure)
        let renditions = car.renditions
        // 15 files + the 60pt@3x copy + 4 index records (iPhone, iPhone 1792, iPad, store)
        #expect(renditions.count == 20)
        #expect(car.header?.renditionCount == 20)
        #expect(Set(renditions.map(\.key)).count == renditions.count)

        // key = appearance, localization, scale, idiom, subtype, dim2, dim1, identifier, element, part
        let identifier: UInt16 = 6849
        let records = renditions.filter { $0.key[9] == 218 }
        #expect(records.count == 4)
        #expect(records.allSatisfy { $0.layout == 1010 && $0.key[7] == identifier && $0.key[2] == 1 })

        func sizes(idiom: UInt16, subtype: UInt16) throws -> [[UInt32]] {
            let record = try #require(records.first { $0.key[3] == idiom && $0.key[4] == subtype })
            let body = record.body
            #expect(String(decoding: body.prefix(4), as: UTF8.self) == "SISM")
            let count = Int(u32(body, 8))
            return (0..<count).map { i in (0..<3).map { u32(body, 12 + 12 * i + 4 * $0) } }
        }
        #expect(try sizes(idiom: 1, subtype: 0) == [[20, 20, 1], [29, 29, 2], [40, 40, 3], [60, 60, 4]])
        #expect(try sizes(idiom: 1, subtype: 1792) == [[90, 90, 7]])
        #expect(try sizes(idiom: 2, subtype: 0) == [[20, 20, 1], [29, 29, 2], [40, 40, 3], [76, 76, 5], [83, 83, 6]])
        #expect(try sizes(idiom: 6, subtype: 0) == [[1024, 1024, 8]])

        // the 60pt@3x icon is also stored as a 2x rendition at subtype 1792, icon index 7
        let copy = try #require(renditions.first { $0.key[4] == 1792 && $0.key[9] == 220 })
        #expect(copy.key[2] == 2 && copy.key[5] == 7 && copy.scaleFactor == 200)

        let facet = try #require(car.treeEntries("FACETKEYS").first { String(decoding: $0.key, as: UTF8.self) == "AppIcon" })
        #expect(u16(facet.value, 16) == identifier)

        // BITMAPKEYS: idioms {1, 2, 6} and icon indexes {0...8}
        let bitmapKeys = try #require(car.treeEntries("BITMAPKEYS").first)
        #expect(u32(bitmapKeys.value, 28) == 0x46)
        #expect(u32(bitmapKeys.value, 36) == 0x1ff)
        #expect(u32(bitmapKeys.value, 40) == 1)
    }
}

private func tinyPNG() -> Data {
    let rgba = [PNG.RGBA<UInt8>](repeating: PNG.RGBA<UInt8>(10, 20, 30, 255), count: 16)
    let image = PNG.Image(
        packing: rgba,
        size: (x: 4, y: 4),
        layout: PNG.Layout(format: .rgba8(palette: [], fill: nil))
    )
    var stream = MemoryBytestreamDestination()
    try! image.compress(stream: &stream)
    return Data(stream.bytes)
}
