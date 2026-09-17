//! 规则求值的共享上下文与各条规则的实现。**纯函数**:同样的 `Ctx` + 同样的包 +
//! 同样的 `today`,永远得到同样的结果。
use chrono::NaiveDate;

/// 一条被规则引用到的化验证据(用于「这次计分用了哪几张单子」的证据链)。
///
/// **`value`/`unit` 永远是报告上印的那一对**,医生要能在纸上原样找到它。规范套
/// (跨院可比的那一套)另放在 `value_canonical`/`unit_canonical` 下,名字自己说
/// 清楚 —— 把 `0.3 g/24h` 显示成 `300 mg/24h` 是一个医生有理由不信的数字,哪怕
/// 换算本身没错。
#[derive(Debug, Clone, serde::Serialize)]
pub struct Evidence {
    /// `parser::SourceDoc::index` —— 调用方据此翻回 document_id。
    pub document_index: usize,
    pub date: Option<String>,
    pub analyte: String,
    /// 报告印的值(定性项就是「阳性」这种原话;`text_present` 是命中的那一整行)。
    pub value: String,
    /// `value` 的单位,报告印的那个。报告没印单位时 `None`(不替它补)。
    pub unit: Option<String>,
    /// 规范单位下的同一个值。非化验证据(原文行)为 `None`。
    pub value_canonical: Option<f64>,
    pub unit_canonical: Option<String>,
    /// `true` = 这条序列上混了印刷单位,`parser` 已把整条统一换算过,上面的
    /// `value`/`unit` 在纸上找不到(`parser::AnalyteSeries::values_converted`
    /// 的文档:「不说就等于改写原文」)。渲染层必须把这件事说出来。
    pub values_converted: bool,
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
    /// 动作日志(开启/关停、PGA、以后的症状勾选…)。开启闸在 `materialize` 里读,
    /// 规则侧由达标表读最近一次 `pga`。
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
/// `body` 的形状(Task 21 的渲染引擎按这一份读):
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
    eval: &Activity,
) -> Option<crate::view::Section> {
    let a = &pkg.rules.activity;
    if a.items.is_empty() {
        return None;
    }
    let window_valid = ctx.window_start(a.window_days).is_some();
    let score = weight_sum(&eval.hits);
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
        title: view_title(pkg, "score_card"),
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
            "hits": eval.hits,
            "missed": eval.missed,
            "unscored": eval.unscored,
        }),
    })
}

/// 一次活动度求值的产物,三个数组互斥(形状见 [`activity_section`])。
///
/// 求值与出卡片分开,是因为它有第二个读者:达标表按 id 从 `hits` 里减掉补体、dsDNA
/// 两条算 cSLEDAI,并且要看 `unscored` 才知道「这次到底算全了没有」。**一份输入只算
/// 一遍** —— 算两遍就有算出两个不同分数的机会,而卡片上的 x/18 与达标表里的 cSLEDAI
/// 说的必须是同一次计分。
pub struct Activity {
    pub hits: Vec<Hit>,
    missed: Vec<Missed>,
    unscored: Vec<Unscored>,
}

/// 逐条求值活动度描述符。纯函数,不出文案。
pub fn activity_eval(ctx: &Ctx<'_>, pkg: &crate::package::Package) -> Activity {
    let a = &pkg.rules.activity;
    // 窗口先整体判一次:包里写了非正数或大到让日期越界的 `window_days`,整张卡
    // 都是未知,而不是让 `in_window` 在移动端的 FFI 上把整个 App 炸掉。
    let window_valid = ctx.window_start(a.window_days).is_some();

    let mut out = Activity {
        hits: Vec::new(),
        missed: Vec::new(),
        unscored: Vec::new(),
    };
    for item in &a.items {
        let outcome = if window_valid {
            eval_activity_item(ctx, item, a.window_days)
        } else {
            Outcome::Unknown("窗口设置无效".into())
        };
        match outcome {
            Outcome::Hit(h) => out.hits.push(h),
            // 一行证据都没有的 ✘ 没什么可给医生看的,不占一行。
            Outcome::Missed(evidence) if !evidence.is_empty() => out.missed.push(Missed {
                id: str_field(item, "id").to_string(),
                label: str_field(item, "label").to_string(),
                evidence,
            }),
            Outcome::Missed(_) => {}
            Outcome::Unknown(reason) => out.unscored.push(Unscored {
                id: str_field(item, "id").to_string(),
                label: str_field(item, "label").to_string(),
                reason,
            }),
        }
    }
    out
}

/// 一组命中的总分。`saturating_add`:`items` 是裸 JSON,权重是包作者写的。手滑写个
/// 大数在 debug 下是 panic、release 下是回绕成小分数 —— 后者更糟,它看起来像个正
/// 常分数。
fn weight_sum<'h>(hits: impl IntoIterator<Item = &'h Hit>) -> u32 {
    hits.into_iter()
        .map(|h| h.weight)
        .fold(0u32, u32::saturating_add)
}

/// section 的标题按 kind 从包的 `views.sections` 里取(spec §6:顺序、标题、空态文案
/// 全来自包)。包里没写就 `None` —— 引擎里垫一句中文,「加一个病不发版」这条前提上
/// 就多了一个例外,而例外只会越来越多。**空标题要是 `null` 不是 `""`**:后者在
/// JSON 里和「作者写了个空标题」长得一样,渲染层分不出包漏了还是包故意的。
fn view_title(pkg: &crate::package::Package, kind: &str) -> Option<String> {
    pkg.views
        .sections
        .iter()
        .find(|s| str_field(s, "kind") == kind)
        .and_then(|s| s.get("title").and_then(|t| t.as_str()))
        .map(str::to_string)
}

fn str_field<'j>(v: &'j serde_json::Value, k: &str) -> &'j str {
    v.get(k).and_then(|x| x.as_str()).unwrap_or_default()
}

/// 一个化验点的证据。**印刷套进 `value`/`unit`,规范套进带后缀的那两个** ——
/// `gt`/`lt` 是拿规范值比的阈值,但拿去给人看的必须是纸上那个数。
fn lab_evidence(s: &parser::AnalyteSeries, p: &parser::LabPoint, analyte: &str) -> Evidence {
    Evidence {
        document_index: p.source,
        date: p.date.map(|d| d.to_string()),
        analyte: analyte.to_string(),
        value: p.value.to_string(),
        unit: p.unit.clone(),
        value_canonical: p.value_canonical,
        unit_canonical: s.unit_canonical.clone(),
        values_converted: s.values_converted,
    }
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
                    let e = lab_evidence(s, p, k);
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
                        // 抽取结果里的原话(「阳性」「1:80」),本来就没有单位、
                        // 也没有规范套可言。
                        value: l.value.clone(),
                        unit: None,
                        value_canonical: None,
                        unit_canonical: None,
                        values_converted: false,
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
                    let (Some(v), Some(thr_here)) = (p.value_canonical, thr_here) else {
                        continue;
                    };
                    // 比是拿规范值比的,给人看的却是**纸上那个数**:把「0.3 g/24h」
                    // 显示成「300 mg/24h」,医生有理由不信这条证据。
                    let e = lab_evidence(s, p, k);
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
                        value_canonical: None,
                        unit_canonical: None,
                        values_converted: false,
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

// ---------------------------------------------------------------------------
// 达标检查表:DORIS 2021 / LLDAS 逐条三态(sle-clinical-sources §C.1/§C.2)。
// 引擎只算逐条,**不下结论**(spec §5.3):全 `yes` 时那句「这几条都满足了,拿去
// 问医生」也是包里的文案,不是引擎说的。
// ---------------------------------------------------------------------------

/// 三态。**`Unknown` 不是 `No`**:PGA 没人录过,不等于「没达标」—— 把「不知道」
/// 显示成「不达标」是在替医生下结论(spec §5.3)。
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Verdict {
    Yes,
    No,
    Unknown,
}

impl Verdict {
    fn as_str(self) -> &'static str {
        match self {
            Verdict::Yes => "yes",
            Verdict::No => "no",
            Verdict::Unknown => "unknown",
        }
    }
}

/// 最近一次 `pga` 事件的分值与**它是哪天录的**(SELENA-SLEDAI PGA,0–3)。从没录过
/// → `None`。
///
/// 日期必须一起带出去:引擎这边不设时效(包/渲染层才知道多久算过期),但 body 里
/// 没有日期的话,Task 21 连「录于 2023-04」都渲染不出来 —— 一个三年前的分值会长得
/// 和今天刚录的一模一样。
///
/// `at` 只到天,同一天录两次时以**日志里靠后的那条**为准(`max_by` 的文档保证:
/// 并列取最后一个),与开启闸同一条日内规则(见 `lib.rs::is_enabled`)。
fn latest_pga<'e>(ctx: &Ctx<'e>, package_id: &str) -> Option<(f64, &'e str)> {
    let e = ctx
        .events
        .iter()
        .filter(|e| e.package == package_id && e.kind == "pga")
        .max_by(|a, b| a.at.cmp(&b.at))?;
    let v = e.payload.get("value").and_then(serde_json::Value::as_f64)?;
    Some((v, e.at.as_str()))
}

/// 最近一次泼尼松等效日剂量(mg/天)。**Task 13 才读用药记录**,在那之前恒为
/// `None`,每条 `pred_*` 如实显示未知。
///
/// 不在这儿垫一张等效换算表:spec §2 里 `pred_equiv` 自己标着「待核」,
/// global-constraints 说没核实的数值一律 `null`。垫一个数出来,界面上就会出现一句
/// 「泼尼松 4 mg/天 < 5,达标」—— 而那个 4 是引擎编的。
fn latest_pred_equiv_mg(_ctx: &Ctx<'_>, _pkg: &crate::package::Package) -> Option<f64> {
    None
}

/// 达标检查表(spec §5.3)。`activity` 是 [`activity_eval`] 已经算好的那一次求值 ——
/// 分数从 `hits` 来,**算全了没有**从 `unscored` 来。
///
/// `body` 的形状(Task 21 的渲染引擎按这一份读):
/// ```text
/// {"states":[{"id","label","source","note","verdict",
///             "items":[{"id","label","verdict","actual","actual_at","reason","note","source"}]}]}
/// ```
/// `verdict` 三态 `"yes"|"no"|"unknown"`;整表 = 任一条 `no` → `no`,否则任一条
/// `unknown` → `unknown`,全 `yes` 才 `yes`。`actual` 是这一条算出来的数(未知时
/// `null`;分数类条目算的是**化验可算部分**,没读到的描述符不在里面),`actual_at`
/// 是那个数是哪天的(目前只有 PGA 有),`reason` 是未知的理由(其余时候 `null`)——
/// 未知必须带一句为什么,不然界面上的「未知」和「这条我们不打算算」长得一样。
pub fn states_section(
    ctx: &Ctx<'_>,
    pkg: &crate::package::Package,
    activity: &Activity,
) -> Option<crate::view::Section> {
    if pkg.rules.states.is_empty() {
        return None;
    }
    let pga = latest_pga(ctx, &pkg.manifest.id);
    let pred = latest_pred_equiv_mg(ctx, pkg);
    // `exclude` 里的 id 要能在活动度规则里找得到,不然减项会静悄悄失效。
    let known: Vec<&str> = pkg
        .rules
        .activity
        .items
        .iter()
        .map(|i| str_field(i, "id"))
        .collect();

    let mut states = Vec::new();
    for st in &pkg.rules.states {
        let mut items = Vec::new();
        let mut worst = Verdict::Yes;
        for it in st
            .get("items")
            .and_then(|v| v.as_array())
            .into_iter()
            .flatten()
        {
            let o = eval_state_item(it, activity, &known, pga, pred);
            if o.verdict == Verdict::No {
                worst = Verdict::No;
            } else if o.verdict == Verdict::Unknown && worst != Verdict::No {
                worst = Verdict::Unknown;
            }
            items.push(serde_json::json!({
                "id": str_field(it, "id"), "label": str_field(it, "label"),
                "verdict": o.verdict.as_str(), "actual": o.actual, "actual_at": o.actual_at,
                "reason": o.reason,
                "note": it.get("note"), "source": str_field(it, "source"),
            }));
        }
        // 一条都没有的表**不是**「全满足」:包里 `items` 写漏(或拼成 `item`)时,
        // 默认的全 `yes` 会在界面上变成「DORIS 每条都对上了」—— 这个功能最坏的一种
        // 错法,一行挡掉。
        if items.is_empty() {
            worst = Verdict::Unknown;
        }
        states.push(serde_json::json!({
            "id": str_field(st, "id"), "label": str_field(st, "label"),
            "source": str_field(st, "source"), "note": st.get("note"),
            "verdict": worst.as_str(), "items": items,
        }));
    }
    Some(crate::view::Section {
        kind: "checklist".into(),
        title: view_title(pkg, "checklist"),
        // 逐条对照永远有意义:未知也是答案,不折叠。
        empty_hint: None,
        body: serde_json::json!({ "states": states }),
    })
}

/// 一条达标条目的结论。
struct ItemOutcome {
    verdict: Verdict,
    /// 这一条算出来的数,未知时 `null`。
    actual: serde_json::Value,
    /// `actual` 是哪天的(目前只有 PGA 有日期)。
    actual_at: Option<String>,
    /// 未知的理由;`Yes`/`No` 时为 `None`。
    reason: Option<String>,
}

impl ItemOutcome {
    fn unknown(why: impl Into<String>) -> ItemOutcome {
        ItemOutcome {
            verdict: Verdict::Unknown,
            actual: serde_json::Value::Null,
            actual_at: None,
            reason: Some(why.into()),
        }
    }

    fn judged(ok: bool, actual: serde_json::Value) -> ItemOutcome {
        ItemOutcome {
            verdict: if ok { Verdict::Yes } else { Verdict::No },
            actual,
            actual_at: None,
            reason: None,
        }
    }
}

/// 从活动度分数推出来的条目(`csledai_eq` / `sledai_le`)。
///
/// **算不出来的描述符不等于 0 分。** 这是「未知不许塌成 ✘」的镜像错法,而且更危险:
/// 一份文档都没有时 8 条描述符全在 `unscored`、`hits` 为空,按分数直接判就成了
/// 「临床 SLEDAI = 0 ✔」—— 旁边的活动度卡片正说着「最近 10 天还没有化验结果」。
///
/// 权重非负,所以只有一件事可以确定:**分数已经超过目标 → 一定不达标**(把没读到的
/// 那几项补上只会更高)。没超过时得看算全了没有:还有非 `exclude` 的描述符没算出来
/// → 未知,并说出第一条是哪一项;全算过了才按分数判。
fn score_item(
    activity: &Activity,
    excluded: &[&str],
    target: f64,
    met: impl Fn(f64, f64) -> bool,
) -> ItemOutcome {
    let score = weight_sum(
        activity
            .hits
            .iter()
            .filter(|h| !excluded.contains(&h.id.as_str())),
    );
    if f64::from(score) > target {
        return ItemOutcome::judged(false, serde_json::json!(score));
    }
    if let Some(u) = activity
        .unscored
        .iter()
        .find(|u| !excluded.contains(&u.id.as_str()))
    {
        return ItemOutcome::unknown(format!("「{}」还没读到,SLEDAI 算不全", u.label));
    }
    ItemOutcome::judged(met(f64::from(score), target), serde_json::json!(score))
}

/// 求一条达标条目。
fn eval_state_item(
    it: &serde_json::Value,
    activity: &Activity,
    known_ids: &[&str],
    pga: Option<(f64, &str)>,
    pred: Option<f64>,
) -> ItemOutcome {
    match (
        str_field(it, "kind"),
        it.get("value").and_then(serde_json::Value::as_f64),
    ) {
        // 包里写 `null` 的目标值(§C 里还没核到逐字原文的那些)不许当成 0 去比 ——
        // 那会把「还不知道」变成一个看起来很确定的 ✔/✘。
        ("csledai_eq" | "sledai_le" | "pga_lt" | "pga_le" | "pred_lt" | "pred_le", None) => {
            ItemOutcome::unknown("这一条的目标值还没核实,暂时比不了")
        }
        // 临床 SLEDAI:分数**减去** `exclude` 里那几条描述符(DORIS 的「irrespective
        // of serology」= 去掉低补体与 dsDNA 两行),减的是活动度那次算好的命中,
        // **不重算** —— 重算就有算出另一个分数的机会。
        ("csledai_eq", Some(v)) => {
            let excluded: Vec<&str> = it
                .get("exclude")
                .and_then(|x| x.as_array())
                .map(|a| a.iter().filter_map(|s| s.as_str()).collect())
                .unwrap_or_default();
            // 拼错的 id 减不掉任何东西,而且一声不响:cSLEDAI 会偏高,界面上是一条
            // 看起来很正常的 ✘。宁可整条未知,也不给一个悄悄算错的数。
            if let Some(bad) = excluded.iter().find(|e| !known_ids.contains(e)) {
                return ItemOutcome::unknown(format!(
                    "包里要去掉的「{bad}」在活动度规则里找不到,这一条先不算"
                ));
            }
            score_item(activity, &excluded, v, |s, t| s == t)
        }
        ("sledai_le", Some(v)) => score_item(activity, &[], v, |s, t| s <= t),
        (k @ ("pga_lt" | "pga_le"), Some(v)) => match pga {
            // 没人录过 ≠ 没达标(spec §5.3,§7:二期由授权医生录)。
            None => ItemOutcome::unknown("还没有人录过医生整体评估(PGA)"),
            // 量表是 SELENA-SLEDAI PGA 的 0–3(§C.2 专门强调不是 0–10 VAS)。按
            // 0–10 录进来的 2 分,拿去和 0.5 比会安静地判成 ✘ —— 那是拿另一把尺
            // 量出来的结论。
            Some((p, _)) if !(0.0..=3.0).contains(&p) => ItemOutcome::unknown("PGA 超出 0–3 范围"),
            Some((p, at)) => ItemOutcome {
                actual_at: Some(at.to_string()),
                ..ItemOutcome::judged(
                    if k == "pga_lt" { p < v } else { p <= v },
                    serde_json::json!(p),
                )
            },
        },
        (k @ ("pred_lt" | "pred_le"), Some(v)) => match pred {
            None => ItemOutcome::unknown("还没读到用药记录"),
            Some(p) => ItemOutcome::judged(
                if k == "pred_lt" { p < v } else { p <= v },
                serde_json::json!(p),
            ),
        },
        // 只有人能答的条目(「无重要脏器活动」「与上次比无新活动」)。二期由医生在
        // 授权查看器里录(spec §7),此刻恒为未知 —— 诚实,不猜。
        ("manual", _) => ItemOutcome::unknown("这一条要人来答,还没有人答过"),
        // 认不出的 kind 同样是未知,不是 ✘:包可以先于引擎加规则类型。
        _ => ItemOutcome::unknown("这一条规则本机还算不了,更新 App 后会自动补上"),
    }
}
