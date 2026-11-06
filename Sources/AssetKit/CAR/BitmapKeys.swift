import Foundation

/// BITMAPKEYS tree: per-asset bitmap descriptors that CoreUI consults during
/// UIImage(named:) resolution for `.imageset` (and analogous) assets.
///
/// Structure (verified against actool's reference Assets.car, Xcode 26 /
/// CoreUI 970, and a Xcode 27.0 per-colorspace oracle):
/// - The tree is `isPathInternal = true` and uses a `blockSize` of 1024.
/// - Each leaf entry's "key" slot is an INLINE u32 NameIdentifier (not a
///   block pointer like other trees).
/// - Each value is a 52-byte descriptor block (48 bytes for colorsets,
///   which carry one fewer trailing sentinel).
///
/// Without this tree present, `UIImage(named:)` returns nil on device even
/// though `assetutil --info` parses the file cleanly and FACETKEYS/RENDITIONS
/// resolve correctly. SpringBoard's appicon-render path does NOT depend on
/// BITMAPKEYS (the home icon still renders via the loose-PNG fallback).
enum BitmapKeys {
    /// The descriptor. Layout was derived by diffing actool's outputs
    /// for `.appiconset` vs `.imageset` (bitmap) vs `.imageset` (vector)
    /// renditions. The first 7 u32s are header-like; only slot 6 varies
    /// across asset kinds. The remaining 6 vary by asset kind.
    struct Descriptor {
        var kind: Kind
        /// Number of distinct (idiom, subtype) tuples this asset is keyed on.
        var idiomSubtypeCount: UInt32

        enum Kind {
            case appIcon
            /// PNG and JPEG `.imageset` assets — bitmap source.
            case image
            /// SVG `.imageset` assets — vector source.
            case vector
            /// `.colorset` assets. actool 27.0 writes one BITMAPKEYS row per
            /// colorset too (marker 0x02, variable section shaped like the
            /// image one).
            case color
        }

        /// Slot 6 of the header (the only header u32 that varies by kind).
        /// `0x04` for bitmap-source assets (PNG, JPG); `0x0e` for vector
        /// sources (SVG) and appicons; `0x02` for colors (actool 27.0
        /// per-space oracle).
        private var assetKindMarker: UInt32 {
            switch kind {
            case .image: return 0x04
            case .vector, .appIcon: return 0x0e
            case .color: return 0x02
            }
        }

        func encode() -> Data {
            var w = ByteWriter()
            w.writeLE(UInt32(1))
            w.writeLE(UInt32(0))
            // Slots 3/4 are length fields: 0x28/9 for 52-byte descriptors
            // (icon/image/vector), 0x24/8 for 48-byte color descriptors.
            w.writeLE(UInt32(kind == .color ? 0x24 : 0x28))
            w.writeLE(UInt32(kind == .color ? 8 : 9))
            w.writeLE(UInt32(0xFFFFFFFF))
            w.writeLE(UInt32(1))
            w.writeLE(assetKindMarker)
            // Variable section. Values come from the actool reference.
            //   AppIcon  : [u32=2, u16=1, u16=1, u32=7]
            //   Image    : [u32=1, u16=1, u16=0, u32=1]
            //   Vector   : [u32=1, u16=1, u16=0, u32=1]   (same shape as Image)
            //   Color    : [u32=1, u16=1, u16=0, u32=1]   (same shape as Image)
            // The exact semantics aren't fully reverse-engineered yet, so for
            // v1 we hardcode the templates per kind and pass through the
            // discovered (idiom, subtype) count. Field 7 in particular seems
            // to track that count.
            w.writeLE(idiomSubtypeCount)
            switch kind {
            case .appIcon:
                w.writeLE(UInt16(1))            // (u16, u16) tuple
                w.writeLE(UInt16(1))
                w.writeLE(UInt32(7))
            case .image, .vector:
                w.writeLE(UInt16(1))
                w.writeLE(UInt16(0))
                w.writeLE(UInt32(1))
            case .color:
                // Colorsets end the variable section after the (u16, u16)
                // pair: no trailing u32 (48-byte descriptor, actool 27.0
                // per-space oracle).
                w.writeLE(UInt16(1))
                w.writeLE(UInt16(0))
            }
            // Three trailing -1 sentinels for every kind.
            w.writeLE(UInt32(0xFFFFFFFF))
            w.writeLE(UInt32(0xFFFFFFFF))
            w.writeLE(UInt32(0xFFFFFFFF))
            precondition(
                w.offset == (kind == .color ? 48 : 52),
                "BITMAPKEYS descriptor must be \(kind == .color ? 48 : 52) bytes; got \(w.offset)")
            return w.data
        }
    }

    /// Per-asset BITMAPKEYS entry: `(NameIdentifier, descriptor bytes)`.
    static func entries(for assets: [(name: String, descriptor: Descriptor)]) -> [BOMTree.InlineKeyEntry] {
        return assets.map { asset in
            BOMTree.InlineKeyEntry(
                key: FacetKeys.nameHash(asset.name) & 0xFFFF,
                value: asset.descriptor.encode()
            )
        }
    }

    /// Derive the BITMAPKEYS descriptor for one asset from its rendition list.
    /// Returns `nil` only for assets with no bitmap, preserved-source, or
    /// color renditions (actool 27.0 writes a BITMAPKEYS row for colorsets
    /// too, marker 0x02).
    ///
    /// `renditions` is the per-asset slice -- only the renditions whose
    /// `name` equals this asset's name. Caller is responsible for the
    /// grouping; this function does not re-filter.
    static func descriptor(forAsset name: String, renditions: [Rendition]) -> Descriptor? {
        let hasDescribableRendition = renditions.contains { rendition in
            switch rendition.body {
            case .bitmap, .preservedSource, .color: return true
            // MultiSized containers only ever accompany bitmap icon
            // renditions; they alone never justify a BITMAPKEYS row.
            case .multiSized: return false
            }
        }
        guard hasDescribableRendition else { return nil }

        let kind = inferKind(from: renditions)

        // (idiom << 16) | subtype packs each tuple into a single UInt32 for Set uniqueness.
        let idiomSubtypes = Set(renditions.map { rendition -> UInt32 in
            let idiom = UInt32(rendition.idiom.rawValueByte)
            let subtype = UInt32(rendition.subtype ?? 0)
            return (idiom << 16) | subtype
        })

        return Descriptor(kind: kind, idiomSubtypeCount: UInt32(idiomSubtypes.count))
    }

    /// AppIcon takes precedence over Vector takes precedence over Image:
    /// an .appiconset is a distinct CoreUI category, and a vector source
    /// outranks plain bitmap because the rasterised PNG fallbacks coexist
    /// with the preserved SVG body. Mixed PNG/JPEG imagesets fall through
    /// to `.image`. Color-only assets (`.colorset`) classify as `.color`.
    ///
    /// The AppIcon arm relies on `ImageRenderer.appIconRenditions` only
    /// producing `.bitmap(.appIcon)` renditions (PNG-only at that entry
    /// point). If that invariant slips, an appiconset whose source was
    /// (say) preserved JPG would be misclassified as `.image` here.
    private static func inferKind(from renditions: [Rendition]) -> Descriptor.Kind {
        for rendition in renditions {
            if case .bitmap(let body) = rendition.body, body.kind == .appIcon {
                return .appIcon
            }
        }
        for rendition in renditions {
            if case .preservedSource(let body) = rendition.body, case .svg = body.format {
                return .vector
            }
        }
        for rendition in renditions {
            if case .color = rendition.body {
                return .color
            }
        }
        return .image
    }
}
