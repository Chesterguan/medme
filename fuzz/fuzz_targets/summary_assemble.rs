//! 给医生看的 summary 是**从 OCR 文本装配出来的**:分段、抽化验、抽用药、配对疾病、
//! 排趋势。输入完全由外部文件决定,切片、下标、日期解析都在这条路上,而它的产物
//! 直接进医生的判断视野 —— 崩溃是小事,静默错位才是要命的。
#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok(text) = std::str::from_utf8(data) else {
        return;
    };
    // 一份文档 + 一份带 doc_type 的文档:后者会走影像/病理的路由分支。
    let docs = [
        parser::SourceDoc {
            index: 0,
            date: None,
            text,
            doc_type: None,
            title: None,
        },
        parser::SourceDoc {
            index: 1,
            date: None,
            text,
            doc_type: Some("imaging_report".into()),
            title: Some(text.chars().take(24).collect()),
        },
    ];
    let _ = parser::assemble_summary(&docs);
});
