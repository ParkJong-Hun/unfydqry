use std::sync::{Arc, Mutex};

use rusqlite::{params, Connection, OptionalExtension};

use crate::config::EngineConfig;
use crate::normalize::{build_normalizer, Normalizer};
use crate::search::{build_strategy, SearchAlgorithm};

/// A single search result: the stable `id` the host indexed under, plus a
/// relevance `score`.
///
/// The engine returns only ids and scores — never the document text — so the
/// host re-fetches the full record from its own source-of-truth store.
#[derive(Debug, Clone, uniffi::Record)]
pub struct Hit {
    /// The id the document was indexed under (see `index`).
    pub id: i64,
    /// Relevance score. For ranked strategies a smaller value is a better
    /// match (bm25 for `trigramBm25`, `1 − similarity` for `fuzzyTrigram`,
    /// edit distance for the Levenshtein strategies). Unranked strategies
    /// (`substring`, `prefix`, `suffix`, `allTerms`) always report `0.0`.
    pub score: f64,
}

/// An error surfaced across the FFI boundary by `SearchEngine`.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum SearchError {
    /// An underlying SQLite / storage failure; the associated string is its
    /// message.
    #[error("{0}")]
    Db(String),
    /// The on-disk index was built with a different normalization profile
    /// than the one requested. Indexed text is profile-specific, so the index
    /// must be rebuilt to change profiles. `stored` is the profile recorded in
    /// the index; `requested` is the one just asked for.
    #[error(
        "index built with normalize profile {stored}, requested {requested}; rebuild required"
    )]
    ConfigMismatch { stored: String, requested: String },
}

impl From<rusqlite::Error> for SearchError {
    fn from(e: rusqlite::Error) -> Self {
        SearchError::Db(e.to_string())
    }
}

/// A persistent full-text search index backed by SQLite.
///
/// Create one with `SearchEngine(dbPath:)` for the default behaviour, or
/// `SearchEngine.withConfig(dbPath:config:)` to choose a normalization profile
/// and a search strategy. Add or update documents with `index`, drop them with
/// `remove`, and query with `search`. The instance is safe to share across
/// threads.
#[derive(uniffi::Object)]
pub struct SearchEngine {
    conn: Mutex<Connection>,
    normalizer: Box<dyn Normalizer>,
    strategy: Box<dyn SearchAlgorithm>,
}

#[uniffi::export]
impl SearchEngine {
    /// Opens the index with the default behaviour (loose normalization +
    /// trigram/bm25). Kept for backward compatibility.
    #[uniffi::constructor]
    pub fn new(db_path: String) -> Result<Arc<Self>, SearchError> {
        Self::with_config(db_path, EngineConfig::default())
    }

    /// Opens the index with a host-selected combination of normalization
    /// profile and search strategy.
    #[uniffi::constructor(name = "withConfig")]
    pub fn with_config(db_path: String, config: EngineConfig) -> Result<Arc<Self>, SearchError> {
        let conn = Connection::open(&db_path)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.execute_batch(
            "CREATE VIRTUAL TABLE IF NOT EXISTS docs
                 USING fts5(norm, tokenize='trigram');
             CREATE TABLE IF NOT EXISTS entries(
                 id INTEGER PRIMARY KEY, norm TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS meta(
                 key TEXT PRIMARY KEY, value TEXT NOT NULL);",
        )?;
        // Used to detect when the index needs to be rebuilt after a future change to a profile.
        conn.execute(
            "INSERT OR IGNORE INTO meta(key, value) VALUES ('index_version', '1')",
            [],
        )?;

        // The normalized text stored in the index depends on the normalize
        // profile, so an index built with one profile cannot be queried with
        // another. Stamp the profile and reject a mismatch.
        let requested = config.normalize.as_key();
        let indexed: i64 = conn.query_row("SELECT COUNT(*) FROM entries", [], |r| r.get(0))?;
        if indexed == 0 {
            // No indexed data → safe to (re)stamp with the requested profile.
            conn.execute(
                "INSERT OR REPLACE INTO meta(key, value) VALUES ('normalize_profile', ?1)",
                params![requested],
            )?;
        } else {
            let stored: Option<String> = conn
                .query_row(
                    "SELECT value FROM meta WHERE key = 'normalize_profile'",
                    [],
                    |r| r.get(0),
                )
                .optional()?;
            // A pre-existing index without the key was built with the loose profile.
            let stored = stored.unwrap_or_else(|| "loose".to_string());
            if stored != requested {
                return Err(SearchError::ConfigMismatch {
                    stored,
                    requested: requested.to_string(),
                });
            }
            conn.execute(
                "INSERT OR IGNORE INTO meta(key, value) VALUES ('normalize_profile', ?1)",
                params![requested],
            )?;
        }

        Ok(Arc::new(Self {
            conn: Mutex::new(conn),
            normalizer: build_normalizer(config.normalize),
            strategy: build_strategy(config.strategy),
        }))
    }

    /// Adds, or replaces, the document stored under `id`.
    ///
    /// The host passes raw `text`; normalization runs inside the engine, so the
    /// engine's profile is applied identically to indexed text and to queries.
    /// Calling `index` again with an existing `id` overwrites that document.
    pub fn index(&self, id: i64, text: String) -> Result<(), SearchError> {
        let norm = self.normalizer.normalize(&text);
        let conn = self.conn.lock().unwrap();
        conn.execute("DELETE FROM docs WHERE rowid=?1", params![id])?;
        conn.execute(
            "INSERT INTO docs(rowid, norm) VALUES (?1, ?2)",
            params![id, &norm],
        )?;
        conn.execute(
            "INSERT OR REPLACE INTO entries(id, norm) VALUES (?1, ?2)",
            params![id, &norm],
        )?;
        Ok(())
    }

    /// Removes the document stored under `id`. A no-op if no such document
    /// exists.
    pub fn remove(&self, id: i64) -> Result<(), SearchError> {
        let conn = self.conn.lock().unwrap();
        conn.execute("DELETE FROM docs WHERE rowid=?1", params![id])?;
        conn.execute("DELETE FROM entries WHERE id=?1", params![id])?;
        Ok(())
    }

    /// Searches the index and returns at most `limit` hits.
    ///
    /// The `query` is normalized with the engine's profile and then matched
    /// using the engine's strategy. A query that is empty — or only whitespace
    /// once normalized — returns no hits. Ordering and scoring depend on the
    /// strategy (see `Hit.score`).
    pub fn search(&self, query: String, limit: u32) -> Result<Vec<Hit>, SearchError> {
        let q = self.normalizer.normalize(&query);
        if q.is_empty() {
            return Ok(Vec::new());
        }
        let conn = self.conn.lock().unwrap();
        self.strategy.search(&conn, &q, limit)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{NormalizeProfile, SearchStrategy};

    fn fresh() -> Arc<SearchEngine> {
        // In-memory DB (independent per test).
        SearchEngine::new(":memory:".to_string()).expect("open")
    }

    #[test]
    fn katakana_query_hits_hiragana_doc() {
        let e = fresh();
        e.index(1, "とうきょうタワー".into()).unwrap();
        let hits = e.search("トウキョウ".into(), 10).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].id, 1);
    }

    #[test]
    fn hiragana_query_hits_kanji_mixed_doc() {
        let e = fresh();
        e.index(42, "東京 ﾄｳｷｮｳ タワー".into()).unwrap();
        let hits = e.search("とうきょう".into(), 10).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].id, 42);
    }

    #[test]
    fn dakuten_is_distinguished() {
        let e = fresh();
        e.index(1, "がっこう".into()).unwrap();
        e.index(2, "かっこう".into()).unwrap();
        let hits = e.search("がっこう".into(), 10).unwrap();
        let ids: Vec<i64> = hits.iter().map(|h| h.id).collect();
        assert_eq!(ids, vec![1]);
    }

    #[test]
    fn short_query_uses_like_fallback() {
        // A 2-char query cannot be served by trigram, so it must take the LIKE path.
        let e = fresh();
        e.index(1, "がっこう".into()).unwrap();
        e.index(2, "かばん".into()).unwrap();
        let hits = e.search("がっ".into(), 10).unwrap();
        let ids: Vec<i64> = hits.iter().map(|h| h.id).collect();
        assert_eq!(ids, vec![1]);
    }

    #[test]
    fn fullwidth_alpha_folded() {
        let e = fresh();
        e.index(1, "Ｐｙｔｈｏｎ 入門".into()).unwrap();
        let hits = e.search("python".into(), 10).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].id, 1);
    }

    #[test]
    fn remove_then_search_returns_none() {
        let e = fresh();
        e.index(1, "とうきょう".into()).unwrap();
        e.remove(1).unwrap();
        let hits = e.search("とうきょう".into(), 10).unwrap();
        assert!(hits.is_empty());
    }

    #[test]
    fn reindex_updates_text() {
        let e = fresh();
        e.index(1, "おおさか".into()).unwrap();
        e.index(1, "なごや".into()).unwrap();
        assert!(e.search("おおさか".into(), 10).unwrap().is_empty());
        let hits = e.search("なごや".into(), 10).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].id, 1);
    }

    #[test]
    fn quote_in_query_is_escaped() {
        let e = fresh();
        e.index(1, r#"say "hello" world"#.into()).unwrap();
        let hits = e.search(r#""hello""#.into(), 10).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].id, 1);
    }

    #[test]
    fn empty_query_returns_empty() {
        let e = fresh();
        e.index(1, "anything".into()).unwrap();
        assert!(e.search("".into(), 10).unwrap().is_empty());
    }

    // --- new behaviour: configurable strategy / profile ---

    fn fresh_with(config: EngineConfig) -> Arc<SearchEngine> {
        SearchEngine::with_config(":memory:".to_string(), config).expect("open")
    }

    #[test]
    fn prefix_strategy_matches_only_prefix() {
        let e = fresh_with(EngineConfig {
            normalize: NormalizeProfile::Loose,
            strategy: SearchStrategy::Prefix,
        });
        e.index(1, "tokyo tower".into()).unwrap();
        e.index(2, "old tokyo".into()).unwrap();
        let ids: Vec<i64> = e
            .search("tokyo".into(), 10)
            .unwrap()
            .iter()
            .map(|h| h.id)
            .collect();
        assert_eq!(ids, vec![1]);
    }

    #[test]
    fn substring_strategy_matches_anywhere_even_short() {
        let e = fresh_with(EngineConfig {
            normalize: NormalizeProfile::Loose,
            strategy: SearchStrategy::Substring,
        });
        e.index(1, "abcdef".into()).unwrap();
        // 2-char query in the middle: substring strategy must still find it.
        let ids: Vec<i64> = e
            .search("cd".into(), 10)
            .unwrap()
            .iter()
            .map(|h| h.id)
            .collect();
        assert_eq!(ids, vec![1]);
    }

    #[test]
    fn suffix_strategy_matches_only_trailing() {
        let e = fresh_with(EngineConfig {
            normalize: NormalizeProfile::Loose,
            strategy: SearchStrategy::Suffix,
        });
        e.index(1, "tokyo tower".into()).unwrap();
        e.index(2, "tower crane".into()).unwrap();
        // Only the doc that ENDS with "tower" matches; mid-string "tower" must not.
        let ids: Vec<i64> = e
            .search("tower".into(), 10)
            .unwrap()
            .iter()
            .map(|h| h.id)
            .collect();
        assert_eq!(ids, vec![1]);
    }

    #[test]
    fn all_terms_strategy_requires_every_term_any_order() {
        let e = fresh_with(EngineConfig {
            normalize: NormalizeProfile::Loose,
            strategy: SearchStrategy::AllTerms,
        });
        e.index(1, "tokyo sky tree".into()).unwrap();
        e.index(2, "tokyo tower".into()).unwrap();
        e.index(3, "sky high".into()).unwrap();
        // "sky tokyo": both terms present in doc 1 (order-independent); doc 2 lacks
        // "sky", doc 3 lacks "tokyo".
        let ids: Vec<i64> = e
            .search("sky tokyo".into(), 10)
            .unwrap()
            .iter()
            .map(|h| h.id)
            .collect();
        assert_eq!(ids, vec![1]);
        // Contrast with Substring, which would need the literal run "sky tokyo".
        let sub = fresh_with(EngineConfig {
            normalize: NormalizeProfile::Loose,
            strategy: SearchStrategy::Substring,
        });
        sub.index(1, "tokyo sky tree".into()).unwrap();
        assert!(sub.search("sky tokyo".into(), 10).unwrap().is_empty());
    }

    #[test]
    fn fuzzy_trigram_tolerates_a_typo_and_ranks_exact_first() {
        let e = fresh_with(EngineConfig {
            normalize: NormalizeProfile::Loose,
            strategy: SearchStrategy::FuzzyTrigram,
        });
        e.index(1, "international".into()).unwrap();
        e.index(2, "supercalifragilistic".into()).unwrap();
        // One-character typo ("...nai" instead of "...nal") still finds doc 1,
        // and the unrelated doc shares no trigrams so it is filtered out.
        let ids: Vec<i64> = e
            .search("internationai".into(), 10)
            .unwrap()
            .iter()
            .map(|h| h.id)
            .collect();
        assert_eq!(ids, vec![1]);
        // An exact query scores 0.0 (similarity 1.0).
        let exact = e.search("international".into(), 10).unwrap();
        assert_eq!(exact[0].id, 1);
        assert!(exact[0].score.abs() < 1e-9);
    }

    #[test]
    fn levenshtein_matches_one_char_typo() {
        let e = fresh_with(EngineConfig {
            normalize: NormalizeProfile::Loose,
            strategy: SearchStrategy::Levenshtein,
        });
        e.index(1, "tokyo tower".into()).unwrap();
        e.index(2, "osaka castle".into()).unwrap();
        // "tokio" is 1 substitution from the word "tokyo"; threshold for a
        // 5-char query is 1, so it matches doc 1 only.
        let ids: Vec<i64> = e
            .search("tokio".into(), 10)
            .unwrap()
            .iter()
            .map(|h| h.id)
            .collect();
        assert_eq!(ids, vec![1]);
    }

    #[test]
    fn damerau_matches_transposition_that_levenshtein_misses() {
        // "tokoy" is a single adjacent transposition of "tokyo": OSA distance 1,
        // plain Levenshtein distance 2. With the 5-char threshold (=1), only the
        // Damerau strategy matches.
        let lev = fresh_with(EngineConfig {
            normalize: NormalizeProfile::Loose,
            strategy: SearchStrategy::Levenshtein,
        });
        lev.index(1, "tokyo tower".into()).unwrap();
        assert!(lev.search("tokoy".into(), 10).unwrap().is_empty());

        let dl = fresh_with(EngineConfig {
            normalize: NormalizeProfile::Loose,
            strategy: SearchStrategy::DamerauLevenshtein,
        });
        dl.index(1, "tokyo tower".into()).unwrap();
        let ids: Vec<i64> = dl
            .search("tokoy".into(), 10)
            .unwrap()
            .iter()
            .map(|h| h.id)
            .collect();
        assert_eq!(ids, vec![1]);
    }

    #[test]
    fn nfkc_case_fold_keeps_katakana_distinct() {
        let e = fresh_with(EngineConfig {
            normalize: NormalizeProfile::NfkcCaseFold,
            strategy: SearchStrategy::Substring,
        });
        e.index(1, "カタカナ".into()).unwrap();
        // Hiragana query must NOT hit the katakana doc under this profile.
        assert!(e.search("かたかな".into(), 10).unwrap().is_empty());
        assert_eq!(e.search("カタカナ".into(), 10).unwrap().len(), 1);
    }

    #[test]
    fn profile_mismatch_on_reopen_errors() {
        let dir = std::env::temp_dir();
        let path = dir.join(format!("unfydqry_test_{}.sqlite", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let p = path.to_string_lossy().to_string();

        {
            let e = SearchEngine::new(p.clone()).expect("open loose");
            e.index(1, "とうきょう".into()).unwrap();
        }
        // Reopen the same indexed DB with a different normalize profile.
        let reopened = SearchEngine::with_config(
            p.clone(),
            EngineConfig {
                normalize: NormalizeProfile::NfkcCaseFold,
                strategy: SearchStrategy::TrigramBm25,
            },
        );
        assert!(
            matches!(reopened, Err(SearchError::ConfigMismatch { .. })),
            "must reject profile mismatch"
        );
        drop(reopened);

        // Reopening with the original (loose) profile still works.
        SearchEngine::new(p.clone()).expect("reopen loose");

        let _ = std::fs::remove_file(&path);
    }
}
