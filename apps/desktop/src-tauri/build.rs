fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        cc::Build::new()
            .file("native/macos.m")
            .file("native/ShortcutCapture.m")
            .flag("-fobjc-arc")
            .flag("-fblocks")
            .compile("pressay_platform");
        println!("cargo:rustc-link-lib=framework=AVFoundation");
        println!("cargo:rustc-link-lib=framework=ApplicationServices");
        println!("cargo:rustc-link-lib=framework=Cocoa");
        println!("cargo:rustc-link-lib=framework=EventKit");
        println!("cargo:rustc-link-lib=framework=CoreAudio");
        println!("cargo:rerun-if-changed=native/macos.m");
        println!("cargo:rerun-if-changed=native/ShortcutCapture.m");
    }
    tauri_build::build()
}
