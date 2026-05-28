//! Concrete normalization profiles.

use unicode_normalization::UnicodeNormalization;

use super::{katakana_to_hiragana, Normalizer};

/// Folds case, full-width/half-width, and kana variant (katakana → hiragana).
/// Dakuten / handakuten are preserved (kept distinct).
pub struct Loose;

impl Normalizer for Loose {
    fn normalize(&self, input: &str) -> String {
        input
            .nfkc()
            .map(katakana_to_hiragana)
            .flat_map(char::to_lowercase)
            .collect()
    }
}

/// Folds case and full-width/half-width via NFKC, but leaves kana variants
/// distinct (カ ≠ か). Useful when katakana/hiragana must not be unified.
pub struct NfkcCaseFold;

impl Normalizer for NfkcCaseFold {
    fn normalize(&self, input: &str) -> String {
        input.nfkc().flat_map(char::to_lowercase).collect()
    }
}
