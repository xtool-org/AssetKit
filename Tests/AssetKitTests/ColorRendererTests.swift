import Foundation
import Testing
@testable import AssetKit

@Suite("ColorRenderer")
struct ColorRendererTests {
    @Test("Parses sRGB float components")
    func parsesFloats() throws {
        let json = """
        {
          "info": { "version": 1, "author": "xcode" },
          "colors": [
            {
              "idiom": "universal",
              "color": {
                "color-space": "srgb",
                "components": {
                  "red": "0.5", "green": "0.25", "blue": "0.75", "alpha": "1.0"
                }
              }
            }
          ]
        }
        """
        let contents = try JSONDecoder().decode(ColorSetContents.self, from: Data(json.utf8))
        let set = LoadedColorSet(
            name: "Accent",
            directory: URL(fileURLWithPath: "/"),
            contents: contents
        )
        let renditions = try ColorRenderer.renditions(for: set)
        #expect(renditions.count == 1)
        guard case .color(let body) = renditions[0].body else {
            Issue.record("expected color body")
            return
        }
        #expect(body.components == [0.5, 0.25, 0.75, 1])
        #expect(body.colorSpaceID == 1)
    }

    @Test("Honours display-P3 gamut")
    func parsesP3() throws {
        let json = """
        {
          "info": { "version": 1, "author": "xcode" },
          "colors": [
            {
              "idiom": "universal",
              "display-gamut": "display-P3",
              "color": {
                "color-space": "display-p3",
                "components": {
                  "red": "1.0", "green": "0.0", "blue": "0.0", "alpha": "1.0"
                }
              }
            }
          ]
        }
        """
        let contents = try JSONDecoder().decode(ColorSetContents.self, from: Data(json.utf8))
        let set = LoadedColorSet(name: "P3Red", directory: URL(fileURLWithPath: "/"), contents: contents)
        let renditions = try ColorRenderer.renditions(for: set)
        #expect(renditions.count == 1)
        #expect(renditions[0].gamut == .displayP3)
        guard case .color(let body) = renditions[0].body else {
            Issue.record("expected color body")
            return
        }
        #expect(body.colorSpaceID == 3)
    }

    @Test("Parses 0x-prefixed hex components")
    func parsesHex() throws {
        let json = """
        {
          "info": { "version": 1, "author": "xcode" },
          "colors": [
            {
              "idiom": "universal",
              "color": {
                "color-space": "srgb",
                "components": {
                  "red": "0xFF", "green": "0x00", "blue": "0x80", "alpha": "1.0"
                }
              }
            }
          ]
        }
        """
        let contents = try JSONDecoder().decode(ColorSetContents.self, from: Data(json.utf8))
        let set = LoadedColorSet(name: "Hex", directory: URL(fileURLWithPath: "/"), contents: contents)
        let renditions = try ColorRenderer.renditions(for: set)
        guard case .color(let body) = renditions[0].body else {
            Issue.record("expected color body")
            return
        }
        #expect(body.components == [1, 0, 128.0 / 255, 1])
    }

    @Test("Reads gray as white and alpha, decimals as is and integers over 255")
    func parsesGrayAndIntegers() throws {
        func body(_ colorSpace: String, _ components: String) throws -> ColorBody {
            let json = """
            {
              "info": { "version": 1, "author": "xcode" },
              "colors": [
                { "idiom": "universal", "color": { "color-space": "\(colorSpace)", "components": { \(components) } } }
              ]
            }
            """
            let contents = try JSONDecoder().decode(ColorSetContents.self, from: Data(json.utf8))
            let set = LoadedColorSet(name: "C", directory: URL(fileURLWithPath: "/"), contents: contents)
            guard case .color(let body) = try ColorRenderer.renditions(for: set)[0].body else {
                throw XCAssetCompilerError.invalidColorComponent("expected color body")
            }
            return body
        }
        let gray = try body("gray-gamma-22", #""white": "0.500", "alpha": "1.000""#)
        #expect(gray.components == [0.5, 1])
        let extended = try body("extended-srgb", #""red": "1", "green": "255", "blue": "1.2", "alpha": "1""#)
        #expect(extended.components == [1.0 / 255, 1, 1.2, 1.0 / 255])
    }
}
