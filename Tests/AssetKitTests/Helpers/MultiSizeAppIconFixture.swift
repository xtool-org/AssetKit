import Foundation
@testable import AssetKit

enum MultiSizeAppIconFixture {
    // actool orders logical sizes independently of source order, scale and idiom.
    static let indices: [Double: UInt16] = [20: 1, 29: 2, 40: 3, 60: 4, 76: 5, 83.5: 6]
    static let entries: [(Idiom, Double, Scale)] = [
        (.iphone, 60, .x2), (.ipad, 20, .x1), (.iphone, 29, .x2),
        (.iphone, 40, .x3), (.iphone, 20, .x2), (.iphone, 60, .x3),
        (.iphone, 40, .x2), (.ipad, 20, .x2), (.ipad, 29, .x2),
        (.ipad, 76, .x2), (.ipad, 83.5, .x2),
    ]

    static func write(to catalog: URL) throws {
        let directory = catalog.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let info = CatalogContents.Info(version: 1, author: "xcode")
        try JSONEncoder().encode(CatalogContents(info: info))
            .write(to: catalog.appendingPathComponent("Contents.json"))

        let rasterizer = StubSVGRasterizer()
        var images: [AppIconContents.Image] = []
        for (idiom, points, scale) in entries {
            let filename = "\(idiom.rawValue)-\(points)@\(scale.rawValue).png"
            let pixels = UInt32(points * Double(scale.factor))
            try rasterizer.rasterize(svgData: Data(), pixelWidth: pixels, pixelHeight: pixels)
                .write(to: directory.appendingPathComponent(filename))
            images.append(AppIconContents.Image(
                idiom: idiom,
                size: "\(points)x\(points)",
                scale: scale,
                filename: filename
            ))
        }
        try JSONEncoder().encode(AppIconContents(images: images, info: info))
            .write(to: directory.appendingPathComponent("Contents.json"))
    }
}
