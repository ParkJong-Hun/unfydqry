import Foundation
import Testing
@testable import UnifiedQuery

/// Materializes the "golden tests" from design doc §E.4 in the form of `spec/*.json`.
/// Reads the same JSON files as the Kotlin and Rust suites, so any drift in the Rust
/// core's normalization or search logic causes all three runners (Swift / Kotlin / Rust)
/// to fail at the same `id` simultaneously.
@Suite("Spec-driven cross-platform")
struct SpecDrivenTests {
    // MARK: - normalize.json

    @Test func normalizeSpecVersionIsExpected() {
        #expect(Spec.normalize.version == Spec.expectedVersion)
    }

    @Test(arguments: Spec.normalize.cases)
    func normalizeMatchesSpec(_ c: NormalizeCase) {
        let got = Self.normalizedString(c.input, options: c.options, profile: c.profile)
        #expect(got == c.expected, "id=\(c.id): \(c.description)")
        // Normalization is a fixed point: applying it to its own output is identity.
        let twice = Self.normalizedString(c.expected, options: c.options, profile: c.profile)
        #expect(twice == c.expected, "id=\(c.id) not idempotent: \(c.description)")
    }

    @Test(arguments: Spec.normalize.inequalities)
    func normalizeInequalityHolds(_ ineq: NormalizeInequality) {
        let na = Self.normalizedString(ineq.a, options: ineq.options, profile: ineq.profile)
        let nb = Self.normalizedString(ineq.b, options: ineq.options, profile: ineq.profile)
        #expect(na != nb,
                "id=\(ineq.id): \(ineq.description); a=\"\(ineq.a)\"→\"\(na)\" b=\"\(ineq.b)\"→\"\(nb)\"")
    }

    /// Normalizes with a record's composable options if present, else its preset.
    static func normalizedString(_ input: String, options: SpecOptions?, profile key: String?) -> String {
        if let options {
            return normalizeWithOptions(input: input, options: options.ffi)
        }
        return normalizeWithProfile(input: input, profile: profile(key))
    }

    // MARK: - search.json: scenarios

    @Test func searchSpecVersionIsExpected() {
        #expect(Spec.search.version == Spec.expectedVersion)
    }

    @Test(arguments: Spec.search.scenarios)
    func scenarioMatchesSpec(_ s: Scenario) throws {
        let engine = try Self.engine(for: s.config)
        try apply(ops: s.ops, to: engine)
        for assertion in s.assertions {
            try check(assertion, on: engine, context: "scenario id=\(s.id): \(s.description)")
        }
    }

    // MARK: - search.json: seeded_matrices

    /// Expand every (matrix × query) over the shared seed into a single `@Test`.
    /// Today there is only one matrix; adding more later automatically multiplies
    /// the case count without further plumbing.
    static let matrixCases: [(matrix: SeededMatrix, query: QueryExpectation)] = {
        Spec.search.seededMatrices.flatMap { m in m.queries.map { (m, $0) } }
    }()

    @Test(arguments: matrixCases)
    func seededMatrixQueryMatchesSpec(_ pair: (matrix: SeededMatrix, query: QueryExpectation)) throws {
        let engine = try Self.engine(for: pair.matrix.config)
        try apply(ops: pair.matrix.seed, to: engine)
        let hits = try engine.search(query: pair.query.query, limit: pair.matrix.limit)
        let got = Set(hits.map(\.id))
        let want = Set(pair.query.expectedIds)
        #expect(got == want,
                "matrix=\(pair.matrix.id) query=\"\(pair.query.query)\": \(pair.query.description); got=\(got.sorted()) want=\(want.sorted())")
    }

    // MARK: - reindex.json

    @Test func reindexSpecVersionIsExpected() {
        #expect(Spec.reindex.version == Spec.expectedVersion)
    }

    @Test(arguments: Spec.reindex.cases)
    func reindexMatchesSpec(_ c: ReindexCase) throws {
        let path = Self.makeReindexDBPath()
        defer { Self.cleanup(path) }

        // Index under the before-profile and pin the pre-rebuild behaviour. The
        // engine is released at the end of this scope so the connection is freed
        // before reopening the same file.
        do {
            let before = try Self.engine(at: path, for: c.configBefore, rebuilding: false)
            try apply(ops: c.ops, to: before)
            try check(c.before, on: before, case: c, phase: "before")
        }
        // Reopen under the after-profile; a profile change regenerates the index
        // from the retained raw text instead of throwing.
        let after = try Self.engine(at: path, for: c.configAfter, rebuilding: true)
        try check(c.after, on: after, case: c, phase: "after")
    }

    private func check(_ checks: [Assertion], on engine: SearchEngine, case c: ReindexCase, phase: String) throws {
        for a in checks {
            try check(a, on: engine, context: "reindex id=\(c.id) [\(phase)]: \(c.description)")
        }
    }

    /// Runs one assertion's `search` and applies every predicate present on it.
    private func check(_ a: Assertion, on engine: SearchEngine, context: String) throws {
        let q = a.search.query
        // A thrown error fails the test (this also satisfies `expect_no_error`).
        let hits = try engine.search(query: q, limit: a.search.limit)

        if let ids = a.expectedIds {
            let got = Set(hits.map(\.id))
            let want = Set(ids)
            #expect(got == want, "\(context) query=\"\(q)\" got=\(got.sorted()) want=\(want.sorted())")
        }
        if let count = a.expectedCount {
            #expect(hits.count == count, "\(context) query=\"\(q)\": expected \(count) hits, got \(hits.count)")
        }
        if let kind = a.score {
            #expect(!hits.isEmpty, "\(context) query=\"\(q)\": score predicate needs at least one hit")
            for h in hits {
                switch kind {
                case "zero":
                    #expect(h.score == 0.0, "\(context) query=\"\(q)\": expected score 0, got \(h.score)")
                case "nonzero_finite":
                    #expect(h.score != 0.0 && h.score.isFinite,
                            "\(context) query=\"\(q)\": expected nonzero finite score, got \(h.score)")
                default:
                    Issue.record("\(context) query=\"\(q)\": unknown score predicate \"\(kind)\"")
                }
            }
        }
        if a.scoresNonDecreasing == true {
            let scores = hits.map(\.score)
            #expect(scores == scores.sorted(),
                    "\(context) query=\"\(q)\": scores not non-decreasing: \(scores)")
        }
    }

    // MARK: - helpers

    /// An independent temp DB file path for a reindex case. The caller cleans it up.
    static func makeReindexDBPath() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnifiedQueryReindex-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("index.sqlite").path
    }

    /// Removes the SQLite file and its WAL/SHM sidecars.
    static func cleanup(_ path: String) {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    /// Opens a persistent engine at `path`, rebuilding the index in place when
    /// `rebuilding` is set (used for the after-profile reopen).
    static func engine(at path: String, for config: SpecConfig?, rebuilding: Bool) throws -> SearchEngine {
        let ec = EngineConfig(normalize: profile(config?.normalize),
                              strategy: strategy(config?.strategy))
        return rebuilding
            ? try SearchEngine.withConfigRebuilding(dbPath: path, config: ec)
            : try SearchEngine.withConfig(dbPath: path, config: ec)
    }

    /// Maps a spec profile key to the FFI enum; absent → loose.
    static func profile(_ key: String?) -> NormalizeProfile {
        switch key ?? "loose" {
        case "loose": return .loose
        case "nfkc_case_fold": return .nfkcCaseFold
        default: fatalError("unknown normalize profile \"\(key ?? "")\"")
        }
    }

    /// Maps a spec strategy key to the FFI enum; absent → trigram_bm25.
    static func strategy(_ key: String?) -> SearchStrategy {
        switch key ?? "trigram_bm25" {
        case "trigram_bm25": return .trigramBm25
        case "substring": return .substring
        case "prefix": return .prefix
        case "suffix": return .suffix
        case "all_terms": return .allTerms
        case "fuzzy_trigram": return .fuzzyTrigram
        case "levenshtein": return .levenshtein
        case "damerau_levenshtein": return .damerauLevenshtein
        default: fatalError("unknown search strategy \"\(key ?? "")\"")
        }
    }

    /// Opens an in-memory engine for the given optional config. A `config.options`
    /// set selects composable normalization (withOptions); otherwise the named
    /// profile path (withConfig) is used.
    static func engine(for config: SpecConfig?) throws -> SearchEngine {
        guard let config else { return try SearchEngine(dbPath: ":memory:") }
        if let options = config.options {
            let ec = EngineOptionsConfig(normalize: options.ffi, strategy: strategy(config.strategy))
            return try SearchEngine.withOptions(dbPath: ":memory:", config: ec)
        }
        let ec = EngineConfig(normalize: profile(config.normalize),
                              strategy: strategy(config.strategy))
        return try SearchEngine.withConfig(dbPath: ":memory:", config: ec)
    }

    private func apply(ops: [IndexOp], to engine: SearchEngine) throws {
        for op in ops {
            switch op.op {
            case "index":
                try engine.index(id: op.id, text: op.text ?? "")
            case "remove":
                try engine.remove(id: op.id)
            default:
                Issue.record("Unknown op \"\(op.op)\" — spec/search.json schema mismatch")
            }
        }
    }
}
