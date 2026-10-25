import Foundation

extension CSIWriter {
    static func layerStack(body: LayerStackBody) -> Data {
        var metadata = ByteWriter()
        writeLayerReferences(body, into: &metadata)

        // Stock two-layer metadata observed in actool's CoreUI 969 output.
        // Its remaining fields are not generalised to custom frame geometry.
        var flags = ByteWriter()
        flags.writeLE(UInt32(2))
        flags.writeZeros(12)
        flags.write(byte: 1)
        flags.writeZeros(12)
        flags.write(byte: 1)
        flags.writeZeros(4)
        writeTLV(1020, flags.data, into: &metadata)

        var layout = ByteWriter()
        layout.writeLE(UInt32(2))
        layout.writeZeros(44)
        writeTLV(1021, layout.data, into: &metadata)
        metadata.write(CSITVL.encode([.sliceScale]))

        let uti = Array("public.layeredimage".utf8) + [0]
        var type = ByteWriter()
        type.writeLE(UInt32(uti.count))
        type.writeLE(UInt32(0))
        type.write(uti)
        writeTLV(1005, type.data, into: &metadata)
        metadata.write(CSITVL.encode([.bitmapFlag]))

        let payload = DWAREnvelope.encode(flags: 0, payload: [])
        let header = CSIHeader.encode(
            renditionFlags: 0,
            width: body.width,
            height: body.height,
            scaleFactor: 100,
            pixelFormat: CSIHeader.pixelFormatData,
            colorSpace: 0,
            layout: .layerStack,
            name: "Contents.json",
            tvlLength: UInt32(metadata.offset),
            bitmapCount: 1,
            renditionLength: UInt32(payload.count)
        )
        return header + metadata.data + payload
    }

    private static func writeLayerReferences(_ body: LayerStackBody, into metadata: inout ByteWriter) {
        var references = ByteWriter()
        references.writeLE(UInt32(2))
        for name in [body.backgroundName, body.foregroundName] {
            references.writeZeros(16)
            references.writeLE(body.width)
            references.writeLE(body.height)
            references.writeLE(UInt32(0))
            references.writeLE(Float(1).bitPattern)
            // The length includes this word and the three attribute pairs.
            references.writeLE(UInt32(16))
            references.writeLE(UInt16(AttributeID.element.rawValue))
            references.writeLE(RenditionKey.Element.bitmap.rawValue)
            references.writeLE(UInt16(AttributeID.part.rawValue))
            references.writeLE(RenditionKey.Part.image.rawValue)
            references.writeLE(UInt16(AttributeID.identifier.rawValue))
            references.writeLE(UInt16(FacetKeys.nameHash(name) & 0xFFFF))
        }
        references.writeLE(UInt32(0))
        writeTLV(1012, references.data, into: &metadata)
    }

    private static func writeTLV(_ tag: UInt32, _ value: Data, into writer: inout ByteWriter) {
        writer.writeLE(tag)
        writer.writeLE(UInt32(value.count))
        writer.write(value)
    }
}
