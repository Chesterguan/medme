//! FRB 派发表是按**函数名**字典序编号的:新增一个排在前面的名字会把后面所有下标
//! 往后推一位,而 `recognize_image_pp` 的下标 44 是外部契约(iOS AppDelegate 直接
//! 按这个号调 PP-OCR,见根 `CLAUDE.md` 与 `apps/mobile_flutter/CLAUDE.md`)。
//!
//! 这条测试让「加个 FFI 函数」这件事不再可能悄悄改掉它:新函数的名字必须排在
//! `recognize_image_pp` 之后(`vault_*` / `view_*` 都满足),否则这里当场红。
#[test]
fn recognize_image_pp_is_still_dispatch_index_44() {
    let src = include_str!("../src/frb_generated.rs");
    assert!(
        src.contains("44 => wire__crate__api__vault__recognize_image_pp_impl"),
        "下标 44 被挪走了 —— 新 FFI 函数名必须字典序排在 recognize_image_pp 之后"
    );
}
