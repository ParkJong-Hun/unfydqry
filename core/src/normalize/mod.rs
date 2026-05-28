//! Swappable text normalization.
//!
//! A [`Normalizer`] is selected by [`NormalizeProfile`] and runs at both index
//! and query time. The per-character building blocks below are shared by the
//! concrete profiles in [`profiles`].

use crate::config::NormalizeProfile;

mod profiles;

/// Folds raw host text into the form stored in the index and matched against.
pub trait Normalizer: Send + Sync {
    fn normalize(&self, input: &str) -> String;
}

/// Maps a Katakana code point to its Hiragana counterpart; other chars pass through.
///
/// Dakuten-marked forms (ガ=U+30AC, ヴ=U+30F4 etc.) also map correctly via -0x60,
/// so they stay distinct from their base forms.
fn katakana_to_hiragana(c: char) -> char {
    match c as u32 {
        0x30A1..=0x30F6 => char::from_u32(c as u32 - 0x60).unwrap_or(c),
        _ => c,
    }
}

/// Builds the concrete normalizer for a profile.
pub fn build_normalizer(profile: NormalizeProfile) -> Box<dyn Normalizer> {
    match profile {
        NormalizeProfile::Loose => Box::new(profiles::Loose),
        NormalizeProfile::NfkcCaseFold => Box::new(profiles::NfkcCaseFold),
    }
}

/// Convenience for callers that just want a one-shot normalization.
pub fn normalize(input: &str, profile: NormalizeProfile) -> String {
    build_normalizer(profile).normalize(input)
}

/// The original loose normalization (NFKC → katakana→hiragana → lowercase).
/// Retained for backward compatibility and used by the spec conformance tests.
pub fn normalize_loose(input: &str) -> String {
    normalize(input, NormalizeProfile::Loose)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Verifies the trace table from design doc §2.2 verbatim.
    #[test]
    fn dakuten_kept_kana_unified() {
        // With dakuten, everything collapses to「が」.
        for s in ["ガ", "が", "ｶﾞ"] {
            assert_eq!(normalize_loose(s), "が", "input={s}");
        }
        // Without dakuten, everything collapses to「か」 (a different key from「が」).
        for s in ["カ", "か", "ｶ"] {
            assert_eq!(normalize_loose(s), "か", "input={s}");
        }
        assert_ne!(normalize_loose("が"), normalize_loose("か"));
    }

    #[test]
    fn handakuten_kept_kana_unified() {
        for s in ["パ", "ぱ", "ﾊﾟ"] {
            assert_eq!(normalize_loose(s), "ぱ", "input={s}");
        }
        assert_ne!(normalize_loose("ぱ"), normalize_loose("は"));
    }

    #[test]
    fn vu_kana_unified() {
        for s in ["ヴ", "ｳﾞ"] {
            assert_eq!(normalize_loose(s), "ゔ", "input={s}");
        }
    }

    #[test]
    fn fullwidth_and_case_folded() {
        for s in ["Ｐ", "P", "ｐ", "p"] {
            assert_eq!(normalize_loose(s), "p", "input={s}");
        }
    }

    #[test]
    fn mixed_string() {
        // 「東京 ﾄｳｷｮｳ Tokyo」 → kanji passes through, kana → hiragana, ASCII → lowercase.
        let s = "東京 ﾄｳｷｮｳ Tokyo";
        let n = normalize_loose(s);
        assert_eq!(n, "東京 とうきょう tokyo");
    }

    #[test]
    fn empty_is_empty() {
        assert_eq!(normalize_loose(""), "");
    }

    #[test]
    fn nfkc_case_fold_keeps_katakana() {
        // NfkcCaseFold folds width + case but does NOT unify kana variants.
        assert_eq!(normalize("カ", NormalizeProfile::NfkcCaseFold), "カ");
        assert_eq!(normalize("Ｐ", NormalizeProfile::NfkcCaseFold), "p");
        // Half-width katakana still recomposes via NFKC, but stays katakana.
        assert_eq!(normalize("ｶ", NormalizeProfile::NfkcCaseFold), "カ");
    }
}
