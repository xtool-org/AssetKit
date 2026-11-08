import Foundation
import Testing
@testable import AssetKit

@Suite("Bitmap row padding")
struct RowPaddingTests {
    @Test("Rows are padded to 32 bytes, in the TLV and in the pixels")
    func rowPadding() throws {
        for (width, expected) in [(20, 96), (29, 128), (87, 352), (167, 672), (180, 736), (256, 1024)] {
            #expect(MLECBody.bytesPerRow(width: UInt32(width)) == expected, "\(width)")
        }
        // 29 px wide, 3 rows: each stored row is 128 bytes, the last 12 zero
        let width = 29, height = 3
        let pixels = [UInt8](repeating: 0xAB, count: width * 4 * height)
        let body = MLECBody.encode(width: UInt32(width), height: UInt32(height), pixelsBGRA: pixels)
        func le32(_ o: Int) -> Int {
            Int(body[body.startIndex + o]) | Int(body[body.startIndex + o + 1]) << 8
                | Int(body[body.startIndex + o + 2]) << 16 | Int(body[body.startIndex + o + 3]) << 24
        }
        // 3 rows divide by 3: one KCBC chunk per row. MLEC header 16 bytes, chunk header 20 bytes
        var offset = 16
        for _ in 0..<3 {
            let size = le32(offset + 16)
            let raw = LZFSE.decode(Array(body[body.startIndex + offset + 20..<body.startIndex + offset + 20 + size]))
            #expect(raw.count == 128)
            #expect(raw.prefix(116).allSatisfy { $0 == 0xAB })
            #expect(raw.suffix(12).allSatisfy { $0 == 0 })
            offset += 20 + size
        }
    }
}

@Suite("Bitmap pixel mode")
struct PixelModeTests {
    @Test("Images are written with alpha (1), app icons as opaque (3)")
    func pixelMode() {
        let pixels = [UInt8](repeating: 0, count: 4 * 4 * 4)
        let image = MLECBody.encode(width: 4, height: 4, pixelsBGRA: pixels, pixelMode: .alpha)
        let icon = MLECBody.encode(width: 4, height: 4, pixelsBGRA: pixels, pixelMode: .opaque)
        #expect(Array(image[image.startIndex + 4..<image.startIndex + 12]) == [1, 0, 0, 0, 4, 0, 0, 0])
        #expect(Array(icon[icon.startIndex + 4..<icon.startIndex + 12]) == [3, 0, 0, 0, 4, 0, 0, 0])
    }
}
