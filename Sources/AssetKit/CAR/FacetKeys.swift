import Foundation

/// FACETKEYS maps human-readable asset names to a list of attribute pairs that
/// CoreUI uses to seed a rendition lookup.
///
/// Value layout (verified against actool output, Xcode 26 / CoreUI 970):
/// - `cursorHotSpotX u16`, `cursorHotSpotY u16`
/// - `numberOfAttributes u16`
/// - array of `(attributeName u16, attributeValue u16)`
enum FacetKeys {
    static func value(for name: String, kind: Kind, options: OutputOptions = .legacy) -> Data {
        var w = ByteWriter()
        w.writeLE(UInt16(0))            // cursorHotSpotX
        w.writeLE(UInt16(0))            // cursorHotSpotY
        let identifier = identifier(for: name, options: options)
        let pairs = kind.pairs(identifier: identifier)
        w.writeLE(UInt16(pairs.count))
        for (attrName, attrValue) in pairs {
            w.writeLE(attrName)
            w.writeLE(attrValue)
        }
        return w.data
    }

    enum Kind {
        case appIcon
        case image
        case color

        func pairs(identifier: UInt16) -> [(UInt16, UInt16)] {
            switch self {
            case .appIcon:
                return [
                    (UInt16(AttributeID.element.rawValue), RenditionKey.Element.bitmap.rawValue),
                    (UInt16(AttributeID.part.rawValue), RenditionKey.Part.appIcon.rawValue),
                    (UInt16(AttributeID.identifier.rawValue), identifier),
                ]
            case .image:
                return [
                    (UInt16(AttributeID.element.rawValue), RenditionKey.Element.bitmap.rawValue),
                    (UInt16(AttributeID.part.rawValue), RenditionKey.Part.image.rawValue),
                    (UInt16(AttributeID.identifier.rawValue), identifier),
                ]
            case .color:
                return [
                    (UInt16(AttributeID.identifier.rawValue), identifier),
                ]
            }
        }
    }

    /// The 16-bit NameIdentifier used in FACETKEYS and rendition keys.
    ///
    /// actool's hash is unknown; CRC32 truncated to 16 bits only has to be
    /// consistent between the two trees. The one value observed in an actool
    /// catalog (`AppIcon` -> 6849) is reproduced when asked for.
    static func identifier(for name: String, options: OutputOptions) -> UInt16 {
        if options.contains(.actoolIdentifiers), let known = actoolIdentifiers[name] {
            return known
        }
        return UInt16(nameHash(name) & 0xFFFF)
    }

    private static let actoolIdentifiers: [String: UInt16] = ["AppIcon": 6849]

    /// CRC32 (IEEE) of the asset name, truncated to 16 bits for the identifier slot.
    static func nameHash(_ name: String) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in name.utf8 {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xEDB88320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}
