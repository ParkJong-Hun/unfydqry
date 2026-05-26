package unfydqry.kmp

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Spec-driven conformance tests that run on every platform target.
 *
 * These tests mirror the scenarios in the Rust / Swift / Android test suites
 * so any divergence in the Rust core's normalisation breaks all targets at once.
 *
 * Subclass this in each platform's test source set and implement [createEngine].
 */
abstract class SearchEngineTest {

    /** Create an isolated engine for each test (use an in-memory or temp path). */
    abstract fun createEngine(): SearchEngine

    // ── Normalisation ────────────────────────────────────────────────────────

    @Test
    fun katakanaQueryHitsHiraganaDoc() {
        val e = createEngine()
        e.index(1, "とうきょうタワー")
        assertEquals(listOf(1L), e.search("トウキョウ").map(Hit::id))
        e.close()
    }

    @Test
    fun hiraganaQueryHitsKanjiMixedDoc() {
        val e = createEngine()
        e.index(42, "東京 ﾄｳｷｮｳ タワー")
        assertEquals(listOf(42L), e.search("とうきょう").map(Hit::id))
        e.close()
    }

    @Test
    fun dakutenIsDistinguished() {
        val e = createEngine()
        e.index(1, "がっこう")
        e.index(2, "かっこう")
        assertEquals(listOf(1L), e.search("がっこう").map(Hit::id))
        e.close()
    }

    @Test
    fun shortQueryUsesLikeFallback() {
        val e = createEngine()
        e.index(1, "がっこう")
        e.index(2, "かばん")
        assertEquals(listOf(1L), e.search("がっ").map(Hit::id))
        e.close()
    }

    @Test
    fun fullwidthAlphaFolded() {
        val e = createEngine()
        e.index(1, "Ｐｙｔｈｏｮ 入門")
        assertEquals(listOf(1L), e.search("python").map(Hit::id))
        e.close()
    }

    // ── Lifecycle ────────────────────────────────────────────────────────────

    @Test
    fun removeThenSearchReturnsEmpty() {
        val e = createEngine()
        e.index(1, "とうきょう")
        e.remove(1)
        assertTrue(e.search("とうきょう").isEmpty())
        e.close()
    }

    @Test
    fun reindexUpdatesText() {
        val e = createEngine()
        e.index(1, "おおさか")
        e.index(1, "なごや")
        assertTrue(e.search("おおさか").isEmpty())
        assertEquals(listOf(1L), e.search("なごや").map(Hit::id))
        e.close()
    }

    @Test
    fun emptyQueryReturnsEmpty() {
        val e = createEngine()
        e.index(1, "anything")
        assertTrue(e.search("").isEmpty())
        e.close()
    }

    @Test
    fun quoteInQueryIsEscaped() {
        val e = createEngine()
        e.index(1, """say "hello" world""")
        assertEquals(listOf(1L), e.search(""""hello"""").map(Hit::id))
        e.close()
    }

    // ── Limit ────────────────────────────────────────────────────────────────

    @Test
    fun limitIsRespected() {
        val e = createEngine()
        repeat(10) { i -> e.index(i.toLong(), "とうきょう item$i") }
        assertTrue(e.search("とうきょう", limit = 3).size <= 3)
        e.close()
    }
}
