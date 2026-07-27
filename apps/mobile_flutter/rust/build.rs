//! 只做一件事:决定这次构建**是否链接 PP-OCR 引擎**,并把结论表达成一个
//! `pp_ocr` cfg —— 规则只写这一处,`src/` 里十来个 `#[cfg(pp_ocr)]` 都读它。
//!
//! 为什么需要它:PP-OCR 靠 `ort`(ONNX Runtime),而 **`ort` 只为 arm64 安卓提供
//! 预编译库,没有 `i686-linux-android`**。此前依赖与代码都按 `target_os =
//! "android"` 门控,而 x86 安卓的 `target_os` **同样是 `android`** —— 于是只要构建
//! 目标里出现 x86,就会去链一个不存在的库,直接失败。
//!
//! 这在实践中的后果是**本地 debug 装机彻底不可用**:cargokit 给 debug 构建硬编码
//! 追加 `android-x86`/`x64`(给模拟器用,见 `rust_builder/cargokit/gradle/plugin.gradle`),
//! 所以 `flutter run` 必挂,真机验证只能走 `--release`(每轮多等几分钟、没有 hot
//! reload)。**这不是 cargokit 的问题**:它编模拟器 ABI 是有意且合理的,是我们把
//! 「安卓」当成了「arm64 安卓」。修在自己这边,就不必给 vendored 的三方构建工具
//! 打补丁(那会带来升级冲突和「补丁被静默冲掉」的风险)。
//!
//! 发布产物零变化:我们本来就只发 arm64-v8a(见 `ci(android): main 公开发布也只出
//! arm64-v8a`)。x86 上少掉的只是 PP-OCR —— 而那个本来就编不出来,现在至少 app
//! 能在模拟器上起来。

fn main() {
    println!("cargo:rerun-if-changed=build.rs");

    let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();

    // iOS:设备与模拟器都保持原样(未受 x86 问题影响,不趁机改动)。
    // 安卓:只有 arm64 有 ort 预编译库,也只有它会被发布。
    let has_pp_ocr = os == "ios" || (os == "android" && arch == "aarch64");
    if has_pp_ocr {
        println!("cargo:rustc-cfg=pp_ocr");
    }
}
