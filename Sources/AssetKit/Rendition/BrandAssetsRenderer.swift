import Foundation

enum BrandAssetsRenderer {
    struct Output {
        var renditions: [Rendition]
        var appIconBundle: AppIconBundle
    }

    static func render(_ brand: LoadedBrandAssets, svgRasterizer: any SVGRasterizer) throws -> Output {
        var sourceNames: Set<String> = []
        for element in brand.elements {
            let name: String
            switch element.content {
            case .imageStack(let stack): name = stack.name
            case .imageSet(let imageSet): name = imageSet.name
            }
            guard sourceNames.insert(name).inserted else {
                throw XCAssetCompilerError.invalidBrandAsset(
                    asset: brand.name, reason: "Multiple branding assets use the name '\(name)'"
                )
            }
        }
        let icons = brand.elements.filter { $0.definition.role == .primaryAppIcon }
        guard let primary = icons.first(where: { $0.definition.size == "400x240" }) else {
            throw XCAssetCompilerError.invalidBrandAsset(
                asset: brand.name, reason: "A 400x240 primary app icon is required"
            )
        }
        guard case .imageStack(let primaryStack) = primary.content else {
            throw XCAssetCompilerError.invalidBrandAsset(asset: brand.name, reason: "The primary icon is not a stack")
        }
        let iconSizes = icons.map(\.definition.size)
        guard Set(iconSizes).count == iconSizes.count,
              iconSizes.allSatisfy({ ["400x240", "1280x768"].contains($0) }) else {
            throw XCAssetCompilerError.invalidBrandAsset(
                asset: brand.name, reason: "Primary app icons support one 400x240 stack and one 1280x768 stack"
            )
        }

        var renditions: [Rendition] = []
        var topShelf: [String: String] = [:]
        for element in brand.elements {
            let size = try dimensions(element.definition.size, asset: brand.name)
            switch element.content {
            case .imageStack(let stack):
                let marketing = element.definition.size == "1280x768"
                renditions.append(contentsOf: try renderStack(
                    stack,
                    primaryName: primaryStack.name,
                    width: size.width,
                    height: size.height,
                    marketing: marketing,
                    svgRasterizer: svgRasterizer
                ))
            case .imageSet(let imageSet):
                let key = element.definition.role == .topShelfImage
                    ? "TVTopShelfPrimaryImage" : "TVTopShelfPrimaryImageWide"
                guard topShelf[key] == nil else {
                    throw XCAssetCompilerError.invalidBrandAsset(asset: brand.name, reason: "Duplicate Top Shelf role")
                }
                let images = try renderImages(imageSet, svgRasterizer: svgRasterizer)
                try validateDimensions(images, width: size.width, height: size.height, asset: imageSet.name)
                renditions.append(contentsOf: images)
                topShelf[key] = imageSet.name
            }
        }

        var plist: [String: any Sendable] = [
            "CFBundleIcons": ["CFBundlePrimaryIcon": primaryStack.name],
        ]
        if !topShelf.isEmpty {
            plist["TVTopShelfImage"] = topShelf
        }
        return Output(
            renditions: renditions,
            appIconBundle: AppIconBundle(
                primaryIconName: primaryStack.name,
                infoPlistAdditions: plist,
                looseFiles: []
            )
        )
    }

    private static func renderStack(
        _ stack: LoadedImageStack,
        primaryName: String,
        width: UInt32,
        height: UInt32,
        marketing: Bool,
        svgRasterizer: any SVGRasterizer
    ) throws -> [Rendition] {
        guard stack.layers.count == 2, stack.contents.properties?.canvasSize == nil else {
            throw XCAssetCompilerError.invalidImageStack(
                asset: stack.name, reason: "Only two embedded PNG layers with default canvas geometry are supported"
            )
        }
        var layers: [[Rendition]] = []
        for layer in stack.layers {
            guard layer.properties?.frameSize == nil,
                  layer.properties?.frameCenter == nil,
                  case .imageSet(var imageSet) = layer.content else {
                throw XCAssetCompilerError.invalidImageStack(
                    asset: stack.name, reason: "Layer '\(layer.name)' must use embedded content and default frame geometry"
                )
            }
            imageSet.name = "\(stack.name)/\(layer.name)/\(imageSet.name)"
            var images = try renderImages(imageSet, svgRasterizer: svgRasterizer)
            try validateDimensions(images, width: width, height: height, asset: imageSet.name)
            for index in images.indices {
                if marketing && images[index].scale != .x1 {
                    throw XCAssetCompilerError.invalidImageStack(
                        asset: stack.name, reason: "Marketing icon layers support only the 1x scale"
                    )
                }
                images[index].idiom = marketing ? .marketing : .tv
            }
            layers.append(images)
        }

        let foreground = layers[0]
        let background = layers[1]
        guard Set(foreground.compactMap(\.scale)) == Set(background.compactMap(\.scale)) else {
            throw XCAssetCompilerError.invalidImageStack(asset: stack.name, reason: "The layer scales must match")
        }
        for rendition in background {
            guard case .bitmap(let body) = rendition.body,
                  stride(from: 3, to: body.pixelsBGRA.count, by: 4).allSatisfy({ body.pixelsBGRA[$0] == 255 }) else {
                throw XCAssetCompilerError.invalidImageStack(asset: stack.name, reason: "The background layer must be opaque")
            }
        }
        let foregroundName = try requireLayerName(foreground, asset: stack.name)
        let backgroundName = try requireLayerName(background, asset: stack.name)
        let descriptor = Rendition(
            name: primaryName,
            idiom: marketing ? .marketing : .universal,
            scale: .x1,
            appearance: nil,
            gamut: nil,
            body: .layerStack(LayerStackBody(
                width: width, height: height,
                backgroundName: backgroundName, foregroundName: foregroundName
            ))
        )
        var previews: [Rendition] = []
        for front in foreground {
            guard let back = background.first(where: { $0.scale == front.scale }),
                  case .bitmap(let frontPixels) = front.body,
                  case .bitmap(let backPixels) = back.body else {
                throw XCAssetCompilerError.invalidImageStack(asset: stack.name, reason: "The layer variants do not match")
            }
            var pixels = frontPixels.pixelsBGRA
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                let inverseAlpha = UInt16(255 - frontPixels.pixelsBGRA[offset + 3])
                for channel in 0..<3 {
                    let value = UInt16(frontPixels.pixelsBGRA[offset + channel]) +
                        (UInt16(backPixels.pixelsBGRA[offset + channel]) * inverseAlpha + 127) / 255
                    pixels[offset + channel] = UInt8(value)
                }
                pixels[offset + 3] = 255
            }
            let scale = front.scale ?? .x1
            previews.append(Rendition(
                name: primaryName,
                idiom: marketing ? .marketing : .tv,
                scale: scale,
                appearance: nil,
                gamut: .sRGB,
                body: .bitmap(BitmapBody(
                    width: frontPixels.width, height: frontPixels.height,
                    pixelsBGRA: pixels,
                    colorSpaceID: 1,
                    kind: .layerStackPreview,
                    renditionName: "ZZZZFlattenedImage-\(scale.factor).1.0-gamut0"
                ))
            ))
        }
        return foreground + background + [descriptor] + previews
    }

    private static func renderImages(_ set: LoadedImageSet, svgRasterizer: any SVGRasterizer) throws -> [Rendition] {
        let images = set.contents.images.filter { $0.filename != nil }
        guard !images.isEmpty,
              images.allSatisfy({ image in
                  image.idiom == .tv &&
                  image.appearances?.isEmpty != false &&
                  (image.displayGamut == nil || image.displayGamut == .sRGB) &&
                  (image.scale == .x1 || image.scale == .x2) &&
                  image.filename.map { SourceFormat.detect(filename: $0) == .png } == true
              }),
              images.contains(where: { $0.scale == .x1 }),
              Set(images.compactMap(\.scale)).count == images.count else {
            throw XCAssetCompilerError.invalidBrandAsset(
                asset: set.name, reason: "Brand images require sRGB tv PNG sources at distinct 1x or 2x scales"
            )
        }
        return try ImageRenderer.renditions(for: set, svgRasterizer: svgRasterizer)
    }

    private static func validateDimensions(
        _ images: [Rendition], width: UInt32, height: UInt32, asset: String
    ) throws {
        for rendition in images {
            let scale = UInt32(rendition.scale?.factor ?? 1)
            guard case .bitmap(let body) = rendition.body,
                  UInt64(body.width) == UInt64(width) * UInt64(scale),
                  UInt64(body.height) == UInt64(height) * UInt64(scale) else {
                throw XCAssetCompilerError.invalidBrandAsset(
                    asset: asset, reason: "The PNG dimensions do not match the declared size and scale"
                )
            }
        }
    }

    private static func requireLayerName(_ renditions: [Rendition], asset: String) throws -> String {
        guard let name = renditions.first?.name else {
            throw XCAssetCompilerError.invalidImageStack(asset: asset, reason: "The layer has no image")
        }
        return name
    }

    private static func dimensions(_ value: String, asset: String) throws -> (width: UInt32, height: UInt32) {
        let parts = value.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let width = UInt32(parts[0]), let height = UInt32(parts[1]), width > 0, height > 0 else {
            throw XCAssetCompilerError.invalidBrandAsset(asset: asset, reason: "Invalid size '\(value)'")
        }
        return (width, height)
    }
}
