//! The bindgen the build scripts run, pinned to this crate's uniffi version so
//! the generated Swift and Kotlin always match the scaffolding compiled in.
fn main() {
    uniffi::uniffi_bindgen_main()
}
