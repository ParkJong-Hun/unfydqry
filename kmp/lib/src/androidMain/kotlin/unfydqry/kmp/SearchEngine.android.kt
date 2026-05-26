package unfydqry.kmp

// ─── Maintenance guide (for iOS developers) ──────────────────────────────────
// This file is the Android counterpart of kmp/ios_bridge/UnfydqryBridge.swift.
// You should rarely need to change it. The only reason to edit it is when the
// native SearchEngine API changes:
//
//   If `uniffi.unfydqry.SearchEngine` gains, removes, or renames a method,
//   this file will FAIL TO COMPILE and the error will point to the exact line.
//   Mirror the same change you made to UnfydqryBridge.swift — the method
//   names and parameters are the same; only the syntax differs.
//
// The Kotlin syntax cheat-sheet for this file:
//   actual fun name(param: Type) = wrap { engine.name(param) }
//                                         ↑ calls the same method on the native engine
// ─────────────────────────────────────────────────────────────────────────────

import uniffi.unfydqry.SearchEngine as UniffiSearchEngine
import uniffi.unfydqry.SearchException as UniffiSearchException

/**
 * Android actual: delegates every call to the JNA-based UniFFI binding.
 *
 * The UniFFI binding lives in the `:unifiedquery` Gradle module and calls
 * into libunfydqry.so through JNA — no logic is duplicated here.
 */
actual class SearchEngine actual constructor(dbPath: String) {

    private val engine: UniffiSearchEngine = try {
        UniffiSearchEngine(dbPath)
    } catch (e: UniffiSearchException) {
        throw SearchException(e.message ?: "open failed")
    }

    actual fun index(id: Long, text: String) = wrap { engine.index(id, text) }

    actual fun remove(id: Long) = wrap { engine.remove(id) }

    actual fun search(query: String, limit: Int): List<Hit> =
        wrap { engine.search(query, limit.toUInt()).map { Hit(it.id, it.score) } }

    actual fun close() = engine.close()

    private fun <T> wrap(block: () -> T): T =
        try {
            block()
        } catch (e: UniffiSearchException) {
            throw SearchException(e.message ?: "search error")
        }
}
