import Foundation
@testable import AssetKit

/// Minimal read-only view of a compiled `Assets.car`: enough to check the
/// shape of what the writer emits (there is no `assetutil` outside macOS).
struct CARInspector {
    struct Rendition {
        var key: [UInt16]
        var csi: Data

        var layout: UInt16 { u16(csi, 36) }
        var name: String {
            let bytes = csi[csi.startIndex + 40..<csi.startIndex + 168]
            return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        var width: UInt32 { u32(csi, 12) }
        var height: UInt32 { u32(csi, 16) }
        var scaleFactor: UInt32 { u32(csi, 20) }
        /// Bytes following the TVL section.
        var body: Data {
            let tvl = Int(u32(csi, 168))
            return csi.suffix(from: csi.startIndex + 184 + tvl)
        }
    }

    var data: Data
    var blocks: [(offset: Int, length: Int)] = []
    var variables: [String: Int] = [:]
    var variableOrder: [String] = []

    init(_ data: Data) {
        self.data = data
        let indexOffset = Int(be32(data, 16))
        let count = Int(be32(data, indexOffset))
        for i in 0..<count {
            blocks.append((Int(be32(data, indexOffset + 4 + 8 * i)), Int(be32(data, indexOffset + 8 + 8 * i))))
        }
        var p = Int(be32(data, 24))
        let n = Int(be32(data, p))
        p += 4
        for _ in 0..<n {
            let block = Int(be32(data, p))
            let len = Int(data[p + 4])
            let name = String(decoding: data[p + 5..<p + 5 + len], as: UTF8.self)
            variables[name] = block
            variableOrder.append(name)
            p += 5 + len
        }
    }

    func block(_ index: Int) -> Data {
        let b = blocks[index]
        return data[b.offset..<b.offset + b.length]
    }

    func variable(_ name: String) -> Data? {
        variables[name].map(block)
    }

    /// (key block, value block) pairs of the single leaf of a tree variable.
    func treeEntries(_ name: String) -> [(key: Data, value: Data)] {
        guard let tree = variable(name) else { return [] }
        let leaf = block(Int(be32(tree, 8)))
        let count = Int(be16(leaf, 2))
        let inlineKeys = tree[tree.startIndex + 20] != 0
        return (0..<count).map { i in
            let value = Int(be32(leaf, 12 + 8 * i))
            let key = Int(be32(leaf, 16 + 8 * i))
            // `isPathInternal` trees (BITMAPKEYS) store the key itself instead of a block number
            let keyData = inlineKeys ? Data([UInt8(key & 0xff), UInt8((key >> 8) & 0xff), UInt8((key >> 16) & 0xff), UInt8(key >> 24)]) : block(key)
            return (keyData, block(value))
        }
    }

    var keyFormat: [UInt32] {
        guard let kfmt = variable("KEYFORMAT") else { return [] }
        let n = Int(u32(kfmt, 8))
        return (0..<n).map { u32(kfmt, 12 + 4 * $0) }
    }

    var renditions: [Rendition] {
        treeEntries("RENDITIONS").map { entry in
            let key = (0..<entry.key.count / 2).map { u16(entry.key, 2 * $0) }
            return Rendition(key: key, csi: entry.value)
        }
    }

    var header: (coreUI: UInt32, renditionCount: UInt32, main: String, version: String)? {
        guard let h = variable("CARHEADER") else { return nil }
        func string(_ from: Int, _ len: Int) -> String {
            String(decoding: h[h.startIndex + from..<h.startIndex + from + len].prefix { $0 != 0 }, as: UTF8.self)
        }
        return (u32(h, 4), u32(h, 16), string(20, 128), string(148, 256))
    }
}

private func be32(_ d: Data, _ o: Int) -> UInt32 {
    (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(d[d.startIndex + o + $1]) }
}
private func be16(_ d: Data, _ o: Int) -> UInt16 {
    (UInt16(d[d.startIndex + o]) << 8) | UInt16(d[d.startIndex + o + 1])
}
func u32(_ d: Data, _ o: Int) -> UInt32 {
    (0..<4).reduce(UInt32(0)) { $0 | (UInt32(d[d.startIndex + o + $1]) << (8 * UInt32($1))) }
}
func u16(_ d: Data, _ o: Int) -> UInt16 {
    UInt16(d[d.startIndex + o]) | (UInt16(d[d.startIndex + o + 1]) << 8)
}
