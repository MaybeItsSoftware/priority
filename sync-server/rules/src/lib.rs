//! The sync rules the server and every client share (docs/sync.md): the
//! hybrid logical clock a push is stamped with, the per-column merge the
//! server settles pushes by, and the push and pull bodies themselves. The
//! server links this crate directly; the Mac, iPhone and Android reach the
//! clock and the bodies through the Rust core (`core/`), so there is one
//! implementation of each rule, not one per platform.

pub mod hlc;
pub mod merge;
pub mod wire;
