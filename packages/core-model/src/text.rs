//! PDF 文本层的字形规范化。
//!
//! 只有一件事:把「部首字形」折回统一汉字。放在 `core-model` 是因为**两条**取文本
//! 的路都要用它,而它们分属不同的 crate:
//!
//! * `parser::extract`(txt / 桌面遗留的 pdf 分支)—— 一直在用;
//! * `core_model::extract_provider` —— 读的是 `ocr_result.text`,那份文本由
//!   `ocr::recognize_pdf_mixed` 产出,**从来没有**经过 `parser::extract`。
//!
//! 曾经有两份各自维护的映射表,结果就是漏项只在其中一份被发现(`⺠` U+2EA0 一直
//! 不在表里,见下)。一份表,一处修。

use unicode_normalization::UnicodeNormalization;

/// Fold CJK radical glyphs back to their unified ideographs.
///
/// Some PDFs (incl. our generated corpus) carry a font whose ToUnicode CMap maps
/// common characters to *radical* codepoints, so `pdf-extract` yields e.g. `意⻅`
/// for `意见`, `⾎糖` for `血糖`. That silently breaks every downstream matcher
/// (labels, lab names, drug/condition dictionaries). NFKC handles the Kangxi
/// Radicals block (U+2F00–2FD5 → unified); the CJK Radicals Supplement
/// (U+2E80–2EF3) has *no* decomposition, so we map the ones seen in practice.
/// Only radical-range codepoints are touched — ordinary text (units, full-width
/// forms, Latin) is left byte-for-byte unchanged.
///
/// ponytail: supplement map covers the radicals observed in the corpus; add more
/// if a new one shows up (they render as a stray radical, never as wrong text).
pub fn normalize_cjk_radicals(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '⻄' => out.push('西'),
            '⻅' => out.push('见'),
            '⻆' => out.push('角'),
            '⻓' => out.push('长'),
            '⻔' => out.push('门'),
            '⻛' => out.push('风'),
            '⻝' => out.push('食'),
            '⻩' => out.push('黄'),
            '⻬' => out.push('齐'),
            // `河 北 省 X X 县 ⼈ ⺠ 医 院` 的 `⺠`(U+2EA0,CJK Radicals
            // Supplement)。同样没有 NFKC 分解,漏了它整份急诊记录就抽不出医院名。
            '⺠' => out.push('民'),
            _ if ('\u{2E80}'..='\u{2FDF}').contains(&c) => {
                // Kangxi radical (and any unmapped supplement char) → NFKC.
                // NFKC of a Kangxi radical is its single unified ideograph;
                // an unmapped supplement char has no decomposition and passes
                // through unchanged.
                out.extend(c.to_string().nfkc());
            }
            _ => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::normalize_cjk_radicals;

    #[test]
    fn kangxi_radicals_fold_via_nfkc() {
        assert_eq!(normalize_cjk_radicals("四川⼤学"), "四川大学");
        assert_eq!(normalize_cjk_radicals("附属中⼭医院"), "附属中山医院");
        assert_eq!(normalize_cjk_radicals("附属第⼀医院"), "附属第一医院");
        assert_eq!(normalize_cjk_radicals("瑞⾦医院"), "瑞金医院");
    }

    /// CJK Radicals Supplement 没有 NFKC 分解,只能靠显式映射表。表里漏一个,
    /// 含那个字的机构名就整份抽不出来 —— `⺠` 就是这么漏掉一整份急诊记录的。
    #[test]
    fn supplement_radicals_fold_via_the_explicit_map() {
        assert_eq!(normalize_cjk_radicals("华⻄医院"), "华西医院");
        assert_eq!(normalize_cjk_radicals("县⼈⺠医院"), "县人民医院");
        assert_eq!(normalize_cjk_radicals("诊断意⻅"), "诊断意见");
    }

    #[test]
    fn ordinary_text_is_untouched() {
        assert_eq!(
            normalize_cjk_radicals("Cr 104 umol/L 见附页"),
            "Cr 104 umol/L 见附页"
        );
    }
}
