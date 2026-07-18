//! 分类与抽取吃的是 OCR 出来的任意文本 —— 内容完全由外部文件决定,
//! 正则回溯、切片越界、日期解析溢出都在这条路上。
#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok(text) = std::str::from_utf8(data) else {
        return;
    };
    let _ = parser::classify(text);
    let _ = parser::guess_date_range(text);
    let _ = parser::extract_demographics(text);
    let _ = parser::detect_language(text);
});
