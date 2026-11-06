import Foundation
import Testing
@testable import AssetKit

@Suite("CSI writer")
struct CSIWriterTests {
    @Test("Bitmap CSI header is 184 bytes with reference field layout (risk-vector-flag)")
    func bitmapHeader() {
        let body = BitmapBody(
            width: 60, height: 60,
            pixelsBGRA: [UInt8](repeating: 0, count: 60 * 60 * 4),
            colorSpaceID: 1,
            kind: .appIcon,
            renditionName: "icon@2x.png"
        )
        let data = CSIWriter.bitmap(name: "AppIcon", body: body, scaleFactor: 200)
        let bytes = [UInt8](data)
        // tag 'CTSI' written as LE multi-char constant -> file bytes 'I','S','T','C'
        #expect(bytes[0] == 0x49)
        #expect(bytes[1] == 0x53)
        #expect(bytes[2] == 0x54)
        #expect(bytes[3] == 0x43)
        // version u32 LE = 1
        #expect(bytes[4] == 0x01)
        // renditionFlags u32 LE = 0 -> bit 1 (vector) cleared
        #expect(bytes[8] == 0)
        #expect(bytes[9] == 0)
        #expect(bytes[10] == 0)
        #expect(bytes[11] == 0)
        // scaleFactor u32 LE = 200 (= scale*100 for 2x)
        #expect(bytes[0x14] == 0xc8)
        #expect(bytes[0x15] == 0x00)
        #expect(bytes[0x16] == 0x00)
        #expect(bytes[0x17] == 0x00)
        // pixelFormat 'ARGB' LE: bytes 'B','G','R','A'
        #expect(bytes[0x18] == 0x42)
        #expect(bytes[0x19] == 0x47)
        #expect(bytes[0x1A] == 0x52)
        #expect(bytes[0x1B] == 0x41)
        // colorSpace u32 LE = 1
        #expect(bytes[0x1C] == 0x01)
        // layout u16 LE = 12 (bitmapIcon)
        #expect(bytes[0x24] == 0x0c)
        #expect(bytes[0x25] == 0x00)
        // name field (128 bytes from offset 0x28) starts with "icon@2x.png"
        let nameStart = 0x28
        let nameBytes = Array(bytes[nameStart..<(nameStart + 11)])
        #expect(nameBytes == Array("icon@2x.png".utf8))
        // bitmap CSI header alone is 184 bytes; body follows
        #expect(data.count >= 184)
    }

    @Test("Color CSI matches actool 27.0's bytes for an sRGB color")
    func colorBody() {
        // Captured from Xcode 27.0 actool (assetutil reads it as sRGB [1, 0, 0, 1]).
        let referenceTVL: [UInt8] = [
            0xEC, 0x03, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0xEE, 0x03, 0, 0, 4, 0, 0, 0, 1, 0, 0, 0,
        ]
        let referenceBody: [UInt8] = [
            0x52, 0x4C, 0x4F, 0x43, 1, 0, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0xF0, 0x3F, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xF0, 0x3F,
        ]
        let body = ColorBody(components: [1, 0, 0, 1], colorSpaceID: 1)
        let data = [UInt8](CSIWriter.color(name: "Dot", body: body))
        #expect(Array(data[184..<(184 + 28)]) == referenceTVL)
        #expect(Array(data[(184 + 28)...]) == referenceBody)
        // Header: scaleFactor (offset 20) and colorSpace (offset 28) zero, bitmap count 1.
        #expect(data[20..<24].allSatisfy { $0 == 0 } && data[28..<32].allSatisfy { $0 == 0 })
        #expect(Array(data[172..<176]) == [1, 0, 0, 0])
    }

    @Test("System color reference matches actool 27.0's bytes (labelColor, light)")
    func systemColorBody() {
        // Captured from Xcode 27.0 actool; assetutil reads it as "System Color Name": "labelColor".
        let referenceBody: [UInt8] = [
            0x52, 0x4C, 0x4F, 0x43, 1, 0, 0, 0, 0x02, 0x01, 0, 0, 2, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xF0, 0x3F,
            0x52, 0x4C, 0x4F, 0x43, 1, 0, 0, 0, 10, 0, 0, 0,
        ] + Array("labelColor".utf8)
        let body = ColorBody(components: [0, 1], colorSpaceID: 1, systemName: "labelColor")
        let data = [UInt8](CSIWriter.color(name: "label", body: body))
        #expect(Array(data[(184 + 28)...]) == referenceBody)
    }
}
