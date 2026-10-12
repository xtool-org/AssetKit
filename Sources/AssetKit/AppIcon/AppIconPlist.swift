import Foundation

struct AppIconPlistResult: Sendable {
    var infoPlistAdditions: [String: any Sendable]
    var iconName: String
    var iconFiles: [IconFile]
}

struct IconFile: Sendable, Hashable {
    var idiom: Idiom
    var pointSize: Double
    var scale: Int
    /// Name of the file the pixels came from, or the name actool would give a generated one.
    var sourceName: String
    var data: Data
    var outputName: String
}

enum AppIconPlistEmitter {
    static func emit(_ appIcon: LoadedAppIcon) throws -> AppIconPlistResult {
        var iphoneFiles: [String] = []
        var ipadFiles: [String] = []
        var allFiles: [IconFile] = []

        let entries = try iconEntries(for: appIcon)
        for entry in entries {
            let bundleName = "\(appIcon.name)\(formatSize(entry.pointSize))x\(formatSize(entry.pointSize))"
            allFiles.append(IconFile(
                idiom: entry.idiom,
                pointSize: entry.pointSize,
                scale: entry.scale,
                sourceName: entry.sourceName,
                data: entry.data,
                outputName: bundleName
            ))
            switch entry.idiom {
            case .iphone:
                if !iphoneFiles.contains(bundleName) { iphoneFiles.append(bundleName) }
            case .ipad:
                if !ipadFiles.contains(bundleName) { ipadFiles.append(bundleName) }
            default:
                break
            }
        }

        var bundleIcons: [String: any Sendable] = [
            "CFBundleIconName": appIcon.name,
        ]
        if !iphoneFiles.isEmpty {
            bundleIcons["CFBundlePrimaryIcon"] = [
                "CFBundleIconName": appIcon.name,
                "CFBundleIconFiles": iphoneFiles,
            ] as [String: any Sendable]
        }

        var additions: [String: any Sendable] = [
            "CFBundleIcons": bundleIcons,
            "CFBundleIconName": appIcon.name,
        ]

        if !ipadFiles.isEmpty {
            additions["CFBundleIcons~ipad"] = [
                "CFBundleIconName": appIcon.name,
                "CFBundlePrimaryIcon": [
                    "CFBundleIconName": appIcon.name,
                    "CFBundleIconFiles": ipadFiles,
                ] as [String: any Sendable],
            ] as [String: any Sendable]
        }

        let fallback = Array(Set(iphoneFiles + ipadFiles)).sorted()
        if !fallback.isEmpty {
            additions["CFBundleIconFiles"] = fallback
        }

        return AppIconPlistResult(
            infoPlistAdditions: additions,
            iconName: appIcon.name,
            iconFiles: allFiles
        )
    }

    private struct Entry {
        var idiom: Idiom
        var pointSize: Double
        var scale: Int
        var sourceName: String
        var data: Data
    }

    /// The icons to emit: one per `Contents.json` entry, or, for the single-size
    /// format, the sizes generated from the 1024x1024 master.
    private static func iconEntries(for appIcon: LoadedAppIcon) throws -> [Entry] {
        var entries: [Entry] = []
        for image in appIcon.contents.images {
            if let platform = image.platform, platform != "ios" {
                throw XCAssetCompilerError.unsupportedAppIconPlatform(asset: appIcon.name, platform: platform)
            }
            // Dark and tinted variants (iOS 18) are not compiled yet; the default icon is used for every appearance.
            if !(image.appearances ?? []).isEmpty { continue }

            guard let filename = image.filename, !filename.isEmpty else {
                throw XCAssetCompilerError.appIconSizeMissing(asset: appIcon.name, size: image.size)
            }
            let src = appIcon.directory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: src.path) else {
                throw XCAssetCompilerError.missingReferencedFile(asset: appIcon.name, filename: filename)
            }
            let data = try Data(contentsOf: src)

            if image.isSingleSizeMaster {
                entries.append(contentsOf: try expandMaster(data, filename: filename, appIcon: appIcon))
                continue
            }
            guard let (w, _) = image.pointSize, let scale = image.scale?.factor else {
                throw XCAssetCompilerError.appIconSizeMissing(asset: appIcon.name, size: image.size)
            }
            entries.append(Entry(idiom: image.idiom, pointSize: w, scale: scale, sourceName: filename, data: data))
        }
        return entries
    }

    /// Point sizes and scales actool generates from a single-size master for iOS.
    private static let generatedSizes: [(idiom: Idiom, points: Double, scale: Int)] = [
        (.iphone, 20, 2), (.iphone, 20, 3),
        (.iphone, 29, 2), (.iphone, 29, 3),
        (.iphone, 40, 2), (.iphone, 40, 3),
        (.iphone, 60, 2), (.iphone, 60, 3),
        (.ipad, 20, 1), (.ipad, 20, 2),
        (.ipad, 29, 1), (.ipad, 29, 2),
        (.ipad, 40, 1), (.ipad, 40, 2),
        (.ipad, 76, 1), (.ipad, 76, 2),
        (.ipad, 83.5, 2),
    ]

    private static func expandMaster(_ data: Data, filename: String, appIcon: LoadedAppIcon) throws -> [Entry] {
        let master = try PNGResizer.decode(data)
        guard master.width == 1024, master.height == 1024 else {
            throw XCAssetCompilerError.appIconSourceSizeMismatch(
                asset: appIcon.name,
                filename: filename,
                expected: "1024x1024",
                actual: "\(master.width)x\(master.height)"
            )
        }
        var resized: [Int: Data] = [:]
        var out: [Entry] = []
        for size in generatedSizes {
            let pixels = Int((size.points * Double(size.scale)).rounded())
            if resized[pixels] == nil {
                resized[pixels] = try PNGResizer.resize(master, width: pixels, height: pixels)
            }
            let suffix = size.scale == 1 ? "" : "@\(size.scale)x"
            let name = "\(formatSize(size.points))x\(formatSize(size.points))"
            out.append(Entry(
                idiom: size.idiom,
                pointSize: size.points,
                scale: size.scale,
                sourceName: "\(appIcon.name)-\(name)\(suffix).png",
                data: resized[pixels]!
            ))
        }
        // The store icon is the master itself.
        out.append(Entry(idiom: .marketing, pointSize: 1024, scale: 1, sourceName: filename, data: data))
        return out
    }

    private static func formatSize(_ n: Double) -> String {
        let rounded = n.rounded()
        if abs(n - rounded) < 0.001 {
            return String(format: "%.0f", n)
        }
        return String(format: "%g", n)
    }
}
