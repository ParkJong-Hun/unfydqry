import Foundation
import UnifiedQuery

/// Loads `spec/*.json` once and exposes them via `Spec.normalize` / `Spec.search`.
/// Walks up from `#filePath` to locate the repo root, so SwiftPM's resources
/// mechanism is not needed (works under both `swift test` and `xcodebuild test`
/// as long as the source files remain on the filesystem).
///
/// See `spec/README.md` for the spec's intent and schema.
enum Spec {
    static let expectedVersion = 3

    static let normalize: NormalizeSpec = load("normalize")
    static let search: SearchSpecFile = load("search")
    static let reindex: ReindexSpecFile = load("reindex")

    private static let repoRoot: URL = {
        // .../ios/Tests/UnifiedQueryTests/SpecLoader.swift → go up 4 levels to reach the repo root.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // UnifiedQueryTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // ios
            .deletingLastPathComponent()    // repo root
    }()

    private static func load<T: Decodable>(_ name: String) -> T {
        let url = repoRoot.appendingPathComponent("spec/\(name).json")
        do {
            let data = try Data(contentsOf: url)
            let value = try JSONDecoder().decode(T.self, from: data)
            return value
        } catch {
            fatalError("Failed to load spec/\(name).json at \(url.path): \(error)")
        }
    }
}

// MARK: - normalize.json

struct NormalizeCase: Decodable, Sendable {
    let id: String
    let description: String
    let input: String
    let expected: String
    let source: String?
    /// Optional normalize profile key (e.g. "nfkc_case_fold"); absent means "loose".
    let profile: String?
    /// Optional composable steps; when present they override `profile`.
    let options: SpecOptions?
}

/// The composable normalization steps a spec record may request, mirroring the
/// FFI `NormalizeOptions`. Absent keys default to false.
struct SpecOptions: Decodable, Sendable {
    let lowercase: Bool?
    let kanaFold: Bool?
    let foldDiacritics: Bool?
    let foldChoonpu: Bool?
    let expandIterationMarks: Bool?
    let normalizeHyphens: Bool?
    let stripDigitGrouping: Bool?
    let collapseWhitespace: Bool?
    enum CodingKeys: String, CodingKey {
        case lowercase
        case kanaFold = "kana_fold"
        case foldDiacritics = "fold_diacritics"
        case foldChoonpu = "fold_choonpu"
        case expandIterationMarks = "expand_iteration_marks"
        case normalizeHyphens = "normalize_hyphens"
        case stripDigitGrouping = "strip_digit_grouping"
        case collapseWhitespace = "collapse_whitespace"
    }

    var ffi: NormalizeOptions {
        NormalizeOptions(
            lowercase: lowercase ?? false,
            kanaFold: kanaFold ?? false,
            foldDiacritics: foldDiacritics ?? false,
            foldChoonpu: foldChoonpu ?? false,
            expandIterationMarks: expandIterationMarks ?? false,
            normalizeHyphens: normalizeHyphens ?? false,
            stripDigitGrouping: stripDigitGrouping ?? false,
            collapseWhitespace: collapseWhitespace ?? false
        )
    }
}

/// Optional per-scenario engine configuration. Absent fields fall back to the
/// original behaviour (loose + trigram_bm25). When `options` is present it
/// selects composable normalization instead of the named `normalize` profile.
struct SpecConfig: Decodable, Sendable {
    let normalize: String?
    let strategy: String?
    let options: SpecOptions?
}

/// A pair that must normalize to *distinct* keys (e.g. dakuten が vs. unvoiced か).
struct NormalizeInequality: Decodable, Sendable {
    let id: String
    let description: String
    let a: String
    let b: String
    let profile: String?
    /// Optional composable steps; when present they override `profile`.
    let options: SpecOptions?
}

struct NormalizeSpec: Decodable, Sendable {
    let version: Int
    let cases: [NormalizeCase]
    let inequalities: [NormalizeInequality]
}

// MARK: - search.json

struct IndexOp: Decodable, Sendable {
    /// Either "index" or "remove".
    let op: String
    let id: Int64
    let text: String?
}

struct SearchSpec: Decodable, Sendable {
    let query: String
    let limit: UInt32
}

/// One search plus the predicates to assert on its result. Every predicate is
/// optional; the loader applies whichever are present (see `spec/README.md`).
struct Assertion: Decodable, Sendable {
    let search: SearchSpec
    let expectedIds: [Int64]?
    let expectedCount: Int?
    let score: String?
    let scoresNonDecreasing: Bool?
    let expectNoError: Bool?
    enum CodingKeys: String, CodingKey {
        case search
        case score
        case expectedIds = "expected_ids"
        case expectedCount = "expected_count"
        case scoresNonDecreasing = "scores_non_decreasing"
        case expectNoError = "expect_no_error"
    }
}

struct Scenario: Decodable, Sendable {
    let id: String
    let description: String
    let ops: [IndexOp]
    let assertions: [Assertion]
    let config: SpecConfig?
}

struct QueryExpectation: Decodable, Sendable {
    let query: String
    let description: String
    let expectedIds: [Int64]
    enum CodingKeys: String, CodingKey {
        case query
        case description
        case expectedIds = "expected_ids"
    }
}

struct SeededMatrix: Decodable, Sendable {
    let id: String
    let description: String
    let limit: UInt32
    let seed: [IndexOp]
    let queries: [QueryExpectation]
    let config: SpecConfig?
}

struct SearchSpecFile: Decodable, Sendable {
    let version: Int
    let scenarios: [Scenario]
    let seededMatrices: [SeededMatrix]
    enum CodingKeys: String, CodingKey {
        case version
        case scenarios
        case seededMatrices = "seeded_matrices"
    }
}

// MARK: - reindex.json

/// One regeneration case: index under `configBefore`, reopen under `configAfter`
/// (via `withConfigRebuilding`), and assert search results before and after the
/// rebuild. Reuses `IndexOp` for `ops` and `Assertion` for the `before`/`after`
/// checks.
struct ReindexCase: Decodable, Sendable {
    let id: String
    let description: String
    let configBefore: SpecConfig?
    let configAfter: SpecConfig?
    let ops: [IndexOp]
    let before: [Assertion]
    let after: [Assertion]
    enum CodingKeys: String, CodingKey {
        case id, description, ops, before, after
        case configBefore = "config_before"
        case configAfter = "config_after"
    }
}

struct ReindexSpecFile: Decodable, Sendable {
    let version: Int
    let cases: [ReindexCase]
}
