import Foundation
import Testing
import PNG
@testable import AssetKit

@Suite("Brand Assets")
struct BrandAssetsTests {
    @Test("Brand asset children are not flattened into ordinary imagesets")
    func preservesBrandAssetHierarchy() async throws {
        let fixture = try BrandFixture()
        defer { fixture.remove() }

        let catalog = try await CatalogLoader().load(catalog: fixture.url, platform: .tvOS)
        #expect(catalog.imageSets.isEmpty)
        let brand = try #require(catalog.brandAssets.first)
        #expect(brand.name == "TVAppIcon")
        #expect(brand.elements.map(\.definition.role) == [.primaryAppIcon, .topShelfImage])
        guard case .imageStack(let stack) = brand.elements[0].content else {
            Issue.record("The primary icon was not loaded as an image stack")
            return
        }
        #expect(stack.layers.map(\.name) == ["Front", "Back"])
    }

    @Test("Layer properties preserve an image-set reference and frame geometry")
    func referenceAndFrame() async throws {
        let fixture = try BrandFixture()
        defer { fixture.remove() }
        let layer = "TVAppIcon.brandassets/App Icon.imagestack/Front.imagestacklayer"
        try FileManager.default.removeItem(at: fixture.url.appendingPathComponent("\(layer)/Content.imageset"))
        try fixture.write("\(layer)/Contents.json", """
        {
          "properties": {
            "content-reference": {
              "type": "image-set", "name": "Shared/Front", "matching-style": "fully-qualified-name"
            },
            "frame-size": { "width": 100, "height": 90 },
            "frame-center": { "x": 70, "y": 50 }
          }
        }
        """)
        let catalog = try await CatalogLoader().load(catalog: fixture.url, platform: .tvOS)
        let brand = try #require(catalog.brandAssets.first)
        guard case .imageStack(let stack) = brand.elements[0].content else {
            Issue.record("The primary icon was not loaded as an image stack")
            return
        }
        let front = try #require(stack.layers.first)
        guard case .reference(let name) = front.content else {
            Issue.record("The image-set reference was lost")
            return
        }
        #expect(name == "Shared/Front")
        #expect(front.properties?.frameSize == AssetSize(width: 100, height: 90))
        #expect(front.properties?.frameCenter == AssetPoint(x: 70, y: 50))
    }

    @Test("tvOS compilation preserves layers, emits its primary icon, and selects platform metadata")
    func compilesTVBrandAssets() async throws {
        let fixture = try BrandFixture(renderable: true)
        defer { fixture.remove() }
        let loaded = try await CatalogLoader().load(catalog: fixture.url, platform: .tvOS)
        let output = try BrandAssetsRenderer.render(try #require(loaded.brandAssets.first), svgRasterizer: StubSVGRasterizer())
        let descriptor = try #require(output.renditions.first { if case .layerStack = $0.body { return true }; return false })
        guard case .layerStack(let stack) = descriptor.body else { return }
        #expect(stack.backgroundName == "App Icon/Back/Content")
        #expect(stack.foregroundName == "App Icon/Front/Content")
        #expect(descriptor.idiom == .universal)
        let preview = try #require(output.renditions.first {
            if case .bitmap(let body) = $0.body { return body.kind == .layerStackPreview }
            return false
        })
        guard case .bitmap(let pixels) = preview.body else { return }
        #expect(Array(pixels.pixelsBGRA.prefix(4)) == [127, 0, 128, 255])

        let result = try await XCAssetCompiler(deploymentTarget: "17.0", platform: .tvOS).compile(catalog: fixture.url)
        let bundle = try #require(result.appIconBundle)
        #expect(bundle.primaryIconName == "App Icon")
        #expect(bundle.looseFiles.isEmpty)
        #expect((bundle.infoPlistAdditions["CFBundleIcons"] as? [String: String])?["CFBundlePrimaryIcon"] == "App Icon")
        #expect((bundle.infoPlistAdditions["TVTopShelfImage"] as? [String: String])?["TVTopShelfPrimaryImage"] == "Top Shelf")
    }

    @Test("Default iOS compilation ignores TV Brand Assets and preserves its AppIcon")
    func mixedCatalogSelectsPlatform() async throws {
        let fixture = try BrandFixture(renderable: true)
        defer { fixture.remove() }
        try fixture.write("AppIcon.appiconset/Contents.json", """
        { "info": { "version": 1, "author": "xcode" },
          "images": [{ "idiom": "iphone", "size": "60x60", "scale": "2x", "filename": "icon.png" }] }
        """)
        try fixture.writePNG("AppIcon.appiconset/icon.png", width: 120, height: 120, color: PNG.RGBA<UInt8>(255, 0, 0, 255))
        let ios = XCAssetCompiler(deploymentTarget: "16.0")
        let mixed = try await ios.compile(catalog: fixture.url)
        #expect(mixed.appIconBundle?.primaryIconName == "AppIcon")
        let tvos = try await XCAssetCompiler(deploymentTarget: "17.0", platform: .tvOS).compile(catalog: fixture.url)
        #expect(tvos.appIconBundle?.primaryIconName == "App Icon")

        try FileManager.default.copyItem(
            at: fixture.url.appendingPathComponent("AppIcon.appiconset"),
            to: fixture.url.appendingPathComponent("Alternative.appiconset")
        )
        let tvWithAlternative = try await XCAssetCompiler(deploymentTarget: "17.0", platform: .tvOS).compile(catalog: fixture.url)
        #expect(tvWithAlternative.carData == tvos.carData)
        try FileManager.default.removeItem(at: fixture.url.appendingPathComponent("Alternative.appiconset"))

        try fixture.write("TVAppIcon.brandassets/Contents.json", "{}")
        let iosIgnoringBrand = try await ios.compile(catalog: fixture.url)
        #expect(iosIgnoringBrand.carData == mixed.carData)
        try FileManager.default.removeItem(at: fixture.url.appendingPathComponent("TVAppIcon.brandassets"))
        let iosOnly = try await ios.compile(catalog: fixture.url)
        #expect(mixed.carData == iosOnly.carData)
    }

    @Test("Marketing icons share the primary facet and retain their own layer names")
    func marketingVariant() async throws {
        let fixture = try BrandFixture(renderable: true)
        defer { fixture.remove() }
        let brandDirectory = fixture.url.appendingPathComponent("TVAppIcon.brandassets")
        let metadataURL = brandDirectory.appendingPathComponent("Contents.json")
        var metadata = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        var assets = try #require(metadata["assets"] as? [[String: String]])
        assets.append(["filename": "App Icon - Large.imagestack", "idiom": "tv",
                       "role": "primary-app-icon", "size": "1280x768"])
        metadata["assets"] = assets
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
        try FileManager.default.copyItem(
            at: brandDirectory.appendingPathComponent("App Icon.imagestack"),
            to: brandDirectory.appendingPathComponent("App Icon - Large.imagestack")
        )
        for name in ["Front", "Back"] {
            try fixture.writePNG("TVAppIcon.brandassets/App Icon - Large.imagestack/\(name).imagestacklayer/Content.imageset/image.png",
                                 width: 1280, height: 768, color: PNG.RGBA<UInt8>(255, 0, 255, 255))
        }
        let catalog = try await CatalogLoader().load(catalog: fixture.url, platform: .tvOS)
        let output = try BrandAssetsRenderer.render(try #require(catalog.brandAssets.first), svgRasterizer: StubSVGRasterizer())
        let marketing = try #require(output.renditions.first {
            if case .layerStack = $0.body { return $0.idiom == .marketing }
            return false
        })
        guard case .layerStack(let body) = marketing.body else { return }
        #expect(marketing.name == "App Icon")
        #expect(body.width == 1280 && body.height == 768)
        #expect(body.backgroundName == "App Icon - Large/Back/Content")
        #expect(body.foregroundName == "App Icon - Large/Front/Content")
        let children = output.renditions.filter { $0.name.hasPrefix("App Icon - Large/") }
        #expect(children.count == 2)
        #expect(children.allSatisfy { $0.idiom == .marketing && $0.scale == .x1 })
    }

    @Test("A Top Shelf name cannot alias an image-stack child identifier")
    func rejectsIdentifierCollision() async throws {
        let fixture = try BrandFixture(renderable: true)
        defer { fixture.remove() }
        let brand = fixture.url.appendingPathComponent("TVAppIcon.brandassets")
        let metadataURL = brand.appendingPathComponent("Contents.json")
        var metadata = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        var assets = try #require(metadata["assets"] as? [[String: String]])
        assets[0]["filename"] = "App Icon - Small.imagestack"
        assets[1]["filename"] = "TopShelf4014.imageset"
        metadata["assets"] = assets
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
        try FileManager.default.moveItem(at: brand.appendingPathComponent("App Icon.imagestack"),
                                         to: brand.appendingPathComponent("App Icon - Small.imagestack"))
        try FileManager.default.moveItem(at: brand.appendingPathComponent("Top Shelf.imageset"),
                                         to: brand.appendingPathComponent("TopShelf4014.imageset"))
        #expect(FacetKeys.nameHash("App Icon - Small/Back/Content") & 0xFFFF == FacetKeys.nameHash("TopShelf4014") & 0xFFFF)
        do {
            _ = try await XCAssetCompiler(deploymentTarget: "17.0", platform: .tvOS).compile(catalog: fixture.url)
            Issue.record("Distinct facet names with colliding identifiers compiled")
        } catch XCAssetCompilerError.assetIdentifierCollision(let first, let second, let identifier) {
            #expect(Set([first, second]) == Set(["App Icon - Small/Back/Content", "TopShelf4014"]))
            #expect(identifier == 53544)
        }
    }

    @Test("Primary icon and Top Shelf roles cannot export the same asset name")
    func rejectsRoleNameCollision() async throws {
        let fixture = try BrandFixture(renderable: true)
        defer { fixture.remove() }
        let brand = fixture.url.appendingPathComponent("TVAppIcon.brandassets")
        let metadataURL = brand.appendingPathComponent("Contents.json")
        var metadata = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        var assets = try #require(metadata["assets"] as? [[String: String]])
        assets[1]["filename"] = "App Icon.imageset"
        metadata["assets"] = assets
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
        try FileManager.default.moveItem(at: brand.appendingPathComponent("Top Shelf.imageset"),
                                         to: brand.appendingPathComponent("App Icon.imageset"))
        await #expect(throws: XCAssetCompilerError.self) {
            _ = try await XCAssetCompiler(deploymentTarget: "17.0", platform: .tvOS).compile(catalog: fixture.url)
        }
    }

    @Test("tvOS bitmap descriptors encode emitted scale and idiom masks")
    func bitmapMasks() throws {
        let stack = LayerStackBody(width: 400, height: 240, backgroundName: "Back", foregroundName: "Front")
        let descriptor = Rendition(name: "Icon", idiom: .universal, scale: .x1, appearance: nil,
                                   gamut: nil, body: .layerStack(stack))
        var marketing = descriptor
        marketing.idiom = .marketing
        func preview(_ scale: Scale, _ idiom: Idiom) -> Rendition {
            Rendition(name: "Icon", idiom: idiom, scale: scale, appearance: nil, gamut: .sRGB,
                      body: .bitmap(BitmapBody(width: 1, height: 1, pixelsBGRA: [0, 0, 0, 255],
                                               colorSpaceID: 1, kind: .layerStackPreview, renditionName: "preview")))
        }
        let value = try #require(BitmapKeys.descriptor(forAsset: "Icon", renditions: [
            descriptor, marketing, preview(.x1, .tv), preview(.x2, .tv), preview(.x1, .marketing),
        ]))
        let bytes = [UInt8](value.encode(platform: .tvOS))
        func word(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 |
                UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        #expect(bytes.count == 52)
        #expect(word(24) == 0x06)
        #expect(word(28) == 0x49)
        #expect(word(32) == 1 && word(36) == 1)
    }

    @Test("Custom layer geometry is rejected rather than silently discarded")
    func rejectsCustomGeometry() async throws {
        let fixture = try BrandFixture(renderable: true)
        defer { fixture.remove() }
        try fixture.write("TVAppIcon.brandassets/App Icon.imagestack/Front.imagestacklayer/Contents.json", """
        { "properties": { "frame-center": { "x": 100, "y": 100 } } }
        """)
        await #expect(throws: XCAssetCompilerError.self) {
            _ = try await XCAssetCompiler(deploymentTarget: "17.0", platform: .tvOS).compile(catalog: fixture.url)
        }
    }

    @Test("Unverified layer counts are rejected", arguments: [1, 3])
    func rejectsLayerCount(_ count: Int) async throws {
        let fixture = try BrandFixture()
        defer { fixture.remove() }
        let filenames = (0..<count).map { ["filename": $0 == 1 ? "Back.imagestacklayer" : "Front.imagestacklayer"] }
        let contents: [String: Any] = ["layers": filenames, "info": ["version": 1, "author": "xcode"]]
        let data = try JSONSerialization.data(withJSONObject: contents)
        try data.write(to: fixture.url.appendingPathComponent("TVAppIcon.brandassets/App Icon.imagestack/Contents.json"))
        do {
            _ = try await XCAssetCompiler(deploymentTarget: "17.0", platform: .tvOS).compile(catalog: fixture.url)
            Issue.record("An unsupported layer count compiled")
        } catch XCAssetCompilerError.invalidImageStack(let name, _) {
            #expect(name == "App Icon")
        }
    }

    @Test("Stack CSI matches the observed CoreUI two-layer descriptor shape")
    func stackCSIShape() throws {
        let body = LayerStackBody(width: 400, height: 240, backgroundName: "Back", foregroundName: "Front")
        let record = [UInt8](CSIWriter.layerStack(body: body))
        func word(_ offset: Int) -> UInt32 {
            UInt32(record[offset]) | UInt32(record[offset + 1]) << 8 |
                UInt32(record[offset + 2]) << 16 | UInt32(record[offset + 3]) << 24
        }
        #expect(record.count == 470)
        #expect(word(12) == 400 && word(16) == 240)
        #expect(word(24) == CSIHeader.pixelFormatData)
        #expect(word(36) == 1002)
        #expect(word(168) == 274)
        #expect(word(184) == 1012 && word(188) == 104)
        #expect(word(192) == 2)
        #expect(word(212) == 400 && word(216) == 240)
        #expect(word(260) == 400 && word(264) == 240)
        #expect(word(236) == 0x00b50002)
        #expect(word(284) == 0x00b50002)
        #expect(word(240) == (FacetKeys.nameHash("Back") & 0xFFFF) << 16 | 17)
        #expect(word(288) == (FacetKeys.nameHash("Front") & 0xFFFF) << 16 | 17)
        #expect(word(296) == 1020 && word(300) == 34)
        #expect(word(338) == 1021 && word(342) == 48)
        #expect(Array(record.suffix(12)) == Array("DWAR".utf8) + [UInt8](repeating: 0, count: 8))
    }

    @Test("Apple assetutil parses the tvOS stack catalog", .enabled(if: ProcessLauncher.isAvailable))
    func appleParsesTVBrandAssets() async throws {
        let fixture = try BrandFixture(renderable: true)
        defer { fixture.remove() }
        let result = try await XCAssetCompiler(deploymentTarget: "17.0", platform: .tvOS).compile(catalog: fixture.url)
        let car = fixture.url.appendingPathComponent("Assets.car")
        try result.carData.write(to: car)
        let invocation = try ProcessLauncher.run(executable: "/usr/bin/xcrun", arguments: ["assetutil", "--info", car.path])
        #expect(invocation.exitCode == 0, "\(String(decoding: invocation.stderr, as: UTF8.self))")
        let entries = try #require(JSONSerialization.jsonObject(with: invocation.stdout) as? [[String: Any]])
        #expect(entries.first?["Platform"] as? String == "atv")
        let names = Set(entries.compactMap { $0["Name"] as? String })
        #expect(names.contains("App Icon"))
        #expect(names.contains("App Icon/Front/Content"))
        #expect(names.contains("App Icon/Back/Content"))
        #expect(names.contains("Top Shelf"))
    }
}

private struct BrandFixture {
    let url: URL

    init(renderable: Bool = false) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("brand-\(UUID().uuidString).xcassets", isDirectory: true)
        try write("Contents.json", """
        { "info": { "version": 1, "author": "xcode" } }
        """)
        try write("TVAppIcon.brandassets/Contents.json", """
        {
          "info": { "version": 1, "author": "xcode" },
          "assets": [
            { "filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240" },
            { "filename": "Top Shelf.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "120x120" }
          ]
        }
        """)
        try write("TVAppIcon.brandassets/App Icon.imagestack/Contents.json", """
        {
          "info": { "version": 1, "author": "xcode" },
          "layers": [
            { "filename": "Front.imagestacklayer" },
            { "filename": "Back.imagestacklayer" }
          ]
        }
        """)
        for name in ["Back", "Front"] {
            try write("TVAppIcon.brandassets/App Icon.imagestack/\(name).imagestacklayer/Content.imageset/Contents.json", """
            {
              "info": { "version": 1, "author": "xcode" },
              "images": [{ "idiom": "tv", "scale": "1x", "filename": "image.png" }]
            }
            """)
        }
        try write("TVAppIcon.brandassets/Top Shelf.imageset/Contents.json", """
        {
          "info": { "version": 1, "author": "xcode" },
          "images": [{ "idiom": "tv", "scale": "1x", "filename": "image.png" }]
        }
        """)
        if renderable {
            try writePNG("TVAppIcon.brandassets/App Icon.imagestack/Front.imagestacklayer/Content.imageset/image.png",
                         width: 400, height: 240, color: PNG.RGBA<UInt8>(255, 0, 0, 128))
            try writePNG("TVAppIcon.brandassets/App Icon.imagestack/Back.imagestacklayer/Content.imageset/image.png",
                         width: 400, height: 240, color: PNG.RGBA<UInt8>(0, 0, 255, 255))
            try writePNG("TVAppIcon.brandassets/Top Shelf.imageset/image.png",
                         width: 120, height: 120, color: PNG.RGBA<UInt8>(0, 255, 0, 255))
        }
    }

    func write(_ path: String, _ json: String) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: file)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func writePNG(_ path: String, width: Int, height: Int, color: PNG.RGBA<UInt8>) throws {
        let image = PNG.Image(
            packing: [PNG.RGBA<UInt8>](repeating: color, count: width * height),
            size: (x: width, y: height), layout: PNG.Layout(format: .rgba8(palette: [], fill: nil))
        )
        var stream = MemoryBytestreamDestination()
        try image.compress(stream: &stream, level: 0)
        try Data(stream.bytes).write(to: url.appendingPathComponent(path))
    }
}
