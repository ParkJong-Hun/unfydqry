package unfydqry.kmp

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.runner.RunWith

/**
 * Runs [SearchEngineTest] on Android using a temporary SQLite database.
 *
 * Execute with:
 *   ./gradlew :lib:connectedAndroidTest
 */
@RunWith(AndroidJUnit4::class)
class SearchEngineAndroidTest : SearchEngineTest() {

    override fun createEngine(): SearchEngine {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val dbPath = ctx.cacheDir.resolve("test_${System.nanoTime()}.sqlite").absolutePath
        return SearchEngine(dbPath)
    }
}
