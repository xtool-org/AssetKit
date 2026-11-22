import Foundation

/// BITMAPKEYS tree: per-asset bitmap descriptors that CoreUI consults during
/// UIImage(named:) resolution for `.imageset` (and analogous) assets.
///
/// Structure (verified against actool's reference Assets.car, Xcode 26 /
/// CoreUI 970):
/// - The tree is `isPathInternal = true` and uses a `blockSize` of 1024.
/// - Each leaf entry's "key" slot is an INLINE u32 NameIdentifier (not a
///   block pointer like other trees).
/// - Each value is a descriptor `(1, 0, byteCount, attributeCount)` followed
///   by one u32 per KEYFORMAT attribute. Appearance, identifier, element and
///   part are 0xFFFFFFFF, and every other attribute is a mask with bit
///   `1 << value` set for each value the asset's renditions use.
///
/// Without this tree present, `UIImage(named:)` returns nil on device even
/// though `assetutil --info` parses the file cleanly and FACETKEYS/RENDITIONS
/// resolve correctly. SpringBoard's appicon-render path does NOT depend on
/// BITMAPKEYS (the home icon still renders via the loose-PNG fallback).
enum BitmapKeys {
    static func descriptor(keys: [RenditionKey], attributes: [AttributeID] = v1KeyFormat) -> Data {
        var w = ByteWriter()
        w.writeLE(UInt32(1))
        w.writeLE(UInt32(0))
        w.writeLE(UInt32(4 * (attributes.count + 1)))
        w.writeLE(UInt32(attributes.count))
        for attribute in attributes {
            switch attribute {
            case .appearance, .identifier, .element, .part:
                w.writeLE(UInt32.max)
            default:
                w.writeLE(keys.reduce(UInt32(0)) { $0 | 1 << UInt32($1.value(for: attribute)) })
            }
        }
        return w.data
    }

    /// Per-asset BITMAPKEYS entry: `(NameIdentifier, descriptor bytes)`.
    static func entries(for assets: [(name: String, descriptor: Data)]) -> [BOMTree.InlineKeyEntry] {
        return assets.map { asset in
            BOMTree.InlineKeyEntry(
                key: FacetKeys.nameHash(asset.name) & 0xFFFF,
                value: asset.descriptor
            )
        }
    }

    /// Derive the BITMAPKEYS descriptor for one asset from its rendition list.
    /// Returns `nil` for color-only assets, which produce no BITMAPKEYS row.
    ///
    /// `renditions` is the per-asset slice -- only the renditions whose
    /// `name` equals this asset's name. Caller is responsible for the
    /// grouping; this function does not re-filter.
    static func descriptor(forAsset name: String, renditions: [Rendition]) -> Data? {
        let hasBitmapOrPreservedSource = renditions.contains { rendition in
            switch rendition.body {
            case .bitmap, .preservedSource: return true
            case .color: return false
            }
        }
        guard hasBitmapOrPreservedSource else { return nil }
        return descriptor(keys: renditions.map(RenditionKey.init(rendition:)))
    }
}
