import Foundation
import Testing
@testable import AssetKit

/// Pins app-icon "Icon Index" assignment and MultiSized rendition emission
/// against the Xcode 27.0 actool oracle
/// (~/tmp/apple-dev/oracle/icon/{Assets.car,assetutil.json}).
///
/// Oracle facts (two independent actool runs):
/// - Icon Index = rank of the rendition's point size among the appiconset's
///   distinct point sizes, ascending, shared across idioms and scales.
/// - An iphone 60 pt @3x source additionally keys the 90 pt large-phone home
///   icon (subtype 1792, scale 2, same image bytes). Without a 60 pt @3x
///   source no 1792 variant is emitted.
/// - One MultiSized rendition (key part=218, scale=1, dimension2=0) per
///   (idiom, subtype) group, sizes ascending, 83.5 pt truncated to 83.
@Suite("AppIconIconIndex")
struct AppIconIconIndexTests {
    // MARK: - Fixtures

    private func loadAppIcon(
        name: String,
        images: [(filename: String, idiom: String, size: String, scale: String)],
        workDir: URL
    ) throws -> LoadedAppIcon {
        let dir = workDir.appendingPathComponent("\(name).appiconset", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let entries = try images.map { image -> String in
            let decoder = JSONDecoder()
            let entry = """
            {"filename":"\(image.filename)","idiom":"\(image.idiom)","size":"\(image.size)","scale":"\(image.scale)"}
            """
            // Re-decode each entry so a malformed fixture fails the test
            // instead of reaching the compiler with silent nils.
            _ = try decoder.decode(AppIconContents.self, from: Data("{\"images\":[\(entry)],\"info\":{\"author\":\"xcode\",\"version\":1}}".utf8))
            return entry
        }
        let json = "{\"images\":[\(entries.joined(separator: ","))],\"info\":{\"author\":\"xcode\",\"version\":1}}"
        try Data(json.utf8).write(to: dir.appendingPathComponent("Contents.json"))
        for image in images {
            try storedPNG().write(to: dir.appendingPathComponent(image.filename))
        }
        let contents = try JSONDecoder().decode(
            AppIconContents.self,
            from: Data(contentsOf: dir.appendingPathComponent("Contents.json"))
        )
        return LoadedAppIcon(name: name, directory: dir, contents: contents)
    }

    private func renditions(for appIcon: LoadedAppIcon) throws -> [Rendition] {
        let files = try AppIconPlistEmitter.emit(appIcon).iconFiles
        return try ImageRenderer.appIconRenditions(for: appIcon, files: files)
    }

    /// Minimal valid 1x1 PNG (pixel content is irrelevant; only rendition
    /// keys and MultiSized CSI bytes are pinned). Stored (uncompressed)
    /// deflate keeps it dependency-free.
    private func storedPNG() -> Data {
        let ihdr: [UInt8] = [0, 0, 0, 0x0D] + Array("IHDR".utf8)
            + [0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0]
            + be32(crc32(Data(Array("IHDR".utf8)) + Data([0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0])))

        // zlib stream with one stored deflate block of 5 bytes
        // (filter byte + RGBA pixel).
        let raw: [UInt8] = [0, 0xFF, 0x00, 0x00, 0xFF]
        var deflate: [UInt8] = [0x01, UInt8(raw.count), 0, UInt8(~raw.count & 0xFF), 0xFF]
        deflate.append(contentsOf: raw)
        var zlib: [UInt8] = [0x78, 0x01]
        zlib.append(contentsOf: deflate)
        zlib.append(contentsOf: be32(adler32(raw)))

        var idat: [UInt8] = [0, 0, 0, 0] + Array("IDAT".utf8) + zlib
        idat.replaceSubrange(0..<4, with: be32(UInt32(zlib.count)))
        idat.append(contentsOf: be32(crc32(Data(idat[4...]))))

        var iend: [UInt8] = Array("IEND".utf8)
        iend.append(contentsOf: be32(crc32(Data(iend))))
        iend.insert(contentsOf: [0, 0, 0, 0], at: 0)

        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + ihdr + idat + iend)
    }

    private func be32(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1 != 0) ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    private func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    // MARK: - Expected bytes

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

    /// Expected 18-byte rendition key. Tokens follow v1KeyFormat:
    /// appearance, localization, scale, idiom, subtype, dimension2,
    /// identifier, element, part. The identifier is AssetKit's CRC32 name
    /// hash (differs from actool's by design).
    private func key(
        scale: UInt16, idiom: UInt16, subtype: UInt16, dimension2: UInt16,
        element: UInt16 = 85, part: UInt16
    ) -> Data {
        var w = ByteWriter()
        for token: UInt16 in [0, 0, scale, idiom, subtype, dimension2,
                              UInt16(FacetKeys.nameHash("AppIcon") & 0xFFFF), element, part] {
            w.writeLE(token)
        }
        return w.data
    }

    // MARK: - Tests

    @Test("Oracle appiconset: icon indices, 1792 variant, and MultiSized CSI match actool")
    func oracleParity() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("IconIndex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let appIcon = try loadAppIcon(
            name: "AppIcon",
            images: [
                ("icon-120.png", "iphone", "60x60", "2x"),
                ("icon-180.png", "iphone", "60x60", "3x"),
                ("icon-152.png", "ipad", "76x76", "2x"),
                ("icon-167.png", "ipad", "83.5x83.5", "2x"),
                ("icon-1024.png", "ios-marketing", "1024x1024", "1x"),
            ],
            workDir: tmp
        )
        let renditions = try renditions(for: appIcon)
        #expect(renditions.count == 10) // 6 icon + 4 MultiSized
        let descriptor = try #require(BitmapKeys.descriptor(forAsset: "AppIcon", renditions: renditions))
        #expect(descriptor.idiomSubtypeCount == 4)

        let expectedKeys = [
            // (scale, idiom, subtype, dimension2, part) per oracle RENDITIONS.
            key(scale: 2, idiom: 1, subtype: 0, dimension2: 1, part: 220), // 60@2x
            key(scale: 3, idiom: 1, subtype: 0, dimension2: 1, part: 220), // 60@3x
            key(scale: 2, idiom: 2, subtype: 0, dimension2: 2, part: 220), // 76@2x
            key(scale: 2, idiom: 2, subtype: 0, dimension2: 3, part: 220), // 83.5@2x
            key(scale: 1, idiom: 6, subtype: 0, dimension2: 5, part: 220), // 1024
            key(scale: 2, idiom: 1, subtype: 1792, dimension2: 4, part: 220), // 90pt 1792
            key(scale: 1, idiom: 1, subtype: 0, dimension2: 0, part: 218), // phone
            key(scale: 1, idiom: 1, subtype: 1792, dimension2: 0, part: 218), // phone 1792
            key(scale: 1, idiom: 2, subtype: 0, dimension2: 0, part: 218), // pad
            key(scale: 1, idiom: 6, subtype: 0, dimension2: 0, part: 218), // marketing
        ]
        let actualKeys = renditions.map { RenditionKey(rendition: $0).encode(format: v1KeyFormat) }
        for expected in expectedKeys {
            #expect(actualKeys.contains(expected), "missing rendition key \(Array(expected))")
        }

        // The 1792 icon is the 60@3x image re-keyed at scale 2 (same decoded
        // pixels verbatim, as in the reference where both 180 px renditions
        // carry identical MLEC bodies).
        let large = renditions.first { $0.subtype == 1792 && RenditionKey(rendition: $0).part == 220 }
        let phone3x = renditions.first { $0.scale == .x3 && $0.idiom == .iphone }
        guard let large, case .bitmap(let largeBody) = large.body,
              let phone3x, case .bitmap(let phone3xBody) = phone3x.body else {
            Issue.record("missing 1792 icon rendition")
            return
        }
        #expect(largeBody.pixelsBGRA == phone3xBody.pixelsBGRA)
        #expect(large.scale == .x2 && large.iconIndex == 4)

        // MultiSized CSI records byte-match the oracle value blobs verbatim
        // (the CSI value carries no identifier, so equality is exact).
        let phone = CSIWriter.multiSized(
            name: "AppIcon",
            body: MultiSizedBody(sizes: [.init(pointWidth: 60, pointHeight: 60, iconIndex: 1)]))
        #expect(phone == bytes("495354430100000000000000000000000000000000000000000000000000000000000000f203000041707049636f6e000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001c000000010000000000000018000000ec030000080000000000000000000000ee03000004000000010000005349534d01000000010000003c0000003c00000001000000"))
        let phone1792 = CSIWriter.multiSized(
            name: "AppIcon",
            body: MultiSizedBody(sizes: [.init(pointWidth: 90, pointHeight: 90, iconIndex: 4)]))
        #expect(phone1792 == bytes("495354430100000000000000000000000000000000000000000000000000000000000000f203000041707049636f6e000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001c000000010000000000000018000000ec030000080000000000000000000000ee03000004000000010000005349534d01000000010000005a0000005a00000004000000"))
        let pad = CSIWriter.multiSized(
            name: "AppIcon",
            body: MultiSizedBody(sizes: [
                .init(pointWidth: 76, pointHeight: 76, iconIndex: 2),
                .init(pointWidth: 83, pointHeight: 83, iconIndex: 3),
            ]))
        #expect(pad == bytes("495354430100000000000000000000000000000000000000000000000000000000000000f203000041707049636f6e000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001c000000010000000000000024000000ec030000080000000000000000000000ee03000004000000010000005349534d01000000020000004c0000004c00000002000000530000005300000003000000"))
        let marketing = CSIWriter.multiSized(
            name: "AppIcon",
            body: MultiSizedBody(sizes: [.init(pointWidth: 1024, pointHeight: 1024, iconIndex: 5)]))
        #expect(marketing == bytes("495354430100000000000000000000000000000000000000000000000000000000000000f203000041707049636f6e000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001c000000010000000000000018000000ec030000080000000000000000000000ee03000004000000010000005349534d0100000001000000000400000004000005000000"))
    }

    @Test("Full classic set: indices shared across idioms; no 1792 without iphone 60@3x")
    func classicSetIndices() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("IconIndexClassic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let images: [(filename: String, idiom: String, size: String, scale: String)] = [
            ("icon-20@2x.png", "iphone", "20x20", "2x"),
            ("icon-20@3x.png", "iphone", "20x20", "3x"),
            ("icon-29@2x.png", "iphone", "29x29", "2x"),
            ("icon-29@3x.png", "iphone", "29x29", "3x"),
            ("icon-40@2x.png", "iphone", "40x40", "2x"),
            ("icon-40@3x.png", "iphone", "40x40", "3x"),
            ("icon-20@1x.png", "ipad", "20x20", "1x"),
            ("icon-20@2x~ipad.png", "ipad", "20x20", "2x"),
            ("icon-29@1x.png", "ipad", "29x29", "1x"),
            ("icon-29@2x~ipad.png", "ipad", "29x29", "2x"),
            ("icon-40@1x.png", "ipad", "40x40", "1x"),
            ("icon-40@2x~ipad.png", "ipad", "40x40", "2x"),
            ("icon-50@1x.png", "ipad", "50x50", "1x"),
            ("icon-50@2x.png", "ipad", "50x50", "2x"),
            ("icon-76.png", "ipad", "76x76", "1x"),
            ("icon-167.png", "ipad", "83.5x83.5", "2x"),
            ("icon-1024.png", "ios-marketing", "1024x1024", "1x"),
        ]
        let appIcon = try loadAppIcon(name: "AppIcon", images: images, workDir: tmp)
        let renditions = try renditions(for: appIcon)

        func iconIndex(named: String) -> UInt16? {
            renditions.first { rendition in
                guard case .bitmap(let body) = rendition.body, body.kind == .appIcon,
                      body.renditionName == named else { return false }
                return true
            }?.iconIndex
        }

        // Second oracle run: 20→1, 29→2, 40→3, 50→4, 76→5, 83.5→6, 1024→7,
        // shared across idioms and scales.
        #expect(iconIndex(named: "icon-20@2x.png") == 1)
        #expect(iconIndex(named: "icon-20@3x.png") == 1)
        #expect(iconIndex(named: "icon-20@1x.png") == 1)
        #expect(iconIndex(named: "icon-20@2x~ipad.png") == 1)
        #expect(iconIndex(named: "icon-29@2x.png") == 2)
        #expect(iconIndex(named: "icon-29@1x.png") == 2)
        #expect(iconIndex(named: "icon-40@3x.png") == 3)
        #expect(iconIndex(named: "icon-50@2x.png") == 4)
        #expect(iconIndex(named: "icon-76.png") == 5)
        #expect(iconIndex(named: "icon-167.png") == 6)
        #expect(iconIndex(named: "icon-1024.png") == 7)

        // No 1792 variant without an iphone 60@3x source: 17 icon renditions
        // + 3 MultiSized groups (phone, pad, marketing).
        #expect(!renditions.contains { $0.subtype == 1792 })
        #expect(renditions.count == 20)

        let phone = renditions.first {
            RenditionKey(rendition: $0).part == RenditionKey.Part.multiSized.rawValue
                && $0.idiom == .iphone
        }
        guard let phone, case .multiSized(let body) = phone.body else {
            Issue.record("missing phone MultiSized rendition")
            return
        }
        #expect(body.sizes.map(\.pointWidth) == [20, 29, 40])
        #expect(body.sizes.map(\.iconIndex) == [1, 2, 3])
    }
}
