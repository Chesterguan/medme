//! A 层:锚点后的值换占位符。词表 = parser::labs::PAGE_FURNITURE 的 22 个(那边是私有 const,
//! 且语义是「挡假化验行」,这边是「掩身份」,两份各自演进,不共享)+ 本 spec 清单补的。
//! 裸的「医生/医师/患者/病人」不当锚点——它们常出现在正常临床叙述里(“医生建议复查”
//! “患者主诉发热”),不是「标签:值」的字段结构,当锚点会把后面一整句话错当成人名吃掉;
//! 复合词(送检医生/审核医生/主治医师/报告医师等)仍是可靠的标签,保留。
use super::redact::RestoreMap;
use regex::Regex;
use std::sync::OnceLock;

/// 锚点 → 占位符种类。人名类 P,号码/地址类 N/A,账号句柄类 U(微信公众号等,和 P 层的
/// URL/邮箱共用同一种占位符前缀,取值规则是自己的一套——见 `take_handle_value`,句柄
/// 形状字符集,不是 A 类那种自由文本),时间类不掩(日期由 dates 偏移;时间戳无身份信息)。
pub const ANCHORS: &[(&str, &str)] = &[
    ("姓名", "P"),
    ("名字", "P"),
    ("联系人", "P"),
    ("监护人", "P"),
    ("检验者", "P"),
    ("审核者", "P"),
    ("送检医生", "P"),
    ("申请医生", "P"),
    ("报告医生", "P"),
    ("审核医生", "P"),
    ("主治医师", "P"),
    ("报告医师", "P"),
    ("门诊号", "N"),
    ("住院号", "N"),
    ("病案号", "N"),
    ("病历号", "N"),
    ("就诊卡号", "N"),
    ("就诊卡", "N"),
    ("床号", "N"),
    ("样本号", "N"),
    ("标本号", "N"),
    ("样本编号", "N"),
    ("条码号", "N"),
    ("条码", "N"),
    ("检验号", "N"),
    ("检查号", "N"),
    ("影像号", "N"),
    ("申请单号", "N"),
    ("医保卡号", "N"),
    ("医保号", "N"),
    ("社保号", "N"),
    ("身份证号", "N"),
    ("身份证", "N"),
    ("发票号", "N"),
    ("收费单号", "N"),
    ("流水号", "N"),
    ("设备编号", "N"),
    ("仪器编号", "N"),
    ("住址", "A"),
    ("地址", "A"),
    ("家庭住址", "A"),
    ("工作单位", "A"),
    ("籍贯", "A"),
    ("民族", "A"),
    ("职业", "A"),
    ("婚姻", "A"),
    ("微信公众号", "U"),
    ("公众号", "U"),
    // --- 英文报告(review-21-22.md Critical 2)-------------------------------
    // 这批词的**主要用途是图片档逐框涂黑**:`redact_boxes` 的
    // `mentions_identity_anchor` / `ends_with_anchor_word` 按它们判「这框里有身份信息」,
    // 不依赖取值成不成功 —— 页脚带一旦按化验行往下让,英文页脚此前一点兜底都没有
    // (实测反例:`Digitally signed by` / `Dr. Cameron Cordara` / `Test id B165AAF4`
    // 三框 COVERED 全 false)。
    //
    // 文本档(`apply`)这边**只增不减**:N 类走 `take_free_value`,`Test id : B165AAF4`
    // 这类编号掩成 [N*];P 类走 `take_name_value`,它在取不到中文名时会再试
    // `take_latin_name_value`,于是 `Doctor  Cameron Cordara` / `Signed by Dr. X` 这些
    // 英文人名也掩得到了(在此之前只有图片档那边逐框涂黑,文本档原样发出去)。
    //
    // 上面那条「裸的医生/患者不当锚点、会把后面一整句话吃掉」的顾虑,在拉丁分支里由
    // 五道边界挡住(见 `take_latin_name_value`)。实测 `Doctor`/`Physician` 换行后紧跟
    // 表格第一行 —— `WBC 6.7 …` / `Hemoglobin 12 …` / `COMPLETE BLOOD COUNT` /
    // `Hb 12.0` / `Ca 2.3 mmol/L` —— 一个字都不会被吃掉。
    ("Digitally signed by", "P"),
    ("Signed by", "P"),
    ("Reported by", "P"),
    ("Verified by", "P"),
    ("Reviewed by", "P"),
    ("Physician", "P"),
    ("Doctor", "P"),
    ("Patient ID", "N"),
    ("Test id", "N"),
    ("Sample id", "N"),
    ("Specimen id", "N"),
    ("Accession", "N"),
    ("Report id", "N"),
    ("MRN", "N"),
];

/// 年龄/性别/科室是**保留字段**,锚点表里没有它们,但 OCR 常常把它们和前一个字段粘在
/// 一起、中间没有分隔符(“姓名孟丁性别男”“门诊号90051065科室儿科”)。取值时必须把
/// 这几个词当成硬性停止点,连同所有锚点词一起,不然值会把它们吃进去。
const EXTRA_STOPS: &[&str] = &["性别", "年龄", "科室"];

fn starts_with_stop_word(s: &str) -> bool {
    ANCHORS.iter().any(|(a, _)| s.starts_with(a)) || EXTRA_STOPS.iter().any(|w| s.starts_with(w))
}

fn is_cjk(c: char) -> bool {
    ('\u{4e00}'..='\u{9fa5}').contains(&c)
}

fn is_sep(c: char) -> bool {
    c.is_whitespace() || matches!(c, ':' | '：' | ',' | '，' | ';' | '；' | '、' | '|' | '。')
}

/// U 类(账号句柄,微信公众号等)允许出现在句柄里的字符——ASCII 字母/数字/`_`/`@`/`.`/`-`。
/// 句柄和自然语言叙述没有可靠的分隔符(“公众号获取检验报告”中间没有空格/标点),只能靠
/// 字符集本身当边界:叙述句是纯 CJK,句柄是纯 ASCII,两者在形状上不会重叠。
fn is_handle_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '_' | '@' | '.' | '-')
}

/// 找锚点词本身用的正则(只找词,不找值——值交给下面两个函数手工扫,因为「遇到停止词
/// 提前收尾」这种逻辑,regex crate 不支持零宽断言,没法写进一条正则里)。
fn anchor_word_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        let alts: Vec<String> = ANCHORS.iter().map(|(a, _)| regex::escape(a)).collect();
        Regex::new(&alts.join("|")).expect("anchor word re")
    })
}

/// 「XX市XX医院 / XX大学附属XX医院 / XX人民医院」整串掩成 [H]。
fn hospital_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"[\u{4e00}-\u{9fa5}]{2,12}(?:医院|卫生院|诊所|医学中心|医疗中心)(?:[\u{4e00}-\u{9fa5}]{0,4}(?:分院|院区))?").expect("hospital re"))
}

fn kind_of(anchor: &str) -> &'static str {
    ANCHORS
        .iter()
        .find(|(a, _)| *a == anchor)
        .map(|(_, k)| *k)
        .unwrap_or("N")
}

/// P 类(人名):2~6 个中文字符(部分少数民族/复姓名字有 5~6 字);一碰到任意锚点词或
/// 性别/年龄/科室 开头,立刻收尾——即使中间没有分隔符。
///
/// 取不到中文名时再试**拉丁人名**([`take_latin_name_value`])。中文那条路一字未动:
/// 只有它返回 `None` 时才走拉丁那条,所以对既有语料**不可能掩得比以前少**。
fn take_name_value(rest: &str) -> Option<&str> {
    let mut end = 0;
    let mut count = 0;
    for c in rest.chars() {
        if count >= 6 || !is_cjk(c) || starts_with_stop_word(&rest[end..]) {
            break;
        }
        end += c.len_utf8();
        count += 1;
    }
    if count >= 2 {
        return Some(&rest[..end]);
    }
    take_latin_name_value(rest)
}

/// 一个 token 像不像**拉丁人名的一节**。
///
/// **必须是 Title-case,不能是全大写** —— 化验表里的项目缩写(`WBC`/`RBC`/`HCT`)和
/// 段落标题(`COMPLETE BLOOD COUNT`)都是全大写,放行它们就会把表格内容当人名掩掉
/// (实测 `Doctor\nWBC 6.7 …` 把 `WBC` 掩成了 `[P1]`)。两个例外:
/// * **称谓/缩写**:3 字符以内且以 `.` 结尾(`Dr.`、`J.`,以及 OCR 把 `Dr.` 认成的 `D1.`);
/// * **中间名缩写**:单个大写字母,且**不能是第一个 token** —— 第一个位置留给
///   `H`/`L` 这类化验异常标记,不许它开头就命中。
fn is_latin_name_token(t: &str, is_first: bool) -> bool {
    let mut cs = t.chars();
    if !cs.next().is_some_and(|c| c.is_ascii_uppercase()) {
        return false;
    }
    let rest: Vec<char> = cs.collect();
    if !rest
        .iter()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '\'' | '-'))
    {
        return false;
    }
    if rest.iter().any(|c| c.is_ascii_lowercase()) {
        return true; // Cameron / O'Neil / Smith-Jones
    }
    (t.len() <= 3 && t.ends_with('.')) || (t.len() == 1 && !is_first)
}

/// 把一个 token 去掉首尾的 `.`/`'`/`-` 之后拿去查词典。
fn lookup_token(t: &str) -> Option<f32> {
    let word = t.trim_matches(|c: char| matches!(c, '.' | '\'' | '-'));
    terminology::normalize(&word.to_lowercase()).map(|m| m.confidence)
}

/// 这个 token 是不是词典**精确命中**的化验项目名(置信度 1.0 = 字典别名逐字命中)。
/// 不卡长度:`Hb`/`Ca`/`Na`/`Mg`/`Fe` 这些两三字母的项目缩写必须挡得住
/// (review-21-fix.md Important 1)。**只在「整个候选就这一个 token」时使用** ——
/// 词典里 `ana`/`alt`/`cea` 与真人名撞车,`Ana Betz` 那种两 token 的候选不能因为
/// 头一个词恰好是缩写就整个判否。
fn is_exact_lab_term(t: &str) -> bool {
    lookup_token(t).is_some_and(|c| c >= 1.0)
}

/// 这个 token 像不像化验项目名,**用在逐 token 那一关**。这里保留 4 字母门槛:
/// 模糊/归一化的非精确命中(OCR 混淆表 0.5、药名剥壳 0.8)本来就不可靠,短词更不可靠,
/// 拿它判否会误杀真人名。精确命中留给 [`is_exact_lab_term`] 在候选整体那一关判。
fn is_lab_term_token(t: &str) -> bool {
    let letters = t.chars().filter(|c| c.is_ascii_alphabetic()).count();
    letters >= 4 && lookup_token(t).is_some()
}

/// 这个 token 是不是**纯数值**(`12.0`、`2.3`、`140`、`0.9`、`4.5-11`)。
/// 用来认「候选后面紧跟着一个数」这个形状 —— 那是化验行,不是人名。
fn is_numeric_token(t: &str) -> bool {
    !t.is_empty()
        && t.chars().any(|c| c.is_ascii_digit())
        && t.chars().all(|c| {
            c.is_ascii_digit() || matches!(c, '.' | '-' | '~' | '<' | '>' | '%' | '+' | ',')
        })
}

/// P 类的**拉丁人名**分支:英文报告里 `Doctor` / `Signed by` / `Reported by` 这些锚点
/// 后面跟的是 ASCII 名字,老的 `take_name_value` 只认 CJK,一个字都掩不到 —— 图片档
/// 那边这一框已经被逐框涂黑,文本档却原样发出去(review-21-22.md 之后的遗留缺口)。
///
/// 取**最多 3 个**首字母大写的 token(`Dr. Cameron Cordara`、`Mary Jane O'Neil`),
/// 五条边界,都是为了不把表格内容当人名吃掉。`apply` 的 `skip` 连换行一起吃,所以
/// 「`Physician` 在行尾、下一行就是表格第一行」这种极常见的版式一定会撞上来:
/// * token 之间只允许**一个空格**。列对齐的报告里字段之间是 2 个以上空格
///   (`Doctor    Cameron Cordara          Test id B165AAF4`),所以值到
///   `Cordara` 就收尾,不会把后面那列的 `Test` 吞进来。
/// * 碰到任意锚点词/停止词立刻收尾(与中文分支同一条规则)。
/// * 逐 token:4 个字母以上、且词典认得的,判否(`Hemoglobin`/`Creatinine`/`Glucose`)。
/// * **整个候选只有一个 token、且它精确命中词典** → 判否。挡住 `Hb`/`Ca`/`Na`/`Mg`
///   这些两三字母的项目缩写(review-21-fix.md Important 1);而 `Ana Betz` 是两个
///   token,不受影响 —— `Ana` 撞 `ana`(抗核抗体)只是三字母缩写的巧合。
/// * **候选后面紧跟着一个纯数值** → 判否。`Hb 12.0` / `Ca 2.3 mmol/L` /
///   `Glucose Fasting 5.6` 都是这个形状:后面跟着数的不是人名,是化验行。
fn take_latin_name_value(rest: &str) -> Option<&str> {
    let mut end = 0;
    let mut taken = 0;
    while taken < 3 {
        let at = &rest[end..];
        if at.is_empty() || starts_with_stop_word(at) {
            break;
        }
        // 第二个 token 起:前面必须恰好一个空格(列对齐的 2 空格即字段边界)。
        let start = if taken == 0 {
            0
        } else if at.starts_with(' ') && !at[1..].starts_with(' ') {
            1
        } else {
            break;
        };
        let body = &at[start..];
        if starts_with_stop_word(body) {
            break;
        }
        let tok_len = body.find(|c: char| c.is_whitespace()).unwrap_or(body.len());
        let tok = &body[..tok_len];
        if tok.is_empty() || !is_latin_name_token(tok, taken == 0) || is_lab_term_token(tok) {
            break;
        }
        end += start + tok_len;
        taken += 1;
    }
    if taken == 0 {
        return None;
    }
    let value = &rest[..end];
    // 整个候选就一个 token、且精确命中词典 → 是项目缩写,不是人名。
    if taken == 1 && is_exact_lab_term(value.trim()) {
        return None;
    }
    // 候选后面紧跟着一个纯数值 → 这是化验行(`Hb 12.0`),不是人名。
    let after = rest[end..].trim_start_matches([' ', '\t']);
    let next_tok = &after[..after
        .find(|c: char| c.is_whitespace())
        .unwrap_or(after.len())];
    if is_numeric_token(next_tok) {
        return None;
    }
    Some(value)
}

/// N/A 类(号码/地址):不设字符数上限,一直取到下一个空白/标点分隔符或下一个锚点词为止
/// ——18 位身份证号、16 位住院号都得整段吃掉,不能像人名那样卡字数。
/// `stop_at_digit_to_cjk` 仅用于 N 类:值一旦以数字开头,后面紧跟的中文字符就不再算进
/// 值里——不然会把没有分隔符、紧贴在号码后面的叙述文字(“门诊号90051065病区三”里的
/// “病区三”)一起吞掉。A 类(住址/民族/职业/婚姻等)本身就是自由文本,没有这种数字/
/// 中文的形状边界可用,继续保持不设上限(fix round 2 item D:已知的残留问题,不在本轮修)。
fn take_free_value(rest: &str, stop_at_digit_to_cjk: bool) -> Option<&str> {
    if rest.starts_with('[') {
        return None; // 已经是占位符(K 层删过),原样放过
    }
    let starts_with_digit =
        stop_at_digit_to_cjk && rest.chars().next().is_some_and(|c| c.is_ascii_digit());
    let mut end = 0;
    for c in rest.chars() {
        if is_sep(c) || starts_with_stop_word(&rest[end..]) || (starts_with_digit && is_cjk(c)) {
            break;
        }
        end += c.len_utf8();
    }
    (end > 0).then(|| &rest[..end])
}

/// U 类(账号句柄):不像 A/N 那样"什么都行、直到分隔符为止"——句柄后面紧跟的往往是
/// 没有分隔符的中文叙述(“关注公众号获取报告”),用 `take_free_value` 会把整句话吃掉。
/// 改成正形状匹配:第一个字符就必须是句柄字符,否则这个锚点根本不取值(“不点火”,
/// 原文原样放过);取到的字符也全部限定在句柄字符集里,天然在遇到 CJK 叙述、全角标点
/// 时收尾,不需要额外的停止词表。
fn take_handle_value(rest: &str) -> Option<&str> {
    if !rest.starts_with(is_handle_char) {
        return None;
    }
    let mut end = 0;
    for c in rest.chars() {
        if !is_handle_char(c) {
            break;
        }
        end += c.len_utf8();
    }
    Some(&rest[..end])
}

pub fn apply(text: &str, map: &mut RestoreMap) -> String {
    let t = hospital_re()
        .replace_all(text, |c: &regex::Captures| map.placeholder("H", &c[0]))
        .into_owned();

    let mut out = String::with_capacity(t.len());
    let mut last = 0;
    for m in anchor_word_re().find_iter(&t) {
        if m.start() < last {
            continue; // 防御性:被上一次取值消费掉的区间不会再产生新匹配的起点
        }
        out.push_str(&t[last..m.start()]);
        let anchor = m.as_str();
        out.push_str(anchor);
        let kind = kind_of(anchor);

        let mut pos = m.end();
        let skip: usize = t[pos..]
            .chars()
            .take_while(|c| *c == ':' || *c == '：' || c.is_whitespace())
            .map(|c| c.len_utf8())
            .sum();
        out.push_str(&t[pos..pos + skip]);
        pos += skip;

        let rest = &t[pos..];
        let value = match kind {
            "P" => take_name_value(rest),
            "U" => take_handle_value(rest),
            _ => take_free_value(rest, kind == "N"),
        };
        if let Some(v) = value {
            out.push_str(&map.placeholder(kind, v));
            pos += v.len();
        }
        last = pos;
    }
    out.push_str(&t[last..]);
    out
}
