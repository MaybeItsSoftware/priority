//! Takt's shared core.
//!
//! Every client — the Mac and iPhone apps through Swift, the Android app
//! through Kotlin, the CLI and the sync server as a Rust dependency — will call
//! this one implementation of the workspace store instead of keeping its own
//! copy. Nothing here knows about a UI toolkit. The migration is incremental;
//! `docs/rust-core-migration.md` is the plan and records which behaviour has
//! moved so far.

uniffi::setup_scaffolding!();

pub mod schema;

/// The version of this crate, as compiled into the library a client loaded.
///
/// The first call across the boundary, and the one a client shows in its
/// diagnostics: when a platform's bindings and its compiled library drift
/// apart, this is the number that says which library it actually has.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_version_is_the_crate_version() {
        assert_eq!(core_version(), env!("CARGO_PKG_VERSION"));
        assert!(!core_version().is_empty());
    }
}
