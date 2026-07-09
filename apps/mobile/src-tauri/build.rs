fn main() {
    // iOS: the Rust cdylib references Swift @_cdecl symbols (medme_vision_*) that
    // are compiled by the Xcode app target AFTER cargo, so allow the dylib to keep
    // them undefined here — the final app link resolves them. Emitting the link arg
    // from build.rs is cwd-independent (unlike .cargo/config.toml, which tauri's
    // cargo invocation doesn't pick up).
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("ios") {
        println!("cargo:rustc-link-arg=-Wl,-undefined,dynamic_lookup");
    }
    tauri_build::build()
}
