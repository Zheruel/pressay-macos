use std::{env, path::PathBuf};

fn main() {
    let root = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap()).join("../..");
    let native = root.join("Runtime/Sources/CNativeASR");
    for path in [
        native.join("PressayNative.cpp"),
        native.join("include/PressayNative.h"),
        native.join("vendor/transcribe.h"),
        native.join("vendor/nemo_asr.h"),
        PathBuf::from("native/protocol_io.cpp"),
    ] {
        println!("cargo:rerun-if-changed={}", path.display());
    }
    cc::Build::new()
        .cpp(true)
        .std("c++17")
        .include(native.join("include"))
        .file(native.join("PressayNative.cpp"))
        .file("native/protocol_io.cpp")
        .compile("pressay_asr_adapter");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        println!("cargo:rustc-link-lib=dl");
    }
}
