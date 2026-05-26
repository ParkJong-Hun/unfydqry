package unfydqry.kmp.sample

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import unfydqry.kmp.SearchEngine

private data class Record(val id: Long, val text: String)

private val seed = listOf(
    Record(1L, "東京タワー"),
    Record(2L, "とうきょうスカイツリー"),
    Record(3L, "ﾄｳｷｮｳ ﾄﾞｰﾑ"),
    Record(4L, "Osaka 城"),
    Record(5L, "がっこう ぐらし"),
    Record(6L, "かっこう の歌"),
    Record(7L, "Ｐｙｔｈｏｮ 入門"),
    Record(8L, "ぱんだ と ﾊﾟﾝﾀﾞ"),
)

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val dbPath = filesDir.resolve("search_index.sqlite").absolutePath
        val engine = SearchEngine(dbPath)
        seed.forEach { engine.index(it.id, it.text) }
        val store = seed.associateBy { it.id }

        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    SearchScreen(engine = engine, store = store)
                }
            }
        }
    }
}

@Composable
private fun SearchScreen(engine: SearchEngine, store: Map<Long, Record>) {
    var query by remember { mutableStateOf("") }
    var status by remember { mutableStateOf("indexed ${seed.size} docs") }
    val results = remember { mutableStateListOf<Record>() }

    Column(modifier = Modifier.fillMaxSize().padding(16.dp)) {
        OutlinedTextField(
            value = query,
            onValueChange = { query = it },
            label = { Text("検索クエリ") },
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(8.dp))
        Button(onClick = {
            val hits = engine.search(query)
            val records = hits.mapNotNull { store[it.id] }
            results.clear()
            results.addAll(records)
            status = "hits: ${records.size}"
        }) { Text("検索") }
        Spacer(Modifier.height(8.dp))
        Text(status, style = MaterialTheme.typography.bodySmall)
        Spacer(Modifier.height(8.dp))
        LazyColumn(modifier = Modifier.fillMaxSize()) {
            items(results, key = { it.id }) { record ->
                Column(modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                    Text(record.text, style = MaterialTheme.typography.bodyLarge)
                    Text("id=${record.id}", style = MaterialTheme.typography.bodySmall)
                }
            }
        }
    }
}
