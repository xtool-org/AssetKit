import Foundation
import Testing
@testable import AssetKit

@Suite("BitmapKeys")
struct BitmapKeysTests {
    @Test("Descriptor masks the values each attribute takes across the asset's renditions")
    func masks() {
        let keys = [
            RenditionKey(scale: 1, idiom: 0, identifier: 7, element: 85, part: 181),
            RenditionKey(scale: 3, idiom: 2, identifier: 7, element: 85, part: 181),
        ]
        let data = BitmapKeys.descriptor(keys: keys)
        let words = stride(from: 0, to: data.count, by: 4).map { offset in
            UInt32(littleEndian: data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        }
        let masks = Dictionary(uniqueKeysWithValues: zip(v1KeyFormat, words.dropFirst(4)))
        #expect(masks[.scale] == 0b1010)
        #expect(masks[.idiom] == 0b101)
    }
}
