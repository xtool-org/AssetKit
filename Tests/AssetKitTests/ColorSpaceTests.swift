import Foundation
import Testing
@testable import AssetKit

/// Pins color rendition bytes against the Xcode 27.0 actool oracle: one
/// colorset per color space (srgb, extended-srgb, display-p3,
/// extended-linear-srgb, gray-gamma-22, extended-gray), light + dark.
///
/// Oracle facts:
/// - COLR colorspace IDs: srgb 1, gray-gamma-22 2, display-p3 3,
///   extended-srgb 4, extended-linear-srgb 5, extended-gray 6.
/// - Gray spaces carry 2 components (white, alpha); RGB spaces carry 4.
/// - Components are quantized to Float32 in the Float64 slots
///   (actool writes 1.1 as 0x3FF19999A0000000).
/// - Color-only catalogs get an 8-attribute KEYFORMAT (no dimension2), so
///   rendition keys are 16 bytes; colors key at element 85 / part 217.
/// - actool writes one BITMAPKEYS row per colorset with marker 0x02.
@Suite("ColorSpace")
struct ColorSpaceTests {
    private func loadColorSet(
        name: String, space: String, lightComponents: String, darkComponents: String
    ) throws -> LoadedColorSet {
        let json = """
        {
          "colors" : [
            {
              "idiom" : "universal",
              "color" : { "platform" : "ios", "color-space" : "\(space)", "components" : \(lightComponents) }
            },
            {
              "idiom" : "universal",
              "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
              "color" : { "platform" : "ios", "color-space" : "\(space)", "components" : \(darkComponents) }
            }
          ],
          "info" : { "author" : "xcode", "version" : 1 }
        }
        """
        let contents = try JSONDecoder().decode(ColorSetContents.self, from: Data(json.utf8))
        return LoadedColorSet(name: name, directory: URL(fileURLWithPath: "/"), contents: contents)
    }

    private func rgbComponents(_ values: [Double]) -> String {
        let keys = ["red", "green", "blue", "alpha"]
        let pairs = zip(keys, values).map { "\"\($0)\" : \"\(stringified([$1]))\"" }
        return "{ \(pairs.joined(separator: ", ")) }"
    }

    private func grayComponents(white: Double, alpha: Double = 1) -> String {
        "{ \"white\" : \"\(stringified([white]))\", \"alpha\" : \"\(stringified([alpha]))\" }"
    }

    private func bytes(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    private func darkRendition(_ renditions: [Rendition]) -> Rendition? {
        renditions.first { $0.appearance?.darkLuminosity == true }
    }

    private func lightRendition(_ renditions: [Rendition]) -> Rendition? {
        renditions.first { $0.appearance?.darkLuminosity != true }
    }

    /// 16-byte color rendition key per the oracle: base 8-attribute format.
    private func colorKey(appearance: UInt16, identifier: UInt16) -> Data {
        var w = ByteWriter()
        for token: UInt16 in [appearance, 0, 1, 0, 0, identifier, 85, 217] {
            w.writeLE(token)
        }
        return w.data
    }

    @Test("Every color space byte-matches actool 27.0 (light and dark)")
    func oracleParity() throws {
        // (set name, color-space, light components, COLR colorspace id, rgb?, oracle CSI)
        let cases: [(String, String, [Double], UInt8, Bool, String)] = [
            ("Srgb", "srgb", [1, 0.5, 0.25, 1], 1, true,
             "495354430100000000000000000000000000000000000000000000000000000000000000f103000053726762000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001c000000010000000000000030000000ec030000080000000000000000000000ee0300000400000001000000524c4f43010000000100000004000000000000000000f03f000000000000e03f000000000000d03f000000000000f03f"),
            ("ExtSrgb", "extended-srgb", [1.2, -0.1, 0.5, 1], 4, true,
             "495354430100000000000000000000000000000000000000000000000000000000000000f103000045787453726762000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001c000000010000000000000030000000ec030000080000000000000000000000ee0300000400000001000000524c4f43010000000400000004000000000000403333f33f000000a09999b9bf000000000000e03f000000000000f03f"),
            ("P3", "display-p3", [1, 0.4, 0.7, 1], 3, true,
             "495354430100000000000000000000000000000000000000000000000000000000000000f103000050330000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001c000000010000000000000030000000ec030000080000000000000000000000ee0300000400000001000000524c4f43010000000300000004000000000000000000f03f000000a09999d93f000000606666e63f000000000000f03f"),
            ("ExtLinear", "extended-linear-srgb", [0.5, 0.25, 0.125, 1], 5, true,
             "495354430100000000000000000000000000000000000000000000000000000000000000f10300004578744c696e65617200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001c000000010000000000000030000000ec030000080000000000000000000000ee0300000400000001000000524c4f43010000000500000004000000000000000000e03f000000000000d03f000000000000c03f000000000000f03f"),
            ("Gray22", "gray-gamma-22", [0.75, 1], 2, false,
             "495354430100000000000000000000000000000000000000000000000000000000000000f103000047726179323200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001c000000010000000000000020000000ec030000080000000000000000000000ee0300000400000001000000524c4f43010000000200000002000000000000000000e83f000000000000f03f"),
            ("ExtGray", "extended-gray", [1.1, 1], 6, false,
             "495354430100000000000000000000000000000000000000000000000000000000000000f103000045787447726179000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001c000000010000000000000020000000ec030000080000000000000000000000ee0300000400000001000000524c4f43010000000600000002000000000000a09999f13f000000000000f03f"),
        ]
        for (name, space, components, colorSpaceID, rgb, oracleHex) in cases {
            let set = try loadColorSet(
                name: name, space: space,
                lightComponents: rgb
                    ? rgbComponents(components)
                    : grayComponents(white: components[0]),
                darkComponents: rgb
                    ? rgbComponents([0, 0, 0, 1])
                    : grayComponents(white: 0))
            let renditions = try ColorRenderer.renditions(for: set)
            #expect(renditions.count == 2, "\(name)")

            let light = try #require(lightRendition(renditions))
            guard case .color(let lightBody) = light.body else {
                Issue.record("\(name): expected color body")
                return
            }
            #expect(lightBody.components == components, "\(name)")
            #expect(lightBody.colorSpaceID == colorSpaceID, "\(name)")
            let csi = CSIWriter.color(name: name, body: lightBody)
            if csi != bytes(oracleHex) {
                let hex = csi.map { String(format: "%02x", $0) }.joined()
                Issue.record("\(name): CSI mismatch\n  ours:   \(hex)\n  oracle: \(oracleHex)")
            }

            // 16-byte rendition keys in the 8-attribute base format.
            let identifier = UInt16(FacetKeys.nameHash(name) & 0xFFFF)
            #expect(RenditionKey(rendition: light).encode(format: baseKeyFormat)
                == colorKey(appearance: 0, identifier: identifier), "\(name)")
            let dark = try #require(darkRendition(renditions))
            #expect(RenditionKey(rendition: dark).encode(format: baseKeyFormat)
                == colorKey(appearance: 1, identifier: identifier), "\(name)")
        }

        // Dark COLR bodies for a gray space (white 0) and extended-gray
        // (white -0.2, alpha 0.5), from the oracle.
        let grayDark = try loadColorSet(name: "Gray22", space: "gray-gamma-22",
                                        lightComponents: grayComponents(white: 0.75),
                                        darkComponents: grayComponents(white: 0))
        let grayDarkBody = try #require(darkRendition(try ColorRenderer.renditions(for: grayDark)))
        guard case .color(let darkBody) = grayDarkBody.body else {
            Issue.record("expected color body")
            return
        }
        #expect(Array(CSIWriter.color(name: "Gray22", body: darkBody)[212...])
            == Array(bytes("524c4f430100000002000000020000000000000000000000000000000000f03f")))

        // Extended-gray dark with the oracle's -0.2 white and 0.5 alpha.
        let extGrayJSON = """
        {
          "colors" : [
            {
              "idiom" : "universal",
              "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
              "color" : { "platform" : "ios", "color-space" : "extended-gray",
                          "components" : { "white" : "-0.200", "alpha" : "0.500" } }
            }
          ],
          "info" : { "author" : "xcode", "version" : 1 }
        }
        """
        let extContents = try JSONDecoder().decode(
            ColorSetContents.self, from: Data(extGrayJSON.utf8))
        let extSet = LoadedColorSet(name: "ExtGray", directory: URL(fileURLWithPath: "/"), contents: extContents)
        let extDark = try #require(darkRendition(try ColorRenderer.renditions(for: extSet)))
        guard case .color(let extBody) = extDark.body else {
            Issue.record("expected color body")
            return
        }
        #expect(extBody.components == [-0.2, 0.5])
        #expect(Array(CSIWriter.color(name: "ExtGray", body: extBody)[212...])
            == Array(bytes("524c4f43010000000600000002000000000000a09999c9bf000000000000e03f")))
    }

    /// Renders the numeric test components as JSON strings.
    private func stringified(_ values: [Double]) -> String {
        values.map { value in
            let rounded = (value * 1000).rounded() / 1000
            return String(format: "%.3f", rounded)
        }.joined(separator: ", ")
    }

    @Test("Decodes the real fullScreenBackgroundColor colorset (gray-gamma-22 dark)")
    func realGrayColorset() throws {
        let json = """
        {
          "info" : { "version" : 1, "author" : "xcode" },
          "colors" : [
            {
              "idiom" : "universal",
              "color" : { "platform" : "ios", "reference" : "systemBackgroundColor" }
            },
            {
              "idiom" : "universal",
              "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
              "color" : {
                "platform" : "ios",
                "color-space" : "gray-gamma-22",
                "components" : { "white" : "0.000", "alpha" : "1.000" }
              }
            }
          ]
        }
        """
        let contents = try JSONDecoder().decode(ColorSetContents.self, from: Data(json.utf8))
        let set = LoadedColorSet(
            name: "fullScreenBackgroundColor",
            directory: URL(fileURLWithPath: "/"),
            contents: contents
        )
        let renditions = try ColorRenderer.renditions(for: set)
        #expect(renditions.count == 2)
        let dark = try #require(darkRendition(renditions))
        guard case .color(let body) = dark.body else {
            Issue.record("expected color body")
            return
        }
        #expect(body.components == [0, 1])
        #expect(body.colorSpaceID == COLRColorSpace.grayGamma22.rawValue)

        // Rendition key: 16 bytes, dark, element 85 / part 217, gray fallback
        // name stays a system reference.
        let identifier = UInt16(FacetKeys.nameHash("fullScreenBackgroundColor") & 0xFFFF)
        #expect(RenditionKey(rendition: dark).encode(format: baseKeyFormat)
            == colorKey(appearance: 1, identifier: identifier))
    }

    @Test("BITMAPKEYS carries a colorset row with marker 0x02")
    func colorBitmapKeysRow() throws {
        let set = try loadColorSet(name: "Srgb", space: "srgb",
                                   lightComponents: rgbComponents([1, 0.5, 0.25, 1]),
                                   darkComponents: rgbComponents([0, 0, 0, 1]))
        let renditions = try ColorRenderer.renditions(for: set)
        let descriptor = try #require(BitmapKeys.descriptor(
            forAsset: "Srgb", renditions: renditions))
        // actool 27.0 value for a universal light+dark colorset, verbatim.
        let encoded = descriptor.encode()
        if encoded != bytes("01000000000000002400000008000000ffffffff01000000020000000100000001000000ffffffffffffffffffffffff") {
            Issue.record("descriptor mismatch: \(encoded.map { String(format: "%02x", $0) }.joined())")
        }
    }

    @Test("Hex and 0-255 decimal component forms decode like Xcode's")
    func componentForms() throws {
        let json = """
        {
          "colors" : [
            {
              "idiom" : "universal",
              "color" : {
                "platform" : "ios",
                "color-space" : "srgb",
                "components" : { "red" : "1", "green" : "0x80", "blue" : "0", "alpha" : "1" }
              }
            }
          ],
          "info" : { "author" : "xcode", "version" : 1 }
        }
        """
        let contents = try JSONDecoder().decode(ColorSetContents.self, from: Data(json.utf8))
        let set = LoadedColorSet(name: "Forms", directory: URL(fileURLWithPath: "/"), contents: contents)
        let renditions = try ColorRenderer.renditions(for: set)
        guard case .color(let body) = renditions[0].body else {
            Issue.record("expected color body")
            return
        }
        #expect(body.components == [1, 128.0 / 255, 0, 1])
    }
}
