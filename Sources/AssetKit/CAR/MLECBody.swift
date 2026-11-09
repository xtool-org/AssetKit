import Foundation

/// MLEC wrapper for bitmap pixels, framed in one or three KCBC chunks.
///
/// Layout verified against actool's reference Assets.car:
///
///   MLEC magic        4 bytes
///   pixelMode         u32  (1 = with alpha, 3 = opaque, see PixelMode)
///   compression       u32  (4 = LZFSE)
///   chunkCount        u32  (1 or 3)
///   then chunkCount * KCBC chunks
///
/// Each KCBC chunk:
///
///   KCBC magic        4 bytes
///   reserved          8 zero bytes
///   chunkHeight       u32  (rows covered by this chunk)
///   payloadSize       u32  (bytes of compressed payload following)
///   payload[]         LZFSE bvx2 stream
///
/// Chunking policy mirrors actool: when height divides evenly by 3, emit 3
/// chunks of equal row height (120 -> 3x40, 180 -> 3x60); otherwise emit a
/// single chunk covering the whole image. The 3-chunk split is mimicry
/// rather than a correctness requirement: CoreUI accepts both layouts.
enum MLECBody {
    /// Rows are padded to a multiple of 32 bytes, like actool, and the
    /// `bytesPerRow` TLV says so. App Store Connect never finishes processing
    /// a build whose catalog stores tightly packed rows that are not already
    /// a multiple of 32 bytes (a 180 px icon: 720 bytes instead of 736).
    static func bytesPerRow(width: UInt32) -> Int {
        (Int(width) * 4 + 31) & ~31
    }

    /// The u32 after the MLEC magic. actool writes 1 for every image with
    /// transparency (534 of 534 renditions in Xcode's own catalogs) and 3 only
    /// in app icon catalogs (the store icon, icon atlases). iOS treats a 3
    /// bitmap as opaque: its transparent pixels come out black.
    enum PixelMode: UInt32 {
        case alpha = 1
        case opaque = 3
    }

    static func encode(width: UInt32, height: UInt32, pixelsBGRA: [UInt8], pixelMode: PixelMode = .alpha) -> Data {
        let packedRow = Int(width) * 4
        let bytesPerRow = Self.bytesPerRow(width: width)
        var padded = pixelsBGRA
        if bytesPerRow != packedRow {
            padded = [UInt8](repeating: 0, count: bytesPerRow * Int(height))
            for row in 0..<Int(height) {
                padded.replaceSubrange(
                    row * bytesPerRow..<row * bytesPerRow + packedRow,
                    with: pixelsBGRA[row * packedRow..<(row + 1) * packedRow]
                )
            }
        }
        let canChunkInThree = height % 3 == 0
        let chunkCount: UInt32 = canChunkInThree ? 3 : 1
        let rowsPerChunk = height / chunkCount

        var chunks: [(rows: UInt32, payload: [UInt8])] = []
        for i in 0..<Int(chunkCount) {
            let start = i * Int(rowsPerChunk) * bytesPerRow
            let end = start + Int(rowsPerChunk) * bytesPerRow
            let slice = Array(padded[start..<end])
            chunks.append((rows: rowsPerChunk, payload: LZFSE.encode(slice)))
        }

        var w = ByteWriter()
        w.writeFourCC("MLEC")
        w.writeLE(pixelMode.rawValue)           // 1 = with alpha, 3 = opaque (app icons)
        w.writeLE(UInt32(4))                    // compression: 4 = LZFSE
        w.writeLE(chunkCount)

        for chunk in chunks {
            w.writeFourCC("KCBC")
            w.writeZeros(8)                     // reserved
            w.writeLE(chunk.rows)               // chunkHeight (rows)
            w.writeLE(UInt32(chunk.payload.count))
            w.write(chunk.payload)
        }
        return w.data
    }
}
