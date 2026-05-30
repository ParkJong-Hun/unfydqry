//! Character-trigram set similarity (Jaccard).
//!
//! Tolerates typos without computing a full edit distance: the query and each
//! document are reduced to their sets of character trigrams, and documents whose
//! Jaccard similarity to the query clears a threshold are returned, ranked by
//! `1 − similarity` (so an exact match scores `0.0`).

use std::collections::HashSet;

use rusqlite::Connection;

use super::SearchAlgorithm;
use crate::engine::{Hit, SearchError};

/// Minimum Jaccard similarity for a document to be considered a match.
const THRESHOLD: f64 = 0.3;

fn trigrams(s: &str) -> HashSet<String> {
    let chars: Vec<char> = s.chars().collect();
    let mut set = HashSet::new();
    if chars.len() < 3 {
        if !chars.is_empty() {
            set.insert(chars.iter().collect());
        }
        return set;
    }
    for w in chars.windows(3) {
        set.insert(w.iter().collect());
    }
    set
}

fn jaccard(a: &HashSet<String>, b: &HashSet<String>) -> f64 {
    let inter = a.intersection(b).count();
    let union = a.len() + b.len() - inter;
    if union == 0 {
        0.0
    } else {
        inter as f64 / union as f64
    }
}

pub struct FuzzyTrigram;

impl SearchAlgorithm for FuzzyTrigram {
    fn search(&self, conn: &Connection, q: &str, limit: u32) -> Result<Vec<Hit>, SearchError> {
        let qset = trigrams(q);
        if qset.is_empty() {
            return Ok(Vec::new());
        }

        let mut stmt = conn.prepare("SELECT id, norm FROM entries")?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))?;

        let mut hits: Vec<Hit> = Vec::new();
        for row in rows {
            let (id, norm) = row?;
            let sim = jaccard(&qset, &trigrams(&norm));
            if sim >= THRESHOLD {
                hits.push(Hit {
                    id,
                    score: 1.0 - sim,
                });
            }
        }
        // Most similar first; break ties by id for a deterministic order.
        hits.sort_by(|a, b| {
            a.score
                .partial_cmp(&b.score)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then(a.id.cmp(&b.id))
        });
        hits.truncate(limit as usize);
        Ok(hits)
    }
}
