// Entry point for `cargo run --bin uniffi-bindgen -- generate ...`.
// Drives Swift binding generation in the build script.
fn main() {
    uniffi::uniffi_bindgen_main()
}
