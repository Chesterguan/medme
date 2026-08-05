#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    // Default utilities - feel free to customize
    flutter_rust_bridge::setup_default_user_utils();
    // 安卓上把 Rust 侧诊断接进 logcat——不接的话 `eprintln!` 在安卓真机上谁都看
    // 不见(见 `crate::diagnostics` 顶部文档)。iOS/其它平台是空操作。
    crate::diagnostics::init();
}
