import Foundation
import PNG
import Testing
@testable import AssetKit

@Suite("Single-size AppIcon")
struct SingleSizeAppIconTests {
    @Test("Xcode 14+ single 1024 universal icon expands to the iPhone, iPad and store sizes")
    func expandsMaster() async throws {
        let catalog = try makeCatalog(entries: [
            #"{ "filename": "icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024" }"#,
        ], master: solidPNG(size: 1024, rgba: (3, 246, 254, 255)))
        defer { try? FileManager.default.removeItem(at: catalog) }

        let result = try await XCAssetCompiler(deploymentTarget: "17.0").compile(catalog: catalog)
        #expect(result.carData.prefix(8) == Data("BOMStore".utf8))

        // every generated rendition has a distinct key (the icon index tells sizes apart)
        let appIcon = try loadAppIcon(at: catalog)
        let renditions = try ImageRenderer.appIconRenditions(
            for: appIcon,
            files: AppIconPlistEmitter.emit(appIcon).iconFiles
        )
        #expect(renditions.count == 18)
        #expect(Set(renditions.map { RenditionKey(rendition: $0).encode() }).count == renditions.count)

        let bundle = try #require(result.appIconBundle)
        #expect(bundle.primaryIconName == "AppIcon")
        let icons = bundle.infoPlistAdditions["CFBundleIcons"] as? [String: any Sendable]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: any Sendable]
        #expect(primary?["CFBundleIconFiles"] as? [String] == [
            "AppIcon20x20", "AppIcon29x29", "AppIcon40x40", "AppIcon60x60",
        ])
        let ipad = bundle.infoPlistAdditions["CFBundleIcons~ipad"] as? [String: any Sendable]
        let ipadPrimary = ipad?["CFBundlePrimaryIcon"] as? [String: any Sendable]
        #expect((ipadPrimary?["CFBundleIconFiles"] as? [String])?.contains("AppIcon83.5x83.5") == true)

        // names are unique and each file has the pixel size its name promises
        let names = bundle.looseFiles.map(\.name)
        #expect(Set(names).count == names.count)
        let expected: [String: Int] = [
            "AppIcon60x60@2x.png": 120, "AppIcon60x60@3x.png": 180, "AppIcon76x76@2x.png": 152,
            "AppIcon83.5x83.5@2x.png": 167, "AppIcon20x20.png": 20, "AppIcon1024x1024.png": 1024,
        ]
        for (name, pixels) in expected {
            let file = try #require(bundle.looseFiles.first { $0.name == name }, "missing \(name)")
            let decoded = try PNGResizer.decode(file.data)
            #expect(decoded.width == pixels && decoded.height == pixels, "\(name) is \(decoded.width)")
        }
    }

    @Test("Dark and tinted variants are skipped, not compiled as the default icon")
    func appearanceVariantsAreSkipped() throws {
        // the variants point at files that do not exist: they must not even be read
        let catalog = try makeCatalog(entries: [
            #"{ "filename": "icon.png", "idiom": "iphone", "scale": "2x", "size": "60x60" }"#,
            #"""
            { "appearances": [{ "appearance": "luminosity", "value": "dark" }],
              "filename": "dark.png", "idiom": "iphone", "scale": "2x", "size": "60x60" }
            """#,
            #"""
            { "appearances": [{ "appearance": "luminosity", "value": "tinted" }],
              "filename": "tinted.png", "idiom": "iphone", "scale": "2x", "size": "60x60" }
            """#,
        ], master: solidPNG(size: 120, rgba: (1, 2, 3, 255)))
        defer { try? FileManager.default.removeItem(at: catalog) }

        let appIcon = try loadAppIcon(at: catalog)
        #expect(try AppIconPlistEmitter.emit(appIcon).iconFiles.count == 1)
    }

    @Test("A master that is not 1024x1024 is rejected")
    func wrongSizeThrows() throws {
        let catalog = try makeCatalog(entries: [
            #"{ "filename": "icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024" }"#,
        ], master: solidPNG(size: 64, rgba: (1, 2, 3, 255)))
        defer { try? FileManager.default.removeItem(at: catalog) }

        let appIcon = try loadAppIcon(at: catalog)
        #expect(throws: XCAssetCompilerError.self) { _ = try AppIconPlistEmitter.emit(appIcon) }
    }

    @Test("A non-iOS platform is rejected")
    func otherPlatformThrows() throws {
        let catalog = try makeCatalog(entries: [
            #"{ "filename": "icon.png", "idiom": "universal", "platform": "watchos", "size": "1024x1024" }"#,
        ], master: solidPNG(size: 16, rgba: (1, 2, 3, 255)))
        defer { try? FileManager.default.removeItem(at: catalog) }

        let appIcon = try loadAppIcon(at: catalog)
        #expect(throws: XCAssetCompilerError.unsupportedAppIconPlatform(asset: "AppIcon", platform: "watchos")) {
            _ = try AppIconPlistEmitter.emit(appIcon)
        }
    }

    @Test("Downscaling averages instead of sampling, and keeps transparency")
    func resizeAverages() throws {
        // left half white, right half black, both opaque; 2x2 blocks average to grey at the seam only
        var rgba = [PNG.RGBA<UInt8>]()
        for _ in 0..<4 { rgba += [PNG.RGBA(255, 255, 255, 255), PNG.RGBA(0, 0, 0, 255), PNG.RGBA(255, 255, 255, 0), PNG.RGBA(0, 0, 0, 0)] }
        let png = try encode(rgba, size: 4)
        let decoded = try PNGResizer.decode(png)
        let small = try PNGResizer.decode(PNGResizer.resize(decoded, width: 2, height: 2))
        // top-left output pixel covers white + black opaque: premultiplied average is 127.5
        #expect(abs(small.pixels[0] - 127.5) < 1)
        #expect(small.pixels[3] == 255)
        // top-right covers fully transparent pixels
        #expect(small.pixels[7] == 0)
    }
}

private func loadAppIcon(at catalog: URL) throws -> LoadedAppIcon {
    let directory = catalog.appendingPathComponent("AppIcon.appiconset")
    let contents = try JSONDecoder().decode(
        AppIconContents.self,
        from: Data(contentsOf: directory.appendingPathComponent("Contents.json"))
    )
    return LoadedAppIcon(name: "AppIcon", directory: directory, contents: contents)
}

private func makeCatalog(entries: [String], master: Data) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SingleSize-\(UUID().uuidString).xcassets")
    let set = root.appendingPathComponent("AppIcon.appiconset")
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    try master.write(to: set.appendingPathComponent("icon.png"))
    let json = #"{ "images": [\#(entries.joined(separator: ","))], "info": { "author": "xcode", "version": 1 } }"#
    try Data(json.utf8).write(to: set.appendingPathComponent("Contents.json"))
    return root
}

private func solidPNG(size: Int, rgba: (UInt8, UInt8, UInt8, UInt8)) -> Data {
    let pixel = PNG.RGBA<UInt8>(rgba.0, rgba.1, rgba.2, rgba.3)
    // swiftlint-free force try: a failure here is a broken test helper
    return try! encode([PNG.RGBA<UInt8>](repeating: pixel, count: size * size), size: size)
}

private func encode(_ rgba: [PNG.RGBA<UInt8>], size: Int) throws -> Data {
    let image = PNG.Image(
        packing: rgba,
        size: (x: size, y: rgba.count / size),
        layout: PNG.Layout(format: .rgba8(palette: [], fill: nil))
    )
    var stream = MemoryBytestreamDestination()
    try image.compress(stream: &stream)
    return Data(stream.bytes)
}
