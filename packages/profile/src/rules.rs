//! 规则求值的共享上下文与各条规则的实现。**纯函数**:同样的 `Ctx` + 同样的包 +
//! 同样的 `today`,永远得到同样的结果。
use chrono::NaiveDate;

/// 一条被规则引用到的化验证据(用于「这次计分用了哪几张单子」的证据链)。
#[derive(Debug, Clone, serde::Serialize)]
pub struct Evidence {
    /// `parser::SourceDoc::index` —— 调用方据此翻回 document_id。
    pub document_index: usize,
    pub date: Option<String>,
    pub analyte: String,
    pub value: String,
    pub unit: Option<String>,
}

/// 规则求值的全部输入,装配一次、各条规则共用。
pub struct Ctx<'a> {
    /// `parser::aggregate` 的产物:已分组、已换算的化验序列 + 用药区间 + 诊断。
    pub clinical: parser::AggregatedClinical,
    /// schema 2 的族级事实,带上它所在文档的 index 与日期(fact 自己的 `date`
    /// 为空时用文档日期兜底)。
    // 第一个读者在 Task 13(达标表/里程碑),活动度这 8 条全在化验里。
    #[allow(dead_code)]
    pub facts: Vec<(usize, Option<NaiveDate>, deid::Fact)>,
    /// 抽取结果里的**原始 labs 行**。定性值(「阴性」「阳性」)解析不出 f64,
    /// 在 `aggregate` 那层就被丢了,但 SLEDAI 的 dsDNA 项允许定性阳性计分
    /// (sle-clinical-sources §B.2),所以必须留一条能看到原文字符串的路。
    pub raw_labs: Vec<(usize, Option<NaiveDate>, deid::LabItem)>,
    /// 每份文档的原文(`text_present` 类规则用:管型这种只在尿沉渣描述里出现)。
    pub texts: Vec<(usize, Option<NaiveDate>, &'a str)>,
    // 开启闸自己在 `materialize` 里读 `events`;规则侧的第一个读者在 Task 14
    // (提醒:上次复查是什么时候要看动作日志)。
    #[allow(dead_code)]
    pub events: &'a [parser::ProfileEvent],
    pub today: NaiveDate,
}

impl<'a> Ctx<'a> {
    /// `docs` 的**切片**借用可以比 `'a` 短:`'a` 只约束文档正文(`SourceDoc::text`)
    /// 活多久,这些 `&str` 被原样搬进 `texts`。切片本身不进 `Ctx`,所以不必把两
    /// 个生命周期绑成一个(绑一起就得靠 `SourceDoc` 对 `'a` 协变才能过,那是
    /// `parser` 那边的实现细节,不该由本函数依赖)。
    pub fn build(
        docs: &[parser::SourceDoc<'a>],
        events: &'a [parser::ProfileEvent],
        today: NaiveDate,
    ) -> Ctx<'a> {
        let clinical = parser::aggregate(docs);
        let mut facts = Vec::new();
        let mut raw_labs = Vec::new();
        let mut texts = Vec::new();
        for d in docs {
            texts.push((d.index, d.date, d.text));
            // 抽取结果解析不出来就当这份没有 facts —— 与 `labs_from_json` 的既有
            // 约定一致(解析失败退回正则路径,而不是让整个投影失败)。
            if let Some(json) = d.extraction_json {
                if let Ok(e) = deid::parse_extraction(json) {
                    for f in e.facts {
                        facts.push((d.index, d.date, f));
                    }
                    for l in e.labs {
                        raw_labs.push((d.index, d.date, l));
                    }
                }
            }
        }
        Ctx {
            clinical,
            facts,
            raw_labs,
            texts,
            events,
            today,
        }
    }

    /// `date` 落在 `[today - window_days, today]` 里吗?没有日期的一律**不算**
    /// —— 取值窗口是 SLEDAI-2K 表格原文的硬要求(前 10 天),猜日期等于编分数。
    pub fn in_window(&self, date: Option<NaiveDate>, window_days: i64) -> bool {
        match date {
            Some(d) => {
                let lo = self.today - chrono::Duration::days(window_days);
                d >= lo && d <= self.today
            }
            None => false,
        }
    }
}

// ---------------------------------------------------------------------------
// 活动度:SLEDAI-2K 里**化验单独能算**的 8 条描述符(sle-clinical-sources §B.2)。
// 权重、阈值、10 天窗口全部来自包,引擎里一个临床数字都不写死。
// ---------------------------------------------------------------------------

/// 一条被命中的活动度描述符。
#[derive(Debug, Clone, serde::Serialize)]
pub struct Hit {
    pub id: String,
    pub label: String,
    pub weight: u32,
    pub source: String,
    pub caveat: Option<String>,
    pub evidence: Vec<Evidence>,
}

/// 一条**这次算不出来**的描述符:窗口里没有它要的那种结果、报告没印参考区间、
/// 单位换算不出来、或者包里的阈值还没核实(`threshold: null`)。
///
/// 与「算过了、没达到」是两回事 —— 后者既不进 `hits` 也不进这里,界面上就是那个
/// ✘。三态分开是硬要求(global-constraints:逐条 ✔/✘/未知,不下结论):把「没做
/// 补体」和「补体正常」都算成 0 分,等于替医生说了一句他没说过的话。
#[derive(Debug, Clone, serde::Serialize)]
pub struct Unscored {
    pub id: String,
    pub label: String,
    pub reason: String,
}

/// 「化验可算部分」的分数。**永远带 `label`,永远不叫 SLEDAI 总分**(spec §8)。
pub fn activity_section(
    ctx: &Ctx<'_>,
    pkg: &crate::package::Package,
) -> Option<crate::view::Section> {
    let a = &pkg.rules.activity;
    if a.items.is_empty() {
        return None;
    }
    let mut hits: Vec<Hit> = Vec::new();
    let mut unscored: Vec<Unscored> = Vec::new();
    for item in &a.items {
        match eval_activity_item(ctx, item, a.window_days) {
            Ok(Some(h)) => hits.push(h),
            // 算过了、没达到阈值:既不计分也不是未知。
            Ok(None) => {}
            Err(reason) => unscored.push(Unscored {
                id: str_field(item, "id").to_string(),
                label: str_field(item, "label").to_string(),
                reason,
            }),
        }
    }
    let score: u32 = hits.iter().map(|h| h.weight).sum();
    // 一条都没算成、也一条都没命中 → 这块没数据,折叠(spec §5.6)。只要有一条
    // 真算过(哪怕是 ✘),这张卡就有话说,不能折。
    let nothing_to_say = hits.is_empty() && unscored.len() == a.items.len();
    Some(crate::view::Section {
        kind: "score_card".into(),
        title: "活动度(化验可算部分)".into(),
        empty_hint: nothing_to_say.then(|| {
            format!(
                "最近 {} 天还没有化验结果,下次抽血后这里会自动算",
                a.window_days
            )
        }),
        body: serde_json::json!({
            "score": score,
            "max": a.max,
            "label": "化验可算部分",
            "window_days": a.window_days,
            "as_of": ctx.today.to_string(),
            "hits": hits,
            "unscored": unscored,
        }),
    })
}

fn str_field<'j>(v: &'j serde_json::Value, k: &str) -> &'j str {
    v.get(k).and_then(|x| x.as_str()).unwrap_or_default()
}

/// 求一条描述符。`Ok(Some)` = 命中,`Ok(None)` = 算过了没达到,`Err(原因)` = 这次
/// 算不出来(进 `unscored`,见 [`Unscored`])。
fn eval_activity_item(
    ctx: &Ctx<'_>,
    item: &serde_json::Value,
    window: i64,
) -> Result<Option<Hit>, String> {
    let kind = str_field(item, "kind");
    let keys: Vec<&str> = item
        .get("any_of")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|x| x.as_str()).collect())
        .unwrap_or_else(|| {
            item.get("key")
                .and_then(|x| x.as_str())
                .into_iter()
                .collect()
        });

    let mut evidence = Vec::new();
    let matched = match kind {
        // 阈值是**该报告自己印的区间**:`parser` 已经按点算好 flag(值 vs 该行的
        // ref_low/ref_high,见 `extraction.rs:87-97` 与 `labs.rs` 的正则路径),所以
        // 这里读 flag 就是读「低于/高于这家医院的界」,不需要也不许在这儿放一个
        // 固定数字。
        "flag_low" | "flag_high" => {
            let want = if kind == "flag_low" { "L" } else { "H" };
            // 「窗口里有这个项目的结果」和「那条结果判得出高低」是两件事:报告没印
            // 参考区间时 flag 为 None,那是未知,不是正常。
            let mut saw_point = false;
            let mut saw_flag = false;
            for s in &ctx.clinical.labs {
                let Some(k) = s.analyte_key.as_deref() else {
                    continue;
                };
                if !keys.contains(&k) || s.self_measured {
                    continue;
                }
                for p in &s.points {
                    if !ctx.in_window(p.date, window) {
                        continue;
                    }
                    saw_point = true;
                    saw_flag |= p.flag.is_some();
                    if p.flag.as_deref() == Some(want) {
                        evidence.push(Evidence {
                            document_index: p.source,
                            date: p.date.map(|d| d.to_string()),
                            analyte: k.to_string(),
                            value: p.value.to_string(),
                            unit: p.unit.clone(),
                        });
                    }
                }
            }
            // 定性阳性(dsDNA 的 ELISA/CLIFT 报「阳性」):数值路整条都看不到它,
            // 只能回到抽取结果的原始行上按字符串认。
            if evidence.is_empty() {
                if let Some(pos) = item.get("qualitative_positive").and_then(|v| v.as_array()) {
                    let words: Vec<&str> = pos.iter().filter_map(|x| x.as_str()).collect();
                    for (idx, date, l) in &ctx.raw_labs {
                        if !ctx.in_window(*date, window) {
                            continue;
                        }
                        if !terminology::resolve(&l.name, None)
                            .is_some_and(|m| keys.contains(&m.key.as_str()))
                        {
                            continue;
                        }
                        // 认出了这个项目 = 这条描述符这次是真看过了。
                        saw_point = true;
                        saw_flag = true;
                        if words.iter().any(|w| l.value.contains(w)) {
                            evidence.push(Evidence {
                                document_index: *idx,
                                date: date.map(|d| d.to_string()),
                                analyte: l.name.clone(),
                                value: l.value.clone(),
                                unit: None,
                            });
                        }
                    }
                }
            }
            if evidence.is_empty() {
                if !saw_point {
                    return Err("最近这段时间没有做这几项".into());
                }
                if !saw_flag {
                    return Err("报告上没印参考区间,判断不了高低".into());
                }
            }
            !evidence.is_empty()
        }
        "gt" | "lt" => {
            // 阈值没核实(§B 里标 NOT VERIFIED 的行)时包里写 `null` —— 那就如实说
            // 算不出来,绝不在引擎里补一个数。
            let thr = item
                .get("threshold")
                .and_then(|v| v.as_f64())
                .ok_or("这一条的阈值还没核实,暂不计分")?;
            let unit = str_field(item, "canonical_unit");
            let mut comparable = false;
            for s in &ctx.clinical.labs {
                let Some(k) = s.analyte_key.as_deref() else {
                    continue;
                };
                if !keys.contains(&k) || s.self_measured {
                    continue;
                }
                for p in &s.points {
                    if !ctx.in_window(p.date, window) {
                        continue;
                    }
                    // **只用规范单位比**:报告印 g/24h、mg/24h 的都有,拿 raw value
                    // 去比 0.5 就是 1000 倍的错。换算不出来的点直接跳过(诚实漏)。
                    let (Some(v), Some(u)) = (p.value_canonical, s.unit_canonical.as_deref())
                    else {
                        continue;
                    };
                    if terminology::normalize_unit(u) != terminology::normalize_unit(unit) {
                        continue;
                    }
                    comparable = true;
                    // 两边都是**严格**不等号:SLEDAI-2K 的「>0.5 g/24h」「<3,000」
                    // 恰好在阈上的那个值不计分。
                    let past_threshold = if kind == "gt" { v > thr } else { v < thr };
                    if past_threshold {
                        evidence.push(Evidence {
                            document_index: p.source,
                            date: p.date.map(|d| d.to_string()),
                            analyte: k.to_string(),
                            value: v.to_string(),
                            unit: Some(u.to_string()),
                        });
                    }
                }
            }
            if !comparable {
                return Err(format!("最近这段时间没有可比的结果(单位要能换算成 {unit})"));
            }
            !evidence.is_empty()
        }
        "text_present" => {
            let pats: Vec<&str> = item
                .get("patterns")
                .and_then(|v| v.as_array())
                .ok_or("这一条规则没给可匹配的字样")?
                .iter()
                .filter_map(|x| x.as_str())
                .collect();
            for (idx, date, text) in &ctx.texts {
                if !ctx.in_window(*date, window) {
                    continue;
                }
                // 一次 `find` 同时当判定和取证。写成 `any()` 判定 + `find().unwrap()`
                // 取证会在两次扫描之间留下一个「刚才一定命中过」的口头不变量 ——
                // 库代码里这种 unwrap 迟早被某次重构踩掉。只扫一次就没有不变量要守。
                let Some(hit) = pats.iter().find(|p| text.contains(**p)) else {
                    continue;
                };
                evidence.push(Evidence {
                    document_index: *idx,
                    date: date.map(|d| d.to_string()),
                    analyte: str_field(item, "id").to_string(),
                    value: (*hit).to_string(),
                    unit: None,
                });
            }
            // 没找到字样时**只能**说未知:窗口里有报告不等于做了这项检查(尿沉渣
            // 没做和做了没管型,在原文里长得一模一样)。判成 ✘ 就是编。
            if evidence.is_empty() {
                return Err("最近这段时间的报告里没提到这些字样".into());
            }
            true
        }
        // 认不出的 kind 不计分、不报错、也不列成未知:包可以先于引擎加规则类型
        // (`min_engine` 管的是**必须**懂的那些;不懂的可选规则静默跳过比整个档案
        // 打不开强,也比在卡片上多出一行用户看不懂的「未知」强)。
        _ => false,
    };

    Ok(matched.then(|| Hit {
        id: str_field(item, "id").to_string(),
        label: str_field(item, "label").to_string(),
        weight: item.get("weight").and_then(|v| v.as_u64()).unwrap_or(0) as u32,
        source: str_field(item, "source").to_string(),
        caveat: item
            .get("caveat")
            .and_then(|v| v.as_str())
            .map(str::to_string),
        evidence,
    }))
}
