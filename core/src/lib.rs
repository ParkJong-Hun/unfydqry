mod config;
mod engine;
mod normalize;
mod search;

pub use config::{EngineConfig, NormalizeProfile, SearchStrategy};
pub use engine::{Hit, SearchEngine, SearchError};
pub use normalize::{normalize, normalize_loose};

uniffi::setup_scaffolding!();

/// Returns `input` normalized with the default `loose` profile (NFKC, then
/// katakana→hiragana, then lowercase).
///
/// This is the same normalization the engine applies to indexed text and
/// queries by default; exposed so a host can preview or debug how a string
/// will be folded before searching.
#[uniffi::export(name = "normalizeLoose")]
pub fn normalize_loose_ffi(input: String) -> String {
    normalize_loose(&input)
}

/// Like `normalizeLoose`, but lets the caller pick the normalization profile.
#[uniffi::export(name = "normalizeWithProfile")]
pub fn normalize_with_profile_ffi(input: String, profile: NormalizeProfile) -> String {
    normalize(&input, profile)
}
