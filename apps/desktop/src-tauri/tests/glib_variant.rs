#![cfg(target_os = "linux")]

use glib::variant::ToVariant;

// RUSTSEC-2024-0429: VariantStrIter used an immutable FFI out-pointer, which
// optimized builds could treat as null even after GLib wrote the string pointer.
#[test]
fn glib_variant_string_iteration_is_sound_when_optimized() {
    let values = ["", "Pressay", "Čujem te", "音声"];
    let variant = values.to_variant();
    assert_eq!(
        variant.array_iter_str().unwrap().collect::<Vec<_>>(),
        values
    );
    assert_eq!(
        variant.array_iter_str().unwrap().rev().collect::<Vec<_>>(),
        values.into_iter().rev().collect::<Vec<_>>()
    );
}
