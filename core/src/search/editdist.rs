//! Edit-distance primitives shared by the typo-tolerant strategies, plus the
//! common "min distance to any word in the doc" scan.
//!
//! Both distances operate on `&[char]` (Unicode scalar values) so that Japanese
//! text is compared per-codepoint, not per-byte. Hand-rolled on purpose: no
//! external crate is needed, and the result stays deterministic across platforms.

use rusqlite::Connection;

use crate::engine::{Hit, SearchError};

/// Classic Levenshtein distance (insert / delete / substitute), two-row DP.
pub fn levenshtein(a: &[char], b: &[char]) -> usize {
    let (n, m) = (a.len(), b.len());
    if n == 0 {
        return m;
    }
    if m == 0 {
        return n;
    }
    let mut prev: Vec<usize> = (0..=m).collect();
    let mut curr = vec![0usize; m + 1];
    for i in 1..=n {
        curr[0] = i;
        for j in 1..=m {
            let cost = usize::from(a[i - 1] != b[j - 1]);
            curr[j] = (prev[j] + 1).min(curr[j - 1] + 1).min(prev[j - 1] + cost);
        }
        std::mem::swap(&mut prev, &mut curr);
    }
    prev[m]
}

/// Optimal String Alignment distance: Levenshtein plus a cost-1 swap of two
/// adjacent characters (each substring edited at most once).
pub fn osa(a: &[char], b: &[char]) -> usize {
    let (n, m) = (a.len(), b.len());
    if n == 0 {
        return m;
    }
    if m == 0 {
        return n;
    }
    let mut d = vec![vec![0usize; m + 1]; n + 1];
    for (i, row) in d.iter_mut().enumerate() {
        row[0] = i;
    }
    for (j, cell) in d[0].iter_mut().enumerate() {
        *cell = j;
    }
    for i in 1..=n {
        for j in 1..=m {
            let cost = usize::from(a[i - 1] != b[j - 1]);
            let mut v = (d[i - 1][j] + 1)
                .min(d[i][j - 1] + 1)
                .min(d[i - 1][j - 1] + cost);
            if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                v = v.min(d[i - 2][j - 2] + 1);
            }
            d[i][j] = v;
        }
    }
    d[n][m]
}

/// Allowed edits scale with query length: 1 per 4 characters, at least 1.
fn max_distance(q_chars: usize) -> usize {
    (q_chars / 4).max(1)
}

/// Scans every entry, takes the smallest distance between the query and any
/// whitespace-separated word of the document, and keeps docs within the
/// length-scaled threshold. Ranked by distance (smaller = better), then id.
pub fn word_fuzzy_search(
    conn: &Connection,
    q: &str,
    limit: u32,
    dist: fn(&[char], &[char]) -> usize,
) -> Result<Vec<Hit>, SearchError> {
    let qchars: Vec<char> = q.chars().collect();
    let threshold = max_distance(qchars.len());

    let mut stmt = conn.prepare("SELECT id, norm FROM entries")?;
    let rows = stmt.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))?;

    let mut hits: Vec<Hit> = Vec::new();
    for row in rows {
        let (id, norm) = row?;
        let best = norm
            .split_whitespace()
            .map(|w| dist(&qchars, &w.chars().collect::<Vec<char>>()))
            .min();
        if let Some(best) = best {
            if best <= threshold {
                hits.push(Hit {
                    id,
                    score: best as f64,
                });
            }
        }
    }
    hits.sort_by(|a, b| {
        a.score
            .partial_cmp(&b.score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(a.id.cmp(&b.id))
    });
    hits.truncate(limit as usize);
    Ok(hits)
}
