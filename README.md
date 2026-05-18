# xcasset-compiler

A clean-room Swift implementation of Apple's `actool` that compiles `.xcassets` catalogs into the `Assets.car` file format.

Targets CoreUI 970 (Xcode 26 / iOS 16+). See [docs/coreui-970-format.md](docs/coreui-970-format.md) for the format reference.

## Usage

```swift
.package(url: "https://github.com/<org>/xcasset-compiler", .upToNextMinor(from: "1.0.0")),
```

```swift
import XCAssetCompiler

let compiler = XCAssetCompiler(deploymentTarget: "16.0")
let result = try await compiler.compile(catalog: catalogURL)

try result.carData.write(to: outputURL.appendingPathComponent("Assets.car"))

if let bundle = result.appIconBundle {
    // Merge bundle.infoPlistAdditions into the app's Info.plist
    // Write each bundle.looseFiles entry into the bundle root for SpringBoard's
    // icon-render fallback path
}
```

## What it supports

- `.imageset` (PNG sources, 1x/2x/3x scales, sRGB and display-P3, dark/light appearances)
- `.colorset` (sRGB and display-P3, hex or float components, dark/light appearances)
- `.appiconset` (per-idiom and per-size, with the loose-PNG fallback that SpringBoard expects alongside `Assets.car`)

## What it deliberately doesn't support

- Vector renditions (`.pdf`, `.svg`)
- Data sets, sticker sets, AR reference objects
- macOS / tvOS / watchOS asset variants beyond what the structural attribute IDs encode

These can be added; the format mechanisms in `Sources/XCAssetCompiler/CAR/` are general enough.

## Compression

Bitmap renditions are compressed with LZFSE on every platform via a vendored
copy of Apple's reference encoder (`Sources/CLZFSE/`, BSD 3-Clause). CAR
output is byte-deterministic across Linux and macOS.

## Tests

```sh
swift test
```

The test suite includes a macOS-only gate (`AssetutilParseTests`) that compiles a fixture catalog and verifies Apple's own `xcrun assetutil --info` parses the bytes and reports the expected rendition fields. This is the durable verification for CoreUI format compatibility and gates merges via CI.

## License

MIT. See [LICENSE.md](LICENSE.md).
