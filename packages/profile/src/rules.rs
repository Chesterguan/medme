//! 规则求值的共享上下文与各条规则的实现。**纯函数**:同样的 `Ctx` + 同样的包 +
//! 同样的 `today`,永远得到同样的结果。
use chrono::NaiveDate;

/// 一条被规则引用到的化验证据(用于「这次计分用了哪几张单子」的证据链)。
// Task 11(活动度计分)起被构造;在那之前只有形状、没有构造点。
#[allow(dead_code)]
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
// 装配好了但还没有读者:各字段从 Task 11 起被各条规则读。
#[allow(dead_code)]
pub struct Ctx<'a> {
    /// `parser::aggregate` 的产物:已分组、已换算的化验序列 + 用药区间 + 诊断。
    pub clinical: parser::AggregatedClinical,
    /// schema 2 的族级事实,带上它所在文档的 index 与日期(fact 自己的 `date`
    /// 为空时用文档日期兜底)。
    pub facts: Vec<(usize, Option<NaiveDate>, deid::Fact)>,
    /// 抽取结果里的**原始 labs 行**。定性值(「阴性」「阳性」)解析不出 f64,
    /// 在 `aggregate` 那层就被丢了,但 SLEDAI 的 dsDNA 项允许定性阳性计分
    /// (sle-clinical-sources §B.2),所以必须留一条能看到原文字符串的路。
    pub raw_labs: Vec<(usize, Option<NaiveDate>, deid::LabItem)>,
    /// 每份文档的原文(`text_present` 类规则用:管型这种只在尿沉渣描述里出现)。
    pub texts: Vec<(usize, Option<NaiveDate>, &'a str)>,
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
    // 第一个调用点在 Task 11(活动度计分的取值窗口)。
    #[allow(dead_code)]
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
