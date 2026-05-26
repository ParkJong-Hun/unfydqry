package unfydqry.kmp

/** A single result returned by [SearchEngine.search]. */
data class Hit(val id: Long, val score: Double)
