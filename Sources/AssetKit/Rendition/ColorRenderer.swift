import Foundation

enum ColorRenderer {
    static func renditions(for set: LoadedColorSet) throws -> [Rendition] {
        var out: [Rendition] = []
        for entry in set.contents.colors {
            let body = ColorBody(components: try entry.color.values(), colorSpaceID: try entry.color.colorSpaceID())
            let appearance = Appearance.keyValue(entry.appearances)
            out.append(Rendition(
                name: set.name,
                idiom: entry.idiom,
                scale: nil,
                appearance: appearance,
                gamut: entry.displayGamut,
                body: .color(body)
            ))
        }
        return out
    }
}
