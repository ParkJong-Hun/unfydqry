mod config;
mod engine;
mod normalize;
mod search;

pub use config::{EngineConfig, NormalizeProfile, SearchStrategy};
pub use engine::{Hit, SearchEngine, SearchError};
pub use normalize::{normalize, normalize_loose};

uniffi::setup_scaffolding!();

/// Exposed through FFI so the loose normalized form can be inspected for
/// testing and debugging. Retained for backward compatibility.
#[uniffi::export(name = "normalizeLoose")]
pub fn normalize_loose_ffi(input: String) -> String {
    normalize_loose(&input)
}

/// Like `normalizeLoose`, but lets the caller pick the normalization profile.
#[uniffi::export(name = "normalizeWithProfile")]
pub fn normalize_with_profile_ffi(input: String, profile: NormalizeProfile) -> String {
    normalize(&input, profile)
}
