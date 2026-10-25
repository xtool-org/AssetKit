# AssetKit

A clean-room Swift implementation of Apple's `actool` that compiles `.xcassets` catalogs into the `Assets.car` file format.

Targets CoreUI 970 (Xcode 26 / iOS 16+). See [docs/coreui-970-format.md](docs/coreui-970-format.md) for the format reference.

## Usage

```swift
.package(url: "https://github.com/xtool-org/AssetKit", .upToNextMinor(from: "1.0.0")),
```

```swift
import AssetKit

// `svgRasterizer` defaults to `RsvgConvertRasterizer()`, which shells out
// to `rsvg-convert` (install with `apt install librsvg2-tools`,
// `dnf install librsvg2-tools`, or `brew install librsvg`). Replace it
// with your own `SVGRasterizer` if you'd rather not depend on a system
// binary.
let compiler = XCAssetCompiler(deploymentTarget: "16.0")
let result = try await compiler.compile(catalog: catalogURL)

try result.carData.write(to: outputURL.appendingPathComponent("Assets.car"))

if let bundle = result.appIconBundle {
    // Merge bundle.infoPlistAdditions into the app's Info.plist
    // Write each bundle.looseFiles entry into the bundle root for SpringBoard's
    // icon-render fallback path
}
```

For a tvOS catalog, select the platform explicitly:

```swift
let compiler = XCAssetCompiler(deploymentTarget: "17.0", platform: .tvOS)
let result = try await compiler.compile(catalog: catalogURL)
```

The default platform remains iOS. In a mixed catalog, iOS selects its
`.appiconset` and ignores TV-only Brand Assets; tvOS selects its `.brandassets`
and ignores the iOS app icon. Merge the returned `appIconBundle` metadata into
the app's Info.plist. tvOS names the small stack in `CFBundleIcons` and maps
the supplied Top Shelf roles into `TVTopShelfImage`.
tvOS compilation rejects distinct facet names that collide in the current
16-bit CoreUI identifier mapping, so a layer cannot alias another asset.
Branding elements must also have unique names across their roles and types.

## What it supports

- `.imageset`
  - PNG sources (1x/2x/3x scales, sRGB and display-P3, dark/light appearances)
  - SVG sources, each emitted as one preserved vector rendition (XML kept verbatim, LZFSE-compressed inside a DWAR envelope) plus three rasterised bitmap fallbacks at 1x/2x/3x (because `UIImage(named:)` reads the rasterised fallbacks; the vector rendition is what other CoreUI consumers and future iOS versions may prefer). Rasterisation is delegated to an injectable `SVGRasterizer`; the default shells out to `rsvg-convert`.
  - JPG sources stored as preserved raw renditions (JPEG bytes passed through; original compression preserved)
- `.colorset` (sRGB and display-P3, hex or float components, dark/light appearances)
- `.appiconset` (per-idiom and per-size, with the loose-PNG fallback that SpringBoard expects alongside `Assets.car`). PNG sources only; SVG/JPG are rejected because SpringBoard's icon-render pipeline requires PNG.
- tvOS `.brandassets` with a 400×240 primary icon and an optional 1280×768
  marketing icon, each containing two embedded PNG layers with default canvas
  and frame geometry. Layer relationships and qualified names are retained in
  CoreUI LayerStack renditions; flattened previews are emitted separately.
  Top Shelf image roles and app icon metadata are returned in `appIconBundle`.
  Sources must use sRGB, the `tv` idiom, and distinct 1x/2x scales (marketing
  icons use 1x only), with an opaque background layer.

## What it deliberately doesn't support

- `.pdf` vector sources (the CoreUI 970 DWAR envelope path is SVG-flavoured; adding PDF would need a separate `pixelFormat`)
- Multi-rendition fanout — actool emits multiple compression variants per asset (`deepmap-lzfse`, `deepmap2`, `palette-img`); this writer emits one rendition per `(idiom, scale, appearance)` tuple per source format. Sufficient for iOS 16+.
- Data sets, sticker sets, AR reference objects
- Standalone `.imagestack` assets, custom tvOS layer geometry, referenced layers, additional layers, and dark or
  display-P3 Brand Assets. Unsupported forms are rejected, rather than flattened
  or emitted with incomplete layer relationships.
- Apple's undocumented blurred radiosity renditions for tvOS focus effects.
  The current output's icon-loading and focus behavior still needs native tvOS
  runtime validation; structural CAR compatibility does not prove that behavior.
- macOS / watchOS asset variants beyond what the structural attribute IDs encode

These can be added; the format mechanisms in `Sources/AssetKit/CAR/` are general enough.

## Compression

Bitmap renditions are compressed with LZFSE on every platform via a vendored
copy of Apple's reference encoder (`Sources/CLZFSE/`, BSD 3-Clause). CAR
output is byte-deterministic across Linux and macOS.

## Tests

```sh
swift test
```

The test suite includes macOS-only gates that compile iOS and tvOS fixture
catalogs and verify Apple's own `xcrun assetutil --info` parses the bytes and
reports the expected rendition fields. These checks run in CI. Linux tests
cover layer ordering and references, mixed-catalog platform selection, the
observed LayerStack record layout, compositing, and unsupported geometry.

## License

MIT. See [LICENSE](LICENSE).
