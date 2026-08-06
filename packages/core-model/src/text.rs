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

    /// 「折部首会不会误伤」的答案,穷举了整个 Kangxi Radicals 块(U+2F00–2FD5)
    /// 才有资格说:**214 个康熙部首,每一个的 NFKC 都恰好是一个统一汉字**,
    /// 没有一个会展开成多字、也没有一个会落到汉字区外。所以这条折叠
    /// 「把一个字换成长得一样的另一个码位」,不会把别的东西搅碎。
    ///
    /// 这条穷举同时是加映射表时的护栏:哪天有人往 `match` 里塞一条把部首映射
    /// 到多字/非汉字的规则,这里会当场炸。
    #[test]
    fn every_kangxi_radical_folds_to_exactly_one_unified_ideograph() {
        let mut n = 0usize;
        for cp in 0x2F00u32..=0x2FD5 {
            let c = char::from_u32(cp).expect("valid scalar");
            let folded = normalize_cjk_radicals(&c.to_string());
            let mut it = folded.chars();
            let one = it.next().expect("folds to something");
            assert!(
                it.next().is_none(),
                "U+{cp:04X} {c} 折成了多个字符 {folded:?} —— 折叠必须是 1:1"
            );
            assert_ne!(one, c, "U+{cp:04X} {c} 没被折走");
            assert!(
                ('\u{3400}'..='\u{9FFF}').contains(&one),
                "U+{cp:04X} {c} 折成了非汉字 U+{:04X}",
                one as u32
            );
            n += 1;
        }
        assert_eq!(n, 214, "Kangxi Radicals 块是 214 个部首");
    }

    /// CJK Radicals Supplement(U+2E80–2EF3)**整块没有 NFKC 分解** —— 115 个里
    /// 只有 2 个能靠 NFKC 折走,其余全靠上面那张手写表。表里现在 10 条,
    /// 剩下 105 个原样穿过。
    ///
    /// 这不是"已经覆盖完了",是"覆盖了见过的"。这条测试把**当前覆盖面**钉成
    /// 一个数字:往表里加一条,这里就得改一次,改的人才会顺手看一眼还差哪些。
    /// 现实里还可能踩到的简化字形部首(各自都是一个常用独体字的同形码位):
    /// `⻉`贝 `⻋`车 `⻘`青 `⻚`页 `⻢`马 `⻥`鱼 `⻦`鸟 `⻮`齿 `⻰`龙 `⺟`母。
    #[test]
    fn supplement_block_coverage_is_a_known_finite_number() {
        let mut folded_count = 0usize;
        let mut assigned = 0usize;
        for cp in 0x2E80u32..=0x2EF3 {
            let c = char::from_u32(cp).expect("valid scalar");
            // U+2E9A 是块内唯一的未分配码位。
            if cp == 0x2E9A {
                continue;
            }
            assigned += 1;
            let folded = normalize_cjk_radicals(&c.to_string());
            if folded != c.to_string() {
                folded_count += 1;
                assert_eq!(
                    folded.chars().count(),
                    1,
                    "U+{cp:04X} {c} 折成了多个字符 {folded:?}"
                );
            }
        }
        assert_eq!(assigned, 115, "Supplement 块分配了 115 个码位");
        assert_eq!(
            folded_count, 12,
            "手写表 10 条 + NFKC 能吃掉的 2 条 = 12。改了表就更新这个数,\
             并顺手看一眼上面注释里列的那批还没进表的常用同形部首"
        );
    }

    /// 折叠必须幂等 —— 不然「在 ingest 折一次、消费者又各折一次」这种叠加会出事。
    #[test]
    fn folding_is_idempotent() {
        let s = "四川⼤学华⻄医院 ⾎糖 6.8 mmol/L 诊断意⻅:⾼⾎压 3 级";
        let once = normalize_cjk_radicals(s);
        assert_eq!(normalize_cjk_radicals(&once), once);
    }
}
