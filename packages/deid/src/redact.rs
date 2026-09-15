//! 三层组合。顺序即优先级:K(已知值)→ A(锚点)→ P(模式)→ 日期偏移。
use crate::{anchors, dates, known, patterns};
use serde::{Deserialize, Serialize};

pub use known::KnownIdentity;

/// 占位符 ↔ 原文。**永不离开手机。**
#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq)]
pub struct RestoreMap {
    pub placeholders: Vec<(String, String)>,
    pub shift_days: i64,
}

impl RestoreMap {
    /// 同一原文只发一个占位符(同一医院名出现三次 → 三处同一个 [H1])。
    pub fn placeholder(&mut self, kind: &str, value: &str) -> String {
        if let Some((p, _)) = self.placeholders.iter().find(|(_, v)| v == value) {
            return p.clone();
        }
        let n = self
            .placeholders
            .iter()
            .filter(|(p, _)| p.starts_with(&format!("[{kind}")))
            .count()
            + 1;
        let p = format!("[{kind}{n}]");
        self.placeholders.push((p.clone(), value.to_string()));
        p
    }
}

pub struct Redacted {
    pub text: String,
    pub map: RestoreMap,
}

pub fn redact_text(text: &str, known: &KnownIdentity, shift_days: i64) -> Redacted {
    let mut map = RestoreMap {
        placeholders: Vec::new(),
        shift_days,
    };
    let t = known::apply(text, known, &mut map);
    let t = anchors::apply(&t, &mut map);
    let t = patterns::apply(&t, &mut map);
    let t = dates::shift_dates(&t, shift_days);
    Redacted { text: t, map }
}

/// 先减日期,再把占位符按登记顺序倒着换回(后登记的可能嵌在先登记的里)。
pub fn restore(text: &str, map: &RestoreMap) -> String {
    let mut out = dates::unshift_dates(text, map.shift_days);
    for (p, v) in map.placeholders.iter().rev() {
        out = out.replace(p, v);
    }
    out
}

// --- spec §1(图片档):OCR 行框 → 哪些框要涂黑 -------------------------------
//
// `deid` 不依赖 `ocr`(不能把识别引擎拖进这个纯函数 crate),所以这里镜像一份
// 轻量的框/矩形类型;调用方(桌面/移动端)负责把 `ocr::LayoutLine`/`PaintRect`
// 和这里的 `Box`/`Rect` 相互转换。

/// 一条 OCR 行:文本 + 在图片像素坐标系里的框(origin 左上)。
pub struct Box {
    pub text: String,
    pub left: f32,
    pub top: f32,
    pub right: f32,
    pub bottom: f32,
}

/// 要涂黑的矩形,像素坐标,与传入的 [`Box`] 同一坐标系。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rect {
    pub left: f32,
    pub top: f32,
    pub right: f32,
    pub bottom: f32,
}

/// 行内数字区间形如 `4.0-10.0` / `115-150`(化验参考区间的典型形状)。跟 P 层的号码
/// 形状规则故意不共享——这里只关心「像不像区间」,不关心该不该被掩。右值也带上可选
/// 小数位(fix round 2 item 4:不然 "4.0-10.0" 只会匹配到 "4.0-10",剩下的 ".0" 会被
/// 「区间后面只能跟空白/标记/单位」的收尾检查误判成不合法的尾巴)。
fn digit_range_re() -> &'static regex::Regex {
    static R: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    R.get_or_init(|| {
        regex::Regex::new(r"\d+(\.\d+)?\s*[-~]\s*\d+(\.\d+)?").expect("digit range re")
    })
}

/// 座机号形状(`patterns::landline_re` 同形,那边是私有的——两条正则字面量,不值得
/// 为此开 pub,`dates.rs` 顶部对 iso_re/cn_re 已有同样的先例)。用来把「电话
/// 010-69156114」这种数字区间形状的座机号从「化验区间」候选里摘出去。
fn looks_like_landline(s: &str) -> bool {
    static R: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    R.get_or_init(|| regex::Regex::new(r"^0\d{2,3}-\d{7,8}$").expect("landline shape re"))
        .is_match(s)
}

/// 在 `t` 里、从 `at` 这个字节偏移开始,是不是一个 `YYYY-MM-DD`/`YYYY/MM/DD` 形状的
/// 日期(`dates::iso_re` 同形,同样的「不值得为此开 pub」理由)。用来把页眉里的
/// 打印日期(`2024-03-06`)从「化验区间」候选里摘出去——区间的左值几乎不会是恰好
/// 4 位数字的「年份」。
fn looks_like_iso_date_at(t: &str, at: usize) -> bool {
    static R: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    R.get_or_init(|| {
        regex::Regex::new(r"^\d{4}[-/.]\d{1,2}[-/.]\d{1,2}").expect("iso date shape re")
    })
    .is_match(&t[at..])
}

/// 这一行有没有出现任何一个身份锚点词(`anchors::ANCHORS`,姓名/证件号/地址等标签)。
/// 化验区间判定要避开这类行——一个贴着「门诊号」标签的号码,哪怕形状像区间,也不是
/// 化验行。
fn has_anchor_word(t: &str) -> bool {
    anchors::ANCHORS.iter().any(|(a, _)| t.contains(a))
}

/// 化验异常标记(高/低箭头,或 H/L 缩写)。
const FLAG_TOKENS: &[&str] = &["↑", "↓", "H", "L"];

/// 数字区间之后、到行尾为止,是不是「只有空白 + 至多一个异常标记 + 至多一个化验单位」
/// ——不能是别的内容(fix round 2 item 4)。比如「标本编号 24-03-1234」里,「24-03」
/// 这一段形状也像区间,但后面还跟着「-1234」,不符合这条收尾规则,不该被当成化验行。
fn range_tail_ok(rest: &str) -> bool {
    let mut s = rest.trim_start();
    for flag in FLAG_TOKENS {
        if let Some(stripped) = s.strip_prefix(flag) {
            s = stripped.trim_start();
            break;
        }
    }
    if s.is_empty() {
        return true;
    }
    patterns::UNIT_TOKENS
        .iter()
        .any(|u| s.strip_prefix(u).is_some_and(|t| t.trim_start().is_empty()))
}

/// 像不像一条化验行:含单位标记(`patterns::UNIT_TOKENS`,与 P 层共用同一份词表,
/// 不再各自维护、也不要求先有数字——这条口径保留不变)一定算;不含单位时,退而看有
/// 没有「数字区间」形状——但排除掉贴着身份锚点词的行,形状凑巧像区间、实则是座机号
/// /日期的行(fix round 1 item 2),以及区间后面还跟着别的内容、不是「空白/标记/
/// 单位到行尾」的行(fix round 2 item 4:「标本编号 24-03-1234」这类三段式编号)。
fn looks_like_lab_row(t: &str) -> bool {
    if patterns::UNIT_TOKENS.iter().any(|u| t.contains(u)) {
        return true;
    }
    if has_anchor_word(t) {
        return false;
    }
    match digit_range_re().find(t) {
        Some(m) if looks_like_landline(m.as_str()) => false,
        Some(m) if looks_like_iso_date_at(t, m.start()) => false,
        Some(m) => range_tail_ok(&t[m.end()..]),
        None => false,
    }
}

/// 像不像**一条化验行的项目名**——只有名字、值和区间被切进了别的框。
///
/// 斜着拍的单子上布局重建必然这样切:实测血常规报告1 的 `1白细胞计数`(y42–124)、
/// 报告4 的 `12红细胞计数`(y723–781)都是纯名字框,`looks_like_lab_row` 一条都不认
/// (没单位、没区间),页眉带于是越过它们继续往下、页脚带的下界也够不到它们,两头
/// 各吃掉 2 行(extract-repro-report.md §3)。
///
/// 判定交给词典(`terminology`,deid 本来就依赖它,见 Cargo.toml)。
///
/// **必须用 `normalize`(整串精确命中)而不是 `resolve`。** `resolve` 会
/// `term_candidates` 按空格拆词再逐个查,还带模糊匹配 —— GNU_Health 那张单子上
/// 患者姓名 **`Ana Betz` 因此以置信度 1.0 命中 `ana`(抗核抗体)**,页眉带被收到
/// y111,把 `Ana Betz`/`Cameron Cordara`/`Patient ID` 整块患者信息露在送出的图上
/// (deid 的 A 层锚点是中文的,这张英文单子上除了页眉带没有第二道防线)。
/// `normalize` 只认整串,`Ana Betz` 归一化后查无此词,真项目名
/// (白细胞计数/12红细胞计数/Hemoglobin/RDW-CV/LYM%…)一个不少 —— 7 张单子实测。
///
/// 置信度仍卡 1.0:OCR 混淆表命中(0.5)和药名剥壳(0.8)都不算。**误判的方向是
/// 危险的** —— 页眉里冒出一个假项目名就会把页眉带收到它上面去,露出患者信息,
/// 所以这里宁可漏、不可错。
fn looks_like_lab_name(t: &str) -> bool {
    // 行号前缀(`12红细胞计数`、`1 白细胞计数`)去掉再查。
    let name = t
        .trim()
        .trim_start_matches(|c: char| c.is_ascii_digit() || c.is_whitespace() || c == '.');
    !name.is_empty() && terminology::normalize(name).is_some_and(|m| m.confidence >= 1.0)
}

/// 框里带不带「数值或化验单位」——`3.3`、`10^3/uL`、`4.5-11` 这类。用来给**短的拉丁
/// 缩写项目名**找旁证(见 [`lab_name_is_trustworthy`])。
///
/// 数字要求是**整个 token** 都由数字/小数点/区间号组成:`PAC001`、`B165AAF4` 这种
/// 编号里虽然有数字,但不是独立的数值 token,不算旁证 —— 否则 `Patient ID PAC001`
/// 就会给旁边的 `Ana` 背书。
fn carries_value_or_unit(t: &str) -> bool {
    if patterns::UNIT_TOKENS.iter().any(|u| t.contains(u)) {
        return true;
    }
    t.split(|c: char| c.is_whitespace() || c == '|')
        .map(|tok| {
            tok.trim_matches(|c: char| matches!(c, ':' | '：' | ',' | '，' | ';' | '；' | '、'))
        })
        .any(|tok| {
            !tok.is_empty()
                && tok.chars().any(|c| c.is_ascii_digit())
                && tok
                    .chars()
                    .all(|c| c.is_ascii_digit() || matches!(c, '.' | '-' | '~' | '%'))
        })
}

/// 一个「像项目名」的框,可不可信到能用来**收住页眉带 / 顶住页脚带**。
///
/// 词典里有一批**三字母缩写**(`ana` 抗核抗体、`alt`、`cea`…)会和真实人名撞车:
/// 布局重建在斜页上本来就会把 `Name  Ana Betz` 切成 `Ana` / `Betz` 两框,而
/// `normalize("Ana")` 置信度就是 1.0。一旦认了,GNU_Health 的页眉带会从 `0..202`
/// 收到 `0..42`,`Ana`/`Betz`/`Patient ID PAC001` 全部露出 —— 而这张英文单子上,
/// 页眉带是唯一一道防线(review-21-22.md Important 3)。
///
/// 三选一才算可信:
/// * 含 CJK —— 中文项目名不会和英文人名撞车;
/// * 拉丁字母 ≥ 4 个 —— `Hemoglobin`/`MCHC`/`RDW-CV` 过,`Ana`/`Alt`/`Cea` 不过;
/// * 本框或**右邻框**带数值/单位 —— `RBC` `3.3`、`WBC` `6.7` 这类三字母缩写靠这条
///   过关,而 `Ana` 右边是 `Betz`(没有数值),过不了。
fn lab_name_is_trustworthy(boxes: &[Box], i: usize) -> bool {
    let t = &boxes[i].text;
    if t.chars().any(|c| ('\u{4e00}'..='\u{9fa5}').contains(&c)) {
        return true;
    }
    if t.chars().filter(|c| c.is_ascii_alphabetic()).count() >= 4 {
        return true;
    }
    carries_value_or_unit(t)
        || next_box_in_reading_order(boxes, i).is_some_and(|n| carries_value_or_unit(&n.text))
}

/// 像不像化验表的内容框:整行(`looks_like_lab_row`)或只有项目名
/// (`looks_like_lab_name`,且过得了 [`lab_name_is_trustworthy`] 那道旁证)。
/// 页眉带的终点、页脚带的下界都按它算——两条带子都是「不许盖住表格」,用的必须是
/// 同一套「什么算表格」。
fn is_lab_content_box(boxes: &[Box], i: usize) -> bool {
    looks_like_lab_row(&boxes[i].text)
        || (looks_like_lab_name(&boxes[i].text) && lab_name_is_trustworthy(boxes, i))
}

/// 英文报告的页脚锚点。`Digitally signed by Dr. Cameron Cordara` 这一行实测原样上云
/// (extract-repro-report.md §5):这张表里 6 个中文词一个都不命中,GNU_Health 送出去的
/// 图底部签名、公钥、Test id 全在。按**小写**比较——真实报告里大小写不定
/// (`Digitally signed by` 的 `signed` 就是小写)。
const FOOTER_ANCHORS_EN: &[&str] = &["signed by", "reported by", "reviewed by", "physician"];

/// 像不像页脚锚点行(检验者/审核者/打印时间/报告医生等,以及 [`FOOTER_ANCHORS_EN`])。
fn looks_like_footer(t: &str) -> bool {
    let lower = t.to_lowercase();
    if FOOTER_ANCHORS_EN.iter().any(|a| lower.contains(a)) {
        return true;
    }
    [
        "检验者",
        "审核者",
        "打印时间",
        "报告医生",
        "报告医师",
        "审核医生",
    ]
    .iter()
    .any(|a| t.contains(a))
}

/// 这一框有没有提到**人名类**锚点(`anchors::ANCHORS` 里 kind = `P` 的那批:姓名/
/// 检验者/审核者/送检医生…)。提到了就整框涂黑,**不管 A 层有没有真的取到值**。
///
/// 为什么不能只靠第 1 类的「redact_text 改了就涂」:A 层要取到值才算命中,而 OCR 把
/// 名字糊掉一半的时候取不到 —— 实测血常规报告4 的 `审核者贸`(名字被认成一个「贸」)、
/// `检验者29028` 两框,`redact_text` 一个都不动,`ends_with_anchor_word` 也不认(锚点词
/// 不在框尾)。这两框此前**唯一**的遮盖就是那条整宽页脚带;页脚带一旦按真化验行的位置
/// 往下让,它们就露在送出的图上了。锚点词本身就是「这框里有个人名」的证据,取值成不成功
/// 不该决定涂不涂。
///
/// 收 `P`(人名)与 `N`(各类单号/ID)两类。`N` 是这一轮补的:英文报告的
/// `Test id B165AAF4` / `MRN 0012345` 这类框,A 层的取值同样可能因为大小写或 OCR 噪声
/// 落空,而它们此前唯一的遮盖也是整宽页脚带(review-21-22.md Critical 2)。
/// `A`(住址籍贯)/`U` 类不收 —— 那两类是自由文本,按词命中会把正常叙述整框涂掉。
/// `性别`/`年龄`/`科室` 是**保留字段**(见 `anchors::EXTRA_STOPS` 的注释),不在锚点表里,
/// 本来就不会被涂。化验行也不会误伤 —— `looks_like_lab_row` 自己就把带锚点词的行排除在外。
///
/// **按小写比**:真实英文报告里大小写不定(`Digitally signed by` 的 `signed` 是小写,
/// `Test id` 有时印成 `TEST ID`)。CJK 不受大小写影响,中文那批行为一字不变。
fn mentions_identity_anchor(t: &str) -> bool {
    let lower = t.to_lowercase();
    anchors::ANCHORS
        .iter()
        .any(|(a, kind)| matches!(*kind, "P" | "N") && lower.contains(&a.to_lowercase()))
}

/// 把 `t` 尾部的分隔符/冒号去掉之后,是不是恰好以一个身份锚点词结尾(fix round 2
/// item 1)。用来抓「标签在框尾、值被切进下一框」的悬空锚点——跟 `has_anchor_word`
/// 不同的是,这里要求锚点词就是(去掉尾部标点后)整框的结尾,不是随便出现在框里
/// 的某个位置,不然「审核者已复核」这类锚点词出现在句中、值就在本框里的正常行也会
/// 被误判成悬空。
///
/// 同样按小写比:`Digitally signed by` 这一框就是靠这条抓住的(它以锚点词
/// `Signed by` 结尾),然后连带把阅读顺序上的下一框 `Dr. Cameron Cordara` 一起涂掉。
fn ends_with_anchor_word(t: &str) -> bool {
    let trimmed = t
        .trim_end_matches(|c: char| {
            c.is_whitespace()
                || matches!(c, ':' | '：' | ',' | '，' | ';' | '；' | '、' | '|' | '。')
        })
        .to_lowercase();
    anchors::ANCHORS
        .iter()
        .any(|(a, _)| trimmed.ends_with(&a.to_lowercase()))
}

/// 涂黑边距:线框高度的 2%,至少 2px——盖住反走样的笔画毛边。
fn margin_for(line_height: f32) -> f32 {
    (line_height * 0.02).max(2.0)
}

/// 裁到页面范围内,防止越界矩形。
fn clip(r: Rect, page_w: f32, page_h: f32) -> Rect {
    Rect {
        left: r.left.max(0.0).min(page_w),
        top: r.top.max(0.0).min(page_h),
        right: r.right.max(0.0).min(page_w),
        bottom: r.bottom.max(0.0).min(page_h),
    }
}

/// 框的几何量,顺带纠正 OCR 偶尔给出的「倒装」框(`right<left` / `bottom<top`,
/// fix round 1 item 6)——只在读取时纠正,不改调用方传入的 `Box`。
fn norm_rect(b: &Box) -> (f32, f32, f32, f32) {
    let (left, right) = if b.left <= b.right {
        (b.left, b.right)
    } else {
        (b.right, b.left)
    };
    let (top, bottom) = if b.top <= b.bottom {
        (b.top, b.bottom)
    } else {
        (b.bottom, b.top)
    };
    (left, top, right, bottom)
}

/// 按行高留边距、裁到页面范围,推入 `out`。
fn push_painted(out: &mut Vec<Rect>, b: &Box, page_w: f32, page_h: f32) {
    let (left, top, right, bottom) = norm_rect(b);
    let m = margin_for(bottom - top);
    let clipped = clip(
        Rect {
            left: left - m,
            top: top - m,
            right: right + m,
            bottom: bottom + m,
        },
        page_w,
        page_h,
    );
    // 健全性检查(fix round 1 item 5):框本身有面积、且跟 page_w/page_h 同一坐标系时,
    // 裁剪后不该整个塌成 0 面积——塌成 0 通常意味着调用方传错了坐标系(比如拿了没做
    // preprocess 的原始朝向帧的框,配 EngineLines 那张 preprocess 过的 working frame)。
    debug_assert!(
        !(right > left && bottom > top)
            || (clipped.right > clipped.left && clipped.bottom > clipped.top),
        "redact_boxes: 有面积的框裁剪后塌成 0 面积——多半是 boxes 和 page_w/page_h 不是同一坐标系"
    );
    out.push(clipped);
}

/// 两个框在竖直方向的重叠比例(相对 `a` 自己的高度)。
fn vertical_overlap_frac(a: (f32, f32, f32, f32), c: (f32, f32, f32, f32)) -> f32 {
    let overlap = (a.3.min(c.3) - a.1.max(c.1)).max(0.0);
    let ah = (a.3 - a.1).max(f32::EPSILON);
    overlap / ah
}

/// 悬空锚点(标签在框尾、取值失败,比如「联系人」单独一框)时,阅读顺序上的下一框:
/// 优先同一行右侧(那一框左边界在本框右边界的一点松弛范围内,且竖直重叠 > 50%);
/// 没有就找下一行(顶边界明显更靠下、且竖直基本不重叠的框里,顶边界最小、左边界最小
/// 的那个)。
///
/// 「同一行右侧」的松弛量是 `max(4px, 本框行高的 20%)`(fix round 2 item 2):OCR
/// 切出来的相邻两框水平方向经常有一两像素的重叠(比如「联系人」和紧跟着的姓名框),
/// 严格要求 `右邻框.left >= 本框.right` 会把这种边界擦边的正常邻框漏掉。
fn next_box_in_reading_order<'a>(boxes: &'a [Box], i: usize) -> Option<&'a Box> {
    let bi = norm_rect(&boxes[i]);
    let slack = ((bi.3 - bi.1) * 0.2).max(4.0);
    let mut same_line: Option<(&Box, f32)> = None;
    for (j, bj) in boxes.iter().enumerate() {
        if j == i {
            continue;
        }
        let r = norm_rect(bj);
        if r.0 >= bi.2 - slack && vertical_overlap_frac(bi, r) > 0.5 {
            match same_line {
                Some((_, left)) if r.0 >= left => {}
                _ => same_line = Some((bj, r.0)),
            }
        }
    }
    if let Some((b, _)) = same_line {
        return Some(b);
    }

    let mid = bi.1 + (bi.3 - bi.1) * 0.5;
    let mut below: Option<(&Box, f32, f32)> = None;
    for (j, bj) in boxes.iter().enumerate() {
        if j == i {
            continue;
        }
        let r = norm_rect(bj);
        if r.1 >= mid && vertical_overlap_frac(bi, r) <= 0.5 {
            match below {
                Some((_, top, left)) if (r.1, r.0) >= (top, left) => {}
                _ => below = Some((bj, r.1, r.0)),
            }
        }
    }
    below.map(|(b, _, _)| b)
}

/// 是不是一条「真」化验行——像化验行、但本身不是页脚锚点行。页脚带的起点判定要用
/// 这份、不能用 `looks_like_lab_row` 本身:页脚框自己有时也会顺带命中化验行的判定
/// (比如「审核者:樊笋 结果单位 mmol/L」,`审核者` 是页脚锚点、`mmol/L` 又是化验单位),
/// 这时候不能让页脚框自己的存在把自己算作「最后一条化验行」,从而拿自己的位置来
/// 卡自己(fix round 2 item 3)。
fn is_real_lab_row(boxes: &[Box], i: usize) -> bool {
    is_lab_content_box(boxes, i) && !looks_like_footer(&boxes[i].text)
}

/// 决定哪些 OCR 行框要涂黑(图片档脱敏,spec §1)。
///
/// **坐标系**:`boxes` 与 `page_w`/`page_h` 必须是同一套像素坐标——典型来源是
/// `ocr::recognize_engine_lines` 返回的 `EngineLines::lines` 配它自己的 `frame`
/// 尺寸,不能拿原始朝向帧量出的框配这里的页面尺寸(反之亦然)。
///
/// 四类矩形,均按各自参考行的行高留 2%(至少 2px)边距、裁到页面范围,最后去重
/// (同一个矩形被两条规则各推了一次的情况——比如某框既是命中又是悬空锚点——只留一份):
/// 1. 逐框跑 `redact_text(...,0)`,与 `dates::shift_dates(...,0)` 的基准比较——文本
///    发生变化(命中 K/A/P 三层任一)的整框涂黑;**提到身份锚点词(人名/单号)的框一律涂黑**,
///    哪怕 A 层没取到值(见 [`mentions_identity_anchor`])。基准用日期归一化过的文本而不是原文,
///    这样单纯的日期写法归一(`2024年3月5日`→`2024-03-05`,偏移量 0)不会被误判成命中
///    (fix round 1 item 4);命中判定的层次与 `redact_text` 完全一致,不另建第二份判断。
/// 2. 页眉带:从页面顶部到第一个「像化验表内容」的框顶(整行,**或只有项目名**——
///    布局重建会把名字和数值切进不同框,见 [`looks_like_lab_name`]),整宽涂黑。
///    没有化验内容 → 不产生页眉带(不是整页兜底涂黑)。
/// 3. 页脚带:从第一条**在某条(排除页脚框自己的)化验行之下**、含检验者/审核者/
///    打印时间/报告医生等锚点的框顶到页面底部,整宽涂黑;起点再往下推到**最后一条**
///    真化验行的底边之下,保证带子不横切表格(斜着拍的单子上左栏页脚会排在右栏化验行
///    之前)。要求「在化验行之下」是因为
///    这类词也可能出现在页眉(报告抬头的打印时间),不加这道顺序保护会把页眉当成页脚、
///    整页涂黑(fix round 1 item 1)。没有化验行,或化验行下面没有这类锚点行 → 不产生
///    页脚带(页眉/正文里的医生姓名仍然会被第 1 类逐框命中涂黑,只是不再触发整条页脚带)。
/// 4. 悬空锚点补涂:某框(去掉尾部分隔符/冒号之后)以身份锚点词(`anchors::ANCHORS`)
///    结尾——不管这框本身有没有被第 1 类判定为命中(fix round 2 item 1:标签和取值
///    分属两框时,带值的那半框——比如「姓名:张建国 性别:男 联系人」里的「张建国」——
///    会先命中,但旧代码用 `else if` 让「联系人」这个悬空标签白白放过了它右边/下边
///    那个真正带 PHI 的框);这类框连同阅读顺序上的下一框一起涂黑(fix round 1 item 3,
///    下一框的查找容许一点水平松弛,fix round 2 item 2)。
pub fn redact_boxes(boxes: &[Box], known: &KnownIdentity, page_w: f32, page_h: f32) -> Vec<Rect> {
    let mut out = Vec::new();

    for (i, b) in boxes.iter().enumerate() {
        let r = redact_text(&b.text, known, 0);
        let baseline = dates::shift_dates(&b.text, 0);
        if r.text != baseline || mentions_identity_anchor(&b.text) {
            push_painted(&mut out, b, page_w, page_h);
        }
        if ends_with_anchor_word(&b.text) {
            push_painted(&mut out, b, page_w, page_h);
            if let Some(next) = next_box_in_reading_order(boxes, i) {
                push_painted(&mut out, next, page_w, page_h);
            }
        }
    }

    if let Some(first) = (0..boxes.len())
        .filter(|i| is_lab_content_box(boxes, *i))
        .map(|i| &boxes[i])
        .min_by(|a, c| norm_rect(a).1.total_cmp(&norm_rect(c).1))
    {
        let (_, top, _, bottom) = norm_rect(first);
        let m = margin_for(bottom - top);
        out.push(clip(
            Rect {
                left: 0.0,
                top: 0.0,
                right: page_w,
                bottom: top + m,
            },
            page_w,
            page_h,
        ));
    }

    if let Some(foot) = boxes
        .iter()
        .filter(|b| looks_like_footer(&b.text))
        .filter(|cand| {
            let cand_top = norm_rect(cand).1;
            (0..boxes.len())
                .any(|j| is_real_lab_row(boxes, j) && norm_rect(&boxes[j]).1 <= cand_top)
        })
        .min_by(|a, c| norm_rect(a).1.total_cmp(&norm_rect(c).1))
    {
        let (_, top, _, bottom) = norm_rect(foot);
        let m = margin_for(bottom - top);
        // 带子的起点再往下推,直到不横切**任何**一条真化验行(fix round 3)。锚点框
        // 「在某一条化验行之下」只保证它不在页眉,不保证它在**最后**一条之下:斜着拍的
        // 单子上(实测血常规报告4 rotation_deg=−100,即摆正 −90 之后还剩 ~10°),左栏的
        // 「审核者」比右栏还没读完的化验行更靠上,整宽带从它那里一刀切到底,连着两行
        // 化验一起黑掉 —— 实测少 4 条 lab(extract-repro-report.md §2)。
        //
        // 只推起点、**不取消**带子:页脚下面跟着「结果仅供参考 mmol/L」这类含单位标记
        // 的免责声明时(它也会被算成化验行),带子照样存在,只是从那条声明之下开始
        // ——页脚锚点框自己带的 PHI 仍由第 1 类逐框命中涂黑,不依赖这条带子。
        let lab_floor = (0..boxes.len())
            .filter(|i| is_real_lab_row(boxes, *i))
            .map(|i| {
                let (_, lab_top, _, lab_bottom) = norm_rect(&boxes[i]);
                lab_bottom + margin_for(lab_bottom - lab_top)
            })
            .fold(f32::NEG_INFINITY, f32::max);
        out.push(clip(
            Rect {
                left: 0.0,
                top: (top - m).max(lab_floor),
                right: page_w,
                bottom: page_h,
            },
            page_w,
            page_h,
        ));
    }

    // fix round 2:去重——同一矩形被多条规则各推一次的情况(命中 + 悬空锚点前瞻都
    // 落到同一框上)只留一份。
    let mut deduped: Vec<Rect> = Vec::with_capacity(out.len());
    for r in out {
        if !deduped.contains(&r) {
            deduped.push(r);
        }
    }
    deduped
}

#[cfg(test)]
mod tests {
    use super::*;

    fn known() -> KnownIdentity {
        KnownIdentity {
            name: "孟丁".into(),
            id_number: Some("110101199001011234".into()),
            phone: Some("13800138000".into()),
        }
    }

    #[test]
    fn known_name_is_removed_even_when_glued() {
        let r = redact_text(
            "姓名孟丁性别男 年龄2岁 门诊号90051065 科室儿科",
            &known(),
            0,
        );
        assert!(!r.text.contains("孟丁"), "{}", r.text);
        assert!(r.text.contains("性别男"), "性别保留:{}", r.text);
        assert!(r.text.contains("年龄2岁"), "年龄保留:{}", r.text);
        assert!(r.text.contains("科室儿科"), "科室保留:{}", r.text);
        assert!(!r.text.contains("90051065"), "门诊号掩掉:{}", r.text);
    }

    #[test]
    fn anchors_mask_value_and_doctor_names() {
        let r = redact_text("北京协和医院检验报告\n姓名:张建国  性别:男  年龄:60岁 病案号:62198842\n审核者樊笋  检验者:王涛", &known(), 0);
        assert!(
            !r.text.contains("张建国")
                && !r.text.contains("62198842")
                && !r.text.contains("樊笋")
                && !r.text.contains("王涛"),
            "{}",
            r.text
        );
        assert!(
            !r.text.contains("北京协和医院"),
            "医院名掩成 [H1]:{}",
            r.text
        );
        assert!(r.text.contains("[H1]"), "{}", r.text);
        assert!(r.text.contains("年龄:60岁"), "{}", r.text);
    }

    #[test]
    fn patterns_catch_id_phone_long_digits_url() {
        let r = redact_text("条码 2023061512345 电话 010-69156114 手机13912345678 身份证 44010519850101123X 网址 www.pumch.cn 白细胞 5.6 4.0-10.0", &known(), 0);
        for leak in [
            "2023061512345",
            "69156114",
            "13912345678",
            "44010519850101123X",
            "www.pumch.cn",
        ] {
            assert!(!r.text.contains(leak), "{leak} 漏了:{}", r.text);
        }
        assert!(
            r.text.contains("白细胞 5.6 4.0-10.0"),
            "检验值与区间不动:{}",
            r.text
        );
    }

    #[test]
    fn restore_puts_everything_back() {
        let src = "北京协和医院 姓名:张建国 采集时间:2024-03-05 门诊号:20230615-1046";
        let r = redact_text(src, &known(), 7);
        assert!(r.text.contains("2024-03-12"), "{}", r.text);
        let back = restore(&r.text, &r.map);
        assert_eq!(back, src);
    }

    // --- fix round 1: 复现审阅发现的泄漏/误伤,逐条钉住 ---

    #[test]
    fn dot_or_dash_lead_in_no_longer_swallows_the_whole_number() {
        // 旧实现:紧邻 `.`/`-` 就当成小数/区间跳过,不管另一侧是不是数字——
        // 结果座机号、条码号整段漏网。三条各占一行,避免和「化验行豁免」(item4)的
        // 行级判断互相干扰——那条规则本身在 patterns.rs 的测试里单独钉住了。
        let r = redact_text(
            "电话010-69156114\n编号No.2023061512345\n参考 100000-300000",
            &known(),
            0,
        );
        assert!(!r.text.contains("69156114"), "座机号漏了:{}", r.text);
        assert!(!r.text.contains("2023061512345"), "条码号漏了:{}", r.text);
        assert!(
            r.text.contains("100000-300000"),
            "参考区间不该被掩:{}",
            r.text
        );
    }

    #[test]
    fn adjacent_long_digit_runs_are_all_masked_not_just_the_first() {
        // 旧实现:消费型正则把分隔符吃进上一个匹配,下一个数字串就找不到合法起点了。
        let r = redact_text("90051065/62198842", &known(), 0);
        assert!(
            !r.text.contains("90051065") && !r.text.contains("62198842"),
            "{}",
            r.text
        );

        let r2 = redact_text("111111 222222 333333", &known(), 0);
        for leak in ["111111", "222222", "333333"] {
            assert!(!r2.text.contains(leak), "{leak} 漏了:{}", r2.text);
        }
    }

    #[test]
    fn anchor_id_and_ward_values_are_not_truncated_by_a_character_cap() {
        // 旧实现:锚点值上限 12 字符,18 位身份证号/16 位住院号被拦腰截断,尾巴明文残留。
        let src = "身份证号44010519850101123X 住院号:1234567890123456";
        let r = redact_text(src, &known(), 0);
        assert!(!r.text.contains("44010519850101123X"), "{}", r.text);
        assert!(!r.text.contains("1234567890123456"), "{}", r.text);
        for tail in ["01123X", "3456"] {
            assert!(!r.text.contains(tail), "残留尾巴 {tail}:{}", r.text);
        }
        let back = restore(&r.text, &r.map);
        assert_eq!(back, src);
    }

    #[test]
    fn compact_date_is_shifted_not_masked_and_round_trips() {
        let src = "采集时间20240305";
        let r = redact_text(src, &known(), 7);
        assert!(
            r.text.contains("20240312"),
            "紧凑日期该偏移而不是掩码:{}",
            r.text
        );
        let back = restore(&r.text, &r.map);
        assert_eq!(back, src);
    }

    #[test]
    fn name_anchor_value_stops_at_next_anchor_word_even_when_glued() {
        let unrelated = KnownIdentity {
            name: "赵六".into(),
            id_number: None,
            phone: None,
        };
        let r = redact_text("姓名孟丁性别男门诊号90051065", &unrelated, 0);
        assert_eq!(r.text, "姓名[P1]性别男门诊号[N1]");
    }

    #[test]
    fn bare_doctor_and_patient_words_are_not_anchors() {
        let a = redact_text("患者主诉发热三天 无咳嗽", &known(), 0);
        assert_eq!(a.text, "患者主诉发热三天 无咳嗽");
        let b = redact_text("医生建议复查肝功能", &known(), 0);
        assert_eq!(b.text, "医生建议复查肝功能");
    }

    #[test]
    fn repeated_value_reuses_the_same_numbered_placeholder() {
        let r = redact_text("审核者樊笋 复核 审核者樊笋", &known(), 0);
        let p_count = r
            .map
            .placeholders
            .iter()
            .filter(|(p, _)| p.starts_with("[P"))
            .count();
        assert_eq!(
            p_count, 1,
            "同一个值该只分配一个占位符:{:?}",
            r.map.placeholders
        );
        assert_eq!(r.text.matches("[P1]").count(), 2, "{}", r.text);
    }

    #[test]
    fn lab_row_units_age_and_sex_all_survive() {
        let r = redact_text(
            "性别:男 年龄:45岁 白细胞 5.6 10^9/L 血小板 120000 参考 100000-300000",
            &known(),
            0,
        );
        for keep in [
            "性别:男",
            "年龄:45岁",
            "白细胞 5.6",
            "10^9/L",
            "血小板 120000",
            "100000-300000",
        ] {
            assert!(r.text.contains(keep), "{keep} 应保留:{}", r.text);
        }
    }

    // --- fix round 2: 第一轮修复自己引入的两条新泄漏,加上两个小的取值边界问题 ---

    #[test]
    fn unanchored_barcode_is_masked_even_though_a_lab_unit_appears_later_in_text() {
        // item A:旧的“整行豁免”让隔壁一句话里出现的 g/L 把跟它八竿子打不着的条码也放过了。
        let r = redact_text("标本 2023061512345 血红蛋白 130 g/L", &known(), 0);
        assert!(!r.text.contains("2023061512345"), "{}", r.text);
        assert!(r.text.contains("130 g/L"), "{}", r.text);
    }

    #[test]
    fn shape_rules_no_longer_split_a_longer_digit_run() {
        // item B:去掉 \b 之后 mobile_re/id18_re 会在长数字串**中间**找到形状对得上的
        // 子串,把中间一截单独掩掉,两头的数字留明文(比如 "样本 2023139123456789" 曾经
        // 变成 "样本 2023[T1]9")。断言占位符对应的值是整段原文,不是被切出来的中间一截
        // ——这样才真正堵住"两头明文残留"这个漏洞,只看 text 里还含不含完整原串堵不住。
        let r = redact_text("样本 2023139123456789", &known(), 0);
        assert_eq!(r.map.placeholders.len(), 1, "{:?}", r.map.placeholders);
        assert_eq!(
            r.map.placeholders[0].1, "2023139123456789",
            "{:?}",
            r.map.placeholders
        );

        let r2 = redact_text("12345678901234567890", &known(), 0);
        assert_eq!(r2.map.placeholders.len(), 1, "{:?}", r2.map.placeholders);
        assert_eq!(
            r2.map.placeholders[0].1, "12345678901234567890",
            "{:?}",
            r2.map.placeholders
        );
    }

    #[test]
    fn six_character_name_is_not_truncated() {
        // item C:4 字上限把「乌力吉巴图」这样 5 个字的名字截断,尾字「图」明文残留。
        let unrelated = KnownIdentity {
            name: "赵六".into(),
            id_number: None,
            phone: None,
        };
        let r = redact_text("姓名乌力吉巴图 性别男", &unrelated, 0);
        assert_eq!(r.text, "姓名[P1] 性别男");
    }

    #[test]
    fn n_kind_value_stops_at_digit_to_cjk_boundary_even_when_glued_to_narrative() {
        // item D:不设上限的号码取值会把紧贴着、没有分隔符的叙述文字也吞进去。
        let r = redact_text("婚姻已婚 门诊号90051065病区三", &known(), 0);
        let n1 = r
            .map
            .placeholders
            .iter()
            .find(|(p, _)| p == "[N1]")
            .map(|(_, v)| v.as_str());
        assert_eq!(n1, Some("90051065"), "{:?}", r.map.placeholders);
        assert!(r.text.contains("病区三"), "{}", r.text);
    }

    #[test]
    fn wechat_official_account_handle_is_masked() {
        // 微信公众号句柄标识的是医院/科室账号,不是号码/URL/邮箱形状,P 层三个模式都
        // 逮不到它;补一个 U 类锚点,和 A 类一样自由取值到下一个分隔符/锚点词为止。
        let r = redact_text(
            "微信公众号 pumch_official 咨询电话010-69156114",
            &known(),
            0,
        );
        assert!(!r.text.contains("pumch_official"), "{}", r.text);
        assert!(r.text.contains("咨询电话"), "{}", r.text);

        let r2 = redact_text("公众号:pumch_official", &known(), 0);
        assert!(!r2.text.contains("pumch_official"), "{}", r2.text);
    }

    // --- fix round 2: U 类锚点上一轮补漏时自己引入的过度脱敏 ---

    #[test]
    fn u_kind_anchor_does_not_fire_without_a_handle_shaped_value() {
        // 「公众号」后面跟的是叙述句、不是账号句柄——旧实现拿 take_free_value 一路扫到底,
        // 把「获取检验报告」整段吃成占位符。值必须是 ASCII 句柄形状,不是就不取,原文不动。
        let r = redact_text("扫码关注公众号获取检验报告", &known(), 0);
        assert_eq!(r.text, "扫码关注公众号获取检验报告");
    }

    #[test]
    fn u_kind_anchor_does_not_swallow_a_full_stop_and_beyond() {
        let r = redact_text("详见公众号。下次复查", &known(), 0);
        assert_eq!(r.text, "详见公众号。下次复查");
    }

    #[test]
    fn u_kind_handle_value_stops_before_trailing_narrative() {
        let r = redact_text("微信公众号 pumch_official 下次复查", &known(), 0);
        assert_eq!(r.text, "微信公众号 [U1] 下次复查");
    }

    #[test]
    fn u_kind_handle_value_stops_at_a_full_stop() {
        let r = redact_text("公众号:xiehe_hospital。", &known(), 0);
        assert_eq!(r.text, "公众号:[U1]。");
    }

    #[test]
    fn a_kind_value_stops_at_a_full_stop_too() {
        // is_sep 加了「。」之后,不只是 U 类受益——A 类(民族/职业等)一样不该把全角句号
        // 后面的下一句吞进去。
        let unrelated = KnownIdentity {
            name: "赵六".into(),
            id_number: None,
            phone: None,
        };
        let r = redact_text("民族汉族。职业教师", &unrelated, 0);
        assert_eq!(r.text, "民族[A1]。职业[A2]");
    }

    // --- redact_boxes: 图片档「哪些框要涂」-----------------------------------

    #[test]
    fn redact_boxes_paints_hits_and_header_footer_bands() {
        let k = KnownIdentity {
            name: "张建国".into(),
            id_number: None,
            phone: None,
        };
        let b = |t: &str, top: f32| Box {
            text: t.into(),
            left: 10.0,
            top,
            right: 300.0,
            bottom: top + 20.0,
        };
        let boxes = vec![
            b("北京协和医院检验报告", 0.0),
            b("姓名:张建国 性别:男 年龄:60岁", 30.0),
            b("白细胞计数 WBC 5.6 10^9/L 4.0-10.0", 100.0),
            b("血红蛋白 HGB 135 g/L 115-150", 130.0),
            b("审核者:樊笋 检验者:王涛", 400.0),
        ];
        let rects = redact_boxes(&boxes, &k, 400.0, 500.0);
        // 页眉带:0..100 整宽;页脚带:400..500 整宽;命中框各一
        assert!(
            rects
                .iter()
                .any(|r| r.top == 0.0 && r.bottom >= 100.0 && r.left == 0.0 && r.right == 400.0),
            "{rects:?}"
        );
        assert!(
            rects
                .iter()
                .any(|r| r.top <= 400.0 && r.bottom == 500.0 && r.left == 0.0),
            "{rects:?}"
        );
        // 化验行不涂(整框——右边界还是 300,不是页眉/页脚那种整宽带)
        assert!(
            !rects
                .iter()
                .any(|r| (r.top - 100.0).abs() < 1.0 && r.right == 300.0),
            "{rects:?}"
        );
        assert!(
            !rects
                .iter()
                .any(|r| (r.top - 130.0).abs() < 1.0 && r.right == 300.0),
            "{rects:?}"
        );
    }

    #[test]
    fn redact_boxes_no_lab_row_means_no_header_band_not_whole_page() {
        // 没有任何一行「像化验行」——不该拿整页兜底涂黑。
        let k = KnownIdentity {
            name: "张建国".into(),
            id_number: None,
            phone: None,
        };
        let boxes = vec![
            Box {
                text: "北京协和医院检验报告".into(),
                left: 0.0,
                top: 0.0,
                right: 300.0,
                bottom: 20.0,
            },
            Box {
                text: "姓名:张建国".into(),
                left: 0.0,
                top: 30.0,
                right: 300.0,
                bottom: 50.0,
            },
        ];
        let rects = redact_boxes(&boxes, &k, 400.0, 500.0);
        // 只有命中框(姓名那行),没有 left=0/right=page_w 的整宽页眉带
        assert!(!rects
            .iter()
            .any(|r| r.left == 0.0 && r.right == 400.0 && r.top == 0.0));
        assert!(rects.iter().any(|r| r.top < 30.0)); // 命中框加了 margin,能往上探一点,但不到 0
    }

    #[test]
    fn redact_boxes_no_footer_anchor_means_no_footer_band() {
        let k = KnownIdentity {
            name: "张建国".into(),
            id_number: None,
            phone: None,
        };
        let boxes = vec![Box {
            text: "白细胞 5.6 10^9/L 4.0-10.0".into(),
            left: 0.0,
            top: 100.0,
            right: 300.0,
            bottom: 120.0,
        }];
        let rects = redact_boxes(&boxes, &k, 400.0, 500.0);
        assert!(!rects.iter().any(|r| r.bottom == 500.0), "{rects:?}");
    }

    #[test]
    fn redact_boxes_margin_is_two_percent_of_line_height_min_2px() {
        let k = KnownIdentity {
            name: "张建国".into(),
            id_number: None,
            phone: None,
        };
        // 行高 20 → 2% = 0.4,取下限 2px。
        let boxes = vec![Box {
            text: "姓名:张建国".into(),
            left: 50.0,
            top: 100.0,
            right: 200.0,
            bottom: 120.0,
        }];
        let rects = redact_boxes(&boxes, &k, 400.0, 500.0);
        let r = rects
            .iter()
            .find(|r| (r.top - 98.0).abs() < 0.01)
            .expect("命中框应扩 2px 边距");
        assert_eq!(r.left, 48.0);
        assert_eq!(r.right, 202.0);
        assert_eq!(r.bottom, 122.0);

        // 行高 200 → 2% = 4px,超过下限,应按 4px 算。
        let boxes2 = vec![Box {
            text: "姓名:张建国".into(),
            left: 50.0,
            top: 100.0,
            right: 200.0,
            bottom: 300.0,
        }];
        let rects2 = redact_boxes(&boxes2, &k, 400.0, 500.0);
        let r2 = rects2
            .iter()
            .find(|r| (r.top - 96.0).abs() < 0.01)
            .expect("大行高按 2% 扩边距");
        assert_eq!(r2.bottom, 304.0);
    }

    #[test]
    fn redact_boxes_clips_to_page_bounds() {
        let k = KnownIdentity {
            name: "张建国".into(),
            id_number: None,
            phone: None,
        };
        // 贴着页面边缘的命中框,加了 margin 之后不能越界。
        let boxes = vec![Box {
            text: "姓名:张建国".into(),
            left: 0.0,
            top: 0.0,
            right: 400.0,
            bottom: 20.0,
        }];
        let rects = redact_boxes(&boxes, &k, 400.0, 500.0);
        assert_eq!(rects.len(), 1);
        assert_eq!(rects[0].left, 0.0);
        assert_eq!(rects[0].top, 0.0);
        assert_eq!(rects[0].right, 400.0);
    }

    // --- fix round 1: 独立复核抓出的 3 类 CRITICAL + 2 类 IMPORTANT ------------

    #[test]
    fn footer_anchor_above_lab_rows_does_not_paint_whole_page() {
        // item 1:旧实现拿「所有页脚关键词框里 top 最小的那个」当页脚带起点——页眉里的
        // 「打印时间」本身就是全篇 top 最小的锚点词框之一,于是页脚带从 0 涂到底,整页涂黑。
        let k = KnownIdentity {
            name: "张建国".into(),
            id_number: None,
            phone: None,
        };
        let b = |t: &str, top: f32| Box {
            text: t.into(),
            left: 0.0,
            top,
            right: 300.0,
            bottom: top + 20.0,
        };
        let boxes = vec![
            b("北京协和医院检验报告 打印时间:2024-03-06 09:12", 0.0),
            b("白细胞计数 WBC 5.6 10^9/L 4.0-10.0", 100.0),
            b("血红蛋白 HGB 135 g/L 115-150", 130.0),
            b("审核者:樊笋", 400.0),
        ];
        let rects = redact_boxes(&boxes, &k, 400.0, 500.0);
        assert!(
            !rects.iter().any(|r| r.top == 0.0 && r.bottom == 500.0),
            "整页涂黑了:{rects:?}"
        );
        assert!(
            rects
                .iter()
                .any(|r| r.bottom == 500.0 && r.top > 130.0 && r.top <= 400.0),
            "页脚带该从化验行下面的审核者框开始:{rects:?}"
        );
    }

    #[test]
    fn header_band_is_not_collapsed_by_phone_or_date_shaped_lines() {
        // item 2:旧的 looks_like_lab_row 只看「有数字 + 有 -/~」,电话号码、ISO 日期这类
        // 页眉常见行会被误判成化验行,把页眉带收缩到只剩 2px 边距。
        let k = KnownIdentity {
            name: "张建国".into(),
            id_number: None,
            phone: None,
        };
        let b = |t: &str, top: f32| Box {
            text: t.into(),
            left: 0.0,
            top,
            right: 300.0,
            bottom: top + 20.0,
        };
        let boxes = vec![
            b("北京协和医院 电话 010-69156114", 0.0),
            b("打印日期 2024-03-06", 30.0),
            b("白细胞计数 WBC 5.6 10^9/L 4.0-10.0", 100.0),
        ];
        let rects = redact_boxes(&boxes, &k, 400.0, 500.0);
        assert!(
            rects
                .iter()
                .any(|r| r.top == 0.0 && r.right == 400.0 && r.bottom >= 100.0 && r.bottom < 130.0),
            "页眉带被电话/日期行提前收尾了:{rects:?}"
        );
    }

    #[test]
    fn dangling_anchor_and_its_value_in_the_next_box_to_the_right_are_both_painted() {
        // item 3:「联系人」单独一框、姓名被 OCR 切进右边那一框——旧实现只看本框文本
        // 有没有变化,取不到值的锚点框和它右边那个裸姓名框都不会被判定为命中。
        let k = KnownIdentity {
            name: "张建国".into(),
            id_number: None,
            phone: None,
        };
        let boxes = vec![
            Box {
                text: "联系人".into(),
                left: 0.0,
                top: 200.0,
                right: 60.0,
                bottom: 220.0,
            },
            Box {
                text: "李秀兰".into(),
                left: 70.0,
                top: 200.0,
                right: 140.0,
                bottom: 220.0,
            },
        ];
        let rects = redact_boxes(&boxes, &k, 400.0, 500.0);
        assert!(
            rects
                .iter()
                .any(|r| r.left <= 0.0 && r.right >= 58.0 && r.top <= 200.0 && r.bottom >= 220.0),
            "联系人 框未涂:{rects:?}"
        );
        assert!(
            rects.iter().any(|r| r.left <= 70.0 && r.right >= 138.0),
            "李秀兰 框未涂:{rects:?}"
        );
    }

    #[test]
    fn dangling_anchor_and_its_value_on_the_next_line_below_are_both_painted() {
        let k = KnownIdentity {
            name: "张建国".into(),
            id_number: None,
            phone: None,
        };
        let boxes = vec![
            Box {
                text: "联系人".into(),
                left: 0.0,
                top: 200.0,
                right: 60.0,
                bottom: 220.0,
            },
            Box {
                text: "李秀兰".into(),
                left: 0.0,
                top: 230.0,
                right: 70.0,
                bottom: 250.0,
            },
        ];
        let rects = redact_boxes(&boxes, &k, 400.0, 500.0);
        assert!(
            rects
                .iter()
                .any(|r| r.top <= 200.0 && r.bottom >= 220.0 && r.right >= 58.0),
            "{rects:?}"
        );
        assert!(
            rects
                .iter()
                .any(|r| r.top >= 228.0 && r.bottom >= 250.0 && r.right >= 68.0),
            "{rects:?}"
        );
    }

    #[test]
    fn date_format_normalization_alone_is_not_a_hit() {
        // item 4:旧实现拿原文和 redact_text 的结果直接比——纯格式归一(斜杠转横杠,
        // 偏移量 0)也算「变了」,把没有任何 K/A/P 命中的化验行整框涂黑。
        let k = KnownIdentity {
            name: "张建国".into(),
            id_number: None,
            phone: None,
        };
        let boxes = vec![Box {
            text: "检测日期 2024/03/06".into(),
            left: 10.0,
            top: 50.0,
            right: 200.0,
            bottom: 70.0,
        }];
        let rects = redact_boxes(&boxes, &k, 400.0, 500.0);
        assert!(rects.is_empty(), "纯日期格式归一不该被当命中涂黑:{rects:?}");
    }

    #[test]
    fn inverted_box_coordinates_are_normalized_before_margins() {
        // item 6:OCR 偶尔给出 right<left / bottom<top 的倒装框,归一化之后应该和正常框
        // 算出同一个矩形,而不是让负的宽高把 margin 算错。
        let k = KnownIdentity {
            name: "张建国".into(),
            id_number: None,
            phone: None,
        };
        let boxes = vec![Box {
            text: "姓名:张建国".into(),
            left: 200.0,
            top: 120.0,
            right: 50.0,
            bottom: 100.0,
        }];
        let rects = redact_boxes(&boxes, &k, 400.0, 500.0);
        assert_eq!(rects.len(), 1);
        assert_eq!(rects[0].left, 48.0);
        assert_eq!(rects[0].top, 98.0);
        assert_eq!(rects[0].right, 202.0);
        assert_eq!(rects[0].bottom, 122.0);
    }

    #[test]
    fn empty_text_and_empty_box_list_paint_nothing() {
        let k = KnownIdentity {
            name: "张建国".into(),
            id_number: None,
            phone: None,
        };
        assert!(redact_boxes(&[], &k, 400.0, 500.0).is_empty());
        let boxes = vec![Box {
            text: String::new(),
            left: 0.0,
            top: 0.0,
            right: 100.0,
            bottom: 20.0,
        }];
        assert!(redact_boxes(&boxes, &k, 400.0, 500.0).is_empty());
    }

    // --- fix round 2: 独立复核在 round 1 的基础上又抓出的 3 类漏涂 + 1 类误涂 ------

    #[test]
    fn dangling_anchor_at_the_end_of_an_already_hit_box_still_forwards_to_the_next_box() {
        // item 1:「姓名:张建国 性别:男 联系人」这一框自己已经因为「张建国」命中,旧代码
        // 用 `else if` 只在**没命中**时才检查悬空锚点,于是「联系人」后面另一框里的
        // 「李秀兰」(不是户主、也不在已知身份表里)就没人管了。改成命中判断和悬空锚点
        // 判断互不排斥,各自独立触发。
        let k = KnownIdentity {
            name: "张建国".into(),
            id_number: None,
            phone: None,
        };
        let boxes = vec![
            Box {
                text: "姓名:张建国 性别:男 联系人".into(),
                left: 0.0,
                top: 200.0,
                right: 260.0,
                bottom: 220.0,
            },
            Box {
                text: "李秀兰".into(),
                left: 270.0,
                top: 200.0,
                right: 340.0,
                bottom: 220.0,
            },
        ];
        let rects = redact_boxes(&boxes, &k, 400.0, 500.0);
        assert!(
            rects.iter().any(|r| r.left <= 0.0 && r.right >= 258.0),
            "第一框未涂:{rects:?}"
        );
        assert!(
            rects.iter().any(|r| r.left <= 270.0 && r.right >= 338.0),
            "李秀兰 框未涂:{rects:?}"
        );
    }

    #[test]
    fn same_line_lookahead_tolerates_a_couple_pixels_of_box_overlap() {
        // item 2:OCR 切出来的相邻两框水平方向经常有一两像素重叠,严格要求
        // `右邻框.left >= 本框.right` 会把这种正常邻框漏掉——两个分支都进不去,
        // 「联系人」单独一框、右边紧挨着(略微重叠)的姓名框就不会被前瞻到。
        let k = KnownIdentity {
            name: "张建国".into(),
            id_number: None,
            phone: None,
        };
        let boxes = vec![
            Box {
                text: "联系人".into(),
                left: 0.0,
                top: 200.0,
                right: 60.0,
                bottom: 220.0,
            },
            Box {
                text: "李秀兰".into(),
                left: 58.0,
                top: 200.0,
                right: 140.0,
                bottom: 220.0,
            },
        ];
        let rects = redact_boxes(&boxes, &k, 400.0, 500.0);
        assert!(
            rects.iter().any(|r| r.left <= 58.0 && r.right >= 138.0),
            "重叠邻框未被前瞻到:{rects:?}"
        );
    }

    #[test]
    fn footer_band_survives_when_the_footer_box_itself_carries_a_unit_token() {
        // item 3 case A:「审核者:樊笋 结果单位 mmol/L」这一框自己就含单位标记,会被
        // `looks_like_lab_row` 判定成化验行——旧代码拿它自己的 bottom 去更新
        // last_lab_bottom,导致它自己的 top 必然小于自己的 bottom,自己把自己排除掉。
        let k = KnownIdentity {
            name: "张建国".into(),
            id_number: None,
            phone: None,
        };
        let b = |t: &str, top: f32| Box {
            text: t.into(),
            left: 0.0,
            top,
            right: 300.0,
            bottom: top + 20.0,
        };
        let boxes = vec![
            b("白细胞计数 WBC 5.6 10^9/L 4.0-10.0", 100.0),
            b("血红蛋白 HGB 135 g/L 115-150", 130.0),
            b("审核者:樊笋 结果单位 mmol/L", 400.0),
        ];
        let rects = redact_boxes(&boxes, &k, 400.0, 500.0);
        assert!(
            rects.iter().any(|r| r.bottom == 500.0 && r.top <= 400.0),
            "页脚带没出现:{rects:?}"
        );
    }

    #[test]
    fn footer_band_survives_when_a_unit_bearing_note_sits_below_it() {
        // item 3 case B:页脚下面还跟着一条「结果仅供参考 mmol/L」之类的免责声明,本身
        // 含单位标记、会被算成化验行。曾经用「整页最后一条化验行的 bottom」做**筛选**
        // 条件,这条声明会把页脚整条带子筛没。现在它只做**起点下推**(fix round 3),
        // 带子照样存在,只是从这条声明之下开始 —— 声明本身没有 PHI,页脚锚点框自己的
        // 姓名仍由第 1 类逐框命中涂黑。
        let k = KnownIdentity {
            name: "张建国".into(),
            id_number: None,
            phone: None,
        };
        let b = |t: &str, top: f32| Box {
            text: t.into(),
            left: 0.0,
            top,
            right: 300.0,
            bottom: top + 20.0,
        };
        let boxes = vec![
            b("白细胞计数 WBC 5.6 10^9/L 4.0-10.0", 100.0),
            b("血红蛋白 HGB 135 g/L 115-150", 130.0),
            b("审核者:樊笋", 400.0),
            b("结果仅供参考 mmol/L", 450.0),
        ];
        let rects = redact_boxes(&boxes, &k, 400.0, 500.0);
        assert!(
            rects
                .iter()
                .any(|r| r.bottom == 500.0 && r.top > 130.0 && r.top <= 475.0),
            "页脚带被后面的免责声明挤没了:{rects:?}"
        );
    }

    #[test]
    fn header_band_ends_at_a_name_only_lab_box() {
        // fix round 3 / extract-repro-report.md §3:布局重建把项目名和数值切进不同框
        // (斜页上必然如此),`1白细胞计数` 这种纯名字框不含单位也不含区间,
        // `looks_like_lab_row` 不认,页眉带于是越过它继续往下 —— 实测血常规报告1 带到
        // y155,把 y42 起的头两条化验行盖掉;报告5 同样吃掉前两行。
        let k = KnownIdentity {
            name: "张建国".into(),
            id_number: None,
            phone: None,
        };
        let b = |t: &str, top: f32| Box {
            text: t.into(),
            left: 10.0,
            top,
            right: 300.0,
            bottom: top + 20.0,
        };
        let boxes = vec![
            b("北京协和医院检验报告", 0.0),
            b("姓名:张建国", 30.0),
            b("1白细胞计数", 100.0),         // 纯名字框:没有单位、没有区间
            b("5.6 10^9/L 4.0-10.0", 130.0), // 值被切到另一框
        ];
        let rects = redact_boxes(&boxes, &k, 400.0, 500.0);
        let band = rects
            .iter()
            .find(|r| r.left == 0.0 && r.right == 400.0 && r.top == 0.0)
            .unwrap_or_else(|| panic!("页眉带没出现:{rects:?}"));
        assert!(
            band.bottom <= 104.0,
            "页眉带盖住了纯名字的化验行(应 ≤104,实际 {}):{rects:?}",
            band.bottom
        );
    }

    #[test]
    fn a_patient_name_that_is_also_a_dictionary_alias_is_not_a_lab_name() {
        // GNU_Health 那张单子上患者叫 `Ana Betz`,而 `ana`(抗核抗体)是词典里的别名。
        // `terminology::resolve` 会按空格拆词、拿 `Ana` 以置信度 1.0 命中,页眉带于是
        // 收到患者信息之上,把 `Ana Betz`/`Cameron Cordara` 露在送出的图上。
        // `looks_like_lab_name` 只认整串精确命中,所以必须判 false。
        assert!(!looks_like_lab_name("Ana Betz"));
        assert!(looks_like_lab_name("Hemoglobin"));
        assert!(looks_like_lab_name("1白细胞计数"));
        assert!(looks_like_lab_name("12红细胞计数"));
        // 表头/页眉词一个都不许算项目名
        for t in ["检验项目", "结果", "参考范围", "Test Name", "科室儿科"] {
            assert!(!looks_like_lab_name(t), "{t} 不该算项目名");
        }
    }

    #[test]
    fn a_name_anchor_box_is_painted_even_when_the_value_cannot_be_parsed() {
        // fix round 3:OCR 把审核者的名字糊成一个字(实测血常规报告4 的「审核者贸」)时
        // A 层取不到值,`redact_text` 不动这框,`ends_with_anchor_word` 也不认(锚点词不在
        // 框尾)。此前唯一的遮盖是整宽页脚带 —— 页脚带按真化验行往下让之后就露了。
        let k = KnownIdentity {
            name: "我".into(), // 成员名,姓名闸空转(gate.rs 要求 >= 2 字)
            id_number: None,
            phone: None,
        };
        let b = |t: &str, top: f32| Box {
            text: t.into(),
            left: 10.0,
            top,
            right: 300.0,
            bottom: top + 20.0,
        };
        for t in ["审核者贸", "检验者29028", "送检医生董"] {
            let boxes = vec![b(t, 400.0)];
            let rects = redact_boxes(&boxes, &k, 400.0, 500.0);
            assert!(
                rects
                    .iter()
                    .any(|r| r.top <= 400.0 && r.bottom >= 420.0 && r.right < 400.0),
                "{t} 没被逐框涂黑:{rects:?}"
            );
        }
        // 保留字段不受影响:性别/年龄/科室不是人名锚点,不该因为这条规则被涂掉。
        for t in ["性别男", "年龄2岁", "科室儿科"] {
            let boxes = vec![b(t, 400.0)];
            assert!(
                redact_boxes(&boxes, &k, 400.0, 500.0).is_empty(),
                "{t} 是保留字段,不该涂"
            );
        }
    }

    /// review-21-22.md Critical 2 的原样反例:左栏页脚三框(y400/430/455)排在右栏
    /// 化验行(y470)**之上**,页脚带的起点因此被顶到 492 —— 三框一个都盖不住。
    /// 逐框兜底必须让它们**不依赖带子**各自被涂黑。
    #[test]
    fn english_footer_boxes_are_painted_even_when_the_band_moves_below_them() {
        let k = KnownIdentity {
            name: "Ana Betz".into(),
            id_number: None,
            phone: None,
        };
        let b = |t: &str, left: f32, top: f32| Box {
            text: t.into(),
            left,
            top,
            right: left + 180.0,
            bottom: top + 20.0,
        };
        let boxes = vec![
            b("Hemoglobin 12 g/dL 11.0 - 16.0", 10.0, 100.0),
            b("Digitally signed by", 10.0, 400.0),
            b("Dr. Cameron Cordara", 10.0, 430.0),
            b("Test id B165AAF4", 10.0, 455.0),
            // 右栏还没读完的化验行,比左栏页脚更靠下 → 把带子顶到 492
            b("WBC 6.7 10^3/uL 4.5-11", 210.0, 470.0),
        ];
        let rects = redact_boxes(&boxes, &k, 400.0, 500.0);
        for (i, bx) in boxes.iter().enumerate().take(4).skip(1) {
            let (l, t, r, bot) = (bx.left, bx.top, bx.right, bx.bottom);
            assert!(
                rects
                    .iter()
                    .any(|rc| rc.left <= l && rc.right >= r && rc.top <= t && rc.bottom >= bot),
                "第 {i} 框 {:?} 没被盖住(COVERED=false):{rects:?}",
                bx.text
            );
        }
    }

    /// review-21-22.md Important 3:斜页上布局重建把 `Name  Ana Betz` 切成两框,
    /// `Ana` 单独一框而 `normalize("Ana")` = ana(抗核抗体)置信度 1.0 —— 页眉带会被
    /// 收到 y42,把整块英文患者信息露出来。真正的项目名从 `Hemoglobin` 那一行才开始。
    #[test]
    fn a_short_latin_name_token_does_not_collapse_the_header_band() {
        let k = KnownIdentity {
            name: "我".into(), // 姓名闸空转的情形:带子是唯一防线
            id_number: None,
            phone: None,
        };
        let b = |t: &str, left: f32, top: f32| Box {
            text: t.into(),
            left,
            top,
            right: left + 60.0,
            bottom: top + 14.0,
        };
        let boxes = vec![
            b("LABORATORY REPORT", 200.0, 90.0),
            b("Ana", 98.0, 109.0),
            b("Betz", 160.0, 109.0),
            b("Patient ID PAC001", 372.0, 109.0),
            b("Cameron Cordara", 97.0, 143.0),
            b("Hemoglobin", 46.0, 215.0),
            b("12", 226.0, 215.0),
            b("RBC", 46.0, 234.0),
            b("3.3", 225.0, 234.0),
        ];
        let rects = redact_boxes(&boxes, &k, 576.0, 627.0);
        let band = rects
            .iter()
            .find(|r| r.left == 0.0 && r.right == 576.0 && r.top == 0.0)
            .unwrap_or_else(|| panic!("页眉带没出现:{rects:?}"));
        assert!(
            band.bottom >= 202.0,
            "页眉带被 `Ana` 收上去了(应 ≥202,实际 {}):{rects:?}",
            band.bottom
        );
        // 而真的三字母缩写项目名(右邻框有数值)仍然算表格内容 —— 带子不许盖到它。
        assert!(
            band.bottom <= 220.0,
            "页眉带盖住了 Hemoglobin/RBC 那几行(实际 {}):{rects:?}",
            band.bottom
        );
    }

    #[test]
    fn english_report_gets_a_footer_band_too() {
        // extract-repro-report.md §5:页脚锚点表原本全是中文,GNU_Health 送出去的图底部
        // `Digitally signed by Dr. Cameron Cordara` / `GNU Public Key` / `Test id` 一个字
        // 没涂。真实报告里大小写不定(`signed` 是小写),所以比较必须不区分大小写。
        let k = KnownIdentity {
            name: "Ana Betz".into(),
            id_number: None,
            phone: None,
        };
        let b = |t: &str, top: f32| Box {
            text: t.into(),
            left: 10.0,
            top,
            right: 300.0,
            bottom: top + 20.0,
        };
        for anchor in [
            "Digitally signed by",
            "Reported by K. Lee",
            "Reviewed by J. Doe",
            "Physician: J. Doe",
        ] {
            let boxes = vec![
                b("Hemoglobin 12 g/dL 11.0 - 16.0", 100.0),
                b(anchor, 400.0),
                b("Dr. Cameron Cordara", 430.0),
            ];
            let rects = redact_boxes(&boxes, &k, 400.0, 500.0);
            assert!(
                rects
                    .iter()
                    .any(|r| r.left == 0.0 && r.right == 400.0 && r.bottom == 500.0),
                "{anchor} 没触发页脚带:{rects:?}"
            );
        }
    }

    #[test]
    fn footer_band_starts_below_the_last_lab_row_on_a_tilted_page() {
        // fix round 3 / extract-repro-report.md §2:斜着拍的单子上,左栏的「审核者」
        // (y400)比右栏还没读完的两条化验行(y430/y460)更靠上。旧代码只要求锚点在
        // **某一条**化验行之下,整宽带从 400 一刀切到底,把那两行一起黑掉 —— 实测
        // 血常规报告4 因此少 4 条 lab。带子的起点必须推到最后一条化验行的底边之下。
        let k = KnownIdentity {
            name: "张建国".into(),
            id_number: None,
            phone: None,
        };
        let b = |t: &str, left: f32, top: f32| Box {
            text: t.into(),
            left,
            top,
            right: left + 180.0,
            bottom: top + 20.0,
        };
        let boxes = vec![
            b("白细胞计数 WBC 5.6 10^9/L 4.0-10.0", 10.0, 100.0),
            b("血红蛋白 HGB 135 g/L 115-150", 10.0, 130.0),
            // 左栏页脚,比右栏剩下的两行更靠上(页面是斜的)
            b("审核者:樊笋 检验者:王涛", 10.0, 400.0),
            b("红细胞计数 RBC 4.35 10^12/L 3.8-5.1", 210.0, 430.0),
            b("血小板计数 PLT 210 10^9/L 100-300", 210.0, 460.0),
        ];
        let rects = redact_boxes(&boxes, &k, 400.0, 500.0);
        let band = rects
            .iter()
            .find(|r| r.left == 0.0 && r.right == 400.0 && r.bottom == 500.0)
            .unwrap_or_else(|| panic!("页脚带没出现:{rects:?}"));
        assert!(
            band.top >= 480.0,
            "页脚带横切了最后两条化验行(应 ≥480,实际 {}):{rects:?}",
            band.top
        );
    }

    #[test]
    fn three_part_id_shaped_like_a_range_does_not_collapse_the_header_band() {
        // item 4:「标本编号 24-03-1234」里的「24-03」形状也像化验区间,但后面还跟着
        // 「-1234」——不是区间应有的收尾方式(空白/标记/单位到行尾),不该被当成化验行。
        // 反例:真化验行(带单位,或区间后只跟异常标记)必须继续被认出来。
        let k = KnownIdentity {
            name: "张建国".into(),
            id_number: None,
            phone: None,
        };
        let b = |t: &str, top: f32| Box {
            text: t.into(),
            left: 0.0,
            top,
            right: 300.0,
            bottom: top + 20.0,
        };
        let boxes = vec![
            b("北京协和医院检验报告", 0.0),
            b("标本编号 24-03-1234", 30.0),
            b("血红蛋白 130 g/L 115-150", 100.0),
            b("白细胞 5.6 4.0-10.0 ↑", 130.0),
        ];
        let rects = redact_boxes(&boxes, &k, 400.0, 500.0);
        // 页眉带得撑到第 100 行才收尾,不能在「标本编号」那行(top 30)就提前结束
        assert!(
            rects
                .iter()
                .any(|r| r.top == 0.0 && r.right == 400.0 && r.bottom >= 100.0 && r.bottom < 130.0),
            "页眉带被「标本编号 24-03-1234」提前收尾了:{rects:?}"
        );
        assert!(looks_like_lab_row("血红蛋白 130 g/L 115-150"));
        assert!(looks_like_lab_row("白细胞 5.6 4.0-10.0 ↑"));
        assert!(!looks_like_lab_row("标本编号 24-03-1234"));
    }

    #[test]
    fn identical_rects_pushed_by_more_than_one_rule_are_deduped() {
        // 「姓名:张建国 性别:男 联系人」这一框会被命中规则(K 层命中「张建国」)和悬空
        // 锚点规则(以「联系人」结尾)各推一次同一个矩形——去重之后只留一份;加上前瞻
        // 推给「李秀兰」的那一份,一共 2 个不重复的矩形,不是 3 个。
        let k = KnownIdentity {
            name: "张建国".into(),
            id_number: None,
            phone: None,
        };
        let boxes = vec![
            Box {
                text: "姓名:张建国 性别:男 联系人".into(),
                left: 0.0,
                top: 200.0,
                right: 260.0,
                bottom: 220.0,
            },
            Box {
                text: "李秀兰".into(),
                left: 270.0,
                top: 200.0,
                right: 340.0,
                bottom: 220.0,
            },
        ];
        let rects = redact_boxes(&boxes, &k, 400.0, 500.0);
        assert_eq!(rects.len(), 2, "去重后应该只剩 2 个矩形:{rects:?}");
        let mut seen: Vec<Rect> = Vec::new();
        for r in &rects {
            assert!(!seen.contains(r), "重复矩形:{r:?}");
            seen.push(*r);
        }
    }
}
