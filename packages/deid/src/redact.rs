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
        let n = self.placeholders.iter().filter(|(p, _)| p.starts_with(&format!("[{kind}"))).count() + 1;
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
    let mut map = RestoreMap { placeholders: Vec::new(), shift_days };
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

/// 像不像一条化验行:含数字,且含区间分隔符或常见单位。
fn looks_like_lab_row(t: &str) -> bool {
    let has_digit = t.chars().any(|c| c.is_ascii_digit());
    has_digit
        && (t.contains('-')
            || t.contains('~')
            || ["/L", "%", "mmol", "g/L", "umol", "μmol", "U/L"].iter().any(|u| t.contains(u)))
}

/// 像不像页脚锚点行(检验者/审核者/打印时间/报告医生等)。
fn looks_like_footer(t: &str) -> bool {
    ["检验者", "审核者", "打印时间", "报告医生", "报告医师", "审核医生"].iter().any(|a| t.contains(a))
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

/// 决定哪些 OCR 行框要涂黑(图片档脱敏,spec §1)。
///
/// 三类矩形,均按各自参考行的行高留 2%(至少 2px)边距、裁到页面范围:
/// 1. 逐框跑 `redact_text(...,0)`——文本发生变化(命中 K/A/P 三层任一)的整框涂黑;
///    命中判定与 `redact_text` 完全一致,不另建第二份判断。
/// 2. 页眉带:从页面顶部到第一条「像化验行」的框顶,整宽涂黑。没有化验行 → 不产生页眉带
///    (不是整页兜底涂黑)。
/// 3. 页脚带:从第一条含检验者/审核者/打印时间/报告医生等锚点的框顶到页面底部,整宽涂黑。
///    没有这类锚点行 → 不产生页脚带。
///
/// 日期偏移、单纯的锚点值替换不影响本函数的判定基准——只看框内文本改没改。
pub fn redact_boxes(boxes: &[Box], known: &KnownIdentity, page_w: f32, page_h: f32) -> Vec<Rect> {
    let mut out = Vec::new();

    for b in boxes {
        let r = redact_text(&b.text, known, 0);
        if r.text != b.text {
            let m = margin_for(b.bottom - b.top);
            out.push(clip(
                Rect { left: b.left - m, top: b.top - m, right: b.right + m, bottom: b.bottom + m },
                page_w,
                page_h,
            ));
        }
    }

    if let Some(first) = boxes.iter().filter(|b| looks_like_lab_row(&b.text)).min_by(|a, c| a.top.total_cmp(&c.top)) {
        let m = margin_for(first.bottom - first.top);
        out.push(clip(Rect { left: 0.0, top: 0.0, right: page_w, bottom: first.top + m }, page_w, page_h));
    }

    if let Some(foot) = boxes.iter().filter(|b| looks_like_footer(&b.text)).min_by(|a, c| a.top.total_cmp(&c.top)) {
        let m = margin_for(foot.bottom - foot.top);
        out.push(clip(Rect { left: 0.0, top: foot.top - m, right: page_w, bottom: page_h }, page_w, page_h));
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn known() -> KnownIdentity {
        KnownIdentity { name: "孟丁".into(), id_number: Some("110101199001011234".into()), phone: Some("13800138000".into()) }
    }

    #[test]
    fn known_name_is_removed_even_when_glued() {
        let r = redact_text("姓名孟丁性别男 年龄2岁 门诊号90051065 科室儿科", &known(), 0);
        assert!(!r.text.contains("孟丁"), "{}", r.text);
        assert!(r.text.contains("性别男"), "性别保留:{}", r.text);
        assert!(r.text.contains("年龄2岁"), "年龄保留:{}", r.text);
        assert!(r.text.contains("科室儿科"), "科室保留:{}", r.text);
        assert!(!r.text.contains("90051065"), "门诊号掩掉:{}", r.text);
    }

    #[test]
    fn anchors_mask_value_and_doctor_names() {
        let r = redact_text("北京协和医院检验报告\n姓名:张建国  性别:男  年龄:60岁 病案号:62198842\n审核者樊笋  检验者:王涛", &known(), 0);
        assert!(!r.text.contains("张建国") && !r.text.contains("62198842") && !r.text.contains("樊笋") && !r.text.contains("王涛"), "{}", r.text);
        assert!(!r.text.contains("北京协和医院"), "医院名掩成 [H1]:{}", r.text);
        assert!(r.text.contains("[H1]"), "{}", r.text);
        assert!(r.text.contains("年龄:60岁"), "{}", r.text);
    }

    #[test]
    fn patterns_catch_id_phone_long_digits_url() {
        let r = redact_text("条码 2023061512345 电话 010-69156114 手机13912345678 身份证 44010519850101123X 网址 www.pumch.cn 白细胞 5.6 4.0-10.0", &known(), 0);
        for leak in ["2023061512345", "69156114", "13912345678", "44010519850101123X", "www.pumch.cn"] {
            assert!(!r.text.contains(leak), "{leak} 漏了:{}", r.text);
        }
        assert!(r.text.contains("白细胞 5.6 4.0-10.0"), "检验值与区间不动:{}", r.text);
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
        assert!(r.text.contains("100000-300000"), "参考区间不该被掩:{}", r.text);
    }

    #[test]
    fn adjacent_long_digit_runs_are_all_masked_not_just_the_first() {
        // 旧实现:消费型正则把分隔符吃进上一个匹配,下一个数字串就找不到合法起点了。
        let r = redact_text("90051065/62198842", &known(), 0);
        assert!(!r.text.contains("90051065") && !r.text.contains("62198842"), "{}", r.text);

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
        assert!(r.text.contains("20240312"), "紧凑日期该偏移而不是掩码:{}", r.text);
        let back = restore(&r.text, &r.map);
        assert_eq!(back, src);
    }

    #[test]
    fn name_anchor_value_stops_at_next_anchor_word_even_when_glued() {
        let unrelated = KnownIdentity { name: "赵六".into(), id_number: None, phone: None };
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
        let p_count = r.map.placeholders.iter().filter(|(p, _)| p.starts_with("[P")).count();
        assert_eq!(p_count, 1, "同一个值该只分配一个占位符:{:?}", r.map.placeholders);
        assert_eq!(r.text.matches("[P1]").count(), 2, "{}", r.text);
    }

    #[test]
    fn lab_row_units_age_and_sex_all_survive() {
        let r = redact_text(
            "性别:男 年龄:45岁 白细胞 5.6 10^9/L 血小板 120000 参考 100000-300000",
            &known(),
            0,
        );
        for keep in ["性别:男", "年龄:45岁", "白细胞 5.6", "10^9/L", "血小板 120000", "100000-300000"] {
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
        assert_eq!(r.map.placeholders[0].1, "2023139123456789", "{:?}", r.map.placeholders);

        let r2 = redact_text("12345678901234567890", &known(), 0);
        assert_eq!(r2.map.placeholders.len(), 1, "{:?}", r2.map.placeholders);
        assert_eq!(r2.map.placeholders[0].1, "12345678901234567890", "{:?}", r2.map.placeholders);
    }

    #[test]
    fn six_character_name_is_not_truncated() {
        // item C:4 字上限把「乌力吉巴图」这样 5 个字的名字截断,尾字「图」明文残留。
        let unrelated = KnownIdentity { name: "赵六".into(), id_number: None, phone: None };
        let r = redact_text("姓名乌力吉巴图 性别男", &unrelated, 0);
        assert_eq!(r.text, "姓名[P1] 性别男");
    }

    #[test]
    fn n_kind_value_stops_at_digit_to_cjk_boundary_even_when_glued_to_narrative() {
        // item D:不设上限的号码取值会把紧贴着、没有分隔符的叙述文字也吞进去。
        let r = redact_text("婚姻已婚 门诊号90051065病区三", &known(), 0);
        let n1 = r.map.placeholders.iter().find(|(p, _)| p == "[N1]").map(|(_, v)| v.as_str());
        assert_eq!(n1, Some("90051065"), "{:?}", r.map.placeholders);
        assert!(r.text.contains("病区三"), "{}", r.text);
    }

    #[test]
    fn wechat_official_account_handle_is_masked() {
        // 微信公众号句柄标识的是医院/科室账号,不是号码/URL/邮箱形状,P 层三个模式都
        // 逮不到它;补一个 U 类锚点,和 A 类一样自由取值到下一个分隔符/锚点词为止。
        let r = redact_text("微信公众号 pumch_official 咨询电话010-69156114", &known(), 0);
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
        let unrelated = KnownIdentity { name: "赵六".into(), id_number: None, phone: None };
        let r = redact_text("民族汉族。职业教师", &unrelated, 0);
        assert_eq!(r.text, "民族[A1]。职业[A2]");
    }

    // --- redact_boxes: 图片档「哪些框要涂」-----------------------------------

    #[test]
    fn redact_boxes_paints_hits_and_header_footer_bands() {
        let k = KnownIdentity { name: "张建国".into(), id_number: None, phone: None };
        let b = |t: &str, top: f32| Box { text: t.into(), left: 10.0, top, right: 300.0, bottom: top + 20.0 };
        let boxes = vec![
            b("北京协和医院检验报告", 0.0),
            b("姓名:张建国 性别:男 年龄:60岁", 30.0),
            b("白细胞计数 WBC 5.6 10^9/L 4.0-10.0", 100.0),
            b("血红蛋白 HGB 135 g/L 115-150", 130.0),
            b("审核者:樊笋 检验者:王涛", 400.0),
        ];
        let rects = redact_boxes(&boxes, &k, 400.0, 500.0);
        // 页眉带:0..100 整宽;页脚带:400..500 整宽;命中框各一
        assert!(rects.iter().any(|r| r.top == 0.0 && r.bottom >= 100.0 && r.left == 0.0 && r.right == 400.0), "{rects:?}");
        assert!(rects.iter().any(|r| r.top <= 400.0 && r.bottom == 500.0 && r.left == 0.0), "{rects:?}");
        // 化验行不涂(整框——右边界还是 300,不是页眉/页脚那种整宽带)
        assert!(!rects.iter().any(|r| (r.top - 100.0).abs() < 1.0 && r.right == 300.0), "{rects:?}");
        assert!(!rects.iter().any(|r| (r.top - 130.0).abs() < 1.0 && r.right == 300.0), "{rects:?}");
    }

    #[test]
    fn redact_boxes_no_lab_row_means_no_header_band_not_whole_page() {
        // 没有任何一行「像化验行」——不该拿整页兜底涂黑。
        let k = KnownIdentity { name: "张建国".into(), id_number: None, phone: None };
        let boxes = vec![
            Box { text: "北京协和医院检验报告".into(), left: 0.0, top: 0.0, right: 300.0, bottom: 20.0 },
            Box { text: "姓名:张建国".into(), left: 0.0, top: 30.0, right: 300.0, bottom: 50.0 },
        ];
        let rects = redact_boxes(&boxes, &k, 400.0, 500.0);
        // 只有命中框(姓名那行),没有 left=0/right=page_w 的整宽页眉带
        assert!(!rects.iter().any(|r| r.left == 0.0 && r.right == 400.0 && r.top == 0.0));
        assert!(rects.iter().any(|r| r.top < 30.0)); // 命中框加了 margin,能往上探一点,但不到 0
    }

    #[test]
    fn redact_boxes_no_footer_anchor_means_no_footer_band() {
        let k = KnownIdentity { name: "张建国".into(), id_number: None, phone: None };
        let boxes = vec![Box { text: "白细胞 5.6 10^9/L 4.0-10.0".into(), left: 0.0, top: 100.0, right: 300.0, bottom: 120.0 }];
        let rects = redact_boxes(&boxes, &k, 400.0, 500.0);
        assert!(!rects.iter().any(|r| r.bottom == 500.0), "{rects:?}");
    }

    #[test]
    fn redact_boxes_margin_is_two_percent_of_line_height_min_2px() {
        let k = KnownIdentity { name: "张建国".into(), id_number: None, phone: None };
        // 行高 20 → 2% = 0.4,取下限 2px。
        let boxes = vec![Box { text: "姓名:张建国".into(), left: 50.0, top: 100.0, right: 200.0, bottom: 120.0 }];
        let rects = redact_boxes(&boxes, &k, 400.0, 500.0);
        let r = rects.iter().find(|r| (r.top - 98.0).abs() < 0.01).expect("命中框应扩 2px 边距");
        assert_eq!(r.left, 48.0);
        assert_eq!(r.right, 202.0);
        assert_eq!(r.bottom, 122.0);

        // 行高 200 → 2% = 4px,超过下限,应按 4px 算。
        let boxes2 = vec![Box { text: "姓名:张建国".into(), left: 50.0, top: 100.0, right: 200.0, bottom: 300.0 }];
        let rects2 = redact_boxes(&boxes2, &k, 400.0, 500.0);
        let r2 = rects2.iter().find(|r| (r.top - 96.0).abs() < 0.01).expect("大行高按 2% 扩边距");
        assert_eq!(r2.bottom, 304.0);
    }

    #[test]
    fn redact_boxes_clips_to_page_bounds() {
        let k = KnownIdentity { name: "张建国".into(), id_number: None, phone: None };
        // 贴着页面边缘的命中框,加了 margin 之后不能越界。
        let boxes = vec![Box { text: "姓名:张建国".into(), left: 0.0, top: 0.0, right: 400.0, bottom: 20.0 }];
        let rects = redact_boxes(&boxes, &k, 400.0, 500.0);
        assert_eq!(rects.len(), 1);
        assert_eq!(rects[0].left, 0.0);
        assert_eq!(rects[0].top, 0.0);
        assert_eq!(rects[0].right, 400.0);
    }
}
