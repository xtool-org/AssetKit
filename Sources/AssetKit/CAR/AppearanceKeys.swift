import Foundation

/// APPEARANCEKEYS tree: maps appearance name strings to UInt16 IDs that match
/// the `appearance` attribute values appearing in rendition keys.
///
/// CoreUI's runtime walks this tree by exact name-string match to resolve
/// the appearance slot in a rendition key. Every numeric ID that can appear
/// in a rendition key must have a row here, or the rendition lookup
/// silently fails (UIImage(named:) returns nil with no error).
///
/// **Platform difference:** iOS uses `UIAppearanceAny` / `UIAppearanceDark`.
/// macOS uses `NSAppearanceNameAqua` / `NSAppearanceNameDarkAqua`. This
/// library targets iOS app catalogs only, so we register the UIAppearance*
/// names. The reference `actool` output only emits the rows for appearances
/// actually used in the catalog (catalogs with no dark variants omit the
/// `UIAppearanceDark` row entirely); we mirror that behaviour by passing
/// the catalog's used-appearances set to `entries(used:)`.
enum AppearanceKeys {
    static let any: UInt16 = 0

    static let names: [UInt16: String] = [
        0: "UIAppearanceAny",
        1: "UIAppearanceDark",
        2: "UIAppearanceHighContrastAny",
        3: "UIAppearanceHighContrastDark",
        4: "UIAppearanceLight",
        5: "UIAppearanceHighContrastLight",
    ]

    static func entries(used: Set<UInt16>) -> [BOMTree.Entry] {
        // `UIAppearanceAny` (id=0) is always present in the reference, even
        // when every rendition has an explicit appearance, because CoreUI
        // packs `appearance=0` as the default-variant marker in rendition
        // keys regardless of whether a dark variant exists.
        used.union([any]).sorted().compactMap { id in
            names[id].map { BOMTree.Entry(key: Data($0.utf8), value: encodeID(id)) }
        }
    }

    private static func encodeID(_ id: UInt16) -> Data {
        var w = ByteWriter()
        w.writeLE(id)
        return w.data
    }
}
