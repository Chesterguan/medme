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
/// Radicals block (U+2F00–2FD5 → unified) in full; the CJK Radicals Supplement
/// (U+2E80–2EF3) has a formal (NFKC) decomposition for only 2 of its 115
/// assigned codepoints, so the rest have to be an explicit map.
///
/// That map below is generated from Unicode's own equivalence data, not typed
/// by eye against how the glyphs look — see the big comment above the `match`
/// for exactly which fields it's sourced from and why 24 assigned codepoints
/// are deliberately left out. Only radical-range codepoints are touched —
/// ordinary text (units, full-width forms, Latin) is left byte-for-byte
/// unchanged.
pub fn normalize_cjk_radicals(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            // --- CJK Radicals Supplement (U+2E80–2EF3), explicit map ---
            //
            // Unicode gives this block no NFKC decomposition (except the 2
            // handled by the NFKC fallback arm below), so every line here is
            // sourced from one of two official UCD files:
            //
            //  * `CJKRadicals.txt` (Unicode 17.0.0, 2025-05-07) — field 2
            //    ("CJK radical character", a Supplement-block codepoint) →
            //    field 3 ("CJK unified ideograph formed from that radical
            //    only"). Covers 29 of the codepoints below.
            //  * `NamesList.txt` (Unicode 17.0.0, 2025-07-30) — each
            //    Supplement-block entry's informative cross-reference line
            //    (`\tx <codepoint>`), kept **only** where a codepoint has
            //    exactly one such line. Covers all codepoints below,
            //    including the 29 also in CJKRadicals.txt (cross-checked,
            //    zero conflicts) plus the rest.
            //
            // 23 assigned Supplement codepoints have *two or more* `x`
            // cross-references in NamesList.txt (Unicode itself unified that
            // radical shape with more than one ideograph — usually a common
            // BMP character plus a near-never-used CJK Ext-B duplicate, but
            // in a couple of cases, e.g. U+2E9C "actually a form of the
            // radical for hat, despite its resemblance in shape to the
            // radical for sun", the visually-obvious pick is documented as
            // the *wrong* one). Picking a side there would be exactly the
            // "guess from how it looks" this table is trying to avoid, so
            // those 23 are left unmapped on purpose, along with U+2E80
            // (no cross-reference at all) and the reserved U+2E9A. See
            // `supplement_block_coverage_is_a_known_finite_number` for the
            // full accounting.
            '⻄' => out.push('西'), // U+2EC4 CJK RADICAL WEST TWO
            '⻅' => out.push('见'), // U+2EC5 CJK RADICAL C-SIMPLIFIED SEE
            '⻆' => out.push('角'), // U+2EC6 CJK RADICAL SIMPLIFIED HORN
            '⻓' => out.push('长'), // U+2ED3 CJK RADICAL C-SIMPLIFIED LONG
            '⻔' => out.push('门'), // U+2ED4 CJK RADICAL C-SIMPLIFIED GATE
            '⻛' => out.push('风'), // U+2EDB CJK RADICAL C-SIMPLIFIED WIND
            '⻝' => out.push('食'), // U+2EDD CJK RADICAL EAT ONE
            '⻩' => out.push('黄'), // U+2EE9 CJK RADICAL SIMPLIFIED YELLOW
            '⻬' => out.push('齐'), // U+2EEC CJK RADICAL C-SIMPLIFIED EVEN
            // `河 北 省 X X 县 ⼈ ⺠ 医 院` 的 `⺠`(U+2EA0,CJK Radicals
            // Supplement)。同样没有 NFKC 分解,漏了它整份急诊记录就抽不出医院名。
            '⺠' => out.push('民'), // U+2EA0 CJK RADICAL CIVILIAN
            '⺂' => out.push('乛'), // U+2E82 CJK RADICAL SECOND ONE
            '⺃' => out.push('乚'), // U+2E83 CJK RADICAL SECOND TWO
            '⺄' => out.push('乙'), // U+2E84 CJK RADICAL SECOND THREE
            '⺅' => out.push('亻'), // U+2E85 CJK RADICAL PERSON
            '⺆' => out.push('冂'), // U+2E86 CJK RADICAL BOX
            '⺉' => out.push('刂'), // U+2E89 CJK RADICAL KNIFE TWO
            '⺊' => out.push('卜'), // U+2E8A CJK RADICAL DIVINATION
            '⺋' => out.push('㔾'), // U+2E8B CJK RADICAL SEAL
            '⺌' => out.push('小'), // U+2E8C CJK RADICAL SMALL ONE
            '⺏' => out.push('尣'), // U+2E8F CJK RADICAL LAME TWO
            '⺐' => out.push('尢'), // U+2E90 CJK RADICAL LAME THREE
            '⺒' => out.push('巳'), // U+2E92 CJK RADICAL SNAKE
            '⺓' => out.push('幺'), // U+2E93 CJK RADICAL THREAD
            '⺔' => out.push('彑'), // U+2E94 CJK RADICAL SNOUT ONE
            '⺖' => out.push('忄'), // U+2E96 CJK RADICAL HEART ONE
            '⺘' => out.push('扌'), // U+2E98 CJK RADICAL HAND
            '⺙' => out.push('攵'), // U+2E99 CJK RADICAL RAP
            '⺛' => out.push('旡'), // U+2E9B CJK RADICAL CHOKE
            '⺝' => out.push('月'), // U+2E9D CJK RADICAL MOON
            '⺞' => out.push('歺'), // U+2E9E CJK RADICAL DEATH
            '⺡' => out.push('氵'), // U+2EA1 CJK RADICAL WATER ONE
            '⺢' => out.push('氺'), // U+2EA2 CJK RADICAL WATER TWO
            '⺣' => out.push('灬'), // U+2EA3 CJK RADICAL FIRE
            '⺤' => out.push('爫'), // U+2EA4 CJK RADICAL PAW ONE
            '⺥' => out.push('爫'), // U+2EA5 CJK RADICAL PAW TWO
            '⺦' => out.push('丬'), // U+2EA6 CJK RADICAL SIMPLIFIED HALF TREE TRUNK
            '⺨' => out.push('犭'), // U+2EA8 CJK RADICAL DOG
            '⺬' => out.push('示'), // U+2EAC CJK RADICAL SPIRIT ONE
            '⺭' => out.push('礻'), // U+2EAD CJK RADICAL SPIRIT TWO
            '⺯' => out.push('糹'), // U+2EAF CJK RADICAL SILK
            '⺰' => out.push('纟'), // U+2EB0 CJK RADICAL C-SIMPLIFIED SILK
            '⺱' => out.push('罓'), // U+2EB1 CJK RADICAL NET ONE
            '⺵' => out.push('𦉫'), // U+2EB5 CJK RADICAL MESH
            '⺶' => out.push('羊'), // U+2EB6 CJK RADICAL SHEEP
            '⺹' => out.push('耂'), // U+2EB9 CJK RADICAL OLD
            '⺺' => out.push('肀'), // U+2EBA CJK RADICAL BRUSH ONE
            '⺻' => out.push('聿'), // U+2EBB CJK RADICAL BRUSH TWO
            '⺼' => out.push('肉'), // U+2EBC CJK RADICAL MEAT
            '⺾' => out.push('艹'), // U+2EBE CJK RADICAL GRASS ONE
            '⺿' => out.push('艹'), // U+2EBF CJK RADICAL GRASS TWO
            '⻀' => out.push('艹'), // U+2EC0 CJK RADICAL GRASS THREE
            '⻁' => out.push('虎'), // U+2EC1 CJK RADICAL TIGER
            '⻂' => out.push('衤'), // U+2EC2 CJK RADICAL CLOTHES
            '⻃' => out.push('覀'), // U+2EC3 CJK RADICAL WEST ONE
            '⻇' => out.push('𧢲'), // U+2EC7 CJK RADICAL HORN
            '⻈' => out.push('讠'), // U+2EC8 CJK RADICAL C-SIMPLIFIED SPEECH
            '⻉' => out.push('贝'), // U+2EC9 CJK RADICAL C-SIMPLIFIED SHELL
            '⻋' => out.push('车'), // U+2ECB CJK RADICAL C-SIMPLIFIED CART
            '⻌' => out.push('辶'), // U+2ECC CJK RADICAL SIMPLIFIED WALK
            '⻍' => out.push('辶'), // U+2ECD CJK RADICAL WALK ONE
            '⻎' => out.push('辶'), // U+2ECE CJK RADICAL WALK TWO
            '⻏' => out.push('邑'), // U+2ECF CJK RADICAL CITY
            '⻐' => out.push('钅'), // U+2ED0 CJK RADICAL C-SIMPLIFIED GOLD
            '⻑' => out.push('長'), // U+2ED1 CJK RADICAL LONG ONE
            '⻒' => out.push('镸'), // U+2ED2 CJK RADICAL LONG TWO
            '⻖' => out.push('阝'), // U+2ED6 CJK RADICAL MOUND TWO
            '⻗' => out.push('雨'), // U+2ED7 CJK RADICAL RAIN
            // Chrome/Skia PDF export has actually emitted this one: a
            // 「青霉素」+「胸骨后闷痛」corpus fixture rendered `青` as U+2ED8.
            '⻘' => out.push('青'), // U+2ED8 CJK RADICAL BLUE
            '⻙' => out.push('韦'), // U+2ED9 CJK RADICAL C-SIMPLIFIED TANNED LEATHER
            '⻚' => out.push('页'), // U+2EDA CJK RADICAL C-SIMPLIFIED LEAF
            '⻜' => out.push('飞'), // U+2EDC CJK RADICAL C-SIMPLIFIED FLY
            '⻞' => out.push('𩙿'), // U+2EDE CJK RADICAL EAT TWO
            '⻟' => out.push('飠'), // U+2EDF CJK RADICAL EAT THREE
            '⻠' => out.push('饣'), // U+2EE0 CJK RADICAL C-SIMPLIFIED EAT
            '⻡' => out.push('𩠐'), // U+2EE1 CJK RADICAL HEAD
            '⻢' => out.push('马'), // U+2EE2 CJK RADICAL C-SIMPLIFIED HORSE
            // Same fixture as `青` above — `骨` (as in 胸骨/骨科) rendered as
            // U+2EE3. This is the one the task description calls out by
            // name: 「⻮科」「牙⻮」would silently break dental-note extraction.
            '⻣' => out.push('骨'), // U+2EE3 CJK RADICAL BONE
            '⻤' => out.push('鬼'), // U+2EE4 CJK RADICAL GHOST
            '⻥' => out.push('鱼'), // U+2EE5 CJK RADICAL C-SIMPLIFIED FISH
            '⻦' => out.push('鸟'), // U+2EE6 CJK RADICAL C-SIMPLIFIED BIRD
            '⻧' => out.push('卤'), // U+2EE7 CJK RADICAL C-SIMPLIFIED SALT
            '⻨' => out.push('麦'), // U+2EE8 CJK RADICAL SIMPLIFIED WHEAT
            '⻪' => out.push('黾'), // U+2EEA CJK RADICAL C-SIMPLIFIED FROG
            '⻫' => out.push('斉'), // U+2EEB CJK RADICAL J-SIMPLIFIED EVEN
            '⻭' => out.push('歯'), // U+2EED CJK RADICAL J-SIMPLIFIED TOOTH
            '⻮' => out.push('齿'), // U+2EEE CJK RADICAL C-SIMPLIFIED TOOTH
            '⻰' => out.push('龙'), // U+2EF0 CJK RADICAL C-SIMPLIFIED DRAGON
            '⻱' => out.push('龜'), // U+2EF1 CJK RADICAL TURTLE
            '⻲' => out.push('亀'), // U+2EF2 CJK RADICAL J-SIMPLIFIED TURTLE
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

    /// 补全批次覆盖的简化字形部首(任务里点名的那批):`⻉`贝 `⻋`车 `⻘`青
    /// `⻚`页 `⻢`马 `⻥`鱼 `⻦`鸟 `⻮`齿 `⻰`龙。`⻮科`/`牙⻮` 是口腔科文档里的
    /// 真实词,补表之前会被静默打穿。
    #[test]
    fn newly_added_simplified_radicals_fold_correctly() {
        assert_eq!(normalize_cjk_radicals("⻉壳化石"), "贝壳化石");
        assert_eq!(normalize_cjk_radicals("⻋祸外伤"), "车祸外伤");
        assert_eq!(normalize_cjk_radicals("⻘霉素"), "青霉素");
        assert_eq!(normalize_cjk_radicals("肝功能检查⻚"), "肝功能检查页");
        assert_eq!(normalize_cjk_radicals("⻢齿苋"), "马齿苋");
        assert_eq!(normalize_cjk_radicals("⻥腥味"), "鱼腥味");
        assert_eq!(normalize_cjk_radicals("⻦氨酸"), "鸟氨酸");
        assert_eq!(normalize_cjk_radicals("⻰血竭"), "龙血竭");
        // 口腔科真实词:「⻮科」「牙⻮」。
        assert_eq!(normalize_cjk_radicals("⻮科门诊"), "齿科门诊");
        assert_eq!(normalize_cjk_radicals("牙⻮松动"), "牙齿松动");
        // 上一轮实测撞到的两个码位:青霉素 + 胸骨后闷痛,经 Chrome 渲染成 PDF
        // 后 `青`(U+2ED8)、`骨`(U+2EE3)正是当时表里没收录的。
        assert_eq!(
            normalize_cjk_radicals("⻘霉素过敏史;胸⻣后闷痛"),
            "青霉素过敏史;胸骨后闷痛"
        );
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

    /// CJK Radicals Supplement(U+2E80–2EF3)**整块没有 NFKC 分解** —— 115 个
    /// 已分配码位里只有 2 个能靠 NFKC 折走(U+2E9F ⺟→母、U+2EF3 ⻳→龟,两个
    /// 都在 NamesList.txt 里标的是正式 `#` 兼容映射,不是本文件的手写表)。
    /// 其余 113 个要么进了上面的手写表,要么保持原样穿过。
    ///
    /// 手写表现在 89 条,全部从 Unicode 官方数据取得依据(见 `match` 块前的
    /// 大注释:`CJKRadicals.txt` 字段 2→3,或 `NamesList.txt` 里恰好只有
    /// 一条 `x` 交叉引用的码位)。剩下 24 个**故意不收**:
    /// 23 个在 NamesList.txt 里有两条或以上 `x` 交叉引用(Unicode 自己都没
    /// 给出唯一答案,常见于「一个常用 BMP 字 + 一个几乎不会出现的 CJK 扩展 B
    /// 重复编码」,但也有 U+2E9C 这种「长得像日,官方交叉引用给的却是冃」的
    /// 反例——按形状挑边正是这张表要避免的事),外加 U+2E80(没有交叉引用)。
    ///
    /// 这不是"已经覆盖完了",是"覆盖了有依据的"。这条测试把**当前覆盖面**钉成
    /// 一个数字:往表里加一条,这里就得改一次,改的人才会顺手看一眼还差哪些
    /// 仍未收录、以及为什么。
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
            folded_count, 91,
            "手写表 89 条 + NFKC 能吃掉的 2 条 = 91。改了表就更新这个数,\
             并顺手看一眼上面注释里说明的、为什么剩下 24 个故意没收"
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
