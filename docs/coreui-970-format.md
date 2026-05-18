# CoreUI 970 `.car` format reference

This document describes the CoreUI `Assets.car` (Compiled Asset Resource) binary format as emitted by `actool` in Xcode 26 (CoreUI 970, `StorageVersion = 17`, targeting iOS 16+).

It is not a replacement for reading `Sources/XCAssetCompiler/`; it is a companion that explains *why* the bytes are the way they are, with particular attention to six places where the public reverse-engineering writeups (Timac 2018, DBG.RE 2026) describe an older format and would have given wrong values if followed literally. This writer was developed against a freshly dumped `actool` reference rather than from those writeups; the divergences below cost real iteration cycles to discover.

## Container

A `.car` is a BOM ("Bill of Materials") container whose payload blocks carry CoreUI-specific data. The BOM format itself is documented elsewhere (libbom, Timac 2018); the relevant points are:

- Header at offset 0, all big-endian: `BOMStore` magic, version, block count, plus offsets to the block index and vars tables.
- Block payloads packed sequentially after the header.
- Block index table: `count u32` then `(addr u32, len u32)` pairs. Block 0 is reserved/null.
- Variables table: `count u32` then per-entry `{ blockID u32, nameLen u8, name[nameLen] }`. CoreUI looks up payloads by name.

The CoreUI-named variables this writer emits, in the canonical order `actool` produces:

| Variable | Type | Purpose |
|---|---|---|
| `CARHEADER` | block | 436-byte fixed-size header with version, storage version, schema version, etc. |
| `RENDITIONS` | tree | Packed-key tuple → CSI rendition bytes. |
| `FACETKEYS` | tree | Asset name → attribute pairs. |
| `APPEARANCEKEYS` | tree | Appearance name string → numeric ID. |
| `KEYFORMAT` | block | Declares the attribute-tuple layout used by RENDITIONS keys. |
| `EXTENDED_METADATA` | block | 1028-byte block; platform / deployment target / authoring tool. |
| `BITMAPKEYS` | tree | Per-asset bitmap descriptors; required for `UIImage(named:)` lookup of generic image assets. |

iOS's `UIImage(named:)` and SpringBoard's icon-render pipeline both walk the vars table in this order and reject catalogs whose ordering doesn't match the reference shape. Order is load-bearing.

## Six places the public writeups are wrong for CoreUI 970

These are listed by detection mode — the first three are caught by Apple's own `assetutil --info`, the last three silently produce a catalog that parses cleanly but fails at runtime on a real iOS device. The latter three were the costly ones to discover, because there's no easy local signal.

### 1. AttributeID enum values are not stable across CoreUI versions

DBG.RE 2026 lists `appearance=6`, `scale=11`, `identifier=15`. CoreUI 970 emits `appearance=7`, `scale=12`, `identifier=17`. The full v1 schema this writer uses:

```
.element       = 1
.part          = 2
.appearance    = 7
.dimension2    = 9
.scale         = 12
.localization  = 13
.idiom         = 15
.subtype       = 16
.identifier    = 17
```

Implementation: [Sources/XCAssetCompiler/CAR/KeyFormat.swift](../Sources/XCAssetCompiler/CAR/KeyFormat.swift).

If you target a different Xcode version, re-derive these by dumping a fresh `assetutil --info` reference catalog. CoreUI itself binary-searches rendition keys by raw byte comparison, so a single wrong attribute number desyncs the entire lookup.

### 2. Magic-word byte order is inconsistent per block

CoreUI mixes endianness for its magic words. The following are little-endian multi-char constants (bytes appear reversed on disk):

- `CTAR` → on disk: `R`, `A`, `T`, `C`
- `CTSI` → on disk: `I`, `S`, `T`, `C`
- `kfmt` → on disk: `t`, `m`, `f`, `k`

These are written in character order (no reversal):

- `MLEC`, `KCBC`, `COLR`, `META`

There's no obvious pattern in the source code for which is which; it must be matched against actool's output per block. Mixing this up produces files that look superficially correct in a hex viewer but fail at runtime.

### 3. A 104-byte TVL section is required between the CSI header and the bitmap body

For raw-bitmap renditions, CoreUI 970 expects a TVL (type-length-value) metadata block of exactly 104 bytes between the 184-byte CSI header and the MLEC-framed bitmap payload. Five entries:

| Type | Length | Value |
|---|---|---|
| 1001 | 20 | bitmap descriptor: `(1, 0, 0, width, height)` |
| 1003 | 28 | destination rect: `(1, 0, 0, 0, 0, width, height)` |
| 1004 | 8 | slice/scale pair: `(0, 1.0f)` |
| 1006 | 4 | `1` — likely bitmap-count or has-mipmap-stages flag |
| 1007 | 4 | bytes per row, aligned up to 16 |

Without this section, CoreUI parses the rendition key but cannot materialise the bitmap. `assetutil --info` reports `AssetType: Unknown` and omits `PixelWidth`, `PixelHeight`, `Encoding`, and `Compression`.

Implementation: [Sources/XCAssetCompiler/CAR/CSIWriter.swift](../Sources/XCAssetCompiler/CAR/CSIWriter.swift).

### 4. iOS uses `UIAppearanceAny` / `UIAppearanceDark` in APPEARANCEKEYS — not the macOS names

The APPEARANCEKEYS tree maps appearance name strings to the numeric IDs that appear in the `appearance` slot of rendition keys. CoreUI walks this tree by exact string match.

- iOS: `UIAppearanceAny` (0), `UIAppearanceDark` (1)
- macOS: `NSAppearanceNameAqua` (0), `NSAppearanceNameDarkAqua` (1)

Registering only the macOS names produces a catalog where `UIImage(named:)` returns nil at runtime for every asset, even though `assetutil --info` parses cleanly. SpringBoard's appicon path doesn't depend on APPEARANCEKEYS (it falls back to loose PNGs we emit alongside `Assets.car`, see §"SpringBoard fallback" below), which masks the bug for icon-only catalogs.

Both `any` and `dark` rows are required, because rendition keys pack `appearance=0` for default variants and `appearance=1` for dark (`luminosity dark`) variants; omitting either row breaks lookups for the corresponding catalog entries.

Implementation: [Sources/XCAssetCompiler/CAR/AppearanceKeys.swift](../Sources/XCAssetCompiler/CAR/AppearanceKeys.swift).

### 5. `actool` allocates value blocks before key blocks in BOM trees

For BOM trees with separate key/value blocks (most trees other than BITMAPKEYS), the convention is to allocate the value block *before* its corresponding key block — so the value block has the lower block ID.

`UIImage(named:)` returns nil if this ordering is reversed. The catalog still parses with `assetutil` because the file structure is valid; iOS's runtime walks the leaf assuming value-first IDs.

Implementation: [Sources/XCAssetCompiler/BOM/BOMTree.swift](../Sources/XCAssetCompiler/BOM/BOMTree.swift).

### 6. BITMAPKEYS is required for `UIImage(named:)` resolution

The BITMAPKEYS tree carries per-asset bitmap descriptors that CoreUI consults during `UIImage(named:)` resolution for `.imageset` (and analogous) assets. Without this tree present, image lookups return nil at runtime even though the renditions are physically present in the file and FACETKEYS / RENDITIONS resolve correctly.

Structure:

- Tree is `isPathInternal = true` and uses a `blockSize` of 1024.
- Each leaf entry's "key" slot is an inline `u32` `NameIdentifier` (not a block pointer like other trees).
- Each value is a 52-byte descriptor.

The 52-byte descriptor layout was derived by diffing `actool`'s outputs for `.appiconset` vs `.imageset` renditions. The first 7 `u32`s are constant (header-like); the remaining 6 vary by asset kind:

| Field | AppIcon | Image |
|---|---|---|
| `u32` slot 8 | (idiom×subtype count) | (idiom×subtype count) |
| `(u16, u16)` slot 9 | `(1, 1)` | `(1, 0)` |
| `u32` slot 10 | `7` | `1` |

Followed by three trailing `0xFFFFFFFF` sentinels. Total: 52 bytes.

The `renditionFlags` field in the CSI header differs correspondingly — bit 4 set for `.image` renditions, cleared for `.appIcon`.

Implementation: [Sources/XCAssetCompiler/CAR/BitmapKeys.swift](../Sources/XCAssetCompiler/CAR/BitmapKeys.swift).

## SpringBoard fallback (loose-PNG escape hatch)

The library emits loose PNGs into the bundle root alongside `Assets.car`, named per `CFBundleIconFiles` (e.g. `AppIcon60x60@2x.png`). These are not redundant with the CAR-embedded renditions — they exist because SpringBoard's home-screen icon-render pipeline uses the loose-PNG fallback whenever CoreUI's rendition lookup misses.

This writer's `NameIdentifier` is `CRC32-IEEE(name) & 0xFFFF`, whereas `actool`'s hash function differs. The truncated CRC32 produces a value that matches across this writer's own FACETKEYS and RENDITIONS trees (which is what CoreUI requires for lookup), but doesn't match what SpringBoard would compute for the same asset name. The loose-PNG fallback masks this for app icons.

Imagesets have no such fallback. This is why divergences #4-6 above gate `UIImage(named:)` for image assets — there's no second chance.

## Workflow: generating a fresh `actool` reference

When changing any CoreUI block-emitting code (`CAR/*.swift`, `BOM/*.swift`), the durable safety net is to generate a reference Assets.car with `actool` and compare bytes.

```sh
# Create a fixture .xcassets, then:
xcrun actool \
  --compile /tmp/actool-out \
  --platform iphoneos \
  --minimum-deployment-target 16.0 \
  --output-partial-info-plist /tmp/actool-out/partial.plist \
  Test.xcassets

# Inspect:
xcrun assetutil --info /tmp/actool-out/Assets.car

# Hex-diff against this writer's output:
xxd /tmp/actool-out/Assets.car > /tmp/ref.hex
xxd /tmp/our-output/Assets.car > /tmp/ours.hex
diff /tmp/ref.hex /tmp/ours.hex
```

The `assetutil` parse gate in [Tests/XCAssetCompilerTests/AssetutilParseTests.swift](../Tests/XCAssetCompilerTests/AssetutilParseTests.swift) automates the most important half of this for the project's CI.

Crash signals like `_swapKeyFormat` are register heuristics from the iOS crash reporter, not diagnoses; treat them as "something is wrong upstream of this point" rather than "this specific function is the bug."

## Drift across Xcode versions

CoreUI's format has changed silently in past Xcode releases without changes to the writeups people cite. Anyone targeting a newer Xcode should:

1. Dump a reference Assets.car with that Xcode's `actool`.
2. Re-derive the AttributeID enum values from the KEYFORMAT block of that reference.
3. Re-verify the magic-word endianness for each block.
4. Re-verify the BITMAPKEYS descriptor layout against `.imageset` and `.appiconset` reference outputs.
5. Run the `assetutil` parse gate against new fixture catalogs.

The format is undocumented and Apple is under no obligation to keep it stable. This document and this writer reflect a snapshot of CoreUI 970; treat it as such.
