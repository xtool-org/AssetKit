import Foundation

struct BrandAssetsContents: Codable, Sendable {
    struct Asset: Codable, Sendable {
        enum Role: String, Codable, Sendable {
            case primaryAppIcon = "primary-app-icon"
            case topShelfImage = "top-shelf-image"
            case topShelfImageWide = "top-shelf-image-wide"
        }

        var filename: String
        var idiom: Idiom
        var role: Role
        var size: String
    }

    var assets: [Asset]
    var info: CatalogContents.Info
}

struct ImageStackContents: Codable, Sendable {
    struct Layer: Codable, Sendable {
        var filename: String
    }

    struct Properties: Codable, Sendable {
        var canvasSize: AssetSize?
    }

    var layers: [Layer]
    var info: CatalogContents.Info
    var properties: Properties?
}

struct ImageStackLayerContents: Codable, Sendable {
    struct Properties: Codable, Sendable {
        struct ContentReference: Codable, Sendable {
            var type: String
            var name: String
            var matchingStyle: String

            enum CodingKeys: String, CodingKey {
                case type, name
                case matchingStyle = "matching-style"
            }
        }

        var contentReference: ContentReference?
        var frameSize: AssetSize?
        var frameCenter: AssetPoint?

        enum CodingKeys: String, CodingKey {
            case contentReference = "content-reference"
            case frameSize = "frame-size"
            case frameCenter = "frame-center"
        }
    }

    var info: CatalogContents.Info?
    var properties: Properties?
}

struct AssetSize: Codable, Sendable, Equatable {
    var width: Double
    var height: Double
}

struct AssetPoint: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
}
