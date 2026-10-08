//! The sync rules the server and every client share (docs/sync.md): the
//! hybrid logical clock a push is stamped with, and the per-column merge the
//! server settles pushes by. The server links this crate directly; the Mac,
//! iPhone and Android reach the clock through the Rust core (`core/`), so
//! there is one implementation of each rule, not one per platform.

pub mod hlc;
pub mod merge;
