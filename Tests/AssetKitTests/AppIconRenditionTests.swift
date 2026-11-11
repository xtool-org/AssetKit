import Foundation
import Testing
@testable import AssetKit

@Suite("App icon rendition keys")
struct AppIconRenditionTests {
    @Test("Multiple logical icon sizes have distinct encoded CAR keys")
    func multipleSizes() async throws {
        let catalog = FileManager.default.temporaryDirectory
            .appendingPathComponent("icons-\(UUID().uuidString).xcassets", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: catalog) }
        try MultiSizeAppIconFixture.write(to: catalog)

        let result = try await XCAssetCompiler(deploymentTarget: "17.0").compile(catalog: catalog)
        let entries = try renditionEntries(in: result.carData)
        #expect(entries.count == MultiSizeAppIconFixture.entries.count)
        #expect(Set(entries.map(\.key)).count == entries.count, "duplicate RENDITIONS keys hide icon sizes")
        for (key, width) in entries {
            let points = Double(width) / Double(key.scale)
            #expect(key.dimension2 == MultiSizeAppIconFixture.indices[points])
            #expect(key.element == 85)
            #expect(key.part == 220)
        }
    }

    @Test("A single logical icon size keeps index 1 and images keep index 0")
    func singleSize() async throws {
        let catalog = try #require(Bundle.module.url(
            forResource: "Test", withExtension: "xcassets", subdirectory: "Fixtures"
        ))
        let result = try await XCAssetCompiler(
            deploymentTarget: "16.0", svgRasterizer: StubSVGRasterizer()
        ).compile(catalog: catalog)
        let entries = try renditionEntries(in: result.carData)
        let icons = entries.filter { $0.key.part == 220 }
        #expect(icons.count == 2)
        #expect(icons.allSatisfy { $0.key.dimension2 == 1 })
        let images = entries.filter { $0.key.part == 181 }
        #expect(!images.isEmpty)
        #expect(images.allSatisfy { $0.key.dimension2 == 0 })
    }

    private func renditionEntries(in data: Data) throws -> [(key: RenditionKey, width: UInt32)] {
        func u32(_ bytes: Data, _ offset: Int) -> UInt32 {
            bytes.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        let index = Int(u32(data, 0x10))
        func block(_ id: UInt32) -> Data {
            let entry = index + 4 + Int(id) * 8
            let start = Int(u32(data, entry))
            return data.subdata(in: start..<(start + Int(u32(data, entry + 4))))
        }
        let variables = Int(u32(data, 0x18))
        var cursor = variables + 4
        var tree: Data?
        for _ in 0..<u32(data, variables) {
            let id = u32(data, cursor)
            let length = Int(data[cursor + 4])
            let name = String(decoding: data[(cursor + 5)..<(cursor + 5 + length)], as: UTF8.self)
            if name == "RENDITIONS" { tree = block(id) }
            cursor += 5 + length
        }
        let header = try #require(tree)
        let leaf = block(u32(header, 8))
        let count = Int(leaf[2]) << 8 | Int(leaf[3])
        return try (0..<count).map { i in
            let value = block(u32(leaf, 12 + i * 8))
            let key = try #require(RenditionKey.decode(block(u32(leaf, 16 + i * 8))))
            let width = value.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
            }
            return (key, width)
        }
    }
}
