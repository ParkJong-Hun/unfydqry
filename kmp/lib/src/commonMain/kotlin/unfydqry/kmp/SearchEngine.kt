package unfydqry.kmp

/** A single result returned by [SearchEngine.search]. */
data class Hit(val id: Long, val score: Double)

/** Thrown when the native search engine reports an error. */
class SearchException(message: String) : Exception(message)

/**
 * Cross-platform wrapper around the unfydqry Rust search engine.
 *
 * The actual indexing and search logic lives in the Rust core; this class
 * just routes calls to the platform's native binding.
 *
 * ```kotlin
 * val engine = SearchEngine("/data/search.sqlite")
 * engine.index(1L, "Ｐｙｔｈｏｮ 入門")
 * val hits = engine.search("python")   // → [Hit(id=1, score=…)]
 * engine.close()
 * ```
 */
expect class SearchEngine(dbPath: String) {
    /** Indexes or re-indexes [text] under [id]. */
    fun index(id: Long, text: String)

    /** Removes the entry with [id] from the index. */
    fun remove(id: Long)

    /**
     * Returns at most [limit] results for [query], ordered by relevance.
     * Queries shorter than 3 characters use a LIKE fallback automatically.
     */
    fun search(query: String, limit: Int = 50): List<Hit>

    /** Releases native resources. */
    fun close()
}
