import Foundation

/// Packed rendition key matching `v1KeyFormat` (CoreUI 970, 9 attributes).
///
/// Encoded as a sequence of little-endian `UInt16` tokens, one per attribute,
/// in the order declared by `KEYFORMAT`. The pair `(attributeID, attributeValue)`
/// is implicit: the position in the tuple selects which attribute the token
/// belongs to. Total size is 18 bytes (9 × u16).
struct RenditionKey: Hashable, Sendable {
    var appearance: UInt16
    var localization: UInt16
    var scale: UInt16
    var idiom: UInt16
    var subtype: UInt16
    var dimension2: UInt16
    var identifier: UInt16
    var element: UInt16
    var part: UInt16

    /// CoreUI element IDs that v1 emits. Values dumped from reference
    /// `Assets.car` produced by actool (Xcode 26 / CoreUI 970).
    enum Element: UInt16 {
        /// Element used by both `.image` (imageset) and `.appIcon` bitmap
        /// renditions. The category is differentiated by `Part` below.
        case bitmap = 85
    }

    /// CoreUI part IDs that v1 emits.
    enum Part: UInt16 {
        /// Used by SpringBoard's icon-render pipeline (`.appiconset`).
        case appIcon = 220
        /// Named colors (`.colorset`). actool keys every color rendition,
        /// system references included, at element 85 / part 217.
        case color = 217
        /// MultiSized icon container (CSI layout 1010, 'MSIS' body). actool
        /// emits one per (idiom, subtype) group of icon renditions; CoreUI
        /// resolves an icon request's point size through it.
        case multiSized = 218
        /// Used by UIImage(named:) for generic `.imageset` assets.
        case image = 181
        /// Slot for preserved-source vector renditions (SVG). Reference
        /// `actool` output places the SVG source rendition under this part
        /// rather than `image`; bitmap variants rasterised from the SVG
        /// (which `UIImage(named:)` actually returns) live under `image`.
        case vectorSource = 42
    }

    init(rendition: Rendition) {
        self.appearance = (rendition.appearance?.darkLuminosity == true) ? 1 : 0
        self.localization = 0
        self.scale = rendition.scale?.rawValueByte ?? 0
        self.idiom = rendition.idiom.rawValueByte
        self.subtype = rendition.subtype ?? 0
        self.identifier = UInt16(FacetKeys.nameHash(rendition.name) & 0xFFFF)
        switch rendition.body {
        case .bitmap(let body):
            self.element = Element.bitmap.rawValue
            switch body.kind {
            case .appIcon:
                self.part = Part.appIcon.rawValue
                // Dimension2 is the appicon "Icon Index" slot: the rank of
                // this rendition's point size among the appiconset's
                // distinct point sizes (assetutil surfaces it as
                // "Icon Index").
                self.dimension2 = rendition.iconIndex ?? 0
            case .image:
                self.part = Part.image.rawValue
                // Generic image assets don't use Dimension2 at all.
                self.dimension2 = 0
            }
        case .multiSized:
            self.element = Element.bitmap.rawValue
            self.part = Part.multiSized.rawValue
            self.dimension2 = 0
        case .color:
            self.element = Element.bitmap.rawValue
            self.part = Part.color.rawValue
            self.dimension2 = 0
            // actool keys named colors at scale 1 (assetutil: "Scale": 1).
            self.scale = 1
        case .preservedSource(let body):
            self.element = Element.bitmap.rawValue
            self.dimension2 = 0
            switch body.format {
            case .svg:
                // SVG source renditions occupy the dedicated vector-source
                // part; bitmap variants rasterised from the SVG (when the
                // compiler emits them) would use Part.image instead.
                self.part = Part.vectorSource.rawValue
            case .jpeg:
                // JPEG sits in the generic-image lookup category — CoreUI
                // decodes the JPG body itself at runtime and returns the
                // resulting bitmap from UIImage(named:).
                self.part = Part.image.rawValue
            }
        }
    }

    init(
        appearance: UInt16 = 0,
        localization: UInt16 = 0,
        scale: UInt16 = 0,
        idiom: UInt16 = 0,
        subtype: UInt16 = 0,
        dimension2: UInt16 = 0,
        identifier: UInt16 = 0,
        element: UInt16 = 0,
        part: UInt16 = 0
    ) {
        self.appearance = appearance
        self.localization = localization
        self.scale = scale
        self.idiom = idiom
        self.subtype = subtype
        self.dimension2 = dimension2
        self.identifier = identifier
        self.element = element
        self.part = part
    }

    /// Packs the key as little-endian UInt16 tokens, one per attribute in
    /// `format` (the catalog's KEYFORMAT). Token count = format count: a
    /// color-only catalog's 8-attribute format yields 16-byte keys, an
    /// icon catalog's 9-attribute format yields 18-byte keys, matching
    /// actool 27.0.
    func encode(format: [AttributeID]) -> Data {
        var w = ByteWriter()
        for attribute in format {
            switch attribute {
            case .appearance: w.writeLE(appearance)
            case .localization: w.writeLE(localization)
            case .scale: w.writeLE(scale)
            case .idiom: w.writeLE(idiom)
            case .subtype: w.writeLE(subtype)
            case .dimension2: w.writeLE(dimension2)
            case .identifier: w.writeLE(identifier)
            case .element: w.writeLE(element)
            case .part: w.writeLE(part)
            }
        }
        return w.data
    }

    /// Decodes a key packed in `v1KeyFormat` order. Returns nil for other
    /// formats (token count and positions differ).
    static func decode(_ data: Data) -> RenditionKey? {
        guard data.count == 18 else { return nil }
        func u16(_ offset: Int) -> UInt16 {
            let lo = UInt16(data[data.index(data.startIndex, offsetBy: offset)])
            let hi = UInt16(data[data.index(data.startIndex, offsetBy: offset + 1)])
            return lo | (hi << 8)
        }
        return RenditionKey(
            appearance: u16(0),
            localization: u16(2),
            scale: u16(4),
            idiom: u16(6),
            subtype: u16(8),
            dimension2: u16(10),
            identifier: u16(12),
            element: u16(14),
            part: u16(16)
        )
    }
}
