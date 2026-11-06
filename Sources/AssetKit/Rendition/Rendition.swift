import Foundation

struct Rendition: Sendable {
    enum Body: Sendable {
        case bitmap(BitmapBody)
        case color(ColorBody)
        case preservedSource(PreservedSourceBody)
        case multiSized(MultiSizedBody)
    }

    var name: String
    var idiom: Idiom
    var scale: Scale?
    var appearance: Appearance?
    var gamut: Gamut?
    /// Raw rendition-key subtype token. Non-zero only for icon variants
    /// keyed on a device trait; actool keys the 90 pt large-phone home icon
    /// (derived from the 60 pt @3x slot) at subtype 1792.
    var subtype: UInt16? = nil
    /// App-icon "Icon Index": the rank of this rendition's point size among
    /// the appiconset's distinct point sizes, ascending. Only icon renditions
    /// carry it; assetutil surfaces it as "Icon Index".
    var iconIndex: UInt16? = nil
    var body: Body
}

/// Body of a MultiSized icon rendition (CSI layout 1010, 'MSIS' payload).
/// actool emits one per (idiom, subtype) group of icon renditions; each
/// entry maps a point size to the Icon Index of the bitmap rendition that
/// satisfies it. Widths/heights are point sizes (83.5 pt truncates to 83,
/// as in the reference output).
struct MultiSizedBody: Sendable {
    struct Size: Sendable {
        var pointWidth: UInt32
        var pointHeight: UInt32
        var iconIndex: UInt32
    }

    /// One entry per distinct point size, ascending.
    var sizes: [Size]
}

struct BitmapBody: Sendable {
    /// Which CoreUI rendition category this bitmap belongs to. Determines the
    /// `(element, part)` pair we encode in the rendition key and FACETKEYS
    /// value -- actool picks different codes for appicons vs. generic images,
    /// and UIImage(named:) only finds renditions whose part matches the
    /// expected category for the lookup path.
    enum Kind: Sendable {
        /// `element=85, part=220`. Used by SpringBoard's icon-render pipeline.
        case appIcon
        /// `element=85, part=181`. Used by UIImage(named:) for generic image
        /// assets from an `.imageset`.
        case image
    }

    var width: UInt32
    var height: UInt32
    var pixelsBGRA: [UInt8]
    var colorSpaceID: UInt8
    var kind: Kind
    /// True iff this bitmap was rasterised from a vector source (SVG, PDF)
    /// rather than supplied directly as bitmap pixels. The reference actool
    /// output tags vector-rasterised bitmaps with extra bits in the CSI
    /// header's `renditionFlags`; some CoreUI runtime paths branch on this
    /// classification (e.g. when re-rasterising via the preserved vector
    /// source at a non-intrinsic size). PNG / appicon bitmaps leave it false.
    var derivedFromVector: Bool = false
    /// The source filename (e.g. "icon@2x.png"). Stored in the CSI header's
    /// 128-char name field; actool uses the filename here, not the asset name.
    var renditionName: String
}

struct ColorBody: Sendable {
    /// Components in the color space's own order; RGB spaces carry 4
    /// (r, g, b, a), gray spaces carry 2 (white, alpha). actool quantizes
    /// each to Float32 before storing it in the COLR body's Float64 slots
    /// (verified: Xcode 27.0 writes 1.1 as 0x3FF19999A0000000).
    var components: [Double]
    /// COLR colorspace ID. actool 27.0 maps: srgb 1, gray-gamma-22 2,
    /// display-p3 3, extended-srgb 4, extended-linear-srgb 5, extended-gray 6;
    /// the gray fallback for system colors carries 0x102.
    var colorSpaceID: UInt8
    /// System color name ("labelColor"). The components then hold a gray
    /// fallback for runtimes that cannot resolve it.
    var systemName: String? = nil
}

/// Source file kept verbatim inside a DWAR envelope rather than rasterised
/// or re-encoded. Used for `.svg` (LZFSE-compressed XML inner payload) and
/// `.jpg` (raw JPEG inner payload). The source-format distinction is carried
/// in the surrounding CSI header's `pixelFormat` and in `Format` below.
struct PreservedSourceBody: Sendable {
    /// Source format plus the per-format data CoreUI needs alongside the
    /// raw bytes. JPEG carries decoded pixel dimensions (populated by
    /// `JPEGDimensions` and emitted into TVL types 1001 / 1003); SVG carries
    /// nothing extra (vector is scale-free and the reference Assets.car
    /// leaves the dimension TVL entries out for SVG renditions). Keeping
    /// these in the enum makes it unrepresentable to construct a JPEG body
    /// without dimensions.
    enum Format: Sendable {
        case svg
        case jpeg(width: UInt32, height: UInt32)
    }

    var format: Format
    /// The user-provided source bytes, unmodified. For SVG this is the raw
    /// XML; for JPG this is the entire JPEG file including JFIF / EXIF
    /// segments.
    var sourceData: Data
    /// The source filename (e.g. "Svg.svg", "Jpg@2x.jpg"). Stored in the
    /// CSI header's 128-char name field; actool uses the filename here, not
    /// the asset name.
    var renditionName: String
}
