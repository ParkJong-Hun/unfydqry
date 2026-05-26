@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package unfydqry.kmp

import kotlinx.cinterop.ObjCObjectVar
import kotlinx.cinterop.alloc
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import platform.Foundation.NSError
import unfydqry_bridge.UnfydqryHit
import unfydqry_bridge.UnfydqrySearchEngine

/**
 * iOS actual: delegates every call to the @objc Swift bridge
 * (kmp/ios_bridge/UnfydqryBridge.swift) which in turn calls
 * UnifiedQuery.SearchEngine → Rust core.
 *
 * The bridge is imported via Kotlin/Native cinterop; you maintain only
 * UnfydqryBridge.swift — the ObjC header is generated from it.
 */
actual class SearchEngine actual constructor(dbPath: String) {

    private val bridge: UnfydqrySearchEngine = memScoped {
        val err = alloc<ObjCObjectVar<NSError?>>()
        UnfydqrySearchEngine.createWithDbPath(dbPath, error = err.ptr)
            ?: throw SearchException(err.value?.localizedDescription ?: "open failed")
    }

    actual fun index(id: Long, text: String): Unit = memScoped {
        val err = alloc<ObjCObjectVar<NSError?>>()
        val ok = bridge.indexWithId(id, text = text, error = err.ptr)
        if (!ok) throw SearchException(err.value?.localizedDescription ?: "index failed")
    }

    actual fun remove(id: Long): Unit = memScoped {
        val err = alloc<ObjCObjectVar<NSError?>>()
        val ok = bridge.removeWithId(id, error = err.ptr)
        if (!ok) throw SearchException(err.value?.localizedDescription ?: "remove failed")
    }

    actual fun search(query: String, limit: Int): List<Hit> = memScoped {
        val err = alloc<ObjCObjectVar<NSError?>>()
        val raw = bridge.searchWithQuery(query, limit = limit, error = err.ptr)
            ?: throw SearchException(err.value?.localizedDescription ?: "search failed")
        raw.filterIsInstance<UnfydqryHit>().map { Hit(it.hitId, it.score) }
    }

    actual fun close() {
        // UnfydqrySearchEngine is reference-counted by Kotlin/Native's ObjC interop.
    }
}
