// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "AssetKit",
    products: [
        .library(
            name: "AssetKit",
            targets: ["AssetKit"]
        ),
    ],
    targets: [
        .target(
            name: "AssetKit"
        ),
        .testTarget(
            name: "AssetKitTests",
            dependencies: ["AssetKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
