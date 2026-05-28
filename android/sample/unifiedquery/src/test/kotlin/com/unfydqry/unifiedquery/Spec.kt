package com.unfydqry.unifiedquery

import com.fasterxml.jackson.annotation.JsonProperty
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import com.fasterxml.jackson.module.kotlin.readValue
import java.io.File
import uniffi.unfydqry.NormalizeOptions

/**
 * Loads normalize.json and search.json from the spec directory once and exposes them
 * via [Spec.normalize] / [Spec.search]. The location of the spec directory is passed
 * in by build.gradle.kts via
 * `tasks.test { systemProperty("unfydqry.spec.dir", ...) }`.
 *
 * Reads the same files as the Swift and Rust suites, so any drift in the Rust
 * core's normalization causes all three test runners to fail at the same `id`
 * simultaneously.
 */
object Spec {
    const val EXPECTED_VERSION: Int = 3

    private val mapper = jacksonObjectMapper()

    private val dir: File = run {
        val path = System.getProperty("unfydqry.spec.dir")
            ?: error("System property `unfydqry.spec.dir` is not set. " +
                "It is wired by android/sample/unifiedquery/build.gradle.kts.")
        File(path).also {
            require(it.isDirectory) { "spec dir does not exist: $path" }
        }
    }

    val normalize: NormalizeSpec = mapper.readValue(dir.resolve("normalize.json"))
    val search: SearchSpecFile = mapper.readValue(dir.resolve("search.json"))
    val reindex: ReindexSpecFile = mapper.readValue(dir.resolve("reindex.json"))
}

// normalize.json

data class NormalizeCase(
    val id: String,
    val description: String,
    val input: String,
    val expected: String,
    val source: String? = null,
    /** Optional normalize profile key (e.g. "nfkc_case_fold"); absent means "loose". */
    val profile: String? = null,
    /** Optional composable steps; when present they override [profile]. */
    val options: SpecOptions? = null,
)

/**
 * The composable normalization steps a spec record may request, mirroring the
 * FFI [NormalizeOptions]. Absent keys default to false.
 */
data class SpecOptions(
    val lowercase: Boolean = false,
    @JsonProperty("kana_fold") val kanaFold: Boolean = false,
    @JsonProperty("fold_diacritics") val foldDiacritics: Boolean = false,
    @JsonProperty("fold_choonpu") val foldChoonpu: Boolean = false,
    @JsonProperty("expand_iteration_marks") val expandIterationMarks: Boolean = false,
    @JsonProperty("normalize_hyphens") val normalizeHyphens: Boolean = false,
    @JsonProperty("strip_digit_grouping") val stripDigitGrouping: Boolean = false,
    @JsonProperty("collapse_whitespace") val collapseWhitespace: Boolean = false,
) {
    fun toFfi(): NormalizeOptions = NormalizeOptions(
        lowercase = lowercase,
        kanaFold = kanaFold,
        foldDiacritics = foldDiacritics,
        foldChoonpu = foldChoonpu,
        expandIterationMarks = expandIterationMarks,
        normalizeHyphens = normalizeHyphens,
        stripDigitGrouping = stripDigitGrouping,
        collapseWhitespace = collapseWhitespace,
    )
}

/**
 * Optional per-scenario engine configuration. Absent fields fall back to the
 * original behaviour (loose + trigram_bm25). When [options] is present it
 * selects composable normalization instead of the named [normalize] profile.
 */
data class SpecConfig(
    val normalize: String? = null,
    val strategy: String? = null,
    val options: SpecOptions? = null,
)

/** A pair that must normalize to *distinct* keys (e.g. dakuten が vs. unvoiced か). */
data class NormalizeInequality(
    val id: String,
    val description: String,
    val a: String,
    val b: String,
    val profile: String? = null,
    /** Optional composable steps; when present they override [profile]. */
    val options: SpecOptions? = null,
)

data class NormalizeSpec(
    val version: Int,
    val cases: List<NormalizeCase>,
    val inequalities: List<NormalizeInequality> = emptyList(),
)

// search.json

data class IndexOp(
    val op: String,
    val id: Long,
    val text: String? = null,
)

data class SearchSpec(
    val query: String,
    val limit: Long,
)

/**
 * One search plus the predicates to assert on its result. Every predicate is
 * optional; the loader applies whichever are present (see `spec/README.md`).
 */
data class Assertion(
    val search: SearchSpec,
    @JsonProperty("expected_ids") val expectedIds: List<Long>? = null,
    @JsonProperty("expected_count") val expectedCount: Int? = null,
    val score: String? = null,
    @JsonProperty("scores_non_decreasing") val scoresNonDecreasing: Boolean? = null,
    @JsonProperty("expect_no_error") val expectNoError: Boolean? = null,
)

data class Scenario(
    val id: String,
    val description: String,
    val ops: List<IndexOp>,
    val assertions: List<Assertion>,
    val config: SpecConfig? = null,
)

data class QueryExpectation(
    val query: String,
    val description: String,
    @JsonProperty("expected_ids") val expectedIds: List<Long>,
)

data class SeededMatrix(
    val id: String,
    val description: String,
    val limit: Long,
    val seed: List<IndexOp>,
    val queries: List<QueryExpectation>,
    val config: SpecConfig? = null,
)

data class SearchSpecFile(
    val version: Int,
    val scenarios: List<Scenario>,
    @JsonProperty("seeded_matrices") val seededMatrices: List<SeededMatrix>,
)

// reindex.json

/**
 * One regeneration case: index under [configBefore], reopen under [configAfter]
 * (via `withConfigRebuilding`), and assert search results before and after the
 * rebuild. Reuses [IndexOp] for `ops` and [Assertion] for the before/after checks.
 */
data class ReindexCase(
    val id: String,
    val description: String,
    @JsonProperty("config_before") val configBefore: SpecConfig? = null,
    @JsonProperty("config_after") val configAfter: SpecConfig? = null,
    val ops: List<IndexOp>,
    val before: List<Assertion>,
    val after: List<Assertion>,
)

data class ReindexSpecFile(
    val version: Int,
    val cases: List<ReindexCase>,
)
