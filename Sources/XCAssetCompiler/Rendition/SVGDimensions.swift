import Foundation

/// Extracts intrinsic pixel dimensions from an SVG source. Used by the SVG
/// raster fanout path to determine the 1x bitmap dimensions; 2x and 3x are
/// computed by multiplication.
///
/// Looks at the root `<svg>` element only. Resolution order matches the SVG
/// spec's intrinsic-sizing rules:
///
/// 1. If both `width` and `height` attributes are present and parseable
///    (with optional `px` suffix), use them.
/// 2. Otherwise fall back to the `viewBox`'s width and height.
/// 3. If neither is available, throw `svgDimensionsMissing`.
///
/// Percentage widths/heights (`width="100%"`) are treated as absent and the
/// parser falls through to the viewBox. SVGs with neither absolute width/height
/// nor a viewBox cannot be rasterised at a definite size and are rejected.
enum SVGDimensions {
    static func read(_ data: Data, asset: String, filename: String) throws -> (width: UInt32, height: UInt32) {
        guard let text = String(data: data, encoding: .utf8) else {
            throw XCAssetCompilerError.svgDimensionsMissing(asset: asset, filename: filename)
        }
        let rootAttrs = svgRootAttributes(text)
        if let w = rootAttrs["width"].flatMap(absoluteLength),
           let h = rootAttrs["height"].flatMap(absoluteLength) {
            return (w, h)
        }
        // Attribute names are stored lowercased in `rootAttrs` so the
        // lookup key has to match — `rootAttrs["viewBox"]` would always
        // miss even when the attribute is present on the root.
        if let viewBox = rootAttrs["viewbox"] {
            let parts = viewBox.split(whereSeparator: { $0 == " " || $0 == "," })
            if parts.count == 4,
               let w = Double(parts[2]),
               let h = Double(parts[3]),
               w > 0, h > 0 {
                return (UInt32(w.rounded()), UInt32(h.rounded()))
            }
        }
        throw XCAssetCompilerError.svgDimensionsMissing(asset: asset, filename: filename)
    }

    /// Parses the attributes on the root `<svg>` element. Skips XML
    /// declarations, comments, and doctypes that may sit before the root.
    /// Returns a dictionary of attribute-name to attribute-value strings.
    ///
    /// Limitations of this byte-walking parser, all of which are violations
    /// of the SVG-as-XML spec and don't appear in output from mainstream
    /// editors (Sketch, Figma, Adobe Illustrator, Inkscape):
    /// - Attribute values must be quoted (the spec requires this anyway).
    /// - Bare boolean attributes (`<svg disabled>`) terminate parsing of
    ///   subsequent attributes on the same tag.
    /// If we need stricter handling we'd swap in Foundation's `XMLParser`
    /// (cross-platform via swift-corelibs-foundation on Linux).
    private static func svgRootAttributes(_ text: String) -> [String: String] {
        // Locate the root `<svg` ensuring the next char is one of
        // `space`/`>`/`/`/`:` so we don't match `<svgfoo>` or `<svg` inside
        // a comment that happens to share the prefix. Iterate matches in
        // case the first is a comment-bound false positive.
        var searchRange = text.startIndex..<text.endIndex
        var openEnd: String.Index?
        while let candidate = text.range(of: "<svg", options: [.caseInsensitive], range: searchRange) {
            if candidate.upperBound == text.endIndex {
                break
            }
            let next = text[candidate.upperBound]
            if next.isWhitespace || next == ">" || next == "/" || next == ":" {
                openEnd = candidate.upperBound
                break
            }
            searchRange = candidate.upperBound..<text.endIndex
        }
        guard let openEnd else { return [:] }
        // Tag body runs from openEnd to the next ">". Within that range we
        // extract key="value" pairs.
        let tail = text[openEnd...]
        guard let closeIndex = tail.firstIndex(of: ">") else { return [:] }
        let body = tail[..<closeIndex]
        var out: [String: String] = [:]
        var i = body.startIndex
        while i < body.endIndex {
            // Skip whitespace.
            while i < body.endIndex, body[i].isWhitespace { i = body.index(after: i) }
            // Read attribute name until '='.
            let nameStart = i
            while i < body.endIndex, body[i] != "=", !body[i].isWhitespace { i = body.index(after: i) }
            let name = String(body[nameStart..<i]).lowercased()
            // Skip until quote.
            while i < body.endIndex, body[i] != "\"", body[i] != "'" { i = body.index(after: i) }
            guard i < body.endIndex else { break }
            let quote = body[i]
            i = body.index(after: i)
            let valueStart = i
            while i < body.endIndex, body[i] != quote { i = body.index(after: i) }
            guard i < body.endIndex else { break }
            let value = String(body[valueStart..<i])
            i = body.index(after: i)
            if !name.isEmpty { out[name] = value }
        }
        return out
    }

    /// Parses an SVG length that the spec calls "absolute" — a plain number,
    /// optionally followed by "px". Other units (em, ex, %, pt, mm, cm, in)
    /// are treated as non-absolute and cause the caller to fall back to
    /// viewBox. Returns the integer pixel count or `nil`.
    private static func absoluteLength(_ raw: String) -> UInt32? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix("px") || s.hasSuffix("PX") {
            s = String(s.dropLast(2))
        }
        guard let n = Double(s), n > 0 else { return nil }
        return UInt32(n.rounded())
    }
}
