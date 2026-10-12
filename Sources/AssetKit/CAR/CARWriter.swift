import Foundation

/// Orchestrates the BOM container and CAR-specific blocks/trees.
///
/// Canonical vars-table order is established by call sequence: each
/// `addBlock` is immediately paired with `setVariable`, and `BOMWriter`
/// emits the vars table in insertion order. CoreUI's `UIImage(named:)`
/// lookup walks the vars table in order and rejects catalogs whose
/// ordering doesn't match the reference shape, so adding a new block out
/// of sequence here would break iOS lookups silently.
struct CARWriter: Sendable {
    var deploymentTarget: String
    var renditions: [Rendition]
    var options: OutputOptions = .legacy

    func write() throws -> Data {
        let layout = CARLayout(renditions: renditions)
        let iconSizeRecords = options.contains(.multisizeIcons) ? Self.iconSizeRecords(for: renditions, options: options) : []
        var bom = BOMWriter()

        // Canonical vars-table order, established by the call sequence
        // below: CARHEADER, RENDITIONS, FACETKEYS, APPEARANCEKEYS,
        // KEYFORMAT, EXTENDED_METADATA, BITMAPKEYS. Reordering or omitting
        // a `setVariable` here breaks iOS lookups silently.

        let headerCount = UInt32(renditions.count + iconSizeRecords.count)
        let headerBlockID = bom.addBlock(
            options.contains(.actoolVersionStrings)
                ? CARHeaderBlock.data(
                    coreuiVersion: 975,
                    renditionCount: headerCount,
                    mainVersionString: CARHeaderBlock.actoolMainVersionString,
                    versionString: CARHeaderBlock.actoolVersionString
                )
                : CARHeaderBlock.data(renditionCount: headerCount)
        )
        bom.setVariable("CARHEADER", blockID: headerBlockID)

        let withDimension1 = options.contains(.dimension1Key)
        var renditionEntries: [BOMTree.Entry] = renditions.map { rendition in
            BOMTree.Entry(
                key: RenditionKey(rendition: rendition, options: options).encode(withDimension1: withDimension1),
                value: csiData(for: rendition)
            )
        }
        renditionEntries += iconSizeRecords.map { record in
            BOMTree.Entry(key: record.key.encode(withDimension1: withDimension1), value: record.value)
        }
        let renditionsTreeID = BOMTree.insert(into: &bom, entries: renditionEntries)
        bom.setVariable("RENDITIONS", blockID: renditionsTreeID)

        let facetEntries = layout.assets.map { asset in
            BOMTree.Entry(
                key: Data(asset.name.utf8),
                value: FacetKeys.value(for: asset.name, kind: asset.kind, options: options)
            )
        }
        let facetTreeID = BOMTree.insert(into: &bom, entries: facetEntries)
        bom.setVariable("FACETKEYS", blockID: facetTreeID)

        let appearanceTreeID = BOMTree.insert(
            into: &bom,
            entries: AppearanceKeys.entries(used: layout.usedAppearances)
        )
        bom.setVariable("APPEARANCEKEYS", blockID: appearanceTreeID)

        let kfmtBlockID = bom.addBlock(KeyFormatBlock.data(attributes: withDimension1 ? v2KeyFormat : v1KeyFormat))
        bom.setVariable("KEYFORMAT", blockID: kfmtBlockID)

        let extendedMetadataBlockID = bom.addBlock(
            options.contains(.actoolVersionStrings)
                ? ExtendedMetadata.data(
                    deploymentTarget: deploymentTarget,
                    authoringTool: ExtendedMetadata.actoolAuthoringTool
                )
                : ExtendedMetadata.data(deploymentTarget: deploymentTarget)
        )
        bom.setVariable("EXTENDED_METADATA", blockID: extendedMetadataBlockID)

        let bitmapAssets: [(name: String, descriptor: BitmapKeys.Descriptor)] =
            layout.assets.compactMap { asset in
                guard let descriptor = BitmapKeys.descriptor(
                    forAsset: asset.name,
                    renditions: asset.renditions,
                    options: options
                ) else { return nil }
                return (asset.name, descriptor)
            }
        if !bitmapAssets.isEmpty {
            let bitmapKeysTreeID = BOMTree.insertInlineKey(
                into: &bom,
                entries: BitmapKeys.entries(for: bitmapAssets, options: options),
                blockSize: 1024
            )
            bom.setVariable("BITMAPKEYS", blockID: bitmapKeysTreeID)
        }

        return bom.finalize()
    }

    /// The app icon size index records (part 218): one per (idiom, subtype)
    /// group, listing the sizes that exist for it, keyed at scale 1.
    private static func iconSizeRecords(
        for renditions: [Rendition],
        options: OutputOptions
    ) -> [(key: RenditionKey, value: Data)] {
        struct Group: Hashable {
            var idiom: Idiom
            var subtype: UInt16
        }
        var groups: [Group: [UInt16: UInt32]] = [:]
        var names: [Group: String] = [:]
        for rendition in renditions {
            guard case .bitmap(let body) = rendition.body, body.kind == .appIcon else { continue }
            let group = Group(idiom: rendition.idiom, subtype: body.subtype)
            // keyed by icon index so that @1x/@2x/@3x files of one size count once
            groups[group, default: [:]][body.iconIndex] = UInt32(body.iconPoints)
            names[group] = rendition.name
        }
        return groups.map { group, sizes in
            var key = RenditionKey(
                scale: 1,
                idiom: group.idiom.rawValueByte,
                subtype: group.subtype,
                identifier: FacetKeys.identifier(for: names[group]!, options: options),
                element: RenditionKey.Element.bitmap.rawValue,
                part: RenditionKey.Part.iconSizes.rawValue
            )
            key.dimension1 = 0
            let entries = sizes.sorted { $0.key < $1.key }.map { (points: $0.value, index: UInt32($0.key)) }
            return (key, CSIWriter.iconSizes(name: names[group]!, entries: entries))
        }
    }

    private func csiData(for rendition: Rendition) -> Data {
        switch rendition.body {
        case .bitmap(let body):
            let scaleFactor = UInt32(rendition.scale?.factor ?? 1) * 100
            return CSIWriter.bitmap(name: rendition.name, body: body, scaleFactor: scaleFactor)
        case .color(let body):
            return CSIWriter.color(name: rendition.name, body: body)
        case .preservedSource(let body):
            // SVG renditions are scale-free; the reference leaves
            // scaleFactor=0 for them. JPGs respect the @Nx suffix the same
            // way PNGs do.
            let scaleFactor: UInt32 = {
                switch body.format {
                case .svg: return 0
                case .jpeg: return UInt32(rendition.scale?.factor ?? 1) * 100
                }
            }()
            return CSIWriter.preservedSource(body: body, scaleFactor: scaleFactor)
        }
    }
}
