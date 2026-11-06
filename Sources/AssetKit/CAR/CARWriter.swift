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

    func write() throws -> Data {
        let layout = CARLayout(renditions: renditions)
        var bom = BOMWriter()

        // Canonical vars-table order, established by the call sequence
        // below: CARHEADER, RENDITIONS, FACETKEYS, APPEARANCEKEYS,
        // KEYFORMAT, EXTENDED_METADATA, BITMAPKEYS. Reordering or omitting
        // a `setVariable` here breaks iOS lookups silently.

        // KEYFORMAT is catalog-wide and actool only lists the attributes in
        // use: the base eight, plus dimension2 when some rendition carries
        // an Icon Index (app icons). Rendition keys pack exactly these
        // tokens in this order (actool 27.0: icon cars 18-byte keys, color
        // cars 16-byte keys).
        let usesIconIndex = renditions.contains { rendition in
            if case .bitmap(let body) = rendition.body, body.kind == .appIcon {
                return true
            }
            return false
        }
        let keyFormat: [AttributeID] = usesIconIndex ? v1KeyFormat : baseKeyFormat

        let headerBlockID = bom.addBlock(CARHeaderBlock.data(renditionCount: UInt32(renditions.count)))
        bom.setVariable("CARHEADER", blockID: headerBlockID)

        let renditionEntries: [BOMTree.Entry] = renditions.map { rendition in
            BOMTree.Entry(
                key: RenditionKey(rendition: rendition).encode(format: keyFormat),
                value: csiData(for: rendition)
            )
        }
        let renditionsTreeID = BOMTree.insert(into: &bom, entries: renditionEntries)
        bom.setVariable("RENDITIONS", blockID: renditionsTreeID)

        let facetEntries = layout.assets.map { asset in
            BOMTree.Entry(
                key: Data(asset.name.utf8),
                value: FacetKeys.value(for: asset.name, kind: asset.kind)
            )
        }
        let facetTreeID = BOMTree.insert(into: &bom, entries: facetEntries)
        bom.setVariable("FACETKEYS", blockID: facetTreeID)

        let appearanceTreeID = BOMTree.insert(
            into: &bom,
            entries: AppearanceKeys.entries(used: layout.usedAppearances)
        )
        bom.setVariable("APPEARANCEKEYS", blockID: appearanceTreeID)

        let kfmtBlockID = bom.addBlock(KeyFormatBlock.data(attributes: keyFormat))
        bom.setVariable("KEYFORMAT", blockID: kfmtBlockID)

        let extendedMetadataBlockID = bom.addBlock(ExtendedMetadata.data(deploymentTarget: deploymentTarget))
        bom.setVariable("EXTENDED_METADATA", blockID: extendedMetadataBlockID)

        let bitmapAssets: [(name: String, descriptor: BitmapKeys.Descriptor)] =
            layout.assets.compactMap { asset in
                guard let descriptor = BitmapKeys.descriptor(
                    forAsset: asset.name,
                    renditions: asset.renditions
                ) else { return nil }
                return (asset.name, descriptor)
            }
        if !bitmapAssets.isEmpty {
            let bitmapKeysTreeID = BOMTree.insertInlineKey(
                into: &bom,
                entries: BitmapKeys.entries(for: bitmapAssets),
                blockSize: 1024
            )
            bom.setVariable("BITMAPKEYS", blockID: bitmapKeysTreeID)
        }

        return bom.finalize()
    }

    private func csiData(for rendition: Rendition) -> Data {
        switch rendition.body {
        case .bitmap(let body):
            let scaleFactor = UInt32(rendition.scale?.factor ?? 1) * 100
            return CSIWriter.bitmap(name: rendition.name, body: body, scaleFactor: scaleFactor)
        case .multiSized(let body):
            return CSIWriter.multiSized(name: rendition.name, body: body)
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
