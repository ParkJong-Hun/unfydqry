package com.unfydqry.unifiedquery

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.Arguments
import org.junit.jupiter.params.provider.MethodSource
import java.io.File
import java.nio.file.Files
import java.util.UUID
import java.util.stream.Stream
import uniffi.unfydqry.EngineConfig
import uniffi.unfydqry.EngineOptionsConfig
import uniffi.unfydqry.NormalizeProfile
import uniffi.unfydqry.SearchEngine
import uniffi.unfydqry.SearchStrategy
import uniffi.unfydqry.normalizeWithOptions
import uniffi.unfydqry.normalizeWithProfile

/**
 * Materializes the "golden tests" from design doc §E.4 in the form of
 * spec/normalize.json and spec/search.json. Reads the same JSON files as the
 * Swift and Rust suites, so any drift in the Rust core's normalization or
 * search logic causes all three runners (Swift / Kotlin / Rust) to fail at the
 * same `id` simultaneously.
 */
@DisplayName("Spec-driven cross-platform")
class SpecDrivenTest {
    companion object {
        @JvmStatic
        fun normalizeCases(): Stream<Arguments> =
            Spec.normalize.cases.stream().map {
                Arguments.of(it.id, it.description, it.input, it.expected, it.profile, it.options)
            }

        @JvmStatic
        fun normalizeInequalities(): Stream<Arguments> =
            Spec.normalize.inequalities.stream().map { Arguments.of(it.id, it) }

        @JvmStatic
        fun scenarios(): Stream<Arguments> =
            Spec.search.scenarios.stream().map { Arguments.of(it.id, it) }

        @JvmStatic
        fun matrixQueries(): Stream<Arguments> =
            Spec.search.seededMatrices.stream().flatMap { m ->
                m.queries.stream().map { q ->
                    Arguments.of("${m.id}/${q.query}", m, q)
                }
            }

        @JvmStatic
        fun reindexCases(): Stream<Arguments> =
            Spec.reindex.cases.stream().map { Arguments.of(it.id, it) }

        private fun makeTempDbPath(): String {
            val dir = Files.createTempDirectory("SpecReindex-${UUID.randomUUID()}").toFile()
            dir.deleteOnExit()
            return File(dir, "index.sqlite").absolutePath
        }

        private fun cleanup(path: String) {
            for (suffix in listOf("", "-shm", "-wal")) {
                File(path + suffix).delete()
            }
        }

        /**
         * Opens a persistent engine at [path], regenerating the index in place
         * when [rebuilding] is set (used for the after-profile reopen).
         */
        private fun openEngine(path: String, config: SpecConfig?, rebuilding: Boolean): SearchEngine {
            val ec = EngineConfig(profile(config?.normalize), strategy(config?.strategy))
            return if (rebuilding) SearchEngine.withConfigRebuilding(path, ec)
            else SearchEngine.withConfig(path, ec)
        }

        private fun check(checks: List<Assertion>, engine: SearchEngine, c: ReindexCase, phase: String) {
            for (a in checks) {
                checkAssertion(engine, a, "reindex id=${c.id} [$phase]: ${c.description}")
            }
        }

        /** Runs one assertion's `search` and applies every predicate present on it. */
        private fun checkAssertion(engine: SearchEngine, a: Assertion, context: String) {
            val q = a.search.query
            // A thrown exception fails the test (this also satisfies `expect_no_error`).
            val hits = engine.search(q, a.search.limit.toUInt())

            a.expectedIds?.let { ids ->
                val got = hits.map { it.id }.toSet()
                val want = ids.toSet()
                assertEquals(want, got, "$context query=\"$q\" got=${got.sorted()} want=${want.sorted()}")
            }
            a.expectedCount?.let { count ->
                assertEquals(count, hits.size, "$context query=\"$q\": expected $count hits, got ${hits.size}")
            }
            a.score?.let { kind ->
                assertTrue(hits.isNotEmpty(), "$context query=\"$q\": score predicate needs at least one hit")
                for (h in hits) {
                    when (kind) {
                        "zero" -> assertEquals(0.0, h.score, "$context query=\"$q\": expected score 0, got ${h.score}")
                        "nonzero_finite" -> assertTrue(h.score != 0.0 && h.score.isFinite(),
                            "$context query=\"$q\": expected nonzero finite score, got ${h.score}")
                        else -> error("$context query=\"$q\": unknown score predicate \"$kind\"")
                    }
                }
            }
            if (a.scoresNonDecreasing == true) {
                val scores = hits.map { it.score }
                assertEquals(scores.sorted(), scores, "$context query=\"$q\": scores not non-decreasing: $scores")
            }
        }

        private fun apply(ops: List<IndexOp>, engine: SearchEngine) {
            for (op in ops) {
                when (op.op) {
                    "index" -> engine.index(op.id, op.text ?: "")
                    "remove" -> engine.remove(op.id)
                    else -> error("Unknown op \"${op.op}\" — spec/search.json schema mismatch")
                }
            }
        }

        /** Maps a spec profile key to the FFI enum; absent → loose. */
        fun profile(key: String?): NormalizeProfile = when (key ?: "loose") {
            "loose" -> NormalizeProfile.LOOSE
            "nfkc_case_fold" -> NormalizeProfile.NFKC_CASE_FOLD
            else -> error("unknown normalize profile \"$key\"")
        }

        /** Maps a spec strategy key to the FFI enum; absent → trigram_bm25. */
        fun strategy(key: String?): SearchStrategy = when (key ?: "trigram_bm25") {
            "trigram_bm25" -> SearchStrategy.TRIGRAM_BM25
            "substring" -> SearchStrategy.SUBSTRING
            "prefix" -> SearchStrategy.PREFIX
            "suffix" -> SearchStrategy.SUFFIX
            "all_terms" -> SearchStrategy.ALL_TERMS
            "fuzzy_trigram" -> SearchStrategy.FUZZY_TRIGRAM
            "levenshtein" -> SearchStrategy.LEVENSHTEIN
            "damerau_levenshtein" -> SearchStrategy.DAMERAU_LEVENSHTEIN
            else -> error("unknown search strategy \"$key\"")
        }

        /**
         * Opens an in-memory engine for the given optional config. A
         * `config.options` set selects composable normalization (withOptions);
         * otherwise the named profile path (withConfig) is used.
         */
        fun engine(config: SpecConfig?): SearchEngine = when {
            config?.options != null -> SearchEngine.withOptions(
                ":memory:",
                EngineOptionsConfig(config.options.toFfi(), strategy(config.strategy)),
            )
            config == null -> SearchEngine(":memory:")
            else -> SearchEngine.withConfig(
                ":memory:",
                EngineConfig(profile(config.normalize), strategy(config.strategy)),
            )
        }

        /** Normalizes with a record's composable options if present, else its preset. */
        fun normalized(input: String, options: SpecOptions?, profileKey: String?): String =
            if (options != null) normalizeWithOptions(input, options.toFfi())
            else normalizeWithProfile(input, profile(profileKey))
    }

    @Test fun `normalize spec version is expected`() {
        assertEquals(Spec.EXPECTED_VERSION, Spec.normalize.version)
    }

    @Test fun `search spec version is expected`() {
        assertEquals(Spec.EXPECTED_VERSION, Spec.search.version)
    }

    @ParameterizedTest(name = "{0}: {1}")
    @MethodSource("normalizeCases")
    fun `normalize matches spec`(id: String, description: String, input: String, expected: String, profile: String?, options: SpecOptions?) {
        assertEquals(expected, normalized(input, options, profile), "id=$id: $description")
        // Normalization is a fixed point: applying it to its own output is identity.
        assertEquals(expected, normalized(expected, options, profile), "id=$id not idempotent: $description")
    }

    @ParameterizedTest(name = "{0}")
    @MethodSource("normalizeInequalities")
    fun `normalize inequality holds`(id: String, ineq: NormalizeInequality) {
        val na = normalized(ineq.a, ineq.options, ineq.profile)
        val nb = normalized(ineq.b, ineq.options, ineq.profile)
        assertNotEquals(na, nb,
            "id=$id: ${ineq.description}; a=\"${ineq.a}\"→\"$na\" b=\"${ineq.b}\"→\"$nb\"")
    }

    @ParameterizedTest(name = "{0}")
    @MethodSource("scenarios")
    fun `scenario matches spec`(id: String, s: Scenario) {
        val engine = engine(s.config)
        apply(s.ops, engine)
        for (assertion in s.assertions) {
            checkAssertion(engine, assertion, "scenario id=${s.id}: ${s.description}")
        }
    }

    @ParameterizedTest(name = "{0}")
    @MethodSource("matrixQueries")
    fun `seeded matrix query matches spec`(label: String, m: SeededMatrix, q: QueryExpectation) {
        val engine = engine(m.config)
        apply(m.seed, engine)
        val got = engine.search(q.query, m.limit.toUInt()).map { it.id }.toSet()
        val want = q.expectedIds.toSet()
        assertEquals(want, got,
            "matrix=${m.id} query=\"${q.query}\": ${q.description}; " +
            "got=${got.sorted()} want=${want.sorted()}")
    }

    @Test fun `reindex spec version is expected`() {
        assertEquals(Spec.EXPECTED_VERSION, Spec.reindex.version)
    }

    @ParameterizedTest(name = "{0}")
    @MethodSource("reindexCases")
    fun `reindex matches spec`(id: String, c: ReindexCase) {
        val path = makeTempDbPath()
        try {
            // Index under the before-profile and pin the pre-rebuild behaviour.
            // Close the engine before reopening so the connection is released.
            val before = openEngine(path, c.configBefore, rebuilding = false)
            try {
                apply(c.ops, before)
                check(c.before, before, c, "before")
            } finally {
                before.close()
            }
            // Reopen under the after-profile; a profile change regenerates the
            // index from the retained raw text instead of throwing.
            val after = openEngine(path, c.configAfter, rebuilding = true)
            try {
                check(c.after, after, c, "after")
            } finally {
                after.close()
            }
        } finally {
            cleanup(path)
        }
    }

    @Test fun `loaded reindex cases are non-empty`() {
        assertTrue(Spec.reindex.cases.isNotEmpty(), "reindex.json had zero cases")
    }

    @Test fun `loaded normalize cases are non-empty`() {
        assertTrue(Spec.normalize.cases.isNotEmpty(), "normalize.json had zero cases")
    }

    @Test fun `loaded scenarios are non-empty`() {
        assertTrue(Spec.search.scenarios.isNotEmpty(), "search.json had zero scenarios")
    }
}
