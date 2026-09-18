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

/// 一份文档:元信息 + 原文。`title`/`doc_type` 是「上次就诊」那一格要的 —— 标题
/// 要原样显示给医生看,`doc_type` 用来把手动录入的那几类(自测/笔记/动作日志)排
/// 除在「就诊」之外。从 `parser::SourceDoc` 原样搬过来,不在这儿重新推导。
///
/// `title`/`doc_type` 在这里**复制**成 `String`:它们是 `SourceDoc` 自己拥有的
/// 字段,生命周期只到那个切片(见 [`Ctx::build`] 的注释:`'a` 只约束正文),借出
/// 来会把整个 `Ctx` 绑死在调用方那个临时 `Vec` 上。两个短字符串,不值得为它改签名。
pub struct Doc<'a> {
    pub index: usize,
    pub date: Option<NaiveDate>,
    pub title: Option<String>,
    pub doc_type: Option<String>,
    /// 原文(`text_present` 类规则用:管型这种只在尿沉渣描述里出现)。
    pub text: &'a str,
}

/// 规则求值的全部输入,装配一次、各条规则共用。
pub struct Ctx<'a> {
    /// `parser::aggregate` 的产物:已分组、已换算的化验序列 + 用药区间 + 诊断。
    pub clinical: parser::AggregatedClinical,
    /// schema 2 的族级事实,带上它所在文档的 index 与日期(fact 自己的 `date`
    /// 为空时用文档日期兜底)。第一个读者是复查提醒里的 `exam_done`(§5.4);
    /// 活动度这 8 条与现行方案卡都不看 facts。
    pub facts: Vec<(usize, Option<NaiveDate>, deid::Fact)>,
    /// 抽取结果里的**原始 labs 行**。定性值(「阴性」「阳性」)解析不出 f64,
    /// 在 `aggregate` 那层就被丢了,但 SLEDAI 的 dsDNA 项允许定性阳性计分
    /// (sle-clinical-sources §B.2),所以必须留一条能看到原文字符串的路。
    pub raw_labs: Vec<(usize, Option<NaiveDate>, deid::LabItem)>,
    /// 每份文档(顺序与调用方给的 `docs` 一致)。
    pub docs: Vec<Doc<'a>>,
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
        let mut out_docs = Vec::new();
        for d in docs {
            out_docs.push(Doc {
                index: d.index,
                date: d.date,
                title: d.title.clone(),
                doc_type: d.doc_type.clone(),
                text: d.text,
            });
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
            docs: out_docs,
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
        .docs
        .iter()
        .any(|d| ctx.in_window(d.date, a.window_days));
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
            for doc in &ctx.docs {
                if !ctx.in_window(doc.date, window) {
                    continue;
                }
                // **逐行**判,不在整份文档上裸匹配:一份报告里「可见红细胞管型」和
                // 「未见红细胞管型」都只是一行,整份 `contains` 分不出这两句,会把
                // 一张明确写着「没有管型」的单子算成 +4(18 分制里最重的一档)。
                for line in doc.text.lines() {
                    let n = terminology::normalize_term(line);
                    if !pats.iter().any(|p| n.contains(p.as_str())) {
                        continue;
                    }
                    // 证据带**原文这一行**(逐字),不是命中的那几个字 —— 不然
                    // 「未见红细胞管型」在证据链里会显示成「红细胞管型」,医生看
                    // 证据也看不出它被否定了。
                    let e = Evidence {
                        document_index: doc.index,
                        date: doc.date.map(|d| d.to_string()),
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

/// 达标检查表(spec §5.3)。`activity` 是 [`activity_eval`] 已经算好的那一次求值 ——
/// 分数从 `hits` 来,**算全了没有**从 `unscored` 来;`regimen` 同理来自
/// [`regimen_eval`],`pred_*` 两条读它的 `daily_mg` / `as_of` / `blocked_reason`。
///
/// 泼尼松等效日剂量**不在这儿另算一遍**:算两遍就有算出两个不同答案的机会,而卡片
/// 上那个「泼尼松 5 mg/天」和达标表里判 `<5` 用的必须是同一个数(与活动度卡和
/// cSLEDAI 同一条理由)。
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
    regimen: &Regimen,
) -> Option<crate::view::Section> {
    if pkg.rules.states.is_empty() {
        return None;
    }
    let pga = latest_pga(ctx, &pkg.manifest.id);
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
            let o = eval_state_item(it, activity, &known, pga, &regimen.gc);
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
    gc: &Gc,
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
        (k @ ("pred_lt" | "pred_le"), Some(v)) => match gc.daily_mg {
            // 理由来自 `regimen_eval`:「一条激素都没读到」和「读到了甲泼尼龙、
            // 换算表待核」在界面上必须是两句不同的话。
            None => ItemOutcome::unknown(
                gc.blocked_reason
                    .clone()
                    .unwrap_or_else(|| "还没读到用药记录".into()),
            ),
            // **日期必须带出去**(与 PGA 的 `actual_at` 一字不差的理由):一张 2019
            // 年的处方今天照样能判出「泼尼松 4 mg < 5 ✔」,日期是唯一能让医生看出
            // 这件事的东西。引擎不设时效,多久算过期由包/渲染层说。
            Some(p) => ItemOutcome {
                actual_at: gc.as_of.map(|d| d.to_string()),
                ..ItemOutcome::judged(
                    if k == "pred_lt" { p < v } else { p <= v },
                    serde_json::json!(p),
                )
            },
        },
        // 只有人能答的条目(「无重要脏器活动」「与上次比无新活动」)。二期由医生在
        // 授权查看器里录(spec §7),此刻恒为未知 —— 诚实,不猜。
        ("manual", _) => ItemOutcome::unknown("这一条要人来答,还没有人答过"),
        // 认不出的 kind 同样是未知,不是 ✘:包可以先于引擎加规则类型。
        _ => ItemOutcome::unknown("这一条规则本机还算不了,更新 App 后会自动补上"),
    }
}

// ---------------------------------------------------------------------------
// 现行方案(spec §5.4,`status_card`):激素等效日剂量、羟氯喹 mg/kg、其它药、
// 上次就诊。**一个临床数字都不写死** —— 等效系数、目标值、说明书原文全在包里。
// ---------------------------------------------------------------------------

/// 换算表未核实时的逐字理由(卡上原样显示;Task 21 的 status_card 断言同一串)。
const GC_TABLE_PENDING: &str = "换算表待核";

/// 达标表那边对「读到了激素、但换不出等效日剂量」的说法。卡上那句是短标签
/// ([`GC_TABLE_PENDING`]),达标表要的是一句完整的话 —— 之前这里恒为「还没读到
/// 用药记录」,而那是一句不实的话:记录读到了,换不出来的是剂量。
const GC_TABLE_PENDING_CHECKLIST: &str = "等效换算表待核,这一项没算进去";

/// 同一天有多条激素记录时的逐字理由。**不求和、也不挑一个**:同一天出现两个激素,
/// 可能是换药、可能是冲击后减量、也可能是 OCR 把一行读成两行,三种情况的日剂量
/// 完全不同。求和会得出一个谁也没开过的剂量,挑一个是替医生猜 —— 而少算的方向
/// 正好制造 DORIS 的假 ✔。
const GC_MULTI_SAME_DAY: &str = "同一天有多条激素记录,请核对";

/// **外用/局部剂型**:压根不是全身激素,不进日剂量、也不占「现行方案」那一格,
/// 整条移到 `others[]`(`class: "gc_nonsystemic"`)。
///
/// 一支复方地塞米松乳膏按口服等效表换算出来是几十毫克泼尼松等效,直接进 DORIS /
/// LLDAS 的判定;在那之前它还会因为「最近」把真正在吃的那个口服激素挤掉。
const GC_NONSYSTEMIC: [&str; 10] = [
    "乳膏",
    "软膏",
    "凝胶",
    "滴眼液",
    "眼膏",
    "喷雾",
    "吸入",
    "鼻喷",
    "外用",
    "滴耳",
];

/// **注射剂型**:进 `unconvertible`,不按口服换算 —— 冲击治疗一次 500 mg 与口服
/// 5 mg/天不是一回事,等效表(待核)覆盖的也只是口服。
const GC_INJECTION: [&str; 7] = ["注射", "针", "静滴", "静脉", "肌注", "iv", "im"];

/// 剂型/途径关键词要找的那片干草:**药名 + 剂量串**,小写。
///
/// ⚠️ 能看到的只有这两处。`parser` 把写在剂量**之后**的给药途径直接剥掉了
/// (`meds.rs::strip_trailing_route`,而 `dose_string` 只拼「剂量 频次」),所以
/// 「甲泼尼龙 40mg 静滴」到这一层时「静滴」已经没了。这道门挡得住把剂型写进
/// **药名**里的那些(复方地塞米松乳膏、注射用甲泼尼龙琥珀酸钠),挡不住写在后面
/// 的 —— 剩下那半要等 parser 把途径也带出来(见 Task 18/19 交接清单)。
fn form_haystack(m: &parser::MedSpan) -> String {
    format!(
        "{} {}",
        m.name,
        m.latest_dose.as_deref().unwrap_or_default()
    )
    .to_ascii_lowercase()
}

/// 把 `MedSpan` 归到包里的某个 `drugs[]` 类(先按 `atc_prefix`,再按 `names` 逐字含)。
/// 包不认得的药返回 `None` —— 它们**不会消失**,照样以 `class: null` 进 `others[]`。
fn drug_class<'p>(
    pkg: &'p crate::package::Package,
    m: &parser::MedSpan,
) -> Option<&'p crate::package::Drug> {
    pkg.drugs.iter().find(|d| {
        d.atc_prefix
            .as_deref()
            .is_some_and(|p| m.atc.as_deref().is_some_and(|a| a.starts_with(p)))
            || d.names.iter().any(|n| m.name.contains(n.as_str()))
    })
}

/// 从 `latest_dose`(`aggregate` 拼的「0.2g bid」这种串)里取**一次**的 mg 数。
///
/// 认不出返回 `None` —— 猜一个数会直接进 DORIS 的「泼尼松 <5 mg」判定,错的比没有
/// 更糟。只认 mg/g:µg、IU、片、粒这些换不成 mg(一片几毫克是规格,处方上没写)。
fn dose_mg(s: &str) -> Option<f64> {
    let t = s.split_whitespace().next()?.to_ascii_lowercase();
    let mg = if let Some(v) = t.strip_suffix("mg") {
        v.parse::<f64>().ok()?
    } else if let Some(v) = t.strip_suffix('g') {
        v.parse::<f64>().ok()? * 1000.0
    } else {
        return None;
    };
    (mg.is_finite() && mg > 0.0).then_some(mg)
}

/// 每天几次。`aggregate` 把频次规范成代码(`qd`/`bid`/…),原文串(「每日两次」)
/// 也认。认不出 → `None`:`qw`/`prn` 这类本来就没有「日剂量」这回事,没写频次的
/// 处方更是 —— 默认 1 次/天等于替处方笺补一个它没写的字。
fn per_day(s: &str) -> Option<f64> {
    let f = s.to_ascii_lowercase();
    // 长的/具体的在前:`tid ac` 含 `tid`,「每日四次」与「每日一次」只差一个字。
    for (pat, n) in [
        ("qid", 4.0),
        ("每日四次", 4.0),
        ("一日四次", 4.0),
        ("每天四次", 4.0),
        ("q8h", 3.0),
        ("tid", 3.0),
        ("每日三次", 3.0),
        ("一日三次", 3.0),
        ("每天三次", 3.0),
        ("q12h", 2.0),
        ("bid", 2.0),
        ("每日两次", 2.0),
        ("每日二次", 2.0),
        ("一日两次", 2.0),
        ("每天两次", 2.0),
        ("qd", 1.0),
        ("qn", 1.0),
        ("每日一次", 1.0),
        ("一日一次", 1.0),
        ("每天一次", 1.0),
        ("每晚一次", 1.0),
    ] {
        if f.contains(pat) {
            return Some(n);
        }
    }
    None
}

/// 一条激素医嘱的泼尼松等效日剂量;算不出来时返回**为什么**(逐字进
/// `gc.unconvertible[].reason`,界面原样显示)。外用/局部剂型不走这里,
/// 在 [`regimen_eval`] 里就被拦去了 `others[]`。
fn gc_daily_mg(d: &crate::package::Drug, m: &parser::MedSpan) -> Result<f64, String> {
    if GC_INJECTION.iter().any(|k| form_haystack(m).contains(k)) {
        return Err("注射剂型,不按口服换算".into());
    }
    let factor = match &d.pred_equiv {
        // 换算表待核(`null`):**只认规范名逐字等于「泼尼松」的那一个**。
        // 泼尼松龙临床上确实按 1:1 算(DORIS Box 1 原文用的就是 prednisolone),
        // 但那是一个**没有出处 id 的临床数值**,写进引擎就违反了 global-constraints
        // 「包里每个数值都带出处 id」。等 Task 19 在包里写 `{"泼尼松龙":1}` + 出处。
        None if m.name == "泼尼松" => 1.0,
        None => return Err(GC_TABLE_PENDING.into()),
        // 表填上以后(Task 19):**最长的那个键赢** —— 「泼尼松龙」比「泼尼松」更
        // 准,而两者都逐字命中「泼尼松龙片」。并列时按键排序定序:`pred_equiv` 是
        // `HashMap`,靠迭代顺序挑等于每次跑都可能挑到另一个系数,而本模块开头承诺
        // 的是「同样的输入永远得到同样的结果」。
        Some(tbl) => match tbl
            .iter()
            .filter(|(k, _)| m.name.contains(k.as_str()))
            .min_by(|a, b| b.0.len().cmp(&a.0.len()).then_with(|| a.0.cmp(b.0)))
        {
            Some((_, f)) => *f,
            None => return Err(GC_TABLE_PENDING.into()),
        },
    };
    // 包是我们签的,签名防的是被人改,防不住作者手滑写个 0 或负数 —— 那会算出一个
    // 0 mg/天的「达标」。
    if !(factor.is_finite() && factor > 0.0) {
        return Err("换算表里的系数不对".into());
    }
    let dose = m.latest_dose.as_deref().unwrap_or_default();
    let Some(mg) = dose_mg(dose) else {
        return Err("剂量读不出来".into());
    };
    let Some(times) = per_day(dose) else {
        return Err("每天几次读不出来".into());
    };
    Ok(mg * times * factor)
}

/// 现行激素方案的一次求值。
struct Gc {
    daily_mg: Option<f64>,
    drug: Option<String>,
    /// 处方上的原剂量串(`"10mg qd"`),证据链用。
    dose: Option<String>,
    /// 这条医嘱出现在哪几份文档里(`parser::SourceDoc::index`)。
    sources: Vec<usize>,
    /// 最早一次被提到的日期。
    since: Option<NaiveDate>,
    /// **截至哪天** —— 最近一次被提到的日期(`MedSpan.end`)。
    ///
    /// 没有这个数,一张 2019 年的处方今天读起来就是「现行方案:泼尼松 4 mg/天」,
    /// DORIS 的「<5 mg」直接 ✔。`since` 是**起始**日期,读起来像「一直吃到现在」,
    /// 答不了这个问题。引擎**不设时效**(与 PGA 同一条:多久算过期由包/渲染层说),
    /// 只负责把日期说出来。
    as_of: Option<NaiveDate>,
    /// 算不进日剂量的激素,`{name, dose, reason, sources}`。
    unconvertible: Vec<serde_json::Value>,
    /// `daily_mg` 为 `None` 时给达标表的那句理由(`None` = 算出来了)。
    blocked_reason: Option<String>,
}

/// 现行方案的一次求值:激素那一格 + 其它药那一格。**一份输入只算一遍**,
/// `status_card` 与达标表读的是同一次结果(与 `activity_eval` 同一条理由)。
pub struct Regimen {
    gc: Gc,
    /// 激素与羟氯喹之外的药,`{class, name, latest_dose, since, sources, infusion}`。
    others: Vec<serde_json::Value>,
}

fn other_row(
    class: Option<&str>,
    m: &parser::MedSpan,
    infusion: Option<&std::collections::HashMap<String, String>>,
) -> serde_json::Value {
    serde_json::json!({
        "class": class,
        "name": m.name,
        "latest_dose": m.latest_dose,
        "since": m.start.map(|x| x.to_string()),
        "as_of": m.end.map(|x| x.to_string()),
        "sources": m.sources,
        // 输注周期是包里的原串(§D.8 的 0/2/4 周后每 4 周之类),引擎不排期。
        "infusion": infusion,
    })
}

/// 逐条过一遍用药,分成「激素」与「其它」两格。
///
/// **「现行」= 最近一次被提到的那条**(`MedSpan.end`),不是「第一个算得出来的」:
/// 病历里常见 2024 年泼尼松、2026 年换甲泼尼龙,挑算得出来的那个会把三年前停掉的
/// 剂量当成今天的方案送进 DORIS 的「<5 mg」判定。当前这条算不出来,就是算不出来。
///
/// **包/词典认不得的药不会消失**:它们以 `class: null` 进 `others[]`(倍他米松、
/// 曲安西龙、可的松今天都不在词典的 H02A* 里),医生照样看得见药名和剂量。
pub fn regimen_eval(ctx: &Ctx<'_>, pkg: &crate::package::Package) -> Regimen {
    let mut gc_lines: Vec<(&parser::MedSpan, Result<f64, String>)> = Vec::new();
    let mut others = Vec::new();
    for m in &ctx.clinical.meds {
        match drug_class(pkg, m) {
            // 认不出的药照样列出来(I2)。
            None => others.push(other_row(None, m, None)),
            Some(d) if d.class == "gc" => {
                if GC_NONSYSTEMIC.iter().any(|k| form_haystack(m).contains(k)) {
                    others.push(other_row(Some("gc_nonsystemic"), m, None));
                } else {
                    gc_lines.push((m, gc_daily_mg(d, m)));
                }
            }
            // 羟氯喹自己一格(`hcq_body`),不在 `others` 里重复一遍。
            Some(d) if d.class == "hcq" => {}
            Some(d) => others.push(other_row(Some(&d.class), m, d.infusion.as_ref())),
        }
    }

    // 最近一次被提到的那个日期;没有日期的整条排在最前(`None < Some`)。
    let newest = gc_lines.iter().map(|(m, _)| m.end).max();
    let same_day: Vec<&(&parser::MedSpan, Result<f64, String>)> = gc_lines
        .iter()
        .filter(|(m, _)| Some(m.end) == newest)
        .collect();
    // 同一天两条以上 → 谁都不算(见 `GC_MULTI_SAME_DAY`)。
    let conflict = same_day.len() > 1;

    let mut unconvertible = Vec::new();
    for (m, r) in &gc_lines {
        let reason = match (conflict && Some(m.end) == newest, r) {
            (true, _) => Some(GC_MULTI_SAME_DAY.to_string()),
            (false, Err(why)) => Some(why.clone()),
            (false, Ok(_)) => None,
        };
        if let Some(reason) = reason {
            unconvertible.push(serde_json::json!({
                "name": m.name, "dose": m.latest_dose,
                "reason": reason, "sources": m.sources,
            }));
        }
    }

    let gc = match (conflict, same_day.first()) {
        // 一条激素都没读到。
        (_, None) => Gc {
            daily_mg: None,
            drug: None,
            dose: None,
            sources: Vec::new(),
            since: None,
            as_of: None,
            unconvertible,
            blocked_reason: Some("还没读到用药记录".into()),
        },
        // 同一天多条:日剂量为空,但**日期照样说出来** —— 「哪天的记录要核对」是
        // 这条提示的一半。
        (true, Some(_)) => Gc {
            daily_mg: None,
            drug: None,
            dose: None,
            sources: Vec::new(),
            since: None,
            as_of: newest.flatten(),
            unconvertible,
            blocked_reason: Some(GC_MULTI_SAME_DAY.into()),
        },
        (false, Some((m, r))) => {
            let blocked = match r {
                Ok(_) => None,
                // 「换算表待核」在达标表里要说成一句完整的话。
                Err(why) if why == GC_TABLE_PENDING => Some(GC_TABLE_PENDING_CHECKLIST.to_string()),
                // 其余理由(剂量读不出来、注射剂型…)原样带过去,**不套用换算表那句**
                // —— 那同样是一句不实的话。
                Err(why) => Some(format!("读到了{},{},这一项算不了", m.name, why)),
            };
            Gc {
                daily_mg: r.as_ref().ok().copied(),
                drug: Some(m.name.clone()),
                dose: m.latest_dose.clone(),
                sources: m.sources.clone(),
                since: m.start,
                as_of: m.end,
                unconvertible,
                blocked_reason: blocked,
            }
        }
    };
    Regimen { gc, others }
}

/// 最近一次体重(日期、kg、来源)。`profile_event{kind:"weight"}` 与病历/自测的
/// `body_weight` 序列**一起比日期,最新的赢**;一条都没有 → `None`。
///
/// 没有体重就不给 mg/kg。拿理想体重公式、拿人群均值、拿上次住院的体重垫一个数出来,
/// 都是在编一个 mg/kg —— 而 5 mg/kg 那条线的分母就是它。
fn latest_weight_kg(ctx: &Ctx<'_>, package_id: &str) -> Option<(Option<NaiveDate>, f64, String)> {
    let mut best: Option<(Option<NaiveDate>, f64, String)> = None;
    let mut offer = |at: Option<NaiveDate>, kg: f64, src: &str| {
        // 0 或负数会让 mg/kg 变成 inf/负数,而这是用户手录的字段。
        if !(kg.is_finite() && kg > 0.0) {
            return;
        }
        if best.as_ref().is_none_or(|(cur, _, _)| at >= *cur) {
            best = Some((at, kg, src.to_string()));
        }
    };
    for s in &ctx.clinical.labs {
        if s.analyte_key.as_deref() != Some("body_weight") {
            continue;
        }
        // 只认规范单位是 kg 的序列 —— `value_canonical` 与它同单位。把 lb 当 kg 用
        // 是一个 2.2 倍的 mg/kg。
        if s.unit_canonical.as_deref() != Some("kg") {
            continue;
        }
        let src = if s.self_measured {
            "self_reported"
        } else {
            "record"
        };
        for p in &s.points {
            if let Some(v) = p.value_canonical {
                offer(p.date, v, src);
            }
        }
    }
    // 事件放在最后:同一天既有事件又有序列时,用户自己刚录的那条说了算。
    for e in ctx.events {
        if e.package != package_id || e.kind != "weight" {
            continue;
        }
        let Some(kg) = e.payload.get("kg").and_then(serde_json::Value::as_f64) else {
            continue;
        };
        offer(e.at.parse().ok(), kg, "self_reported");
    }
    best
}

/// 羟氯喹那一格。
///
/// **说明书那几个数只进 `label_rule` / `label_rule_pending`,不进任何判定** ——
/// `mg_per_kg` 永远只跟包里的指南值 `target` 比(§D.2.1:指南 5 mg/kg 真实体重 vs
/// 说明书 6.5 mg/kg 理想体重,两套同时成立,引擎不许替医生挑一份)。
///
/// 剂量与体重**各带各的日期**(`dose_at` / `weight_at`):一张 2019 年的处方配今天
/// 的体重,算出来的 mg/kg 看着像今天的,不说日期就是一句不实的话。
fn hcq_body(ctx: &Ctx<'_>, pkg: &crate::package::Package) -> serde_json::Value {
    let t = pkg.rules.targets.get("hcq");
    let label_rule = t.and_then(|h| h.get("label_rule"));
    // 与激素同一条规则:取**最近一次被提到**的那条,不是碰巧排在前面的那条。
    let med = ctx
        .clinical
        .meds
        .iter()
        .filter(|m| drug_class(pkg, m).is_some_and(|d| d.class == "hcq"))
        .max_by_key(|m| m.end);
    let daily = med.and_then(|m| {
        let dose = m.latest_dose.as_deref()?;
        Some(dose_mg(dose)? * per_day(dose)?)
    });
    let weight = latest_weight_kg(ctx, &pkg.manifest.id);
    let mg_per_kg = daily.zip(weight.as_ref()).map(|(d, (_, kg, _))| d / kg);
    // 未知必须带一句为什么,不然界面上的空白和「这项我们不打算算」长得一样。
    let reason = match (med, daily, &weight) {
        (None, _, _) => Some("还没读到羟氯喹的处方"),
        (Some(_), None, _) => Some("处方上的剂量或用法读不出来,算不出日剂量"),
        (Some(_), Some(_), None) => Some("还没有体重记录,算不了 mg/kg"),
        _ => None,
    };
    serde_json::json!({
        "daily_mg": daily,
        "dose": med.and_then(|m| m.latest_dose.clone()),
        "dose_at": med.and_then(|m| m.end).map(|d| d.to_string()),
        "sources": med.map(|m| m.sources.clone()).unwrap_or_default(),
        "weight_kg": weight.as_ref().map(|(_, kg, _)| *kg),
        // 体重是哪天的。三年前的体重和今天刚录的,少了这一行在界面上长得一模一样
        // (与达标表里 PGA 的 `actual_at` 同一条理由)。
        "weight_at": weight.as_ref().and_then(|(at, _, _)| at.map(|d| d.to_string())),
        "weight_source": weight.as_ref().map(|(_, _, s)| s.as_str()),
        "mg_per_kg": mg_per_kg,
        "target": t.and_then(|h| h.get("target")),
        "target_source": t.and_then(|h| h.get("target_source")),
        "label_rule": label_rule.and_then(|l| l.get("text")),
        // **fail closed**:只有逐字的 `"verified"` 能清掉这面旗。`verify_status` 漏写、
        // 拼错、写成别的值,一律算「待核」—— 反过来(缺省即已核实)是把一句没人核过
        // 的说明书原文当成核过的送到医生眼前,而这张卡上说明书那几个数和指南的数**不
        // 一样**(§D.2.1)。旗立错了只是多一句提示,旗漏了是一句不实的话。
        "label_rule_pending":
            label_rule.and_then(|l| l.get("verify_status")).and_then(|v| v.as_str()) != Some("verified"),
        "reason": reason,
    })
}

/// 上次就诊 = 最近一份**医疗机构出的**文档。手动录入的那几类(自测、笔记、动作
/// 日志)不是就诊 —— 把用户昨天随手录的一次体重显示成「上次就诊」是一句不实的话。
/// 没有日期的文档不参与:「最近」是按日期比出来的。
///
/// ⚠️ 这里没有科室信息,所以它是「上次交进来的那份病历」,**不是**「上次风湿科
/// 就诊」。Task 21 不许把它标成后者。
///
/// 第二个读者是复查提醒里的病级节律([`cadence_rule`]):「该复诊了」要按**上次
/// 就诊**算,不是按上次化验 —— 所以这里返回文档本身,两个调用方各取所需。
fn last_visit_doc<'c, 'a>(ctx: &'c Ctx<'a>) -> Option<&'c Doc<'a>> {
    ctx.docs
        .iter()
        .filter(|d| {
            !matches!(
                d.doc_type.as_deref(),
                Some("self_measurement" | "note" | "profile_event")
            ) && d.date.is_some()
        })
        .max_by_key(|d| d.date)
}

fn last_visit(ctx: &Ctx<'_>) -> serde_json::Value {
    let Some(d) = last_visit_doc(ctx) else {
        return serde_json::Value::Null;
    };
    serde_json::json!({
        "date": d.date.map(|x| x.to_string()),
        "title": d.title,
    })
}

/// 现行方案卡(spec §6 的 `status_card`)。
///
/// `body` 的形状(Task 21 的渲染引擎按这一份读):
/// ```text
/// {"gc":{"daily_pred_equiv_mg","drug","dose","sources","since","as_of",
///        "targets":[{"value","label","source"}],                 // 包里的两条维持线
///        "unconvertible":[{"name","dose","reason","sources"}]},   // 没算进日剂量的 + 为什么
///  "hcq":{"daily_mg","dose","dose_at","sources","weight_kg","weight_at","weight_source",
///         "mg_per_kg","target","target_source","label_rule","label_rule_pending","reason"},
///  "others":[{"class","name","latest_dose","since","as_of","sources","infusion"}],
///  "last_visit":{"date","title"}}                                // 一份都没有时为 null
/// ```
/// **`gc.as_of` / `hcq.dose_at` 必须显示在剂量旁边**(Task 21):引擎不设时效,
/// 一张 2019 年的处方照样会出现在这张卡上,日期是唯一能让医生看出这件事的东西。
///
/// 包里一个 `drugs[]` 都没声明时不出这张卡:没有药物表就没有任何可认的东西,一张
/// 全是 `null` 的卡片不如没有。
pub fn status_section(
    ctx: &Ctx<'_>,
    pkg: &crate::package::Package,
    reg: &Regimen,
) -> Option<crate::view::Section> {
    if pkg.drugs.is_empty() {
        return None;
    }
    let gc = &reg.gc;
    let hcq = hcq_body(ctx, pkg);
    let visit = last_visit(ctx);
    // 折叠的条件和活动度卡一样:**真的没东西可看**。只要读到了一个药(哪怕它的
    // 剂量算不出来),就展开 —— 让 `unconvertible` 的理由自己说话。
    let nothing = gc.drug.is_none()
        && gc.unconvertible.is_empty()
        && hcq["daily_mg"].is_null()
        && reg.others.is_empty();
    Some(crate::view::Section {
        kind: "status_card".into(),
        title: view_title(pkg, "status_card"),
        empty_hint: (nothing && visit.is_null())
            .then(|| "还没读到处方,下次把处方笺或出院小结拍进来,这里会显示现行方案".to_string()),
        body: serde_json::json!({
            "gc": {
                "daily_pred_equiv_mg": gc.daily_mg,
                "drug": gc.drug,
                "dose": gc.dose,
                "sources": gc.sources,
                "since": gc.since.map(|d| d.to_string()),
                "as_of": gc.as_of.map(|d| d.to_string()),
                // 包里没写、或者写成了别的形状,就是空数组:三个数组字段(targets /
                // unconvertible / others)在渲染层一律当数组遍历,少一个类型分支。
                "targets": pkg.rules.targets.get("gc").filter(|v| v.is_array())
                    .cloned().unwrap_or_else(|| serde_json::json!([])),
                "unconvertible": gc.unconvertible,
            },
            "hcq": hcq,
            "others": reg.others,
            "last_visit": visit,
        }),
    })
}

// ---------------------------------------------------------------------------
// 复查提醒(spec §5.4,`reminders`)。**只有三种来源,没有第四种**:
//   1. `disease_cadence` —— 病级复诊节律(指南按活动/稳定给的间隔);
//   2. `drug_schedule`   —— 说明书/指南**明示**的监测频率(分档);
//   3. `drug_threshold`  —— 说明书/指南在某个剂量-时长-年龄阈值上**明示**的动作。
// 引擎**永远不会按单项化验指标造一个复查间隔** —— sle-clinical-sources §A.1 的
// 「最重要的负面发现」:中国 2020/2025 与 EULAR 都没有给 dsDNA/补体/尿蛋白/血常规
// 任何单项间隔。多出来的第四种 kind 一律进 `unknown`,不猜、也不静默。
// ---------------------------------------------------------------------------

/// 活动度没算全时,复诊提醒文案上要加的那一句(逐字显示)。
const CADENCE_UNSURE: &str = "活动度还没算全,按较密的节律提醒";

/// 一条提醒这次的结论。
enum Remind {
    /// 到期了:`0` 是该查的那天,`1` 是从那天起超了多少天。
    Overdue(NaiveDate, i64),
    /// 从没查过 —— 比逾期更硬的缺口,排在前面。
    Never,
    /// 算不了,附一句为什么(未知必须带理由,不然和「这条我们不打算算」长得一样)。
    Unknown(String),
    /// 包里这条(或这一档)的间隔/阈值还没核实:只显示,**永远不算出到期日**。
    Pending,
    /// 不用提(没到期、或没达到阈值)。不进列表。
    Ok,
}

/// 一条提醒求值的产物:状态 + 要盖到包那份 JSON 上的字段。
///
/// `extra` 是个字典而不是一串具名字段:各种来源要盖的东西不一样(节律盖
/// `disease_state`/`text`,药物类盖 `since`/`as_of`,分档的还要盖 `basis`/`source`/
/// `note`),而**只有算出它的那段代码知道该盖什么** —— 在结构体上给每一种都开一个
/// `Option` 字段,等于让另外两种各带一个恒为 `None` 的洞。
struct Reminder {
    state: Remind,
    /// 当前这一档的间隔。`None` = 这条没有间隔(阈值类,或间隔没核实)。
    every_days: Option<i64>,
    extra: serde_json::Map<String, serde_json::Value>,
}

fn plain(state: Remind, every_days: Option<i64>) -> Reminder {
    Reminder {
        state,
        every_days,
        extra: serde_json::Map::new(),
    }
}

/// 复查提醒(spec §5.4)。`activity` / `regimen` 是 [`activity_eval`] 与
/// [`regimen_eval`] 已经算好的那一次求值,**不在这儿重算**(与达标表同一条理由:
/// 算两遍就有算出两个不同答案的机会)。
///
/// `body` 的形状(Task 21 的渲染引擎按这一份读):包里那条规则的**全部字段原样带出**
/// (`id`/`kind`/`basis`/`source`/`text`/`target`/`action`/`note`/`panel_keys`…),
/// 再盖上引擎算出来的这几个:
/// ```text
/// {"items":[{…包里的原字段…,
///            "state":"never|overdue|unknown|pending",  // 排序也按这个顺序
///            "pending":bool,                            // 数没核实 = 只显示不到期
///            "reason":"…"|null,                         // 只有 unknown 有
///            "due_at":"YYYY-MM-DD"|null,                // 最近一次 + 间隔
///            "overdue_days":int|null,                   // 从 due_at 起超了几天
///            "every_days":int|null,                     // 当前这一档的间隔
///            // 下面几个按来源出现,不适用的那种根本没有这个键:
///            "disease_state":"active|stable",           // 病级节律
///            "since","as_of":"YYYY-MM-DD"|null,         // 药物类:处方最早/最近的日期
///            "basis","source","note"}]}                 // 分档的可由档级覆盖规则级
/// ```
/// 包里 `disease_cadence` 那个 `state`(active|stable)是**规则的适用条件**,与这里
/// 的提醒状态同名不同义,所以出口时挪进 `disease_state`,`state` 让给提醒状态。
///
/// 包里一条 `monitoring` 都没有时不出这张卡(没有规则就没有「该查没查」这回事)。
pub fn reminders_section(
    ctx: &Ctx<'_>,
    pkg: &crate::package::Package,
    activity: &Activity,
    regimen: &Regimen,
) -> Option<crate::view::Section> {
    if pkg.rules.monitoring.is_empty() {
        return None;
    }
    let mut items: Vec<serde_json::Value> = pkg
        .rules
        .monitoring
        .iter()
        .filter_map(|m| eval_monitor(ctx, pkg, activity, regimen, m))
        .collect();
    // 「还没查过」排在「逾期」前面(更硬的缺口),同档按超期天数倒序;算不了的和
    // 没核实的排最后 —— 它们连到期日都算不出来,不该占着列表最上面那一屏。
    // `sort_by_key` 是稳定排序,并列时保持包里的顺序 —— 同一份输入永远同一个顺序。
    items.sort_by_key(|i| {
        let rank = match str_field(i, "state") {
            "never" => 0,
            "overdue" => 1,
            "unknown" => 2,
            _ => 3,
        };
        (rank, -i["overdue_days"].as_i64().unwrap_or(0))
    });
    Some(crate::view::Section {
        kind: "reminders".into(),
        title: view_title(pkg, "reminders"),
        // 空列表有三种来源:都没到期、都被忽略了、包里的规则都不适用。说「该查的
        // 都查过了」只有第一种成立,另外两种是不实的话。
        empty_hint: items.is_empty().then(|| "暂时没有到期要补的".to_string()),
        body: serde_json::json!({ "items": items }),
    })
}

/// 求一条监测规则。`None` = 这条**不适用**(没在吃这个药、或病情状态不是它那一档),
/// 不出现在列表里。
fn eval_monitor(
    ctx: &Ctx<'_>,
    pkg: &crate::package::Package,
    activity: &Activity,
    regimen: &Regimen,
    m: &serde_json::Value,
) -> Option<serde_json::Value> {
    let r = match str_field(m, "kind") {
        "disease_cadence" => cadence_rule(ctx, m, activity)?,
        "drug_schedule" => schedule_rule(ctx, pkg, m)?,
        "drug_threshold" => threshold_rule(ctx, pkg, m, regimen)?,
        // 认不出的 kind **要如实说算不了**,不静默跳过:静默等于给「悄悄加第四种
        // 来源」留了一条看不见的路。包可以先于引擎加规则类型(`min_engine` 管的是
        // 必须懂的那些)。
        _ => plain(
            Remind::Unknown("这一条规则本机还算不了,更新 App 后会自动补上".into()),
            None,
        ),
    };
    let (state, reason, due, overdue_days) = match &r.state {
        Remind::Ok => return None,
        Remind::Never => ("never", None, None, None),
        Remind::Overdue(due, days) => ("overdue", None, Some(*due), Some(*days)),
        Remind::Unknown(why) => ("unknown", Some(why.clone()), None, None),
        Remind::Pending => ("pending", None, None, None),
    };
    let id = str_field(m, "id");
    // 没有 id 的条目忽略不掉、在界面上也定位不住(渲染层按 id 做 key),不如不出。
    // 包里不该有这种条目,由包校验那一层钉住(`reminders.rs` 的守卫用例)。
    if id.is_empty() || dismissed(ctx, pkg, id, due, r.every_days) {
        return None;
    }
    // 包里那条规则**原样带出**:`basis`/`source`/`note`/`text` 这些全是包作者写的,
    // 引擎逐个转抄只会漏字段(spec §5.4:每条提醒带出处 id 与三选一的标签)。
    let mut row = m.clone();
    let obj = row.as_object_mut()?;
    obj.insert("state".into(), serde_json::json!(state));
    // **`pending` 是「这条规则的数没核实」,不只是「这次的状态是 pending」**:
    // 阈值类可能因为别的原因(没年龄)先落进 unknown,那面旗还是得举着 —— 不然
    // 渲染层会把一条没人核过的规则当成一条只是暂时算不出来的规则。
    obj.insert(
        "pending".into(),
        serde_json::json!(matches!(r.state, Remind::Pending) || monitor_pending(m)),
    );
    obj.insert("reason".into(), serde_json::json!(reason));
    obj.insert(
        "due_at".into(),
        serde_json::json!(due.map(|d| d.to_string())),
    );
    obj.insert("overdue_days".into(), serde_json::json!(overdue_days));
    obj.insert("every_days".into(), serde_json::json!(r.every_days));
    for (k, v) in r.extra {
        obj.insert(k, v);
    }
    Some(row)
}

/// 包里这条规则(或这一档)的间隔/阈值核实了没有。**fail closed**:只有逐字
/// `"verified"` 能清掉这面旗(与 `hcq.label_rule_pending` 同一条规矩,理由也一样)。
/// 漏写、拼错、写成别的值一律算「待核」—— 反过来(缺省即已核实)会把一个没人核过
/// 的间隔算成到期日推到用户面前,而 §D.1/§D.2.1 里核不实的间隔恰恰是最多的那一类。
fn monitor_pending(m: &serde_json::Value) -> bool {
    str_field(m, "verify_status") != "verified"
}

/// 病级复诊节律。活动/稳定来自 [`activity_eval`] 那一次求值:**有命中 = 活动**;
/// 全算过了、一条都没命中 = 稳定;**没算全就按活动期那条(更密的)提醒**,并在
/// 文案里说出来 —— 把「这次没读到」当成「病情稳定」,是把复诊间隔从 1 个月拉到
/// 3 个月,而这个方向上的错会漏掉复发。
///
/// **「上次做过」= 上次就诊 与 最近一次那组化验,取更晚的那一个。** 复诊提醒说的是
/// 「该去看医生了」,不是「你的某项化验过期了」(§A.1 的负面发现):上周刚看完门诊、
/// 只是那次没开化验(或化验单还没拍进来),今天不该被告知「该复诊了」;反过来,
/// 拍进来一张化验单本身就说明去过医院了。
fn cadence_rule(ctx: &Ctx<'_>, m: &serde_json::Value, activity: &Activity) -> Option<Reminder> {
    let (state, unsure) = if !activity.hits.is_empty() {
        ("active", false)
    } else if activity.unscored.is_empty() {
        ("stable", false)
    } else {
        ("active", true)
    };
    // 另一档的那条规则这次不适用。
    if str_field(m, "state") != state {
        return None;
    }
    let mut extra = serde_json::Map::new();
    extra.insert("disease_state".into(), serde_json::json!(state));
    if monitor_pending(m) {
        return Some(Reminder {
            extra,
            ..plain(Remind::Pending, None)
        });
    }
    let Some(every) = m.get("every_days").and_then(serde_json::Value::as_i64) else {
        return Some(Reminder {
            extra,
            ..plain(
                Remind::Unknown("这一条的间隔读不出来(包里不是整数)".into()),
                None,
            )
        });
    };
    if unsure {
        extra.insert(
            "text".into(),
            serde_json::json!(format!("{}({CADENCE_UNSURE})", str_field(m, "text"))),
        );
    }
    let last = latest_done(ctx, m).max(visited_on(ctx));
    Some(Reminder {
        extra,
        ..plain(due_state(ctx, last, every), (every >= 1).then_some(every))
    })
}

/// 上次就诊那天(`last_visit` 找的是同一份文档),**未来日期不算**:OCR 把
/// 2026 读成 2027 的单子不该把一条该提的提醒按下去(与 [`latest_done`] 同一条)。
fn visited_on(ctx: &Ctx<'_>) -> Option<NaiveDate> {
    last_visit_doc(ctx)
        .and_then(|d| d.date)
        .filter(|d| *d <= ctx.today)
}

/// 说明书/指南明示的监测频率。没在吃这个药 = 这条规则不适用,整条不出现。
fn schedule_rule(
    ctx: &Ctx<'_>,
    pkg: &crate::package::Package,
    m: &serde_json::Value,
) -> Option<Reminder> {
    let meds = meds_of_class(ctx, pkg, str_field(m, "drug_class"));
    if meds.is_empty() {
        return None;
    }
    let mut extra = span_dates(&meds);
    let (state, every_days) = schedule_due(ctx, m, &meds, &mut extra);
    Some(Reminder {
        state,
        every_days,
        extra,
    })
}

/// `phases` 按顺序取**第一条还没过期**的:`until_days` 是这一档的终点(用药第几天
/// 为止),不写 = 这一档没有终点。
///
/// **档级的 `basis`/`source`/`note`/`verify_status` 覆盖规则级**:说明书逐字往往只
/// 覆盖前几档(MMF 只写到「the remainder of the first year」),包作者把之后那一档
/// 按同样的频率沿用下去是**外推**,它必须以自己的身份出去(`package_default` +
/// 待核),不能顶着「出处=说明书」的标签发给渲染层。覆盖只能把事情变得**更**待核:
/// 规则级已经待核的,前面早就短路了。
///
/// 几档都过完了(每一档都写了终点)是 `unknown` 不是「不用查」:说明书只写到第一年
/// 的时候,「之后不用再查了」是它没说过的话。
fn schedule_due(
    ctx: &Ctx<'_>,
    m: &serde_json::Value,
    meds: &[&parser::MedSpan],
    extra: &mut serde_json::Map<String, serde_json::Value>,
) -> (Remind, Option<i64>) {
    if monitor_pending(m) {
        return (Remind::Pending, None);
    }
    // 起始日 = 最早一次**有日期**的提及。⚠️ `profile_event{kind:"drug_start"}`
    // 目前还没有任何地方产出(C5 的界面才会录),等它有了要一起参与取最早值。
    let Some(start) = meds.iter().filter_map(|x| x.start).min() else {
        return (
            Remind::Unknown("处方上没有日期,算不出现在该按哪一档".into()),
            None,
        );
    };
    let phases = m
        .get("phases")
        .and_then(|p| p.as_array())
        .map(Vec::as_slice)
        .unwrap_or_default();
    // 「包里根本没写档」和「几档都过完了」是两回事,理由不能混着说。
    if phases.is_empty() {
        return (Remind::Unknown("包里没给这一条写监测频率".into()), None);
    }
    let days_on = (ctx.today - start).num_days();
    let Some(phase) = phases.iter().find(|p| {
        p.get("until_days")
            .and_then(serde_json::Value::as_i64)
            .is_none_or(|u| days_on <= u)
    }) else {
        return (
            Remind::Unknown("说明书给的几档都过完了,之后多久查一次没有出处".into()),
            None,
        );
    };
    for k in ["basis", "source", "note"] {
        if let Some(v) = phase.get(k) {
            extra.insert(k.to_string(), v.clone());
        }
    }
    // **只有档里自己写了 `verify_status` 才算档级声明**:没写的那几档沿用规则级
    // (照 `monitor_pending` 的 fail closed 直接判,会把没写的档一律打成待核)。
    if phase.get("verify_status").is_some() && monitor_pending(phase) {
        return (Remind::Pending, None);
    }
    let Some(every) = phase.get("every_days").and_then(serde_json::Value::as_i64) else {
        return (
            Remind::Unknown("这一档的间隔读不出来(包里不是整数)".into()),
            None,
        );
    };
    (
        due_state(ctx, latest_done(ctx, m), every),
        (every >= 1).then_some(every),
    )
}

/// 剂量-时长(-年龄)阈值上的动作:§D.1 的「⩾7.5 mg 且超过 3 个月 → 补钙和维 D」
/// 是唯一一条能逐字拿到的。达阈就是 `never`(这类动作没有「上次做过」这回事,
/// 用户做过了自己忽略掉)。没在吃这个药 = 不适用,整条不出现。
fn threshold_rule(
    ctx: &Ctx<'_>,
    pkg: &crate::package::Package,
    m: &serde_json::Value,
    reg: &Regimen,
) -> Option<Reminder> {
    let class = str_field(m, "drug_class");
    let meds = meds_of_class(ctx, pkg, class);
    if meds.is_empty() {
        return None;
    }
    Some(Reminder {
        extra: span_dates(&meds),
        ..plain(threshold_due(ctx, m, &meds, reg, class), None)
    })
}

/// 阈值判定的顺序是**先算逐字的门槛,再说我们能不能开口**:
///
/// 1. 剂量(`min_daily_pred_equiv`)、2. 时长(`min_days`)—— 这两个是源文件里逐字的
///    适用人群;不满足就是**这条规则跟这个人无关**(`Ok`,整条不出)。
/// 3. 满足了,才轮到 `min_age` / `verify_status`:它们把一条**本该提的**提醒降级成
///    「算不了」或「数还没核实」。
///
/// 顺序反过来会出人命题:吃 1 mg 泼尼松 2 天的人,会因为这条规则整体待核而看到
/// 「做一次骨密度」—— 待核该挡住的是那个没核过的数(≥40 岁 FRAX),不是这条规则
/// 的适用人群。
///
/// 日剂量读 [`regimen_eval`] 那一次算好的 `gc.daily_mg`,**算不出来时是 `unknown`
/// 附理由,不是「没到阈值」** —— 静默跳过会让一条该提的提醒消失得无声无息。
///
/// ⚠️ 近似:阈值原文是「started on ⩾7.5 mg **and continues**」,引擎拿的是
/// **现行**日剂量(最近一条医嘱)配**最早一次**激素提及起算的天数。从 60 mg 减到
/// 5 mg 的人不会被提(现行剂量没到阈),这是对的;但「中间停过几个月」这件事
/// `MedSpan` 看不出来,那种情况下天数会偏长 —— 所以出口带 `since`/`as_of`。
fn threshold_due(
    ctx: &Ctx<'_>,
    m: &serde_json::Value,
    meds: &[&parser::MedSpan],
    reg: &Regimen,
    class: &str,
) -> Remind {
    if let Some(min_mg) = m
        .get("min_daily_pred_equiv")
        .and_then(serde_json::Value::as_f64)
    {
        // 泼尼松等效日剂量只有激素那一格算得出来;包把这个条件写在别的药上,
        // 是引擎还不懂的规则,不是「没到阈值」。
        if class != "gc" {
            return Remind::Unknown("这一条规则本机还算不了,更新 App 后会自动补上".into());
        }
        let Some(daily) = reg.gc.daily_mg else {
            return Remind::Unknown(
                reg.gc
                    .blocked_reason
                    .clone()
                    .unwrap_or_else(|| "算不出泼尼松等效日剂量".into()),
            );
        };
        if daily < min_mg {
            return Remind::Ok;
        }
    }
    if let Some(min_days) = m.get("min_days").and_then(serde_json::Value::as_i64) {
        let Some(start) = meds.iter().filter_map(|x| x.start).min() else {
            return Remind::Unknown("处方上没有日期,算不出用了多久".into());
        };
        if (ctx.today - start).num_days() < min_days {
            return Remind::Ok;
        }
    }
    // 档案里根本没有年龄这一项。「没有就当不满足」会让这条**永远**不出现、而且
    // 一声不响 —— 骨密度那条恰恰是最容易被忘掉的一类。如实说算不了。
    if m.get("min_age").is_some() {
        return Remind::Unknown("这一条要看年龄,档案里还没有年龄".into());
    }
    if monitor_pending(m) {
        return Remind::Pending;
    }
    Remind::Never
}

/// 到期判定(spec §5.4):最近一次 + 间隔 ×1.2 还早于今天 → 逾期;从没查过 →
/// `never`;都不是 → 不用提。「最近一次」由调用方给(节律那条还要算上就诊日期)。
fn due_state(ctx: &Ctx<'_>, last: Option<NaiveDate>, every_days: i64) -> Remind {
    if every_days < 1 {
        return Remind::Unknown("包里的间隔不是正整数,这一条先不提".into());
    }
    let Some(last) = last else {
        return Remind::Never;
    };
    // 宽限按整数算(`×12/10` 向下取整):每 30 天 → 36 天。早一天开口只是多问一句,
    // 晚一天是漏掉一次该做的复查。乘法也得是 checked 的:`every_days` 是包里的裸
    // `i64`,手滑写个大数在 debug 下是 panic、release 下会回绕成一个**很短**的宽限
    // (与 `weight_sum` 同一条:回绕出来的那个数看起来很正常)。
    let Some((due, grace)) = add_days(last, every_days).zip(
        every_days
            .checked_mul(12)
            .and_then(|x| add_days(last, x / 10)),
    ) else {
        return Remind::Unknown("包里的间隔算出来越界了,这一条先不提".into());
    };
    if grace < ctx.today {
        Remind::Overdue(due, (ctx.today - due).num_days())
    } else {
        Remind::Ok
    }
}

/// 上一次做过是哪天:`panel_keys` 里任一化验的最新**有日期**的点,与 `exam_names`
/// 里任一 `exam_done` fact 的日期,取更晚的那个。都没有 → `None`(= 从没查过)。
///
/// 三道门,方向都是同一个 —— **宁可多提一次,不可少提一次**:
/// - 没有日期的结果不算(与 `in_window` 同一条:猜日期等于编一个到期日);
/// - **今天之后的日期不算**(同 `in_window` 的 `d <= today`):一张被 OCR 读成 2027 年
///   的化验单,会把今天该提的提醒整条按下去;
/// - 自测值不算 —— 家里量的那一次不是「去医院复查过了」;
/// - 逐字验不过的 fact 不算:抽取幻觉出来的一句「已做骨密度」压不住提醒。
fn latest_done(ctx: &Ctx<'_>, m: &serde_json::Value) -> Option<NaiveDate> {
    let keys = str_list(m, "panel_keys");
    let mut best: Option<NaiveDate> = None;
    for s in &ctx.clinical.labs {
        let Some(k) = s.analyte_key.as_deref() else {
            continue;
        };
        if !keys.contains(&k) || s.self_measured {
            continue;
        }
        for p in &s.points {
            best = best.max(p.date.filter(|d| *d <= ctx.today));
        }
    }
    // 眼底、骨密度、心超这类不会变成化验序列,只会以 `exam_done` fact 进来。
    let exams = str_list(m, "exam_names");
    for (_, doc_date, f) in &ctx.facts {
        if f.r#type != "exam_done" || f.unverified {
            continue;
        }
        let name = terminology::normalize_term(&f.name);
        if !exams
            .iter()
            .any(|e| name.contains(&terminology::normalize_term(e)))
        {
            continue;
        }
        // fact 自己的日期优先,没写才用文档日期兜底。
        best = best.max(
            f.date
                .parse::<NaiveDate>()
                .ok()
                .or(*doc_date)
                .filter(|d| *d <= ctx.today),
        );
    }
    best
}

/// 一条提醒被忽略过、而且**从那以后还没再到期**,就不再显示(spec §5.4:
/// 「下次到期再提」)。「一轮」是这样定的:
/// - 忽略发生在**这一轮到期之前**的不算数(那是上一轮的事);
/// - 忽略把这条压住**一个完整间隔**,间隔过完还没查就再提。
///
/// 从没查过的那条没有「这一轮的到期日」,只受第二条管;阈值类连间隔都没有
/// (「该补钙了」不是周期性的),忽略就是长期的 —— 用户说了「这事我处理了」。
///
/// 日期在今天之后的忽略不算数:日志是用户自己录的,一条 2027 年的忽略会把提醒
/// 静静压住一年多(与 [`latest_done`] 同一个方向)。
fn dismissed(
    ctx: &Ctx<'_>,
    pkg: &crate::package::Package,
    id: &str,
    due: Option<NaiveDate>,
    every_days: Option<i64>,
) -> bool {
    ctx.events
        .iter()
        .filter(|e| e.package == pkg.manifest.id && e.kind == "dismiss_reminder")
        .filter(|e| e.payload.get("id").and_then(|v| v.as_str()) == Some(id))
        .filter_map(|e| e.at.parse::<NaiveDate>().ok())
        .filter(|at| *at <= ctx.today)
        .any(|at| {
            due.is_none_or(|d| at >= d)
                && every_days
                    .is_none_or(|n| add_days(at, n).is_none_or(|next_due| next_due > ctx.today))
        })
}

/// `date + n` 天,越界返回 `None`。`NaiveDate + Duration` 在越界时**直接 panic**,
/// 而这里的 `n` 是包里的裸整数(与 `Ctx::window_start` 同一条理由:签名防的是被人
/// 改,防不住作者手滑,而移动端一次 panic 就是整个 App 崩)。
fn add_days(date: NaiveDate, n: i64) -> Option<NaiveDate> {
    date.checked_add_signed(chrono::TimeDelta::try_days(n)?)
}

/// 包里某个字段下的字符串数组;没写、或写成了别的形状 → 空。
fn str_list<'j>(v: &'j serde_json::Value, k: &str) -> Vec<&'j str> {
    v.get(k)
        .and_then(|x| x.as_array())
        .map(|a| a.iter().filter_map(|x| x.as_str()).collect())
        .unwrap_or_default()
}

/// 包里 `class` 那一类药的全部用药区间(认药走 [`drug_class`],与现行方案卡同一条路)。
fn meds_of_class<'c>(
    ctx: &'c Ctx<'_>,
    pkg: &crate::package::Package,
    class: &str,
) -> Vec<&'c parser::MedSpan> {
    ctx.clinical
        .meds
        .iter()
        .filter(|m| drug_class(pkg, m).is_some_and(|d| d.class == class))
        .collect()
}

/// 这几条医嘱的起止:`since` = 最早一次被提到,`as_of` = **最近**一次被提到。
///
/// **引擎不推断停药**(`parser::MedSpan::status` 恒为 active,见 `aggregate.rs` 的
/// 模块头「discontinuation is not inferred」),所以一张 2020 年的处方今天照样会让
/// 这条提醒亮起来。日期是唯一能让用户和医生看出这件事的东西 —— 与现行方案卡上的
/// `gc.as_of` 一字不差的理由。
fn span_dates(meds: &[&parser::MedSpan]) -> serde_json::Map<String, serde_json::Value> {
    let mut extra = serde_json::Map::new();
    extra.insert(
        "since".into(),
        serde_json::json!(meds
            .iter()
            .filter_map(|x| x.start)
            .min()
            .map(|d| d.to_string())),
    );
    extra.insert(
        "as_of".into(),
        serde_json::json!(meds
            .iter()
            .filter_map(|x| x.end)
            .max()
            .map(|d| d.to_string())),
    );
    extra
}
