import Foundation
import Testing
@testable import AssetKit

/// Not a real test: writes progressively actool-like `Assets.car` files for
/// uploading to App Store Connect, one difference from actool at a time.
/// Runs only when `CAR_CANDIDATES_OUT` is set; `CAR_CANDIDATES_ICONS` and
/// `CAR_CANDIDATES_FULL` point to the catalogs to compile.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CAR_CANDIDATES_OUT"] != nil))
struct CandidateGeneratorTests {
    @Test func generate() async throws {
        let env = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: try #require(env["CAR_CANDIDATES_OUT"]))
        let icons = URL(fileURLWithPath: try #require(env["CAR_CANDIDATES_ICONS"]))
        let full = URL(fileURLWithPath: try #require(env["CAR_CANDIDATES_FULL"]))
        let steps: [(String, OutputOptions, URL)] = [
            ("cand-0-baseline-icons-only", .legacy, icons),
            ("cand-1-keyformat", [.dimension1Key], icons),
            ("cand-2-header", [.dimension1Key, .actoolVersionStrings], icons),
            ("cand-3-multisize", [.dimension1Key, .actoolVersionStrings, .multisizeIcons], icons),
            ("cand-3b-multisize-honest", [.dimension1Key, .multisizeIcons], icons),
            ("cand-4-identifier", .actool26_5, icons),
            ("cand-4b-identifier-honest", .actoolStructure, icons),
            ("cand-5-with-launch-background", .actool26_5, full),
            ("cand-5b-launch-background-honest", .actoolStructure, full),
        ]
        for (name, options, catalog) in steps {
            let result = try await XCAssetCompiler(deploymentTarget: "17.0", options: options).compile(catalog: catalog)
            try result.carData.write(to: out.appendingPathComponent("\(name).car"))
        }
    }
}
