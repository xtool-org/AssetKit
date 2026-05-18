import Foundation
import CLZFSE

/// CSI ("CTSI") rendition header is 184 bytes little-endian, followed by an
/// optional TVL section (currently unused, tvlLength=0) and then the body.
/// Layout verified against the reference Assets.car produced by actool
/// (Xcode 26 / CoreUI 970): on disk the tag reads "ISTC" (CTSI as an LE
/// multi-char constant), layout=12 for bitmap icons, scaleFactor=scale*100.
enum CSIWriter {
    /// 'CTSI' as an LE multi-char constant. Produces file bytes I,S,T,C.
    static let tag: UInt32 = 0x43545349

    /// `pixelFormat` = 'ARGB' as an LE multi-char constant. Produces file
    /// bytes B,G,R,A. The pixel encoding is in BGRA byte order in memory.
    static let pixelFormatARGB: UInt32 = 0x41524742

    /// `pixelFormat` = 'JPEG' as an LE multi-char constant. Produces file
    /// bytes G,E,P,J. Reused for preserved-source JPG renditions; CoreUI
    /// dispatches on this constant to invoke its JPEG decoder on the
    /// DWAR-wrapped body.
    static let pixelFormatJPEG: UInt32 = 0x4A504547

    /// `pixelFormat` = 'SVG ' (trailing space) as an LE multi-char constant.
    /// Produces file bytes space,G,V,S. Used for preserved-source SVG
    /// renditions; CoreUI dispatches on this constant to invoke its SVG
    /// renderer on the DWAR-wrapped body.
    static let pixelFormatSVG: UInt32 = 0x53564720

    /// Layout types observed in the reference. The names are derived from
    /// CoreUI symbol names where known.
    enum Layout: UInt16 {
        /// Per the reference: every raw bitmap icon emitted by actool uses 12.
        /// Preserved-source JPG renditions reuse this same layout value (the
        /// pixelFormat selects the decoder, not the layout).
        case bitmapIcon = 12
        case namedColor = 1009
        /// Used by preserved-source SVG renditions in CoreUI 970. JPG keeps
        /// `bitmapIcon` because JPEG sits inside CoreUI's bitmap-asset
        /// category; SVG promotes to its own layout because vector
        /// renditions surface a different AssetType to `assetutil`.
        case vector = 9
    }

    static func bitmap(name: String, body: BitmapBody, scaleFactor: UInt32) -> Data {
        let tvl = bitmapTVL(width: body.width, height: body.height)
        let payload = bitmapBody(width: body.width, height: body.height, pixels: body.pixelsBGRA)
        // actool sets bit 4 of renditionFlags for `.image` (generic) bitmaps
        // and leaves it cleared for `.appIcon`. We mirror this; the bit is
        // structural and on-device UIImage(named:) resolution does work
        // through the LZFSE+KCBC path verified end-to-end.
        let renditionFlags: UInt32 = (body.kind == .image) ? 0x10 : 0x00
        var w = ByteWriter()
        writeHeader(
            into: &w,
            renditionFlags: renditionFlags,
            width: body.width,
            height: body.height,
            scaleFactor: scaleFactor,
            pixelFormat: pixelFormatARGB,
            colorSpace: UInt32(body.colorSpaceID),
            layout: .bitmapIcon,
            name: body.renditionName,
            tvlLength: UInt32(tvl.count),
            bitmapCount: 1,
            renditionLength: UInt32(payload.count)
        )
        w.write(tvl)
        w.write(payload)
        return w.data
    }

    /// Preserved-source rendition for `.svg` and `.jpg`. The CSI header is
    /// the same shape as for bitmaps (184 bytes) but several fields encode
    /// "not a decoded bitmap": dimensions, scaleFactor (for SVG), and
    /// colorSpace are all zero. The body is a DWAR envelope wrapping the
    /// original source bytes, with LZFSE compression for SVG and raw
    /// passthrough for JPG. Layout, pixelFormat, renditionFlags, and TVL
    /// shape all differ by source format.
    static func preservedSource(body: PreservedSourceBody, scaleFactor: UInt32) -> Data {
        let layout: Layout
        let pixelFormat: UInt32
        let renditionFlags: UInt32
        let tvl: Data
        let dwarFlags: UInt32
        let dwarPayload: [UInt8]
        switch body.format {
        case .svg:
            layout = .vector
            pixelFormat = pixelFormatSVG
            // Bit 2 set; this distinguishes the vector category from the
            // generic-image bitmap category (bit 4) in the reference output.
            renditionFlags = 0x04
            tvl = vectorTVL()
            dwarFlags = 1
            dwarPayload = lzfseEncode([UInt8](body.sourceData))
        case .jpeg(let width, let height):
            layout = .bitmapIcon
            pixelFormat = pixelFormatJPEG
            // Same bit as generic-image bitmap; JPEG lives in the bitmap
            // category from CoreUI's classification standpoint.
            renditionFlags = 0x10
            tvl = jpegTVL(width: width, height: height)
            dwarFlags = 0
            dwarPayload = [UInt8](body.sourceData)
        }
        let envelope = dwarEnvelope(flags: dwarFlags, payload: dwarPayload)
        var w = ByteWriter()
        writeHeader(
            into: &w,
            renditionFlags: renditionFlags,
            // Width / height live in TVL 1001 for JPG; the CSI header carries
            // zeros for both preserved-source variants in the reference.
            width: 0,
            height: 0,
            scaleFactor: scaleFactor,
            pixelFormat: pixelFormat,
            colorSpace: 0,
            layout: layout,
            name: body.renditionName,
            tvlLength: UInt32(tvl.count),
            bitmapCount: 1,
            renditionLength: UInt32(envelope.count)
        )
        w.write(tvl)
        w.write(envelope)
        return w.data
    }

    static func color(name: String, body: ColorBody) -> Data {
        let payload = colorBody(body: body)
        var w = ByteWriter()
        writeHeader(
            into: &w,
            renditionFlags: 0,
            width: 0,
            height: 0,
            scaleFactor: 100,
            pixelFormat: 0,
            colorSpace: UInt32(body.colorSpaceID),
            layout: .namedColor,
            name: name,
            tvlLength: 0,
            bitmapCount: 0,
            renditionLength: UInt32(payload.count)
        )
        w.write(payload)
        return w.data
    }

    // swiftlint:disable:next function_parameter_count
    private static func writeHeader(
        into w: inout ByteWriter,
        renditionFlags: UInt32,
        width: UInt32,
        height: UInt32,
        scaleFactor: UInt32,
        pixelFormat: UInt32,
        colorSpace: UInt32,
        layout: Layout,
        name: String,
        tvlLength: UInt32,
        bitmapCount: UInt32,
        renditionLength: UInt32
    ) {
        let start = w.offset
        w.writeLE(tag)
        w.writeLE(UInt32(1))                    // version
        w.writeLE(renditionFlags)
        w.writeLE(width)
        w.writeLE(height)
        w.writeLE(scaleFactor)
        w.writeLE(pixelFormat)
        w.writeLE(colorSpace)
        w.writeLE(UInt32(0))                    // modtime (matches reference; was wall-clock)
        w.writeLE(layout.rawValue)
        w.writeLE(UInt16(0))                    // zero
        w.writePadded(name, length: 128)
        w.writeLE(tvlLength)
        w.writeLE(bitmapCount)
        w.writeLE(UInt32(0))                    // reserved
        w.writeLE(renditionLength)
        precondition(w.offset - start == 184, "CSI header must be 184 bytes; got \(w.offset - start)")
    }

    /// MLEC wrapper for bitmap pixels, framed in a single KCBC chunk.
    ///
    /// Layout verified against actool's reference Assets.car:
    ///
    ///   MLEC magic        4 bytes
    ///   compressionType   u32  (0 = raw, 3 = LZFSE)
    ///   bytesPerPixel     u32  (4 for BGRA8)
    ///   chunkCount        u32  (1 for our single-chunk path)
    ///   then chunkCount * KCBC chunks
    ///
    /// Each KCBC chunk:
    ///
    ///   KCBC magic        4 bytes
    ///   reserved          8 zero bytes
    ///   chunkHeight       u32  (rows covered by this chunk)
    ///   payloadSize       u32  (bytes of compressed/raw payload following)
    ///   payload[]         raw BGRA pixels (when compressionType=0)
    ///                     or LZFSE bvx2 stream (when compressionType=3)
    /// 104-byte TVL (type-length-value) metadata block emitted between the
    /// CSI header and the MLEC body for bitmap renditions.
    ///
    /// Five entries, with types and values derived from actool's reference
    /// output. Without these, CoreUI can parse the rendition's key but cannot
    /// "materialize" the bitmap -- `assetutil --info` reports AssetType
    /// "Unknown" and omits PixelWidth/PixelHeight/Encoding/Compression.
    private static func bitmapTVL(width: UInt32, height: UInt32) -> Data {
        var w = ByteWriter()

        // Type 1001 (20-byte value): bitmap descriptor.
        // Fields: (1, 0, 0, width, height). The leading 1 is presumed to be a
        // bitmap-type/flags field; the trailing dims duplicate the CSI header
        // dims and seem to be what CoreUI consults during materialisation.
        w.writeLE(UInt32(1001))
        w.writeLE(UInt32(20))
        w.writeLE(UInt32(1))
        w.writeLE(UInt32(0))
        w.writeLE(UInt32(0))
        w.writeLE(width)
        w.writeLE(height)

        // Type 1003 (28-byte value): destination rect.
        // Fields: (1, 0, 0, 0, 0, width, height) -- (flags, x, y, z, w, w, h).
        w.writeLE(UInt32(1003))
        w.writeLE(UInt32(28))
        w.writeLE(UInt32(1))
        w.writeLE(UInt32(0))
        w.writeLE(UInt32(0))
        w.writeLE(UInt32(0))
        w.writeLE(UInt32(0))
        w.writeLE(width)
        w.writeLE(height)

        // Type 1004 (8-byte value): slice/scale pair. Reference is (0, 1.0f).
        w.writeLE(UInt32(1004))
        w.writeLE(UInt32(8))
        w.writeLE(UInt32(0))
        w.writeLE(UInt32(Float(1).bitPattern))

        // Type 1006 (4-byte value): always 1 in the reference. Likely a
        // bitmap-count/has-mipmap-stages flag.
        w.writeLE(UInt32(1006))
        w.writeLE(UInt32(4))
        w.writeLE(UInt32(1))

        // Type 1007 (4-byte value): bytes per row, aligned up to 16.
        w.writeLE(UInt32(1007))
        w.writeLE(UInt32(4))
        let bytesPerRow = width * 4
        let aligned = (bytesPerRow + 15) & ~15
        w.writeLE(aligned)

        precondition(w.offset == 104, "bitmap TVL must be 104 bytes; got \(w.offset)")
        return w.data
    }

    /// 12-byte framing wrapper introduced in CoreUI 970 for preserved-source
    /// renditions. `flags = 1` declares the payload is an LZFSE-framed inner
    /// stream (`bvxn` / `bvx2`); `flags = 0` declares the payload is the raw
    /// source bytes. The same envelope serves both SVG (compressed) and JPG
    /// (raw); CoreUI uses the surrounding CSI `pixelFormat` to choose a
    /// decoder for the inner content.
    static func dwarEnvelope(flags: UInt32, payload: [UInt8]) -> Data {
        var w = ByteWriter()
        // 'DWAR' in character order on disk (D, W, A, R). Same byte
        // convention as META / MLEC / KCBC, not LE-multi-char like CTSI.
        w.writeFourCC("DWAR")
        w.writeLE(flags)
        w.writeLE(UInt32(payload.count))
        w.write(payload)
        return w.data
    }

    /// Trimmed TVL for vector (SVG) renditions: 28 bytes carrying only
    /// `1004 (slice/scale)` and `1006 (bitmap-count flag)`. The
    /// bitmap-specific entries (`1001`, `1003`, `1007`) are omitted because
    /// width, height, and bytes-per-row are not meaningful for a scale-free
    /// vector source.
    private static func vectorTVL() -> Data {
        var w = ByteWriter()
        // Type 1004 (slice/scale pair): (0, 1.0f).
        w.writeLE(UInt32(1004))
        w.writeLE(UInt32(8))
        w.writeLE(UInt32(0))
        w.writeLE(UInt32(Float(1).bitPattern))

        // Type 1006: always 1 in the reference. Likely bitmap-count flag.
        w.writeLE(UInt32(1006))
        w.writeLE(UInt32(4))
        w.writeLE(UInt32(1))

        precondition(w.offset == 28, "vector TVL must be 28 bytes; got \(w.offset)")
        return w.data
    }

    /// TVL for preserved-source JPG renditions: 92 bytes. Same shape as the
    /// bitmap TVL but with type 1007 (bytes-per-row) omitted. Bytes-per-row
    /// is a strided-bitmap concept that has no analogue in a JPEG bitstream;
    /// CoreUI consumes the JPG by decoding the SOS markers itself.
    private static func jpegTVL(width: UInt32, height: UInt32) -> Data {
        var w = ByteWriter()

        // Type 1001 (bitmap descriptor): (1, 0, 0, width, height).
        w.writeLE(UInt32(1001))
        w.writeLE(UInt32(20))
        w.writeLE(UInt32(1))
        w.writeLE(UInt32(0))
        w.writeLE(UInt32(0))
        w.writeLE(width)
        w.writeLE(height)

        // Type 1003 (destination rect): (1, 0, 0, 0, 0, width, height).
        w.writeLE(UInt32(1003))
        w.writeLE(UInt32(28))
        w.writeLE(UInt32(1))
        w.writeLE(UInt32(0))
        w.writeLE(UInt32(0))
        w.writeLE(UInt32(0))
        w.writeLE(UInt32(0))
        w.writeLE(width)
        w.writeLE(height)

        // Type 1004 (slice/scale pair): (0, 1.0f).
        w.writeLE(UInt32(1004))
        w.writeLE(UInt32(8))
        w.writeLE(UInt32(0))
        w.writeLE(UInt32(Float(1).bitPattern))

        // Type 1006: always 1 in the reference.
        w.writeLE(UInt32(1006))
        w.writeLE(UInt32(4))
        w.writeLE(UInt32(1))

        precondition(w.offset == 92, "JPEG TVL must be 92 bytes; got \(w.offset)")
        return w.data
    }

    private static func bitmapBody(width: UInt32, height: UInt32, pixels: [UInt8]) -> Data {
        // actool splits appicon bitmaps into 3 KCBC chunks of equal row
        // height (120 -> 3x40, 180 -> 3x60). We mirror that when the height
        // divides evenly by 3; otherwise we fall back to a single chunk
        // covering the whole image. The 3-chunk split is mimicry rather than
        // a correctness requirement: CoreUI accepts both layouts.
        let bytesPerRow = Int(width) * 4
        let canChunkInThree = height % 3 == 0
        let chunkCount: UInt32 = canChunkInThree ? 3 : 1
        let rowsPerChunk = height / chunkCount

        var chunks: [(rows: UInt32, payload: [UInt8])] = []
        for i in 0..<Int(chunkCount) {
            let start = i * Int(rowsPerChunk) * bytesPerRow
            let end = start + Int(rowsPerChunk) * bytesPerRow
            let slice = Array(pixels[start..<end])
            chunks.append((rows: rowsPerChunk, payload: lzfseEncode(slice)))
        }

        var w = ByteWriter()
        w.writeFourCC("MLEC")
        w.writeLE(UInt32(3))                    // compressionType = 3 (LZFSE)
        w.writeLE(UInt32(4))                    // bytesPerPixel (BGRA8 = 4)
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

    /// Produce a valid LZFSE stream from `input` via the vendored encoder.
    /// See `Sources/CLZFSE/UPSTREAM.md`.
    static func lzfseEncode(_ input: [UInt8]) -> [UInt8] {
        // Upstream `lzfse_encode_buffer` writes the worst-case-bounded output
        // (raw passthrough is the worst case) into `dst`, returning the
        // written length or 0 on failure. Scratch=nil lets the encoder malloc
        // its own scratch per call.
        //
        // Worst case is upstream's uncompressed-block fallback (`bvx-` +
        // n_raw_bytes + payload + `bvx$`, 12 bytes of envelope). The +256
        // slack is generous insurance against any constant-size framing the
        // encoder might add ahead of choosing the fallback path.
        let bound = input.count + 256
        var output = [UInt8](repeating: 0, count: bound)
        let encoded = input.withUnsafeBufferPointer { inBuf -> Int in
            output.withUnsafeMutableBufferPointer { outBuf in
                lzfse_encode_buffer(
                    outBuf.baseAddress!, bound,
                    inBuf.baseAddress!, input.count,
                    nil
                )
            }
        }
        precondition(encoded > 0, "LZFSE encoding failed for \(input.count)-byte buffer")
        return Array(output.prefix(encoded))
    }

    private static func colorBody(body: ColorBody) -> Data {
        var w = ByteWriter()
        w.writeFourCC("COLR")
        w.writeLE(UInt32(0))                    // version
        w.writeLE(UInt32(body.colorSpaceID))    // colorSpaceID with flag bits
        w.writeLE(UInt32(4))                    // numberOfComponents
        for component in [body.red, body.green, body.blue, body.alpha] {
            w.writeLE(component.bitPattern)
        }
        return w.data
    }
}
