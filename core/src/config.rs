//! Behaviour selectors that the host binding passes into the engine.
//!
//! The *implementations* of each profile / strategy live in Rust (see
//! `normalize/` and `search/`); these enums only let the binding pick which
//! combination is active. Consistency across platforms therefore still holds
//! "by construction" for any given `EngineConfig`.

/// Which normalization pipeline runs at index and query time.
///
/// `Loose` is the original behaviour (NFKC → katakana→hiragana → lowercase).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum NormalizeProfile {
    Loose,
    /// NFKC + lowercase only; kana variants are kept distinct.
    NfkcCaseFold,
}

impl NormalizeProfile {
    /// Stable identifier persisted in the `meta` table and used in spec JSON.
    pub fn as_key(self) -> &'static str {
        match self {
            NormalizeProfile::Loose => "loose",
            NormalizeProfile::NfkcCaseFold => "nfkc_case_fold",
        }
    }
}

/// Which query algorithm `SearchEngine::search` uses.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SearchStrategy {
    /// Trigram FTS5 + bm25, with a LIKE fallback for queries shorter than 3 chars.
    TrigramBm25,
    /// Substring match (`LIKE '%q%'`) for every query.
    Substring,
    /// Prefix match (`LIKE 'q%'`) for every query.
    Prefix,
}

/// The combination the host selects when constructing an engine.
#[derive(Debug, Clone, uniffi::Record)]
pub struct EngineConfig {
    pub normalize: NormalizeProfile,
    pub strategy: SearchStrategy,
}

impl Default for EngineConfig {
    /// The original behaviour, used by `SearchEngine::new(db_path)`.
    fn default() -> Self {
        Self {
            normalize: NormalizeProfile::Loose,
            strategy: SearchStrategy::TrigramBm25,
        }
    }
}
