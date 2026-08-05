//! 病人自己保险箱上的**只读投影** —— 趋势图 / 应急卡 / 就诊摘要单三个新页面的数据源。
//!
//! # 为什么不是 `ProxySummaryDto`
//!
//! 现有的 `api::vault::proxy_summary` / `api::vault_ephemeral::ephemeral_summary` 走的是
//! `parser::assemble_summary` → 查看器 JSON schema → [`crate::api::dto::ProxySummaryDto`]
//! 这条链。那条链的形状是为**医生代拍审阅屏的「病情摘要卡」**定的,画不了图:
//!
//! - `handoff::points_json` 把点格式化成 `"%Y-%m"`,**日精度丢了**;
//! - `vault_ephemeral::proxy_lab_from_json` 只留最近 4 个点;
//! - `LabPoint::flag`(每点的 H/L)不进 JSON;
//! - `series_to_json` 虽然产出了 `evidence`,但 `ProxyLabDto` 没有承接它的字段 ——
//!   **没有任何一条化验点能跳回原件**。
//!
//! 所以本模块**不走那条链**,直接调 `parser::aggregate()`:它返回的
//! `AnalyteSeries`/`LabPoint`/`MedSpan`/`AggregatedCondition` 字段是完整的
//! (`LabPoint` 带 `date: Option<NaiveDate>` 日精度、`flag`、`source`),投影时一个字段
//! 都不用丢。抽取规则仍是同一套 `parser`,不是另写一遍 —— 与查看器/加密分享看到的
//! 是同一份事实。
//!
//! # 三个投影都是纯读
//!
//! 不追加任何事件、不改 schema、不碰 vault 格式。给定同一箱数据,输出确定
//! (`parser::aggregate` 自己已把序列/药/诊断排成确定序)。
//!
//! # 怎么拿到 Vault
//!
//! 经 `api::vault` 已有的 **pub** 函数(`load_archive` / `get_document` /
//! `patient_profile`)组合,不碰 `vault.rs` 一个字节 —— 对 `vault.rs` 的 git diff 恒为 0。
//! 理由与 `vault_ephemeral.rs` 顶部记的是同一条:上一次为了复用而把 `vault.rs` 的内部
//! 函数改成 `pub(crate)`,上线后真机 OCR 识别质量出现回归,即使 OCR 函数本身字节未变。
//! 那次的教训是「宁可多绕一层,也不动 `vault.rs` 的结构」,这里照办 —— 代价只是每份
//! 文档多一次 `get_document` 查询(投影是用户点开页面时跑一次的读操作,不在热路径上)。
//!
//! # DTO 为什么不放 `dto.rs`
//!
//! `dto.rs` 的文档把自己限定为「供 `api::vault` 里的全量 vault API 使用」;下面这些
//! 类型只有本模块的三个投影会构造,放在唯一构造它们的代码旁边更好读。FRB 扫描整个
//! `crate::api` 找 pub 符号,放这里同样能生成 Dart 绑定。复用已有 DTO 的地方(患者档案
//! 头用 [`PatientProfileDto`])就直接复用,不另造一个同形状的类型。
//!
//! # 函数命名为什么统一 `view_` 前缀
//!
//! FRB codegen 按**函数名**全局字典序分配 `funcId`(见 `frb_generated.rs` 里 wire 函数
//! 的排列:`…enable_icloud_sync` → `ephemeral_*` → `export_timeline_html` → …,跨模块
//! 混排)。现存最末一个是 `source_file_object_path`,`view_*` 排在它之后,于是新增的三
//! 个函数只会**追加**在生成代码末尾,不会把 `recognize_image_pp`(iOS/安卓 PP-OCR 路径)
//! 及其之后所有函数的 `funcId` 往后挪 —— 与 `api/mod.rs` 里模块排序那条注释同一个用意。
use crate::api::dto::PatientProfileDto;
use crate::api::dto::TimelineGroupDto;
use chrono::NaiveDate;
use std::collections::BTreeMap;
use std::collections::BTreeSet;
use std::sync::OnceLock;

/// 就诊摘要单「最近关键化验」最多列几条(一屏能看完;完整序列去趋势页)。
const VISIT_SUMMARY_MAX_LABS: usize = 8;

/// 就诊摘要单「最近就诊」最多列几条。
const VISIT_SUMMARY_MAX_VISITS: usize = 5;

// ─────────────────────────── DTO ───────────────────────────

/// 一条化验序列的**全保真**投影(趋势图)。与 `ProxyLabDto` 的区别:点不截断、
/// 日精度、每点带 `flag` 与 `document_id`,并带上 `analyte_key`/`loinc` 供 UI 做
/// 同一指标的跨来源合并/跳转。
#[derive(Debug, Clone)]
pub struct TrendSeriesDto {
    /// 显示名:能归一化到词典时是规范中文名,否则是化验单上的原始名
    /// (`parser::AnalyteSeries::group_name`)。
    pub name: String,
    /// 归一化后的内部规范键(如 `"creatinine"`);未能归一化时为 None
    /// —— 未归一化的序列**绝不与已归一化的合并**,这是 `parser::aggregate` 的分组约定。
    pub analyte_key: Option<String>,
    pub loinc: Option<String>,
    /// 序列级单位:取**最后一个点**的单位,与 `handoff::series_to_json` 同一取法
    /// (同一指标跨报告单位可能不一致,故每个点自己也带 `unit`,以点为准)。
    pub unit: Option<String>,
    pub ref_low: Option<f64>,
    pub ref_high: Option<f64>,
    /// 任一点被标记 H/L(`parser::AnalyteSeries::any_abnormal`)。
    pub any_abnormal: bool,
    /// 这条序列按 LOINC 落在哪些「关注方向」分组下(见 [`problem_groups_for`]),
    /// 顺序固定、与 [`view_trend_group_catalog`] 一致;一条序列可以属于多个分组
    /// (如 LDL 同时在糖尿病相关/血脂/冠心病相关里),**不去重合并**。空表示这条
    /// 序列没有 LOINC 或 LOINC 不在任何一条泳道里 —— UI 把它归入「其他」。
    pub problem_groups: Vec<String>,
    /// **全部**观测点,按时间升序(无日期的排最后)。不做任何数量裁剪。
    pub points: Vec<TrendPointDto>,
    /// 这条序列是不是手动录入的自测值(血压/血糖/体重/体温/心率,「记录」入口
    /// 产出,而非从化验单 OCR 出来的)——`parser::AnalyteSeries::self_measured`
    /// 透传。自测序列结构上永远不会与同名医院序列合并(`aggregate` 的分组约定,
    /// 见 MANUAL-ENTRY-DESIGN.md),这个字段只用于**显示**:UI 据此加"(家测)"
    /// 标注 / 换个点形状,不改变哪些点属于这条序列。
    pub self_measured: bool,
}

/// 序列上的一个观测点。
#[derive(Debug, Clone)]
pub struct TrendPointDto {
    /// **日精度** `"YYYY-MM-DD"`(取自文档的临床日期)。这一份报告没能定出日期时为
    /// None —— 这样的点画不到时间轴上,UI 应跳过它;但它仍带 `document_id`,原件照样
    /// 可达(`docs/007_UI_Guidelines.md` §2.1「原件永远可达」)。整条序列**全部**点都
    /// 无日期时该序列根本不会出现在结果里,见 [`is_renderable`]。
    pub date: Option<String>,
    pub value: f64,
    pub unit: Option<String>,
    /// 化验单上的异常标记,通常是 `"H"` / `"L"`;没有标记时为 None。
    pub flag: Option<String>,
    /// 这个点来自哪份文档 —— **真正的 document_id**,可直接喂
    /// `api::vault::get_document` / `read_source_bytes` 跳回原件。
    pub document_id: i64,
}

/// 应急卡:过敏史 + 在用药 + 确诊慢病,每一项都带来源。
#[derive(Debug, Clone)]
pub struct EmergencyCardDto {
    /// **恒为 None** —— 当前的抽取链路(`parser`)没有血型抽取,宁可留空也不编。
    /// 见本文件 [`view_emergency_card`] 的说明。
    pub blood_type: Option<String>,
    pub allergies: Vec<AllergyItemDto>,
    pub active_meds: Vec<ActiveMedDto>,
    pub conditions: Vec<ChronicConditionDto>,
}

/// 一条过敏史。`substance`/`reaction` 都是**报告原文逐字**片段。
#[derive(Debug, Clone)]
pub struct AllergyItemDto {
    pub substance: String,
    /// 括号里的反应描述(如 `"皮疹"`);原文只写了物质名时为空串。
    pub reaction: String,
    /// 提到这条过敏史的全部文档 id,升序去重。
    pub document_ids: Vec<i64>,
}

/// 一条在用药。
#[derive(Debug, Clone)]
pub struct ActiveMedDto {
    pub name: String,
    pub atc: Option<String>,
    /// 最近一次提到的剂量(如 `"0.5g bid"`);没识别到剂量时为 None。
    pub dose: Option<String>,
    /// 最早/最晚一次带日期的提及,`"YYYY-MM-DD"`;没有任何带日期的提及时为 None。
    pub since: Option<String>,
    pub until: Option<String>,
    /// 提到这个药的全部文档 id,升序去重。
    pub document_ids: Vec<i64>,
}

/// 一条确诊慢病。`term` 是病历原文逐字的诊断名。
#[derive(Debug, Clone)]
pub struct ChronicConditionDto {
    pub term: String,
    /// 最早一次带日期的提及,`"YYYY-MM-DD"`;都没日期时为 None。
    pub onset: Option<String>,
    /// 病历自己印在诊断旁的 ICD 编码(如有)。
    pub icd_code: Option<String>,
    /// 提到这条诊断的全部文档 id,升序去重。
    pub document_ids: Vec<i64>,
}

/// 就诊摘要单:结构化版(给 UI 渲染)+ 纯文本版(给「复制给医生」)。
#[derive(Debug, Clone)]
pub struct VisitSummaryDto {
    pub patient: PatientProfileDto,
    pub allergies: Vec<AllergyItemDto>,
    pub active_meds: Vec<ActiveMedDto>,
    /// 最近的关键化验:每条序列取**最新一个带日期的点**,按日期倒序,最多
    /// [`VISIT_SUMMARY_MAX_LABS`] 条。完整序列在趋势页。
    pub recent_labs: Vec<VisitLabDto>,
    /// 最近就诊/文档,最多 [`VISIT_SUMMARY_MAX_VISITS`] 条。
    pub recent_visits: Vec<VisitRecordDto>,
    /// 与上面结构化字段**同源同内容**的纯文本渲染,供直接复制给医生。
    /// 只含原文逐字内容 + 字段标签,不含任何解释、结论或推断。
    pub plain_text: String,
}

/// 摘要单上的一行化验:一个具体的测量点。
#[derive(Debug, Clone)]
pub struct VisitLabDto {
    pub name: String,
    /// `"YYYY-MM-DD"`。只收带日期的点,故必有值。
    pub date: String,
    pub value: f64,
    pub unit: Option<String>,
    pub flag: Option<String>,
    pub ref_low: Option<f64>,
    pub ref_high: Option<f64>,
    pub document_id: i64,
    /// 见 `TrendSeriesDto::self_measured` 的文档 —— 同一份透传,就诊单据此在
    /// 「复制给医生」纯文本里追加"(家测)"(`render_plain_text`)。
    pub self_measured: bool,
}

/// 摘要单上的一行就诊记录 —— 一个就诊组,或一份不属于任何就诊的独立文档。
#[derive(Debug, Clone)]
pub struct VisitRecordDto {
    /// 就诊组标题 / 文档标题;识别不到标题时为 None。
    pub title: Option<String>,
    /// 就诊组:`inpatient|outpatient|emergency|exam`;独立文档:该文档的
    /// `doc_type`(如 `lab_report`)。
    pub kind: String,
    /// `"YYYY-MM-DD"`;没有日期时为 None。
    pub date: Option<String>,
    /// 这条记录涵盖的文档 id(就诊组含组内全部文档)。
    pub document_ids: Vec<i64>,
}

// ─────────────────── 装配:index → document_id ───────────────────

/// 一份文档在**本次装配列表**里的载体。
///
/// `parser::SourceDoc::index` 只是「调用方记录列表里的序号」,`LabPoint::source` /
/// `MedSpan::sources` / `AggregatedCondition::sources` 回指的都是这个序号,**不是
/// document_id**。所以装配时必须自己把序号和真实 document_id 绑在一起 —— 本结构就是
/// 那条绑定:`docs[i].document_id` 即序号 `i` 对应的原件。丢了它,UI 就跳不回原件,
/// 违反 `docs/007_UI_Guidelines.md` §2.1「原件永远可达」。
struct ProjectionDoc {
    document_id: i64,
    date: Option<NaiveDate>,
    text: String,
    doc_type: Option<String>,
    title: Option<String>,
}

/// 一次 `load_archive` 取到的全部投影输入:文档(带 index→document_id 绑定)+ 就诊记录。
struct VaultProjection {
    docs: Vec<ProjectionDoc>,
    /// 就诊组 + 独立文档,按日期倒序(无日期最后)—— 与 `load_archive` 的顺序一致。
    visits: Vec<VisitRecordDto>,
}

fn parse_rfc3339_date(s: &str) -> Option<NaiveDate> {
    chrono::DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|dt| dt.date_naive())
}

fn fmt_date(d: NaiveDate) -> String {
    d.format("%Y-%m-%d").to_string()
}

/// 把 `AnalyteSeries` 等结构里的 `SourceDoc::index` 列表翻译成真实 document_id。
/// 越界的序号(不该出现)静默跳过,不 panic。
fn document_ids_for(docs: &[ProjectionDoc], indices: &[usize]) -> Vec<i64> {
    indices
        .iter()
        .filter_map(|i| docs.get(*i).map(|d| d.document_id))
        .collect()
}

/// 读一遍病人保险箱,装配出投影输入。
///
/// 顺序:按临床日期升序、同日按 document_id 升序,无日期的排最后。确定序,让
/// `SourceDoc::index` 在同一箱数据上稳定可复现。
///
/// 单份文档取不到详情(如原件元信息缺失,`get_document` 会报错)时**降级为空文本**
/// 而不是让整个投影失败 —— 一份坏文档不该让整张趋势图/应急卡打不开。它仍占一个
/// index,序号与 document_id 的对应关系因此不受影响。
fn gather() -> anyhow::Result<VaultProjection> {
    let groups = crate::api::vault::load_archive()?;

    // 展平成 (document_id, date, doc_type, title),同时记下就诊记录行。
    let mut flat: Vec<(i64, Option<NaiveDate>, String, Option<String>)> = Vec::new();
    let mut visits: Vec<VisitRecordDto> = Vec::new();
    for g in &groups {
        match g {
            TimelineGroupDto::Encounter { encounter, docs } => {
                for d in docs {
                    flat.push((
                        d.id,
                        d.doc_date.as_deref().and_then(parse_rfc3339_date),
                        d.doc_type.to_lowercase(),
                        d.title.clone(),
                    ));
                }
                visits.push(VisitRecordDto {
                    title: encounter.title.clone(),
                    kind: encounter.kind.clone(),
                    date: encounter
                        .start_date
                        .as_deref()
                        .and_then(parse_rfc3339_date)
                        .map(fmt_date),
                    document_ids: docs.iter().map(|d| d.id).collect(),
                });
            }
            TimelineGroupDto::Document { doc } => {
                let date = doc.doc_date.as_deref().and_then(parse_rfc3339_date);
                flat.push((doc.id, date, doc.doc_type.to_lowercase(), doc.title.clone()));
                visits.push(VisitRecordDto {
                    title: doc.title.clone(),
                    kind: doc.doc_type.to_lowercase(),
                    date: date.map(fmt_date),
                    document_ids: vec![doc.id],
                });
            }
        }
    }

    // 病程正序(旧→新),无日期最后;同日按 id 稳定排。
    flat.sort_by(|a, b| match (a.1, b.1) {
        (Some(x), Some(y)) => x.cmp(&y).then_with(|| a.0.cmp(&b.0)),
        (Some(_), None) => std::cmp::Ordering::Less,
        (None, Some(_)) => std::cmp::Ordering::Greater,
        (None, None) => a.0.cmp(&b.0),
    });

    let docs = flat
        .into_iter()
        .map(|(id, date, doc_type, title)| ProjectionDoc {
            document_id: id,
            date,
            text: crate::api::vault::get_document(id)
                .map(|d| d.ocr_text)
                .unwrap_or_default(),
            doc_type: Some(doc_type),
            title,
        })
        .collect();

    Ok(VaultProjection { docs, visits })
}

fn source_docs(docs: &[ProjectionDoc]) -> Vec<parser::SourceDoc<'_>> {
    docs.iter()
        .enumerate()
        .map(|(index, d)| parser::SourceDoc {
            index,
            date: d.date,
            text: &d.text,
            doc_type: d.doc_type.clone(),
            title: d.title.clone(),
        })
        .collect()
}

// ─────────────────────── 契约:可渲染的序列 ───────────────────────

/// 这条序列**画得出来吗**?
///
/// 契约出处:`packages/parser/src/handoff.rs` 的 `fn is_renderable`(private,且那个
/// 文件不在本次改动范围内,故在此按同一规则重写一遍)。原注释的理由照录:每个渲染器
/// (在线查看器、Flutter、桌面)都是从点序列里长出趋势线、最近值、日期标签和原件跳转
/// 链接的;全部点都无日期的序列**渲染出来就是一片空白**,却给用户一个「这里有化验可
/// 看」的承诺。查看器为此根本不把这种序列放进 summary,移动端趋势页必须用同一条线,
/// 否则同一份数据在 app 与查看器里表现不一致。
///
/// 被挡掉的观测**没有丢**:它仍在那份文档自己的识别文本里,经「查看原件」可达;
/// 丢掉的只是「这里有一条趋势」这个说法。
fn is_renderable(s: &parser::AnalyteSeries) -> bool {
    s.points.iter().any(|p| p.date.is_some())
}

// ─────────────────────── 关注方向分组(泳道 chip) ───────────────────────
//
// 产品问题:手机上的搜索框对「找和这个病相关的检查」没用 —— 打「嗜酸性粒细胞
// 百分比」比滚一屏还慢。这里给的是分类入口:点一个方向,看这个方向下的全部序列。
//
// **数据驱动,不是诊断驱动。** 故意不复用 `packages/parser/src/handoff.rs` 的
// `match_disease`(诊断名匹配,`assemble_summary` 的泳道逻辑)—— 那条路要求病历里
// 抽出对应诊断才会出现泳道,诊断抽取本身有已知缺口,靠它当分类入口会造成「诊断没
// 抽出来 → 一个分类都没有」,比现在的搜索框更差。这里改成只要用户记录里有该泳道
// 任一化验(不问诊断),分组就出现 —— 数据驱动永远有得用。
//
// **只认 LOINC,没有名字兜底。** LOINC 是干净的等价判据;名字匹配是猜,而且
// `problem_map.json` 里同一名字在不同医院可能有多种写法(见 `trends_screen.dart`
// 顶部关于「肌酐/血肌酐/Cr」断线的说明),用名字子串去凑等于在数据里编关系。没有
// LOINC 的序列(实测占比不低,terminology 未映射的那部分)如实降级进 UI 的「其他」
// 桶,而不是被硬凑进某条泳道。
//
// **chip 文案是中性的 —— 描述化验,不描述人。** `problem_map.json` 的 `disease`
// 字段是「糖尿病」「高血压」这种诊断名,直接拿来当 chip 会让只查过一次血糖的人误
// 以为 app 认为他有糖尿病。这里的 [`group_label`] 统一转成「关注方向」措辞:多数
// 加「相关」后缀(「糖尿病相关」「高血压相关」),两条更适合按方向翻译(CKD → 「肾
// 功能」、血脂异常 → 「血脂」,读起来更像检查类别而不是诊断)。取舍逐条写在
// [`group_label`] 里,不是统一规则。
//
// 甲减/甲亢两条泳道的化验高度重叠(TSH/FT4/FT3/TPOAb 四项共有)但**不合并**:同一
// 个 TSH 异常既可能是甲减也可能是甲亢,分组入口不该替用户下这个判断,两个 chip
// 同时出现是诚实的表达,不是重复。

/// LOINC 匹配用的一条「关注方向」:chip 文案 + 该方向下的 LOINC 集合。
struct ProblemGroupEntry {
    label: &'static str,
    loincs: BTreeSet<String>,
}

/// `problem_map.json` 每条慢病对应的 chip 文案。**必须覆盖 JSON 里出现的每一个
/// `disease`**——覆盖不到时 panic,而不是默默漏掉一条泳道:那样的失败要在开发期
/// 炸出来,不能悄悄让某条泳道从分类入口里消失(与本文件其它「宁可少一条也不编」
/// 的准则方向相反,这里选择「宁可炸也不漏」,因为漏的后果是分类入口悄悄变窄,
/// 没有任何信号能让人发现)。
///
/// 取舍(逐条):
/// - 「2型糖尿病」→「糖尿病相关」、「高血压」→「高血压相关」、「冠心病」→
///   「冠心病相关」、「贫血」→「贫血相关」:disease 名本身就是最自然的检查类别
///   描述,加「相关」把断言从「你有这个病」改成「这组检查跟这个方向有关」。
/// - 「慢性肾脏病(CKD)」→「肾功能」:泳道里的化验(eGFR/UACR/肌酐/血钾/钙磷/
///   血红蛋白)本质是「肾功能」这个器官功能维度,比「CKD相关」更像一句检查分类。
/// - 「高脂血症(血脂异常)」→「血脂」:泳道里四项(LDL/TC/HDL/TG)本身就是「血脂」
///   这份检查的全部内容,「血脂异常相关」反而绕。
/// - 「甲状腺功能减退症」→「甲减相关」、「甲状腺功能亢进症」→「甲亢相关」:两条
///   保留诊断名的常用简称(「甲减」「甲亢」和「糖尿病」一样是中文里的日常说法,
///   不是生僻术语),因为「甲状腺功能」一个方向盖不住二者化验成分的差异(甲减比
///   甲亢多一项 TgAb)。
/// - 「痛风/高尿酸血症」→「尿酸相关」:泳道核心是尿酸(诊断切点、治疗目标都围
///   绕它),肌酐/eGFR 是给药前的肾功能校核,已经在「肾功能」泳道里重复覆盖了,
///   chip 文案抓大放小。
/// - 「代谢相关(非酒精性)脂肪性肝病」→「肝功能相关」:泳道以肝酶(ALT/AST/GGT)
///   为主,「肝功能」是这组检查最自然的方向名。
fn group_label(disease: &str) -> &'static str {
    match disease {
        "2型糖尿病" => "糖尿病相关",
        "高血压" => "高血压相关",
        "高脂血症(血脂异常)" => "血脂",
        "冠心病" => "冠心病相关",
        "慢性肾脏病(CKD)" => "肾功能",
        "甲状腺功能减退症" => "甲减相关",
        "甲状腺功能亢进症" => "甲亢相关",
        "贫血" => "贫血相关",
        "痛风/高尿酸血症" => "尿酸相关",
        "代谢相关(非酒精性)脂肪性肝病" => "肝功能相关",
        other => panic!(
            "problem_map.json 新增了一条本文件还没配 chip 文案的泳道:{other} \
             —— 去 group_label() 补一条,别让分类入口悄悄漏掉它"
        ),
    }
}

/// 解析一遍 `problem_map.json`,只取分组要用的两个字段(`disease` 与
/// `labs[].loinc`);其余字段(icd10/药物/来源引用)与本文件无关。
///
/// 直接用 `serde_json::Value` 而不是派生 `Deserialize` 的结构体:本 crate 没有
/// 直接依赖 `serde`(只有 `serde_json`),为两个字段新增一条 derive 依赖不值得。
///
/// 顺序沿用 JSON 数组顺序 —— `problem_map.json` 本身就是人工按临床优先级策展的,
/// 这份顺序也是 chip 的展示顺序([`view_trend_group_catalog`])。
fn problem_group_table() -> &'static [ProblemGroupEntry] {
    static T: OnceLock<Vec<ProblemGroupEntry>> = OnceLock::new();
    T.get_or_init(|| {
        let raw: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../../packages/parser/data/problem_map.json"
        ))
        .expect("problem_map.json is valid JSON");
        raw.as_array()
            .expect("problem_map.json is a JSON array")
            .iter()
            .map(|entry| {
                let disease = entry["disease"]
                    .as_str()
                    .expect("problem_map.json entry has a `disease` string");
                let loincs = entry["labs"]
                    .as_array()
                    .expect("problem_map.json entry has a `labs` array")
                    .iter()
                    .filter_map(|lab| lab["loinc"].as_str().map(str::to_string))
                    .collect();
                ProblemGroupEntry {
                    label: group_label(disease),
                    loincs,
                }
            })
            .collect()
    })
}

/// 一条序列(按 LOINC)属于哪些「关注方向」分组,按 [`problem_group_table`] 的
/// 顺序,一条序列可以属于多个分组(如 LDL 同时在糖尿病相关/血脂/冠心病相关里)。
///
/// `loinc: None`(序列没能归一化出 LOINC)一律返回空表 —— 这是诚实的降级,不用
/// 名字子串去硬凑;UI 把空表的序列归入「其他」。
fn problem_groups_for(loinc: Option<&str>) -> Vec<String> {
    let Some(loinc) = loinc else {
        return Vec::new();
    };
    problem_group_table()
        .iter()
        .filter(|g| g.loincs.contains(loinc))
        .map(|g| g.label.to_string())
        .collect()
}

/// 分组 chip 的完整目录,固定顺序,与每条 [`TrendSeriesDto::problem_groups`] 用的
/// 是同一份表。**只回答「有哪些分组、先后顺序是什么」**——UI 不应该自己另定一份
/// 顺序(比如按"数据里第一次出现的顺序"排),否则两端顺序会漂移,同一个人重新打开
/// 页面 chip 顺序都可能不一样。
///
/// 不含「全部」「其他」—— 那两个是 UI 侧的兜底 sentinel,不是从 LOINC 匹配算出来
/// 的分组,不该跟着这份表的「怎么算」走。
pub fn view_trend_group_catalog() -> Vec<String> {
    problem_group_table()
        .iter()
        .map(|g| g.label.to_string())
        .collect()
}

// ─────────────────────────── 过敏史 ───────────────────────────
//
// `handoff::extract_allergies_pairs` / `parse_allergy_item` 都是 private,且
// `packages/parser` 不在本次改动范围内,故按**同一规则**在此重写一遍(逐条对照
// `packages/parser/src/handoff.rs` 的那两个函数)。重写的另一个必要理由:那两个函数
// 只产出 `(substance, reaction)`,不带来源;应急卡要求每条过敏史能跳回原件,必须在
// 逐份扫描时自己记住是哪一份文档说的。

/// 在 `text` 里找过敏史标签(`过敏史` / `过敏`),取标签之后的剩余部分,按
/// `；;，,、` 拆成若干条 `物质(反应)`。否定式(`无…` / `否认…`)与空条目跳过。
/// 同 `handoff::extract_allergies_pairs`。
fn extract_allergies_pairs(text: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for line in text.lines() {
        // 先试更长的标签,免得 `过敏史:` 被 `过敏` 切开。
        let rest = ["过敏史", "过敏"].iter().find_map(|lbl| {
            line.find(lbl).map(|p| {
                line[p + lbl.len()..]
                    .trim_start_matches(|c: char| c.is_whitespace() || matches!(c, ':' | '：'))
            })
        });
        let Some(rest) = rest else { continue };
        for item in rest.split(['；', ';', '，', ',', '、']) {
            if let Some(pair) = parse_allergy_item(item) {
                out.push(pair);
            }
        }
    }
    out
}

/// 解析一条 `青霉素(皮疹)` → `("青霉素", "皮疹")`,或裸的 `磺胺` → `("磺胺", "")`。
/// 空条目/否定式返回 None。同 `handoff::parse_allergy_item`。
fn parse_allergy_item(item: &str) -> Option<(String, String)> {
    let item = item
        .trim()
        .trim_matches(|c: char| c.is_whitespace() || matches!(c, '。' | '.' | ';' | '；'));
    if item.is_empty() || item.starts_with('无') || item.starts_with("否认") {
        return None;
    }
    if let Some(op) = item.find(['(', '（']) {
        let substance = item[..op].trim().to_string();
        if substance.is_empty() {
            return None;
        }
        let reaction = item[op..]
            .trim_matches(|c: char| matches!(c, '(' | '（' | ')' | '）'))
            .trim()
            .to_string();
        return Some((substance, reaction));
    }
    Some((item.to_string(), String::new()))
}

/// 逐份扫过敏史,按 `(substance, reaction)` 去重、合并来源 document_id。
/// 去重键与 `handoff::assemble_summary` 的 allergies 段一致;多出来的是来源合并。
fn collect_allergies(docs: &[ProjectionDoc]) -> Vec<AllergyItemDto> {
    // BTreeMap 保证输出顺序确定(按物质名、再按反应)。
    let mut acc: BTreeMap<(String, String), Vec<i64>> = BTreeMap::new();
    for d in docs {
        for (substance, reaction) in extract_allergies_pairs(&d.text) {
            let ids = acc.entry((substance, reaction)).or_default();
            if !ids.contains(&d.document_id) {
                ids.push(d.document_id);
            }
        }
    }
    acc.into_iter()
        .map(|((substance, reaction), mut document_ids)| {
            document_ids.sort_unstable();
            AllergyItemDto {
                substance,
                reaction,
                document_ids,
            }
        })
        .collect()
}

/// `MedSpan` → 在用药 DTO。只收 `status == "active"` 的。
///
/// 注:`parser::aggregate` 目前给每条 `MedSpan` 都写 `status = "active"`
/// (见 `aggregate.rs` 的 `MedSpan::status` 文档:停药不做推断)。这里照样按
/// `status` 过滤而不是无条件全收 —— 等 parser 哪天能识别停药,本函数不用改。
fn collect_active_meds(docs: &[ProjectionDoc], meds: &[parser::MedSpan]) -> Vec<ActiveMedDto> {
    meds.iter()
        .filter(|m| m.status == "active")
        .map(|m| ActiveMedDto {
            name: m.name.clone(),
            atc: m.atc.clone(),
            dose: m.latest_dose.clone(),
            since: m.start.map(fmt_date),
            until: m.end.map(fmt_date),
            document_ids: document_ids_for(docs, &m.sources),
        })
        .collect()
}

fn collect_conditions(
    docs: &[ProjectionDoc],
    conds: &[parser::AggregatedCondition],
) -> Vec<ChronicConditionDto> {
    conds
        .iter()
        .map(|c| ChronicConditionDto {
            term: c.raw_text.clone(),
            onset: c.onset.map(fmt_date),
            icd_code: c.icd_code.clone(),
            document_ids: document_ids_for(docs, &c.sources),
        })
        .collect()
}

/// `AnalyteSeries` → 趋势序列 DTO(全保真:点不截断、日精度、带 flag 与 document_id)。
fn trend_series(docs: &[ProjectionDoc], s: &parser::AnalyteSeries) -> TrendSeriesDto {
    TrendSeriesDto {
        name: s.group_name.clone(),
        analyte_key: s.analyte_key.clone(),
        loinc: s.loinc.clone(),
        problem_groups: problem_groups_for(s.loinc.as_deref()),
        unit: s.points.last().and_then(|p| p.unit.clone()),
        ref_low: s.ref_low,
        ref_high: s.ref_high,
        any_abnormal: s.any_abnormal,
        points: s
            .points
            .iter()
            .filter_map(|p| {
                // 序号翻不回 document_id 的点只可能来自 bug;宁可少一个点也不给 UI 一个
                // 跳不回原件的点(§2.1)。
                let document_id = docs.get(p.source)?.document_id;
                Some(TrendPointDto {
                    date: p.date.map(fmt_date),
                    value: p.value,
                    unit: p.unit.clone(),
                    flag: p.flag.clone(),
                    document_id,
                })
            })
            .collect(),
        self_measured: s.self_measured,
    }
}

// ─────────────────────────── 三个投影 ───────────────────────────

/// **趋势图**:病人保险箱里每一条可渲染的化验序列,全保真。
///
/// 与「病情摘要卡」(`proxy_summary`)的区别见本文件头:这里不截断点数、保留日精度
/// 日期与每点的 H/L 标记、每点都带真实 document_id。
///
/// 序列顺序沿用 `parser::aggregate` 的确定序(按显示名、再按 `analyte_key`)。
/// 全部点都无日期的序列不出现在结果里 —— 见 [`is_renderable`]。
pub fn view_trends() -> anyhow::Result<Vec<TrendSeriesDto>> {
    let projection = gather()?;
    let src = source_docs(&projection.docs);
    let clinical = parser::aggregate(&src);
    Ok(clinical
        .labs
        .iter()
        .filter(|s| is_renderable(s))
        .map(|s| trend_series(&projection.docs, s))
        .collect())
}

/// **应急卡**:过敏史 + 在用药 + 确诊慢病,每项都带来源 document_id。
///
/// 血型恒为 None:当前抽取链路(`parser`)里没有血型抽取,输出 None 是如实说
/// 「我们不知道」。急救场景下编一个血型是会出人命的,宁可空着让人去问。
pub fn view_emergency_card() -> anyhow::Result<EmergencyCardDto> {
    let projection = gather()?;
    let src = source_docs(&projection.docs);
    let clinical = parser::aggregate(&src);
    Ok(EmergencyCardDto {
        blood_type: None,
        allergies: collect_allergies(&projection.docs),
        active_meds: collect_active_meds(&projection.docs, &clinical.meds),
        conditions: collect_conditions(&projection.docs, &clinical.conditions),
    })
}

/// **就诊摘要单**:一屏能看完的结构化版(给 UI 渲染)+ 纯文本版(给「复制给医生」)。
///
/// 内容:基本信息 + 过敏史 + 在用药 + 最近关键化验(带日期与 flag)+ 最近就诊记录标题。
/// 全部是原文逐字内容或从原文抽出的数值/日期,**不生成任何解释性文字或结论**。
pub fn view_visit_summary() -> anyhow::Result<VisitSummaryDto> {
    let projection = gather()?;
    let src = source_docs(&projection.docs);
    let clinical = parser::aggregate(&src);
    let patient = crate::api::vault::patient_profile()?;

    let allergies = collect_allergies(&projection.docs);
    let active_meds = collect_active_meds(&projection.docs, &clinical.meds);

    // 每条可渲染序列取最新一个**带日期**的点,按日期倒序,同日按名字稳定排。
    let mut recent_labs: Vec<VisitLabDto> = clinical
        .labs
        .iter()
        .filter(|s| is_renderable(s))
        .filter_map(|s| {
            // `aggregate` 已把点按日期升序排好、无日期的排最后,故最后一个带日期的点
            // 就是最新的那个。
            let p = s.points.iter().rev().find(|p| p.date.is_some())?;
            Some(VisitLabDto {
                name: s.group_name.clone(),
                date: fmt_date(p.date?),
                value: p.value,
                unit: p.unit.clone().or_else(|| s.points.last()?.unit.clone()),
                flag: p.flag.clone(),
                ref_low: s.ref_low,
                ref_high: s.ref_high,
                document_id: projection.docs.get(p.source)?.document_id,
                self_measured: s.self_measured,
            })
        })
        .collect();
    recent_labs.sort_by(|a, b| b.date.cmp(&a.date).then_with(|| a.name.cmp(&b.name)));
    recent_labs.truncate(VISIT_SUMMARY_MAX_LABS);

    let mut recent_visits = projection.visits;
    recent_visits.truncate(VISIT_SUMMARY_MAX_VISITS);

    let plain_text = render_plain_text(
        &patient,
        &allergies,
        &active_meds,
        &recent_labs,
        &recent_visits,
    );

    Ok(VisitSummaryDto {
        patient,
        allergies,
        active_meds,
        recent_labs,
        recent_visits,
        plain_text,
    })
}

/// 数值渲染:与 `handoff::fmt_num` 同一取法(`{}` 的默认 f64 格式,`7.9` 不会变成
/// `7.90`,`112` 不会变成 `112.0`)。
fn fmt_num(v: f64) -> String {
    format!("{v}")
}

/// 结构化摘要 → 纯文本(「复制给医生」)。
///
/// 每一行的内容都来自原文逐字片段或从原文抽出的数值/日期;方括号标题与字段名是版式,
/// 不是对病情的陈述。**某一段抽不到东西时明说「未从记录中识别到」,绝不打印「无」**
/// —— 「无过敏史」是一句医学断言,我们没有依据说它;「没识别到」才是事实。
fn render_plain_text(
    patient: &PatientProfileDto,
    allergies: &[AllergyItemDto],
    active_meds: &[ActiveMedDto],
    recent_labs: &[VisitLabDto],
    recent_visits: &[VisitRecordDto],
) -> String {
    const NOT_FOUND: &str = "(未从记录中识别到)";
    let mut out = String::new();

    out.push_str("【基本信息】\n");
    let mut basics: Vec<String> = Vec::new();
    if let Some(n) = &patient.name {
        basics.push(format!("姓名:{n}"));
    }
    if let Some(g) = &patient.gender {
        basics.push(format!("性别:{g}"));
    }
    if let Some(a) = &patient.age {
        basics.push(format!("年龄:{a}"));
    }
    if let Some(b) = &patient.birth_date {
        basics.push(format!("出生日期:{b}"));
    }
    if basics.is_empty() {
        out.push_str(NOT_FOUND);
        out.push('\n');
    } else {
        out.push_str(&basics.join("  "));
        out.push('\n');
    }
    out.push_str(&format!("记录份数:{}\n", patient.record_count));

    out.push_str("\n【过敏史】\n");
    if allergies.is_empty() {
        out.push_str(NOT_FOUND);
        out.push('\n');
    } else {
        for a in allergies {
            if a.reaction.is_empty() {
                out.push_str(&format!("{}\n", a.substance));
            } else {
                out.push_str(&format!("{}({})\n", a.substance, a.reaction));
            }
        }
    }

    out.push_str("\n【在用药】\n");
    if active_meds.is_empty() {
        out.push_str(NOT_FOUND);
        out.push('\n');
    } else {
        for m in active_meds {
            out.push_str(&m.name);
            if let Some(d) = &m.dose {
                out.push(' ');
                out.push_str(d);
            }
            if let Some(s) = &m.since {
                out.push_str(&format!("(自 {s}"));
                match &m.until {
                    Some(u) if u != s => out.push_str(&format!(" → {u})")),
                    _ => out.push(')'),
                }
            }
            out.push('\n');
        }
    }

    out.push_str("\n【最近化验】\n");
    if recent_labs.is_empty() {
        out.push_str(NOT_FOUND);
        out.push('\n');
    } else {
        for l in recent_labs {
            out.push_str(&format!("{} {} {}", l.date, l.name, fmt_num(l.value)));
            if let Some(u) = &l.unit {
                out.push(' ');
                out.push_str(u);
            }
            // 自测值(家测血压/血糖/体重/体温/心率)与医院值在这份纯文本里长得
            // 一样,靠这个标注让医生一眼分清"这是病人自己量的"——不是诊室测的。
            if l.self_measured {
                out.push_str(" (家测)");
            }
            if let Some(f) = &l.flag {
                out.push(' ');
                out.push_str(f);
            }
            match (l.ref_low, l.ref_high) {
                (Some(lo), Some(hi)) => {
                    out.push_str(&format!(" [参考 {}-{}]", fmt_num(lo), fmt_num(hi)))
                }
                (None, Some(hi)) => out.push_str(&format!(" [参考 ≤{}]", fmt_num(hi))),
                (Some(lo), None) => out.push_str(&format!(" [参考 ≥{}]", fmt_num(lo))),
                (None, None) => {}
            }
            out.push('\n');
        }
    }

    out.push_str("\n【最近就诊】\n");
    if recent_visits.is_empty() {
        out.push_str(NOT_FOUND);
        out.push('\n');
    } else {
        for v in recent_visits {
            let title = v.title.as_deref().unwrap_or(&v.kind);
            match &v.date {
                // 就诊组的标题由 core-model 生成、本身就带日期(如 `门诊 · 2024-06-01`),
                // 再前缀一次会印成 `2024-06-01 门诊 · 2024-06-01`。标题里已经有这个日期
                // 就不重复。
                Some(d) if !title.contains(d.as_str()) => out.push_str(&format!("{d} {title}\n")),
                _ => out.push_str(&format!("{title}\n")),
            }
        }
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::dto::SelfMeasuredValueDto;
    use std::sync::Mutex;

    // 端到端测试跑同一个进程级 `api::vault::VAULT` cell(和生产代码一样,一次只有一个
    // 打开的保险箱),不能并发跑;用一把粗互斥锁串行化 —— 与 `vault_ephemeral` 的
    // 测试同一手法。
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    /// 造一批 `ProjectionDoc`(纯函数测试用,不开保险箱)。document_id 故意**不等于**
    /// index —— 从 100 起跳,这样任何把 index 当 document_id 用的 bug 都会立刻暴露。
    fn docs_from(texts: &[(&str, Option<&str>, &str)]) -> Vec<ProjectionDoc> {
        texts
            .iter()
            .enumerate()
            .map(|(i, (text, date, doc_type))| ProjectionDoc {
                document_id: 100 + i as i64,
                date: date.map(|d| NaiveDate::parse_from_str(d, "%Y-%m-%d").unwrap()),
                text: (*text).to_string(),
                doc_type: Some((*doc_type).to_string()),
                title: None,
            })
            .collect()
    }

    /// LDL(22748-8)在 `problem_map.json` 里同时挂在糖尿病(index 0)、高脂血症
    /// (index 2)、冠心病(index 3)三条泳道下 —— 分组**不去重**,一条序列可以进
    /// 多个 chip,顺序沿用 `problem_group_table` 的表顺序(即 JSON 数组顺序)。
    #[test]
    fn problem_groups_for_multi_membership_loinc_is_not_deduped() {
        assert_eq!(
            problem_groups_for(Some("22748-8")),
            vec!["糖尿病相关", "血脂", "冠心病相关"]
        );
    }

    /// 肌酐(14682-9)挂在高血压(index 1)、CKD(index 4)、痛风/高尿酸血症
    /// (index 8)三条泳道 —— 覆盖另一组多归属组合,且顺序仍是表顺序而不是
    /// 数值大小或字母序。
    #[test]
    fn problem_groups_for_creatinine_spans_hypertension_ckd_and_gout() {
        assert_eq!(
            problem_groups_for(Some("14682-9")),
            vec!["高血压相关", "肾功能", "尿酸相关"]
        );
    }

    /// 没有 LOINC、或 LOINC 不在任何一条泳道里,都返回空表 —— 这是 UI「其他」
    /// 桶的判据(空表示不属于任何分组),不是 panic 或猜测。
    #[test]
    fn problem_groups_for_missing_or_unmapped_loinc_is_empty() {
        assert_eq!(problem_groups_for(None), Vec::<String>::new());
        // 这个编号不是任何真实 LOINC(纯构造,确认「查不到」时如实返回空,而不是
        // 名字兜底猜一个分组进去)。
        assert_eq!(problem_groups_for(Some("00000-0")), Vec::<String>::new());
    }

    /// 目录:10 条泳道,每条文案唯一(chip 靠文案本身当 key,不能撞名),顺序与
    /// `problem_map.json` 的数组顺序一致。
    #[test]
    fn view_trend_group_catalog_has_ten_distinct_labels_in_source_order() {
        let catalog = view_trend_group_catalog();
        assert_eq!(catalog.len(), 10, "实际={catalog:?}");
        let uniq: BTreeSet<&String> = catalog.iter().collect();
        assert_eq!(uniq.len(), catalog.len(), "chip 文案不能撞名:{catalog:?}");
        assert_eq!(
            catalog,
            vec![
                "糖尿病相关",
                "高血压相关",
                "血脂",
                "冠心病相关",
                "肾功能",
                "甲减相关",
                "甲亢相关",
                "贫血相关",
                "尿酸相关",
                "肝功能相关",
            ]
        );
    }

    /// `trend_series` 把 `problem_groups_for` 的结果原样接到 DTO 上 —— 端到端
    /// 钉一次装配路径本身没有再插一层去重/改序。
    #[test]
    fn trend_series_dto_carries_problem_groups_from_loinc() {
        let docs = docs_from(&[(
            "生化检验报告单\n低密度脂蛋白胆固醇 3.6 mmol/L 0-3.4\n",
            Some("2024-06-01"),
            "lab_report",
        )]);
        let src = source_docs(&docs);
        let clinical = parser::aggregate(&src);
        let ldl = clinical
            .labs
            .iter()
            .find(|s| s.loinc.as_deref() == Some("22748-8"))
            .expect("LDL series should resolve to its LOINC via the terminology dictionary");
        let dto = trend_series(&docs, ldl);
        assert_eq!(dto.problem_groups, vec!["糖尿病相关", "血脂", "冠心病相关"]);
    }

    #[test]
    fn trends_keep_every_point_with_day_precision_flag_and_document_id() {
        // 同一指标散在三份化验单里,日精度日期各不相同、其中两个点带 H 标记。
        let docs = docs_from(&[
            (
                "生化检验报告单\n糖化血红蛋白 6.2 % 4-6.5\n",
                Some("2023-01-15"),
                "lab_report",
            ),
            (
                "生化检验报告单\n糖化血红蛋白 7.1 % H 4-6.5\n",
                Some("2023-07-20"),
                "lab_report",
            ),
            (
                "生化检验报告单\n糖化血红蛋白 7.9 % H 4-6.5\n",
                Some("2024-06-01"),
                "lab_report",
            ),
        ]);
        let src = source_docs(&docs);
        let clinical = parser::aggregate(&src);
        let series: Vec<TrendSeriesDto> = clinical
            .labs
            .iter()
            .filter(|s| is_renderable(s))
            .map(|s| trend_series(&docs, s))
            .collect();

        let hba1c = series
            .iter()
            .find(|s| s.name == "糖化血红蛋白")
            .expect("糖化血红蛋白 series");

        // 三个点全在(`ProxyLabDto` 会截到 4 个,这里根本不截)。
        assert_eq!(hba1c.points.len(), 3);
        // 日精度 —— `assemble_summary` 那条链会把这里变成 "2023-01"。
        assert_eq!(hba1c.points[0].date.as_deref(), Some("2023-01-15"));
        assert_eq!(hba1c.points[2].date.as_deref(), Some("2024-06-01"));
        // 每点的 flag —— `ProxyLabPointDto` 里根本没有这个字段。参考区间内的点
        // `extract_labs` 会标 "N",超上限标 "H"。
        assert_eq!(hba1c.points[0].flag.as_deref(), Some("N"));
        assert_eq!(hba1c.points[1].flag.as_deref(), Some("H"));
        assert_eq!(hba1c.points[2].flag.as_deref(), Some("H"));
        assert!(hba1c.any_abnormal);
        // 每点回指**真实 document_id**(101/102 而不是 index 1/2)。
        assert_eq!(hba1c.points[0].document_id, 100);
        assert_eq!(hba1c.points[1].document_id, 101);
        assert_eq!(hba1c.points[2].document_id, 102);
        // 序列级元信息。
        assert_eq!(hba1c.ref_high, Some(6.5));
        assert_eq!(hba1c.unit.as_deref(), Some("%"));
        assert!(
            hba1c.analyte_key.is_some(),
            "糖化血红蛋白 应能归一化到词典键"
        );
    }

    #[test]
    fn undated_only_series_is_dropped_per_is_renderable_contract() {
        // 一份没有临床日期的化验单:序列存在,但一个点都没有日期 → 画不出来。
        let docs = docs_from(&[(
            "生化检验报告单\n肌酐 112 umol/L 57-97\n",
            None,
            "lab_report",
        )]);
        let src = source_docs(&docs);
        let clinical = parser::aggregate(&src);
        assert!(
            !clinical.labs.is_empty(),
            "aggregate 本身应抽到序列(契约挡的是渲染,不是抽取)"
        );
        assert!(
            clinical.labs.iter().all(|s| !is_renderable(s)),
            "全部点无日期的序列应判为不可渲染"
        );

        // 同一指标只要有**一个**带日期的点,整条序列就该放行(含那个无日期的点,
        // 它照样带 document_id 供跳回原件)。
        let docs = docs_from(&[
            (
                "生化检验报告单\n肌酐 112 umol/L 57-97\n",
                None,
                "lab_report",
            ),
            (
                "生化检验报告单\n肌酐 105 umol/L 57-97\n",
                Some("2024-06-01"),
                "lab_report",
            ),
        ]);
        let src = source_docs(&docs);
        let clinical = parser::aggregate(&src);
        let renderable: Vec<TrendSeriesDto> = clinical
            .labs
            .iter()
            .filter(|s| is_renderable(s))
            .map(|s| trend_series(&docs, s))
            .collect();
        let cr = renderable
            .iter()
            .find(|s| s.name.contains("肌酐"))
            .expect("肌酐 series renderable");
        assert_eq!(cr.points.len(), 2, "无日期的点不丢,只是 date 为 None");
        assert!(
            cr.points.iter().any(|p| p.date.is_none()),
            "无日期的点应保留并以 date=None 如实标注"
        );
        assert!(cr.points.iter().all(|p| p.document_id >= 100));
    }

    #[test]
    fn allergies_carry_every_source_document_id() {
        let docs = docs_from(&[
            (
                "门诊病历\n过敏史:青霉素(皮疹)、磺胺\n",
                Some("2023-03-02"),
                "clinical_note",
            ),
            (
                "入院记录\n过敏史:青霉素(皮疹)\n",
                Some("2024-01-05"),
                "clinical_note",
            ),
            (
                "门诊病历\n否认药物过敏史\n",
                Some("2024-02-01"),
                "clinical_note",
            ),
        ]);
        let allergies = collect_allergies(&docs);

        let pen = allergies
            .iter()
            .find(|a| a.substance == "青霉素")
            .expect("青霉素");
        assert_eq!(pen.reaction, "皮疹");
        // 两份文档都提到 → 两个来源 id 都在(这是 assemble_summary 的 allergies 段
        // 给不出来的东西)。
        assert_eq!(pen.document_ids, vec![100, 101]);

        let sulfa = allergies
            .iter()
            .find(|a| a.substance == "磺胺")
            .expect("磺胺");
        assert_eq!(sulfa.reaction, "");
        assert_eq!(sulfa.document_ids, vec![100]);

        // 否定式不该产出条目(`否认药物过敏史` 里没有第三条)。
        assert_eq!(allergies.len(), 2, "实际={allergies:?}");
    }

    #[test]
    fn active_meds_and_conditions_carry_source_document_ids() {
        let docs = docs_from(&[
            (
                "出院小结\n出院诊断:2型糖尿病\n出院医嘱:\n二甲双胍 0.5g bid\n",
                Some("2023-05-10"),
                "discharge_summary",
            ),
            (
                "处方笺\n二甲双胍 1.0g bid\n",
                Some("2024-06-01"),
                "prescription",
            ),
        ]);
        let src = source_docs(&docs);
        let clinical = parser::aggregate(&src);

        let meds = collect_active_meds(&docs, &clinical.meds);
        let met = meds
            .iter()
            .find(|m| m.name.contains("二甲双胍"))
            .expect("二甲双胍");
        assert_eq!(
            met.document_ids,
            vec![100, 101],
            "两份都提到,两个来源都要在"
        );
        // `extract_meds` 会把剂量归一化(`1.0g` → `1g`);取的是**最近一次**那份处方的。
        assert_eq!(met.dose.as_deref(), Some("1g bid"), "取最近一次的剂量");
        assert_eq!(met.since.as_deref(), Some("2023-05-10"));
        assert_eq!(met.until.as_deref(), Some("2024-06-01"));

        let conds = collect_conditions(&docs, &clinical.conditions);
        let dm = conds
            .iter()
            .find(|c| c.term.contains("2型糖尿病"))
            .expect("2型糖尿病");
        assert_eq!(dm.document_ids, vec![100]);
        assert_eq!(dm.onset.as_deref(), Some("2023-05-10"));
    }

    #[test]
    fn plain_text_is_verbatim_and_says_not_found_instead_of_none() {
        let patient = PatientProfileDto {
            name: Some("张建国".into()),
            gender: Some("男".into()),
            birth_date: None,
            age: Some("58".into()),
            record_count: 3,
        };
        let allergies = vec![AllergyItemDto {
            substance: "青霉素".into(),
            reaction: "皮疹".into(),
            document_ids: vec![100],
        }];
        let labs = vec![VisitLabDto {
            name: "糖化血红蛋白".into(),
            date: "2024-06-01".into(),
            value: 7.9,
            unit: Some("%".into()),
            flag: Some("H".into()),
            ref_low: Some(4.0),
            ref_high: Some(6.5),
            document_id: 102,
            self_measured: false,
        }];
        let text = render_plain_text(&patient, &allergies, &[], &labs, &[]);

        assert!(text.contains("姓名:张建国"));
        assert!(text.contains("青霉素(皮疹)"));
        // 数值不被改写成 7.90,单位与 flag 逐字带出。
        assert!(
            text.contains("2024-06-01 糖化血红蛋白 7.9 % H [参考 4-6.5]"),
            "实际:\n{text}"
        );
        // 在用药/最近就诊抽不到 → 明说「没识别到」,绝不打印「无」这种医学断言。
        assert!(text.contains("(未从记录中识别到)"));
        assert!(!text.contains("无过敏"), "不得凭空断言「无」");
        // 不含任何解释性文字/结论词。
        for banned in ["建议", "考虑", "提示", "可能", "控制不佳", "正常"] {
            assert!(!text.contains(banned), "纯文本不得出现解释性词语:{banned}");
        }
    }

    #[test]
    fn index_to_document_id_mapping_survives_reordering() {
        // gather() 会把文档按日期重排,index 因此**不等于**任何外部 id。
        // 这里直接验证映射函数本身:序号翻出的是 ProjectionDoc 自己的 document_id。
        let docs = docs_from(&[
            ("a", Some("2024-01-01"), "lab_report"),
            ("b", Some("2023-01-01"), "lab_report"),
        ]);
        assert_eq!(document_ids_for(&docs, &[0, 1]), vec![100, 101]);
        // 越界序号静默跳过,不 panic。
        assert_eq!(document_ids_for(&docs, &[1, 9]), vec![101]);
    }

    #[test]
    fn end_to_end_over_a_real_vault() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let home = tempfile::tempdir().unwrap();
        let docs_dir = home.path().join("docs");
        let data_dir = home.path().join("data");
        crate::api::vault::open_vault(
            docs_dir.to_string_lossy().to_string(),
            data_dir.to_string_lossy().to_string(),
            None,
        )
        .unwrap();

        let older = "生化检验报告单\n检验日期 2023-05-10\n糖化血红蛋白 7.1 % H 4-6.5\n";
        // 段头故意用 `化验:` 而不是 `生化:` —— 出院小结这类文档只从**被识别的**化验段里
        // 挖化验(`aggregate::header_kind` 的 LABS 表:检验项目/检验结果/化验/生化检验/
        // 检验报告),`生化` 单独一个词不在表里,写成那样这行根本不会被抽出来。
        let newer = "出院小结\n出院日期 2024-06-01\n过敏史:青霉素(皮疹)\n\
出院诊断:2型糖尿病\n化验:\n糖化血红蛋白 7.9 % H 4-6.5\n出院医嘱:\n二甲双胍 0.5g bid\n";
        let a = crate::api::vault::ingest_bytes("化验单.txt".into(), older.as_bytes().to_vec())
            .unwrap();
        let b = crate::api::vault::ingest_bytes("出院小结.txt".into(), newer.as_bytes().to_vec())
            .unwrap();
        let older_id = a.document_id.expect("document created");
        let newer_id = b.document_id.expect("document created");

        // ── 趋势:两个点、日精度、各自回指自己那份原件 ──
        let trends = view_trends().unwrap();
        let hba1c = trends
            .iter()
            .find(|s| s.name == "糖化血红蛋白")
            .unwrap_or_else(|| {
                panic!(
                    "糖化血红蛋白 序列缺失,实际={:?}",
                    trends.iter().map(|s| &s.name).collect::<Vec<_>>()
                )
            });
        assert_eq!(hba1c.points.len(), 2);
        assert_eq!(hba1c.points[0].date.as_deref(), Some("2023-05-10"));
        assert_eq!(hba1c.points[0].document_id, older_id);
        assert_eq!(hba1c.points[1].date.as_deref(), Some("2024-06-01"));
        assert_eq!(hba1c.points[1].document_id, newer_id);

        // ── 应急卡 ──
        let card = view_emergency_card().unwrap();
        assert_eq!(card.blood_type, None, "抽不出血型就该是 None,不许编");
        let pen = card
            .allergies
            .iter()
            .find(|x| x.substance == "青霉素")
            .expect("青霉素");
        assert_eq!(pen.document_ids, vec![newer_id]);
        assert!(card
            .active_meds
            .iter()
            .any(|m| m.name.contains("二甲双胍") && m.document_ids.contains(&newer_id)));
        assert!(card
            .conditions
            .iter()
            .any(|c| c.term.contains("2型糖尿病") && c.document_ids.contains(&newer_id)));

        // ── 就诊摘要单 ──
        let visit = view_visit_summary().unwrap();
        assert_eq!(visit.patient.record_count, 2);
        let lab = visit
            .recent_labs
            .iter()
            .find(|l| l.name == "糖化血红蛋白")
            .expect("最近化验里应有 糖化血红蛋白");
        assert_eq!(lab.date, "2024-06-01", "取最新一个带日期的点");
        assert_eq!(lab.value, 7.9);
        assert_eq!(lab.flag.as_deref(), Some("H"));
        assert_eq!(lab.document_id, newer_id);
        assert!(!visit.recent_visits.is_empty());
        assert!(visit.plain_text.contains("青霉素(皮疹)"));
        assert!(visit.plain_text.contains("2024-06-01 糖化血红蛋白 7.9"));

        // 纯文本里出现的医学内容必须是某份原文的逐字子串(挡幻觉)。逐字校验对象是
        // **原文抄下来的**那些:过敏物质/反应、诊断名、药名。化验显示名走的是词典
        // 规范名(`AnalyteSeries::group_name`),可能与化验单上的写法不同字,不在
        // 此校验之列 —— 这一点在交付说明里如实列出。
        let corpus = format!("{older}{newer}");
        for a in &visit.allergies {
            assert!(
                corpus.contains(&a.substance),
                "过敏物质非逐字:{}",
                a.substance
            );
            assert!(
                corpus.contains(&a.reaction),
                "过敏反应非逐字:{}",
                a.reaction
            );
        }
        for m in &visit.active_meds {
            assert!(corpus.contains(&m.name), "药名非逐字:{}", m.name);
        }
        for c in &card.conditions {
            assert!(corpus.contains(&c.term), "诊断名非逐字:{}", c.term);
        }

        // ── 删掉新的那份,投影应立即反映(纯读、无缓存)──
        crate::api::vault::delete_document(newer_id).unwrap();
        let card_after = view_emergency_card().unwrap();
        assert!(
            card_after.allergies.is_empty(),
            "过敏史来源被删后应消失,实际={:?}",
            card_after.allergies
        );
        let trends_after = view_trends().unwrap();
        let hba1c_after = trends_after
            .iter()
            .find(|s| s.name == "糖化血红蛋白")
            .expect("剩下那份仍有序列");
        assert_eq!(hba1c_after.points.len(), 1);
        assert_eq!(hba1c_after.points[0].document_id, older_id);
    }

    // ──────────────── MANUAL-ENTRY-DESIGN.md: 手动录入端到端 ────────────────

    /// 自测血压(§3.4/§5.3)与同一天的医院血压绝不合并成一条线,即使
    /// `analyte_key` 相同;`view_trends()` 里能分辨出哪条是自测(`selfMeasured`),
    /// `render_plain_text` 据此在纯文本里标"(家测)"。
    #[test]
    fn self_measured_bp_never_merges_with_hospital_bp_end_to_end() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let home = tempfile::tempdir().unwrap();
        crate::api::vault::open_vault(
            home.path().join("docs").to_string_lossy().to_string(),
            home.path().join("data").to_string_lossy().to_string(),
            None,
        )
        .unwrap();

        // 同一天:医院化验单印了一次血压(诊室值,140 应判 H——诊室切点 140/90);
        // 用户自己在家又量了一次(128,低于家测阈值 135,应判正常/无 flag)。
        let hospital = crate::api::vault::ingest_bytes(
            "检验单.txt".into(),
            "生化检验报告单\n检验日期 2026-08-01\n收缩压 140 mmHg\n".into(),
        )
        .unwrap();
        assert!(hospital.document_id.is_some());

        let self_doc_id = crate::api::vault::add_self_measurement(
            vec![
                SelfMeasuredValueDto {
                    analyte_key: "bp_systolic".into(),
                    value: 128.0,
                    unit: "mmHg".into(),
                },
                SelfMeasuredValueDto {
                    analyte_key: "bp_diastolic".into(),
                    value: 82.0,
                    unit: "mmHg".into(),
                },
            ],
            Some("2026-08-01T07:30:00Z".into()),
        )
        .unwrap();
        assert!(self_doc_id > 0);

        let trends = view_trends().unwrap();
        let bp_series: Vec<&TrendSeriesDto> = trends
            .iter()
            .filter(|s| s.analyte_key.as_deref() == Some("bp_systolic"))
            .collect();
        assert_eq!(
            bp_series.len(),
            2,
            "自测收缩压与医院收缩压必须是两条独立序列: {:?}",
            bp_series
                .iter()
                .map(|s| (s.self_measured, s.points.len()))
                .collect::<Vec<_>>()
        );
        let self_series = bp_series
            .iter()
            .find(|s| s.self_measured)
            .expect("一条应标 selfMeasured");
        let hospital_series = bp_series
            .iter()
            .find(|s| !s.self_measured)
            .expect("一条应是医院来源");
        assert_eq!(self_series.points[0].value, 128.0);
        // 家测阈值 135,128 未超 → "N"(有区间、值在区间内,与 extract_labs 同一套
        // 三态 flag 约定,见 labs.rs)。这条要钉住的是用的是家测阈值 135 而不是
        // 误套诊室切点 140——两套阈值下 128 都是"N",所以另一个测试
        // (aggregate.rs 的 self_measured_bp_uses_home_range_not_clinic_range)
        // 用一个能在两套阈值下给出不同结论的值来钉这件事;这里只做端到端冒烟。
        assert_eq!(self_series.points[0].flag.as_deref(), Some("N"));
        assert_eq!(hospital_series.points[0].value, 140.0);

        // 就诊单纯文本:自测那一行带"(家测)",医院那一行不带。
        let visit = view_visit_summary().unwrap();
        assert!(
            visit.plain_text.contains("128 mmHg (家测)"),
            "缺少家测标注,实际:\n{}",
            visit.plain_text
        );
        assert!(
            !visit.plain_text.contains("140 mmHg (家测)"),
            "医院血压不该被标成家测"
        );
    }

    /// 编辑=删除旧文档+重新走一遍新增(§3.6,没有专门的编辑 API)。
    /// `self_measurement_values` 供预填表单,读回的值须与写入的一致。
    #[test]
    fn self_measurement_edit_via_delete_and_recreate() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let home = tempfile::tempdir().unwrap();
        crate::api::vault::open_vault(
            home.path().join("docs").to_string_lossy().to_string(),
            home.path().join("data").to_string_lossy().to_string(),
            None,
        )
        .unwrap();

        let doc_id = crate::api::vault::add_self_measurement(
            vec![SelfMeasuredValueDto {
                analyte_key: "heart_rate".into(),
                value: 72.0,
                unit: "/min".into(),
            }],
            Some("2026-08-01T08:00:00Z".into()),
        )
        .unwrap();

        let readback = crate::api::vault::self_measurement_values(doc_id).unwrap();
        assert_eq!(readback.len(), 1);
        assert_eq!(readback[0].analyte_key, "heart_rate");
        assert_eq!(readback[0].value, 72.0);

        // "编辑":删旧的,拿读回的值改一个数再写一份新的。
        crate::api::vault::delete_document(doc_id).unwrap();
        let new_id = crate::api::vault::add_self_measurement(
            vec![SelfMeasuredValueDto {
                analyte_key: "heart_rate".into(),
                value: 75.0,
                unit: "/min".into(),
            }],
            Some("2026-08-01T08:00:00Z".into()),
        )
        .unwrap();
        // 不断言 `doc_id != new_id`——`document.id` 是普通 SQLite `INTEGER PRIMARY
        // KEY`(schema.rs 没有 `AUTOINCREMENT`),删掉唯一一份文档后 rowid 可能被
        // 复用,这是这套 derived DB 一直以来的既有行为(id 只在一次物化快照内保证
        // 唯一,不是全局永不重复的审计标识——真正 append-only、永久保留历史的是
        // 事件日志本身,`DocumentDeleted` 事件永远留痕,可查)。这里要钉住的是
        // "旧的那份数据真的没了、新的那份数据是新值",不是 id 数值本身。
        let _ = new_id;

        let trends = view_trends().unwrap();
        let hr = trends
            .iter()
            .find(|s| s.analyte_key.as_deref() == Some("heart_rate"))
            .expect("心率序列仍在");
        assert_eq!(hr.points.len(), 1, "旧文档已删,不该残留旧的那个点");
        assert_eq!(hr.points[0].value, 75.0);
    }

    /// 笔记("头晕,是不是又高血压了")不该被读成一条诊断——不进应急卡的
    /// `conditions`,也不进任何 `TrendSeriesDto`。
    #[test]
    fn note_never_becomes_a_condition_or_a_lab_series() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let home = tempfile::tempdir().unwrap();
        crate::api::vault::open_vault(
            home.path().join("docs").to_string_lossy().to_string(),
            home.path().join("data").to_string_lossy().to_string(),
            None,
        )
        .unwrap();

        crate::api::vault::add_note(
            "今天有点头晕,是不是又高血压了,下次问问医生。".into(),
            Some("2026-08-01T09:00:00Z".into()),
        )
        .unwrap();

        let card = view_emergency_card().unwrap();
        assert!(
            card.conditions.is_empty(),
            "笔记不该被读出诊断: {:?}",
            card.conditions.iter().map(|c| &c.term).collect::<Vec<_>>()
        );
        assert!(view_trends().unwrap().is_empty());

        // 但笔记本身仍然是一份可见文档(时间线/档案里看得到)——就诊单的
        // 「最近就诊」里应该出现这条记录。
        let visit = view_visit_summary().unwrap();
        assert_eq!(visit.patient.record_count, 1);
    }

    /// 编辑必须"先删旧的,再写新的"——反过来在"编辑但没改任何字段直接保存"
    /// 时会把记录整个删没:CAS 是内容寻址,新文本与旧文档逐字节相同时
    /// `Vault::import` 命中去重,`add_self_measurement` 的去重防线(见
    /// `vault.rs` 的注释)会把旧文档自己的 id 当"新文档"直接返回;随后再删除
    /// 这个 id,删掉的就是用户刚保存的那条。这条测试钉住**正确**顺序(先删
    /// 后写)在内容完全相同时仍然保留记录——手机端 `manual_entry_sheet.dart`
    /// 的 `_save()` 必须遵守这个顺序。
    #[test]
    fn editing_with_unchanged_values_preserves_the_record_when_delete_precedes_add() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let home = tempfile::tempdir().unwrap();
        crate::api::vault::open_vault(
            home.path().join("docs").to_string_lossy().to_string(),
            home.path().join("data").to_string_lossy().to_string(),
            None,
        )
        .unwrap();

        let values = vec![SelfMeasuredValueDto {
            analyte_key: "heart_rate".into(),
            value: 72.0,
            unit: "/min".into(),
        }];
        let when = Some("2026-08-01T08:00:00Z".to_string());
        let id1 = crate::api::vault::add_self_measurement(values.clone(), when.clone()).unwrap();

        // "编辑但没改任何字段"直接保存:正确顺序是先删,再用完全相同的值重写。
        crate::api::vault::delete_document(id1).unwrap();
        let id2 = crate::api::vault::add_self_measurement(values, when).unwrap();
        assert!(id2 > 0);

        let trends = view_trends().unwrap();
        let hr = trends
            .iter()
            .find(|s| s.analyte_key.as_deref() == Some("heart_rate"))
            .expect("记录必须还在——即使内容与被删的那份逐字节相同");
        assert_eq!(hr.points.len(), 1);
        assert_eq!(hr.points[0].value, 72.0);
    }

    /// 反过来的顺序(先写"新"的、再删旧的)在内容不变时会把记录删没——这条
    /// 测试明确钉住错误顺序的后果,防止将来有人"优化"手机端代码把顺序改
    /// 回来。**这是在记录一个已知陷阱,不是在认可它。**
    #[test]
    fn editing_with_unchanged_values_loses_the_record_when_add_precedes_delete() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let home = tempfile::tempdir().unwrap();
        crate::api::vault::open_vault(
            home.path().join("docs").to_string_lossy().to_string(),
            home.path().join("data").to_string_lossy().to_string(),
            None,
        )
        .unwrap();

        let values = vec![SelfMeasuredValueDto {
            analyte_key: "heart_rate".into(),
            value: 72.0,
            unit: "/min".into(),
        }];
        let when = Some("2026-08-01T08:00:00Z".to_string());
        let id1 = crate::api::vault::add_self_measurement(values.clone(), when.clone()).unwrap();

        // 错误顺序:先"写新的"(内容相同 → CAS 去重 → 拿回的其实还是 id1),
        // 再删这个 id —— 结果是把刚"保存"的记录删没了。
        let id2 = crate::api::vault::add_self_measurement(values, when).unwrap();
        assert_eq!(id2, id1, "内容相同 → 去重防线返回的就是旧文档本身的 id");
        crate::api::vault::delete_document(id2).unwrap();

        assert!(
            view_trends().unwrap().is_empty(),
            "这就是错误顺序的后果:记录整个消失了"
        );
    }
}
