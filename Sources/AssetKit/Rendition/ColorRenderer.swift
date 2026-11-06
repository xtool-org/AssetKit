import Foundation

/// COLR colorspace IDs, verified against actool 27.0 (Xcode 27) with one
/// colorset per color space: srgb 1, gray-gamma-22 2, display-p3 3,
/// extended-srgb 4, extended-linear-srgb 5, extended-gray 6. (System colors
/// carry 0x102 for the gray fallback instead.)
enum COLRColorSpace: UInt8 {
    case srgb = 1
    case grayGamma22 = 2
    case displayP3 = 3
    case extendedSrgb = 4
    case extendedLinearSrgb = 5
    case extendedGray = 6

    /// Maps the Contents.json `color-space` string. Unlisted spaces fall
    /// back to the declared display gamut (sRGB / display-P3), matching
    /// actool's treatment of plain sRGB entries.
    init(colorSpace: String?, gamut: Gamut) {
        switch colorSpace {
        case "srgb": self = .srgb
        case "gray-gamma-22": self = .grayGamma22
        case "display-p3": self = .displayP3
        case "extended-srgb": self = .extendedSrgb
        case "extended-linear-srgb": self = .extendedLinearSrgb
        case "extended-gray": self = .extendedGray
        default: self = gamut == .displayP3 ? .displayP3 : .srgb
        }
    }
}

enum ColorRenderer {
    static func renditions(for set: LoadedColorSet) throws -> [Rendition] {
        var out: [Rendition] = []
        for entry in set.contents.colors {
            let appearance = entry.appearances?.first { $0.darkLuminosity }
            if let systemName = entry.color.reference {
                // ponytail: gray fallback is black (light) / white (dark), which is exact for
                // labelColor; CoreUI resolves the name itself, so the fallback rarely shows.
                let white: Double = appearance == nil ? 0 : 1
                out.append(Rendition(
                    name: set.name, idiom: entry.idiom, scale: nil, appearance: appearance, gamut: .sRGB,
                    body: .color(ColorBody(components: [white, 1], colorSpaceID: COLRColorSpace.grayGamma22.rawValue,
                                           systemName: systemName))
                ))
                continue
            }
            guard let components = entry.color.components else {
                throw XCAssetCompilerError.invalidColorComponent("missing components in \(set.name)")
            }
            let gamut: Gamut = {
                if let declared = entry.displayGamut { return declared }
                switch entry.color.colorSpace {
                case "display-p3": return .displayP3
                default: return .sRGB
                }
            }()
            let colorSpaceID = COLRColorSpace(colorSpace: entry.color.colorSpace, gamut: gamut).rawValue
            let body: ColorBody
            if components.isGray {
                let (white, alpha) = try components.asGrayDoubles()
                body = ColorBody(components: [white, alpha], colorSpaceID: colorSpaceID)
            } else {
                let (r, g, b, a) = try components.asRGBDoubles()
                body = ColorBody(components: [r, g, b, a], colorSpaceID: colorSpaceID)
            }
            out.append(Rendition(
                name: set.name,
                idiom: entry.idiom,
                scale: nil,
                appearance: appearance,
                gamut: gamut,
                body: .color(body)
            ))
        }
        return out
    }
}
