import Foundation

/// Builds the per-rendition CSI ("CTSI") record CoreUI binary-searches at
/// runtime: 184-byte header + TVL metadata block + body bytes.
///
/// Three orchestrators, one per rendition body kind. Each composes a header
/// (`CSIHeader`), a list of TVL entries (`TVLEntry` + `CSITVL`), and a body
/// (`MLECBody` for bitmaps, `DWAREnvelope` for preserved-source, an inline
/// COLR block for color).
enum CSIWriter {
    static func bitmap(name: String, body: BitmapBody, scaleFactor: UInt32) -> Data {
        let tvl = CSITVL.encode([
            .bitmapDescriptor(width: body.width, height: body.height),
            .destRect(width: body.width, height: body.height),
            .sliceScale,
            .bitmapFlag,
            .bytesPerRow(width: body.width),
        ])
        let payload = MLECBody.encode(width: body.width, height: body.height, pixelsBGRA: body.pixelsBGRA)

        // Bit 4 (0x10): generic-image category; set for `.image`, cleared
        // for `.appIcon`. Matches what UIImage(named:) walks for imageset
        // resolution.
        //
        // Bits 2 and 8 (0x104): set when this bitmap was rasterised from a
        // vector source (SVG / PDF). Matches actool's reference output for
        // SVG-rasterised bitmaps (flags=0x114 vs flags=0x10 for native PNG).
        // Bit 2 (0x04) is also set on the standalone vector source rendition
        // emitted from `preservedSource(.svg)`; the pair (0x04, 0x100)
        // together appears to mark "rendition is a raster derived from a
        // vector source", letting CoreUI's runtime branch into the
        // re-rasterise-from-vector path at non-intrinsic sizes.
        var renditionFlags: UInt32 = (body.kind == .image) ? 0x10 : 0x00
        if body.derivedFromVector {
            renditionFlags |= 0x104
        }

        let header = CSIHeader.encode(
            renditionFlags: renditionFlags,
            width: body.width,
            height: body.height,
            scaleFactor: scaleFactor,
            pixelFormat: CSIHeader.pixelFormatARGB,
            colorSpace: UInt32(body.colorSpaceID),
            layout: .bitmapIcon,
            name: body.renditionName,
            tvlLength: UInt32(tvl.count),
            bitmapCount: 1,
            renditionLength: UInt32(payload.count)
        )
        return header + tvl + payload
    }

    /// Preserved-source rendition for `.svg` and `.jpg`. The CSI header is
    /// the same shape as for bitmaps (184 bytes) but several fields encode
    /// "not a decoded bitmap": dimensions, scaleFactor (for SVG), and
    /// colorSpace are all zero. The body is a DWAR envelope wrapping the
    /// original source bytes, with LZFSE compression for SVG and raw
    /// passthrough for JPG. Layout, pixelFormat, renditionFlags, and TVL
    /// shape all differ by source format.
    static func preservedSource(body: PreservedSourceBody, scaleFactor: UInt32) -> Data {
        let layout: CSIHeader.Layout
        let pixelFormat: UInt32
        let renditionFlags: UInt32
        let tvl: Data
        let envelope: Data
        switch body.format {
        case .svg:
            layout = .vector
            pixelFormat = CSIHeader.pixelFormatSVG
            // Bit 2 set; this distinguishes the vector category from the
            // generic-image bitmap category (bit 4) in the reference output.
            renditionFlags = 0x04
            // Trimmed TVL for vector renditions: only slice/scale and the
            // bitmap-count flag. Width, height, and bytes-per-row are not
            // meaningful for a scale-free vector source.
            tvl = CSITVL.encode([.sliceScale, .bitmapFlag])
            envelope = DWAREnvelope.encode(flags: 1, payload: LZFSE.encode([UInt8](body.sourceData)))
        case .jpeg(let width, let height):
            layout = .bitmapIcon
            pixelFormat = CSIHeader.pixelFormatJPEG
            // Same bit as generic-image bitmap; JPEG lives in the bitmap
            // category from CoreUI's classification standpoint.
            renditionFlags = 0x10
            // JPG TVL is the bitmap shape with bytes-per-row omitted: stride
            // is a strided-bitmap concept that has no analogue in a JPEG
            // bitstream (CoreUI consumes the JPG by decoding the SOS markers
            // itself).
            tvl = CSITVL.encode([
                .bitmapDescriptor(width: width, height: height),
                .destRect(width: width, height: height),
                .sliceScale,
                .bitmapFlag,
            ])
            envelope = DWAREnvelope.encode(flags: 0, payload: [UInt8](body.sourceData))
        }
        let header = CSIHeader.encode(
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
        return header + tvl + envelope
    }

    /// MultiSized icon container (layout 1010). Header dimensions, scale,
    /// pixelFormat and colorSpace are all zero like named colors; TVL is the
    /// same all-zero 1004 + 1006:1 pair. The name is the ASSET name (not a
    /// source filename), and the body lists point sizes; 83.5 pt truncates
    /// to 83, as in the reference output.
    static func multiSized(name: String, body: MultiSizedBody) -> Data {
        let tvl = CSITVL.encode([.colorSlice, .bitmapFlag])
        var w = ByteWriter()
        w.writeLE(UInt32(0x4D53_4953))          // 'MSIS' (file bytes SISM)
        w.writeLE(UInt32(1))                    // version
        w.writeLE(UInt32(body.sizes.count))
        for size in body.sizes {
            w.writeLE(size.pointWidth)
            w.writeLE(size.pointHeight)
            w.writeLE(size.iconIndex)
        }
        let payload = w.data
        let header = CSIHeader.encode(
            renditionFlags: 0,
            width: 0,
            height: 0,
            scaleFactor: 0,
            pixelFormat: 0,
            colorSpace: 0,
            layout: .multiSized,
            name: name,
            tvlLength: UInt32(tvl.count),
            bitmapCount: 1,
            renditionLength: UInt32(payload.count)
        )
        return header + tvl + payload
    }

    /// Named color, in the layout actool 27.0 writes: header scale, colorSpace
    /// and pixelFormat all zero; TVL (1004: zeros, 1006: 1); one body.
    static func color(name: String, body: ColorBody) -> Data {
        let tvl = CSITVL.encode([.colorSlice, .bitmapFlag])
        let payload = colorBody(body: body)
        let header = CSIHeader.encode(
            renditionFlags: 0,
            width: 0,
            height: 0,
            scaleFactor: 0,
            pixelFormat: 0,
            colorSpace: 0,
            layout: .namedColor,
            name: name,
            tvlLength: UInt32(tvl.count),
            bitmapCount: 1,
            renditionLength: UInt32(payload.count)
        )
        return header + tvl + payload
    }

    /// 'COLR' as an LE multi-char constant (file bytes R,L,O,C), version 1,
    /// colorSpaceID with flag bits, component count, then Float64 components.
    /// A system color is a gray fallback (colorspace 0x102, [white, alpha])
    /// followed by a second COLR record holding the name (length + UTF-8).
    private static func colorBody(body: ColorBody) -> Data {
        var w = ByteWriter()
        w.writeLE(UInt32(0x434F_4C52))
        w.writeLE(UInt32(1))                    // version
        if let name = body.systemName {
            w.writeLE(UInt32(0x102))            // gray gamma 2.2, as actool writes it
            w.writeLE(UInt32(2))
            for component in body.components {
                w.writeLE(component.bitPattern)
            }
            w.writeLE(UInt32(0x434F_4C52))
            w.writeLE(UInt32(1))
            w.writeLE(UInt32(name.utf8.count))
            w.write(Array(name.utf8))
            return w.data
        }
        w.writeLE(UInt32(body.colorSpaceID))    // colorSpaceID with flag bits
        w.writeLE(UInt32(body.components.count))
        for component in body.components {
            // actool quantizes each component to Float32 before storing it
            // in the Float64 slot (Xcode 27.0 writes 1.1 as 0x3FF19999A0000000).
            w.writeLE(Double(Float(component)).bitPattern)
        }
        return w.data
    }
}
