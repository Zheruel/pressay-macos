fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        let output = std::path::PathBuf::from(std::env::var_os("OUT_DIR").unwrap());
        let architecture = match std::env::var("CARGO_CFG_TARGET_ARCH").unwrap().as_str() {
            "aarch64" => "arm64",
            "x86_64" => "x86_64",
            other => panic!("Unsupported macOS architecture: {other}"),
        };
        let status = std::process::Command::new("xcrun")
            .args([
                "swiftc",
                "-swift-version",
                "6",
                "-parse-as-library",
                "-emit-library",
                "-static",
                "-module-name",
                "PressayIsland",
                "-target",
                &format!("{architecture}-apple-macosx26.0"),
                "-O",
                "native/OverlayIsland.swift",
                "-o",
            ])
            .arg(output.join("libPressayIsland.a"))
            .status()
            .expect("Swift compiler is required for the native Pressay island");
        assert!(status.success(), "Could not compile native Pressay island");
        let sdk = std::process::Command::new("xcrun")
            .args(["--sdk", "macosx", "--show-sdk-path"])
            .output()
            .expect("Could not locate macOS SDK");
        assert!(sdk.status.success(), "Could not locate macOS SDK");
        println!("cargo:rustc-link-search=native={}", output.display());
        println!(
            "cargo:rustc-link-search=native={}/usr/lib/swift",
            String::from_utf8(sdk.stdout).unwrap().trim()
        );
        println!("cargo:rustc-link-lib=static=PressayIsland");
        println!("cargo:rustc-link-lib=framework=SwiftUI");
        // Swift runtime dylibs ship with supported macOS; never depend on Xcode
        // or a compiler installation when the app is relocated or distributed.
        println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
        println!("cargo:rerun-if-changed=native/OverlayIsland.swift");
        cc::Build::new()
            .file("native/macos.m")
            .file("native/ShortcutCapture.m")
            .file("native/AppMetadata.m")
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
        println!("cargo:rerun-if-changed=native/AppMetadata.m");
    }
    tauri_build::build()
}
