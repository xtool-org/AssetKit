// swift-tools-version:6.0

import PackageDescription

let package = Package(
    name: "xcasset-compiler",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "XCAssetCompiler",
            targets: ["XCAssetCompiler"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/tayloraswift/swift-png", from: "4.5.0"),
    ],
    targets: [
        .target(
            name: "XCAssetCompiler",
            dependencies: [
                .product(name: "PNG", package: "swift-png"),
            ]
        ),
        .testTarget(
            name: "XCAssetCompilerTests",
            dependencies: [
                "XCAssetCompiler",
            ],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
