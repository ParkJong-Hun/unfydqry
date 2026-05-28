//! Swappable query algorithms.
//!
//! A [`SearchAlgorithm`] is selected by [`SearchStrategy`] at engine
//! construction. It receives an already-normalized, non-empty query and the
//! live SQLite connection, and returns ranked [`Hit`]s.

use rusqlite::Connection;

use crate::config::SearchStrategy;
use crate::engine::{Hit, SearchError};

mod all_terms;
mod damerau_levenshtein;
mod editdist;
mod fuzzy_trigram;
mod levenshtein;
mod prefix;
mod substring;
mod suffix;
mod trigram_bm25;

/// Runs a query against the index. The query is already normalized and
/// guaranteed non-empty by the engine.
pub trait SearchAlgorithm: Send + Sync {
    fn search(&self, conn: &Connection, query: &str, limit: u32) -> Result<Vec<Hit>, SearchError>;
}

/// Builds the concrete algorithm for a strategy.
pub fn build_strategy(strategy: SearchStrategy) -> Box<dyn SearchAlgorithm> {
    match strategy {
        SearchStrategy::TrigramBm25 => Box::new(trigram_bm25::TrigramBm25),
        SearchStrategy::Substring => Box::new(substring::Substring),
        SearchStrategy::Prefix => Box::new(prefix::Prefix),
        SearchStrategy::Suffix => Box::new(suffix::Suffix),
        SearchStrategy::AllTerms => Box::new(all_terms::AllTerms),
        SearchStrategy::FuzzyTrigram => Box::new(fuzzy_trigram::FuzzyTrigram),
        SearchStrategy::Levenshtein => Box::new(levenshtein::Levenshtein),
        SearchStrategy::DamerauLevenshtein => Box::new(damerau_levenshtein::DamerauLevenshtein),
    }
}
