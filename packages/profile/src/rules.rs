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

    /// 窗口左端点。`None` = 这个 `window_days` 根本算不出窗口:非正数,或大到让
    /// 日期越界。
    ///
    /// 必须是 checked 的:`today - Duration::days(n)` 在 n 大到越界时**直接 panic**,
    /// 而 `window_days` 是包里的裸 `i64`(`package.rs` 的 `ActivityRules`),加载时
    /// 不校验。包是我们签的没错,但签名防的是被人改,防不住作者手滑 —— 而在移动端
    /// 这条路走 FFI,一次 panic 就是整个 App 崩。
    pub fn window_start(&self, window_days: i64) -> Option<NaiveDate> {
        if window_days < 1 {
            return None;
        }
        self.today
            .checked_sub_signed(chrono::TimeDelta::try_days(window_days)?)
    }

    /// `date` 落在 `[today - window_days, today]` 里吗?没有日期的一律**不算**
    /// —— 取值窗口是 SLEDAI-2K 表格原文的硬要求(前 10 天),猜日期等于编分数。
    /// 窗口本身算不出来时同样一律不算(调用方另行整体判为「窗口设置无效」)。
    pub fn in_window(&self, date: Option<NaiveDate>, window_days: i64) -> bool {
        let (Some(d), Some(lo)) = (date, self.window_start(window_days)) else {
            return false;
        };
        d >= lo && d <= self.today
    }
}

// ---------------------------------------------------------------------------
// 活动度:SLEDAI-2K 里**化验单独能算**的 8 条描述符(sle-clinical-sources §B.2)。
// 权重、阈值、10 天窗口全部来自包,引擎里一个临床数字都不写死。
// ---------------------------------------------------------------------------

/// 一条被命中的活动度描述符(✔,进 `hits`)。
#[derive(Debug, Clone, serde::Serialize)]
pub struct Hit {
    pub id: String,
    pub label: String,
    pub weight: u32,
    pub source: String,
    pub caveat: Option<String>,
    pub evidence: Vec<Evidence>,
}

/// 一条**算过了、没达到**的描述符(✘,进 `missed`),带上看过的那几行当**反面
/// 证据**。
///
/// 「尿沉渣写着未见红细胞管型」和「这张卡压根没提管型」在界面上必须长得不一样:
/// 前者是医生能直接用的阴性结果,后者是这项没做。没有这个数组的话,✘ 只能靠
/// 「三个数组里都没有它」去反推,那条信息传不到医生眼前。
#[derive(Debug, Clone, serde::Serialize)]
pub struct Missed {
    pub id: String,
    pub label: String,
    pub evidence: Vec<Evidence>,
}

/// 一条**这次算不出来**的描述符(未知,进 `unscored`):窗口里没有它要的那种
/// 结果、报告没印参考区间、单位换算不出来、或者包里的阈值还没核实
/// (`threshold: null`)。
#[derive(Debug, Clone, serde::Serialize)]
pub struct Unscored {
    pub id: String,
    pub label: String,
    pub reason: String,
}

/// 一条描述符这次的结论。三态是硬要求(global-constraints:达标表逐条 ✔/✘/未知,
/// 不下结论):把「这次没做补体」和「补体正常」都压成 0 分,等于替医生说了一句
/// 他没说过的话。
enum Outcome {
    /// ✔ 命中。
    Hit(Hit),
    /// ✘ 算过了、没达到,附看过的那几行。
    Missed(Vec<Evidence>),
    /// 未知,附说清为什么算不出来的一句话。
    Unknown(String),
}

/// 否定/零值标记。行里出现任一个,这一行就是「做了、没有」,不是命中。
///
/// 比之前两边都先过 [`terminology::normalize_term`](全角折半角、去空白、转小写),
/// 所以 `（-）`、`0 个` 这些中国报告单上极常见的全角/带空格写法不会漏。
const NEGATION_MARKERS: [&str; 7] = ["未见", "阴性", "(-)", "(−)", "未检出", "0.00", "0 个"];

/// 「化验可算部分」的分数。**永远带 `label`,永远不叫 SLEDAI 总分**(spec §8)。
///
/// `body` 的形状(Task 12 的渲染引擎按这一份读):
/// ```text
/// {"score","max","label","window_days","as_of",
///  "hits":    [{"id","label","weight","source","caveat","evidence":[…]}],  // ✔ 命中,计分
///  "missed":  [{"id","label","evidence":[…]}],                             // ✘ 算过了没达到
///  "unscored":[{"id","label","reason"}]}                                   // 未知,算不出来
/// ```
/// 三个数组互斥。一条描述符哪个都不在,只有两种情况:引擎不认识那条规则的
/// `kind`(不会发生,不认识的一律进 `unscored`),或者它算过了没达到但一行证据
/// 都没留下。
pub fn activity_section(
    ctx: &Ctx<'_>,
    pkg: &crate::package::Package,
) -> Option<crate::view::Section> {
    let a = &pkg.rules.activity;
    if a.items.is_empty() {
        return None;
    }
    // 窗口先整体判一次:包里写了非正数或大到让日期越界的 `window_days`,整张卡
    // 都是未知,而不是让 `in_window` 在移动端的 FFI 上把整个 App 炸掉。
    let window_valid = ctx.window_start(a.window_days).is_some();

    let mut hits: Vec<Hit> = Vec::new();
    let mut missed: Vec<Missed> = Vec::new();
    let mut unscored: Vec<Unscored> = Vec::new();
    for item in &a.items {
        let outcome = if window_valid {
            eval_activity_item(ctx, item, a.window_days)
        } else {
            Outcome::Unknown("窗口设置无效".into())
        };
        match outcome {
            Outcome::Hit(h) => hits.push(h),
            // 一行证据都没有的 ✘ 没什么可给医生看的,不占一行。
            Outcome::Missed(evidence) if !evidence.is_empty() => missed.push(Missed {
                id: str_field(item, "id").to_string(),
                label: str_field(item, "label").to_string(),
                evidence,
            }),
            Outcome::Missed(_) => {}
            Outcome::Unknown(reason) => unscored.push(Unscored {
                id: str_field(item, "id").to_string(),
                label: str_field(item, "label").to_string(),
                reason,
            }),
        }
    }
    // `saturating_add`:`items` 是裸 JSON,权重是包作者写的。手滑写个大数在 debug
    // 下是 panic、release 下是回绕成小分数 —— 后者更糟,它看起来像个正常分数。
    let score = hits
        .iter()
        .map(|h| h.weight)
        .fold(0u32, u32::saturating_add);
    // 折叠成一行(spec §5.6)的条件是**真的没东西可看**:窗口内既没有化验点、
    // 也没有任何文档。只要用户交了单子,哪怕这张卡一条都算不出来,也要展开 ——
    // 让 `unscored` 的理由自己说话。把「引擎读不懂这张单子」显示成「你还没去
    // 抽血」是一句不实的话。
    let any_point = ctx.clinical.labs.iter().any(|s| {
        s.points
            .iter()
            .any(|p| ctx.in_window(p.date, a.window_days))
    });
    let any_doc = ctx
        .texts
        .iter()
        .any(|(_, date, _)| ctx.in_window(*date, a.window_days));
    Some(crate::view::Section {
        kind: "score_card".into(),
        title: "活动度(化验可算部分)".into(),
        empty_hint: (window_valid && !any_point && !any_doc).then(|| {
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
            "missed": missed,
            "unscored": unscored,
        }),
    })
}

fn str_field<'j>(v: &'j serde_json::Value, k: &str) -> &'j str {
    v.get(k).and_then(|x| x.as_str()).unwrap_or_default()
}

/// 行里有否定/零值标记吗(全角、空格、大小写都已折平)?
fn is_negated(normalized_line: &str) -> bool {
    NEGATION_MARKERS
        .iter()
        .any(|m| normalized_line.contains(&terminology::normalize_term(m)))
}

/// 把包里按**源行单位**写的阈值,换算到这条序列的规范单位上。
///
/// 用的是词典那张 `UnitConversion`(`canonical = slope * raw + intercept`),与
/// `parser` 换算点值走的是同一张表、同一个方向。这样包里就能逐字写源行的数
/// (SLEDAI-2K 印的是「>0.5 gram/24 hours」),不必先在包里手算成 500 mg ——
/// 换算一旦写死进包,读包的人就再也看不出那个数不是源行原值了
/// (global-constraints:包里每个数值都带出处 id)。
///
/// 换算不出来返回 `None`,调用方据此判「单位对不上」,**绝不拿两个不同单位的数
/// 硬比** —— §A.3 记着 C3 的 mg/L 与 g/L 差 1000 倍这个坑。
fn threshold_in(unit_from: &str, unit_to: &str, key: &str, thr: f64) -> Option<f64> {
    if terminology::normalize_unit(unit_from) == terminology::normalize_unit(unit_to) {
        return Some(thr);
    }
    let entry = terminology::dictionary_entries()
        .iter()
        .find(|e| e.key == key)?;
    // 只认「换到这条序列的规范单位」这一个方向:词典的 slope/intercept 就是
    // 「本单位 → canonical」,反方向没有表,也不该在这儿自己求逆。
    if entry
        .canonical_unit
        .as_deref()
        .map(terminology::normalize_unit)
        != Some(terminology::normalize_unit(unit_to))
    {
        return None;
    }
    let row = entry
        .units
        .iter()
        .find(|u| terminology::normalize_unit(&u.unit) == terminology::normalize_unit(unit_from))?;
    Some(row.slope * thr + row.intercept)
}

/// 求一条描述符,见 [`Outcome`]。
fn eval_activity_item(ctx: &Ctx<'_>, item: &serde_json::Value, window: i64) -> Outcome {
    let kind = str_field(item, "kind");
    // 权重先读:读不出来(包里写成浮点、或漏了)时这条不能当成「命中 0 分」悄悄
    // 混进 `hits` —— 那在卡片上是一条不加分的命中,没有任何信号。
    let Some(weight) = item
        .get("weight")
        .and_then(serde_json::Value::as_u64)
        .and_then(|w| u32::try_from(w).ok())
    else {
        return Outcome::Unknown("这一条的权重读不出来(包里不是整数)".into());
    };
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

    let hit = |evidence: Vec<Evidence>| {
        Outcome::Hit(Hit {
            id: str_field(item, "id").to_string(),
            label: str_field(item, "label").to_string(),
            weight,
            source: str_field(item, "source").to_string(),
            caveat: item
                .get("caveat")
                .and_then(|v| v.as_str())
                .map(str::to_string),
            evidence,
        })
    };

    match kind {
        // 阈值是**该报告自己印的区间**:`parser` 已经按点算好 flag(值 vs 该行的
        // ref_low/ref_high,见 `extraction.rs:87-97` 与 `labs.rs` 的正则路径),所以
        // 这里读 flag 就是读「低于/高于这家医院的界」,不需要也不许在这儿放一个
        // 固定数字。
        "flag_low" | "flag_high" => {
            let want = if kind == "flag_low" { "L" } else { "H" };
            let mut evidence = Vec::new();
            // 判得出高低、但不是我们要的那个方向的点 —— 它们就是 ✘ 的证据。
            let mut judged = Vec::new();
            // 窗口里有这个项目的结果,但一条都判不出高低(报告没印参考区间)。
            let mut saw_unjudgeable = false;
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
                    let Some(flag) = p.flag.as_deref() else {
                        saw_unjudgeable = true;
                        continue;
                    };
                    let e = Evidence {
                        document_index: p.source,
                        date: p.date.map(|d| d.to_string()),
                        analyte: k.to_string(),
                        value: p.value.to_string(),
                        unit: p.unit.clone(),
                    };
                    if flag == want {
                        evidence.push(e);
                    } else {
                        judged.push(e);
                    }
                }
            }
            // 定性阳性(dsDNA 的 ELISA/CLIFT 报「阳性」):数值路整条都看不到它,
            // 只能回到抽取结果的原始行上按字符串认。
            if let Some(pos) = item.get("qualitative_positive").and_then(|v| v.as_array()) {
                let words: Vec<String> = pos
                    .iter()
                    .filter_map(|x| x.as_str())
                    .map(terminology::normalize_term)
                    .collect();
                for (idx, date, l) in &ctx.raw_labs {
                    if !ctx.in_window(*date, window) {
                        continue;
                    }
                    if !terminology::resolve(&l.name, None)
                        .is_some_and(|m| keys.contains(&m.key.as_str()))
                    {
                        continue;
                    }
                    // **只有真·定性**(值解析不出数)才算「判得出来」。印了数值却
                    // 没印参考区间的行,高不高完全取决于这家实验室的上限 —— 没印
                    // 就是不知道,那是未知,不是「不高」。
                    if l.value.trim().parse::<f64>().is_ok() {
                        continue;
                    }
                    let e = Evidence {
                        document_index: *idx,
                        date: date.map(|d| d.to_string()),
                        analyte: l.name.clone(),
                        value: l.value.clone(),
                        unit: None,
                    };
                    let v = terminology::normalize_term(&l.value);
                    if words.iter().any(|w| v.contains(w.as_str())) {
                        evidence.push(e);
                    } else {
                        judged.push(e);
                    }
                }
            }
            if !evidence.is_empty() {
                return hit(evidence);
            }
            if !judged.is_empty() {
                return Outcome::Missed(judged);
            }
            if saw_unjudgeable {
                return Outcome::Unknown("报告上没印参考区间,判断不了高低".into());
            }
            Outcome::Unknown("最近这段时间没有做这几项".into())
        }
        "gt" | "lt" => {
            // 阈值没核实(§B 里标 NOT VERIFIED 的行)时包里写 `null` —— 那就如实说
            // 算不出来,绝不在引擎里补一个数。
            let Some(thr) = item.get("threshold").and_then(|v| v.as_f64()) else {
                return Outcome::Unknown("这一条的阈值还没核实,暂不计分".into());
            };
            let unit = str_field(item, "canonical_unit");
            let mut evidence = Vec::new();
            let mut compared = Vec::new();
            // 「窗口里压根没做这一项」和「做了但单位换算不过来」是两回事,理由不能
            // 混着说 —— 一张只有尿检的单子说「白细胞的单位要能换算成 10*9/L」,
            // 用户只会以为是自己哪里弄错了。
            let mut saw_point = false;
            for s in &ctx.clinical.labs {
                let Some(k) = s.analyte_key.as_deref() else {
                    continue;
                };
                if !keys.contains(&k) || s.self_measured {
                    continue;
                }
                // **只用规范单位比**:报告印 g/24h、mg/24h 的都有,拿 raw value
                // 去比 0.5 就是 1000 倍的错。
                let thr_here = s
                    .unit_canonical
                    .as_deref()
                    .and_then(|u| threshold_in(unit, u, k, thr));
                for p in &s.points {
                    if !ctx.in_window(p.date, window) {
                        continue;
                    }
                    saw_point = true;
                    // 换算不出来的点直接跳过(诚实漏)。
                    let (Some(v), Some(u), Some(thr_here)) =
                        (p.value_canonical, s.unit_canonical.as_deref(), thr_here)
                    else {
                        continue;
                    };
                    let e = Evidence {
                        document_index: p.source,
                        date: p.date.map(|d| d.to_string()),
                        analyte: k.to_string(),
                        value: v.to_string(),
                        unit: Some(u.to_string()),
                    };
                    // 两边都是**严格**不等号:SLEDAI-2K 的「>0.5 g/24h」「<3,000」
                    // 恰好在阈上的那个值不计分。
                    if if kind == "gt" {
                        v > thr_here
                    } else {
                        v < thr_here
                    } {
                        evidence.push(e);
                    } else {
                        compared.push(e);
                    }
                }
            }
            if !evidence.is_empty() {
                return hit(evidence);
            }
            if !compared.is_empty() {
                return Outcome::Missed(compared);
            }
            if saw_point {
                return Outcome::Unknown(format!("这一项的单位换算不成 {unit},比不了"));
            }
            Outcome::Unknown("最近这段时间没有做这一项".into())
        }
        "text_present" => {
            let Some(raw_pats) = item.get("patterns").and_then(|v| v.as_array()) else {
                return Outcome::Unknown("这一条规则没给可匹配的字样".into());
            };
            let pats: Vec<String> = raw_pats
                .iter()
                .filter_map(|x| x.as_str())
                .map(terminology::normalize_term)
                .collect();
            let mut evidence = Vec::new();
            let mut negated = Vec::new();
            for (idx, date, text) in &ctx.texts {
                if !ctx.in_window(*date, window) {
                    continue;
                }
                // **逐行**判,不在整份文档上裸匹配:一份报告里「可见红细胞管型」和
                // 「未见红细胞管型」都只是一行,整份 `contains` 分不出这两句,会把
                // 一张明确写着「没有管型」的单子算成 +4(18 分制里最重的一档)。
                for line in text.lines() {
                    let n = terminology::normalize_term(line);
                    if !pats.iter().any(|p| n.contains(p.as_str())) {
                        continue;
                    }
                    // 证据带**原文这一行**(逐字),不是命中的那几个字 —— 不然
                    // 「未见红细胞管型」在证据链里会显示成「红细胞管型」,医生看
                    // 证据也看不出它被否定了。
                    let e = Evidence {
                        document_index: *idx,
                        date: date.map(|d| d.to_string()),
                        analyte: str_field(item, "id").to_string(),
                        value: line.trim().to_string(),
                        unit: None,
                    };
                    if is_negated(&n) {
                        negated.push(e);
                    } else {
                        evidence.push(e);
                    }
                }
            }
            if !evidence.is_empty() {
                return hit(evidence);
            }
            // 写着「未见管型」的那一行**证明这项做过了**,所以是 ✘ 不是未知。
            if !negated.is_empty() {
                return Outcome::Missed(negated);
            }
            // 一行都没提到:分不清「没做尿沉渣」和「做了、报告没列这一项」,只能未知。
            Outcome::Unknown("最近这段时间的报告里没提到这些字样".into())
        }
        // 认不出的 kind 不计分、不报错,但**要如实说算不了**:静默跳过会让它在
        // 卡片上和「算过了、正常」长得一模一样,等于把「没懂」伪装成 ✘。包可以
        // 先于引擎加规则类型(`min_engine` 管的是**必须**懂的那些)。
        _ => Outcome::Unknown("这一条规则本机还算不了,更新 App 后会自动补上".into()),
    }
}
