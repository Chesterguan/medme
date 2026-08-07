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

/// 就诊摘要单「最近关键化验」最多列几条(一屏能看完;完整序列去趋势页)。
const VISIT_SUMMARY_MAX_LABS: usize = 8;

/// 就诊摘要单「最近就诊」最多列几条。
const VISIT_SUMMARY_MAX_VISITS: usize = 5;

/// 就诊摘要单「我最近的变化」最多列几条。**独立于** [`VISIT_SUMMARY_MAX_LABS`] ——
/// 那个 8 条上限是跨全部检验大类排的,天天量的家测血压很容易被更晚一次的医院化验
/// 挤出前 8(见本文件 [`view_visit_summary`] 的说明),所以「变化」这一节从未截断的
/// 全量最新点里单独选,不共享同一个上限。
const VISIT_SUMMARY_MAX_CHANGES: usize = 8;

/// 就诊摘要单「我想问医生的」最多列几条笔记。产品判断(2026-08-05):这一节没有
/// 「已读/已问过」的标记(见 [`VisitNoteDto`] 文档),列太多会让屏幕被去年写的
/// 笔记占满,列太少又会漏掉最近真正想问的那条,5 条是能一屏看完又不算苛刻的折中。
const VISIT_SUMMARY_MAX_NOTES: usize = 5;

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
    /// 序列级单位:取**最后一个点**的单位,与 `handoff::series_to_json` 同一取法。
    ///
    /// 单位是 `parser::aggregate` 定下的**显示基准**单位 —— 绝大多数情况就是化验单
    /// 上逐字印的那个(患者要拿 app 上的数去核对手里那张纸);只有一条线上混了不同
    /// 印刷单位时才是规范单位,此时 [`Self::values_converted`] 为 `true`。
    /// 详见 `packages/parser/src/aggregate.rs` 模块头的「哪一层用哪一套单位」。
    pub unit: Option<String>,
    /// 参考区间,**与 [`TrendPointDto::value`] 同单位**(`parser` 侧的硬不变量:
    /// 保证不了就整体留空)。UI 拿它画参考带 —— 带子和点必须同一个单位。
    pub ref_low: Option<f64>,
    pub ref_high: Option<f64>,
    /// 这条线上混了不同印刷单位,值和参考区间**已统一换算**到规范单位。
    ///
    /// `true` 时 UI **必须说出来**:用户在自己那张化验单上找不到屏幕上这个数字,
    /// 不说等于改写原文(`docs/007` §2.1「原件永远可达」「不改写原文」)。
    /// `false`(常态)= 屏幕上的数值/单位/区间就是纸上印的那一套。
    pub values_converted: bool,
    /// 任一点被标记 H/L(`parser::AnalyteSeries::any_abnormal`)。
    pub any_abnormal: bool,
    /// 这条序列所属的**检验大类**(化验单项目组表头,如「血常规」「肝功能」——
    /// 见 `terminology::panel_for` / `packages/terminology/panel_methodology.md`),
    /// 是 [`view_trend_panel_catalog`] 目录里的一个值,或 `None`。**只给一个**
    /// (不像疾病泳道允许多重归属:一项化验在真实报告单上只印在一个项目组表头
    /// 下)。`None` 表示这条序列没能归一化出 `analyte_key`,或归一化到的条目在
    /// 词典里没配 panel(专科/低频检验,如实留空而不是硬凑)—— 两种情况 UI 都
    /// 归入「其他」。
    pub panel: Option<String>,
    /// **全部**观测点,按时间升序(无日期的排最后)。不做任何数量裁剪。
    pub points: Vec<TrendPointDto>,
    /// 这条序列是不是手动录入的自测值(血压/血糖/体重/体温/心率,「记录」入口
    /// 产出,而非从化验单 OCR 出来的)——`parser::AnalyteSeries::self_measured`
    /// 透传。自测序列结构上永远不会与同名医院序列合并(`aggregate` 的分组约定,
    /// 见 MANUAL-ENTRY-DESIGN.md),这个字段只用于**显示**:UI 据此加"(家测)"
    /// 标注 / 换个点形状,不改变哪些点属于这条序列。
    pub self_measured: bool,
    /// 家测参考区间的出处引文(`self_entry::HomeRefRange::source` 原样透传),仅
    /// [`Self::self_measured`] 为 `true` 且该分析物有可引用的家测区间时才是
    /// `Some`——与 `ref_low`/`ref_high` 同源同一次 `home_ref_range` 查询,不会出现
    /// "有区间没出处"或"有出处没区间"的错配。
    ///
    /// 医院化验序列(`self_measured == false`)恒为 `None`:那条序列的参考区间
    /// 出处是化验单原件本身,不是这段可引用的指南/共识文字能替代的——UI 改用卡底
    /// 「查看原件」入口交代来源(`trends_screen.dart` 的 `SeriesCard`),不读这个
    /// 字段。
    ///
    /// **追加在结尾**,不插进中间——与本文件头「函数命名为什么统一 `view_`
    /// 前缀」那条注释同一个用意:FRB 的 `sse_encode`/`sse_decode` 按字段声明顺序
    /// 逐个编解码,新增字段放最后,现有字段的顺序 / 生成代码的既有形状都不挪动。
    pub ref_source: Option<String>,
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
    /// [`VISIT_SUMMARY_MAX_LABS`] 条。完整序列在趋势页。**这一屏不单独渲染这份
    /// 全量列表**(2026-08-05 改版后只显示 [`recent_changes`]),它只喂
    /// [`plain_text`]——复制给医生的那份要带全的最近化验,不只是异常的那几条。
    pub recent_labs: Vec<VisitLabDto>,
    /// 「我最近的变化」:[`recent_labs`] 里自测的(`self_measured`)或**确为异常**
    /// (`flag` 是 `H`/`L`)的那些,最多 [`VISIT_SUMMARY_MAX_CHANGES`] 条,**不是**
    /// 从 [`recent_labs`] 截出来的——见 [`view_visit_summary`] 里的说明,共享同一个
    /// 8 条上限会把自测值挤没。只进这一屏的 UI,不进 [`plain_text`]/二维码分享
    /// (那两处已经有更完整的化验数据,不需要再复述一遍"哪些变了")。
    pub recent_changes: Vec<VisitLabDto>,
    /// 最近就诊/文档,最多 [`VISIT_SUMMARY_MAX_VISITS`] 条。
    pub recent_visits: Vec<VisitRecordDto>,
    /// 「我想问医生的」:最近的手动笔记,最多 [`VISIT_SUMMARY_MAX_NOTES`] 条,
    /// 按记录时间倒序。**只进这一屏,患者自己看**——见 [`VisitNoteDto`] 文档,
    /// 绝不进 [`plain_text`] 或二维码分享。
    pub recent_notes: Vec<VisitNoteDto>,
    /// 与上面结构化字段**同源同内容**的纯文本渲染,供直接复制给医生。
    /// 只含原文逐字内容 + 字段标签,不含任何解释、结论或推断,**且不含笔记**——
    /// 笔记是患者自由文本,混进给医生的这份容易被当成病历内容(见
    /// [`VisitNoteDto`] 文档)。
    pub plain_text: String,
}

/// 摘要单上的一行化验:一个具体的测量点。
#[derive(Debug, Clone)]
pub struct VisitLabDto {
    pub name: String,
    /// `"YYYY-MM-DD"`。只收带日期的点,故必有值。
    pub date: String,
    /// 值 / 单位 / 参考区间三者**同单位**,来自 `parser::aggregate` 定下的显示基准
    /// (见那里的「哪一层用哪一套单位」)。常态下就是化验单上逐字印的那一套。
    pub value: f64,
    pub unit: Option<String>,
    pub flag: Option<String>,
    pub ref_low: Option<f64>,
    pub ref_high: Option<f64>,
    /// 见 [`TrendSeriesDto::values_converted`] —— 同一份透传。`true` 时这一行的
    /// 数值在患者手里那张纸上找不到,UI 必须标注「已统一换算」。
    pub values_converted: bool,
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

/// 就诊摘要单「我想问医生的」一节的一条笔记。
///
/// ## 为什么不进 [`VisitSummaryDto::plain_text`] 或二维码分享
///
/// 笔记是患者自己写的自由文本("今天头晕""问王医生片子的事"),不是从病历原文
/// 抽出来的。这一屏其它每一节都可以说"这是原文逐字"或"这是从原文抽出的数值/
/// 日期";笔记不行——它是患者此刻的主观记录,混进给医生的那份文本,读起来会
/// 被当成一条病历陈述(甚至被当成主诉)。所以它只出现在这一屏上,给患者自己看,
/// 提醒"待会儿要问这个"。二维码分享走的是 `packages/parser::handoff::assemble_summary`
/// 那条完全不同的管线(结构化的 problems/labs/meds,没有"最近文档"这种原文转述),
/// 笔记原本就到不了那里,这条边界是**结构性的**,不需要额外过滤。
///
/// ## 为什么没有"已经问过医生"这种已读标记
///
/// `MANUAL-ENTRY-DESIGN.md` §5.4 提过一个更细的方案:录入笔记时加一个"要问医生"
/// 的勾选标记,只有勾了的笔记才进这一节。这需要在笔记文本里编码一个隐藏标记(见
/// 该文档 §3.2 自测值的"结构化载荷"先例)——但笔记的 OCR 文本在这个项目里是一条
/// 反复强调的不变量:「逐字来自你的记录」,`note_never_becomes_a_condition_or_a_lab_series`
/// 这类测试钉的就是这条保真度。往里面塞一个显示时要再摘掉的隐藏前缀,是在为了一个
/// UI 分类去弄脏这条不变量,且没有历史笔记的回填路径(老笔记永远没有这个标记)。
/// 权衡下来选了更简单的退路:直接显示**最近几条**笔记(见
/// [`VISIT_SUMMARY_MAX_NOTES`]),不分类。代价是"今天头晕"和"问王医生片子的事"
/// 会混在一起,好处是零 core-model/parser 改动、老笔记立刻可用、没有退化的空标记
/// 语义。
#[derive(Debug, Clone)]
pub struct VisitNoteDto {
    /// 笔记原文,逐字。
    pub text: String,
    /// 记录时间,`"YYYY-MM-DD"`。录入弹层的"测量时间"对笔记同样必填,实践中恒有
    /// 值,但仍按 `Option` 处理,不假设。
    pub date: Option<String>,
    pub document_id: i64,
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

// ─────────────────────── 检验大类分组(panel chip) ───────────────────────
//
// 产品问题:手机上的搜索框对「找和这类检查相关的指标」没用 —— 打「嗜酸性粒细胞
// 百分比」比滚一屏还慢。这里给的是分类入口:点一个大类,看这个大类下的全部序列。
//
// **这里不是「关注方向」(那是 `problem_map.json` 的疾病泳道,医生查看器用)。**
// 早先这里确实按疾病泳道分过(糖尿病相关/高血压相关…),但疾病泳道天生稀疏 ——
// 演示数据 19 条序列里有 6 条(中性粒细胞%、淋巴细胞%、血小板、红细胞压积、
// 平均红细胞体积、嗜酸性粒细胞%——全是血常规计数项)一条泳道都不落,只能进
// 「其他」。真实用户找化验时想的是**检验大类**:血常规、肝功能、肾功能……这正是
// 中国化验单本身印刷的项目组表头。改用 `terminology::panel_for`(按 `analyte_key`
// 查词典里策展好的 `panel` 字段,见 `packages/terminology/panel_methodology.md`)
// 后,那 6 条全部归位到「血常规」。疾病泳道仍然存在,只是留在医生查看器里 ——
// 那才是它该在的地方,`packages/parser/data/problem_map.json` 一个字节没动。
//
// **只认归一化后的 `analyte_key`,没有名字兜底。** 未能归一化的序列(实测占比不
// 低)如实降级进 UI 的「其他」桶,而不是被硬凑进某个大类 —— 与本文件其它
// 「宁可少一条也不编」的准则一致。
//
// **只给一个 panel**(不像疾病泳道允许多重归属):一项化验在真实报告单上物理上
// 只印在一个项目组表头下,这是 panel 与 problem_group 最本质的区别,取舍写在
// `panel_methodology.md` 里,不是本文件的判断。

/// 分组 chip 的完整目录,固定顺序(策展在 `terminology::PANEL_CATALOG`,与每条
/// [`TrendSeriesDto::panel`] 用的是同一份表)。**只回答「有哪些大类、先后顺序是
/// 什么」**——UI 不应该自己另定一份顺序(比如按"数据里第一次出现的顺序"排),
/// 否则两端顺序会漂移,同一个人重新打开页面 chip 顺序都可能不一样。
///
/// 不含「全部」「其他」—— 那两个是 UI 侧的兜底 sentinel,不是词典策展出来的大类,
/// 不该跟着这份表的「怎么算」走。
pub fn view_trend_panel_catalog() -> Vec<String> {
    terminology::PANEL_CATALOG
        .iter()
        .map(|s| s.to_string())
        .collect()
}

// ─────────────────────────── 过敏史 ───────────────────────────
//
// `handoff::extract_allergies_pairs` / `parse_allergy_item` 都是 private,且
// `packages/parser` 不在本次改动范围内,故按**同一规则**在此重写一遍(逐条对照
// `packages/parser/src/handoff.rs` 的那两个函数)。重写的另一个必要理由:那两个函数
// 只产出 `(substance, reaction)`,不带来源;应急卡要求每条过敏史能跳回原件,必须在
// 逐份扫描时自己记住是哪一份文档说的。

/// 过敏史否定词前缀集合,分别用在两层检查上:一次判整个分句(第一层,见
/// `extract_allergies_pairs`),一次判单条 item(第二层,`parse_allergy_item`)——
/// 两处都要判的原因见各自函数上的注释。同 `handoff::ALLERGY_NEGATION_PREFIXES`。
///
/// - `否认`:病历里最常见的否定写法,后面永远跟着"没有的东西"(否认食物过敏/
///   否认药物过敏史……),不存在"否认"本身就是物质名一部分的歧义,所以整词
///   前缀匹配是安全的。
/// - `未见`:查体/病史场景下"未见异常"式的否定,语义上就是"没有"。
/// - `(-)`/`（-）`:皮试等检验报告惯用的阴性结果记号,同样是"没有"的另一种
///   写法(半角/全角括号都收,因为录入时括号和减号常常不是同一种宽度)。
///
/// `无` **不在这张表里**——它单独处理,见 `is_negation_after_wu`(下方
/// `is_allergy_negation` 里内联的分支):`无` 后面跟的可能是"没有的东西"
/// (无过敏史/无殊),也可能是一个恰好以"无"开头的物质名(无花果)。整词
/// 前缀匹配对"否认"安全,对"无"不安全,不能一视同仁——见 #65。
///
/// 刻意不收 `不详`/`不知`/`未知`/`不清楚`:那是"不知道",不是"没有过敏"。把
/// 这类词也归进否定词,会让应急卡把"信息缺失"显示成"确认无过敏"——这本身
/// 就是一次反向安全事故,跟这次要修的是同一类问题。这几个词走的是另一条
/// 独立的"宁缺"规则(见 `is_allergy_unclear`),不产出条目,但**不是**因为
/// 判成了否定。
const ALLERGY_NEGATION_PREFIXES: [&str; 4] = ["否认", "未见", "(-)", "（-）"];

/// `无` 后面接的词决定它是不是否定词。这些词都是"没有的东西/没有的说法",
/// 而不是一个物质名的开头。
///
/// **这张表清单是本次 #65 修复里刻意选择的失败方向**:白名单漏收某种病历里
/// 真实存在、但这里没想到的否定写法,那条会被当成物质名显示在应急卡的红框
/// 里——一次**假阳性**。假阳性会被使用者/医生看见、质疑、可以当场澄清;而
/// 误把真实过敏原(比如"无花果过敏")的"无"字当否定词吃掉是**假阴性**——
/// 过敏原从卡片上直接消失,没人有机会发现少了什么,却仍可能被当作"已确认
/// 无过敏"来行动。两种错误不对称,所以这张表宁可漏收,也不要贪多误伤真实
/// 物质名。
const WU_NEGATION_CONTINUATIONS: [&str; 9] = [
    "过敏", "特殊", "殊", "明确", "明显", "已知", "药物", "食物", "其他",
];

/// 判断一段文本(一个分句,或退化到一条 item)是不是以否定词开头。
fn is_allergy_negation(s: &str) -> bool {
    let s = s.trim();
    if let Some(rest) = s.strip_prefix('无') {
        // 剥掉「无」之后,剩余为空(单独一个「无」)、或以某个"否定延续词"开头,
        // 才判否定;否则「无」就是物质名自己的第一个字(无花果、无花果酱……)。
        return rest.is_empty()
            || WU_NEGATION_CONTINUATIONS
                .iter()
                .any(|p| rest.starts_with(p));
    }
    ALLERGY_NEGATION_PREFIXES.iter().any(|p| s.starts_with(p))
}

/// 「不详」类标记:病历里的意思是"没查清楚/没说清楚",既不是"有过敏"也不是
/// "无过敏"。宁缺规则——卡片默认状态本来就是"未识别",这类条目不构成一条
/// 明确的过敏原,不需要占红框重复表达同一件事,所以直接不产出。
///
/// **这不是否定词**,故意不并进 `is_allergy_negation`/`ALLERGY_NEGATION_PREFIXES`:
/// 语义上不一样(见该常量上的注释),混在一起会让下一个读代码的人以为"不详"
/// 可以当"无过敏"处理。
const ALLERGY_UNCLEAR_MARKERS: [&str; 4] = ["不详", "不知", "未知", "不清楚"];

/// 判断一条 item(标签已经在 `extract_allergies_pairs` 里去掉)是不是"不详"
/// 类的含糊标记。行标签(过敏史/过敏)有时会在剩余文本里再出现一次——例如
/// 「过敏史:过敏史不详。」——所以先剥掉可能重复出现的标签前缀,再整词比对。
fn is_allergy_unclear(item: &str) -> bool {
    let s = item
        .trim_start_matches("过敏史")
        .trim_start_matches("过敏")
        .trim();
    ALLERGY_UNCLEAR_MARKERS.contains(&s)
}

/// 在 `text` 里找过敏史标签(`过敏史` / `过敏`),取标签之后的剩余部分,分两层解析。
/// 同 `handoff::extract_allergies_pairs`。
///
/// **第一层——按分句切,否定分句整句丢弃。** 按 `；;。`(只认句子边界标点)切成
/// 分句,每个分句是一句完整陈述;分句开头是否定词就整句丢掉,根本不进第二层。
/// 这就是本次修复的核心:**「否认」/「无」管的是它引出的整个分句,不是紧贴在
/// 它后面的那一个条目**。「否认食物、药物过敏史」是一句被否定的话,句里的
/// 食物、药物两个物质都在「否认」的管辖范围内;旧逻辑在判否定之前就先按 `、`
/// 切开,「食物」独立成第一条(碰巧自己开头是「否认」,还能被挡住),「药物过敏史」
/// 却独立成第二条,开头既不是「否认」也不是「无」,读起来就成了阳性过敏——
/// 而且因为它尾巴上还带着行标签同款的「过敏史」三个字,连"物质名"看起来都是
/// 「药物过敏史」。这就是「无已知过敏」被印成过敏原的根因。`、`/`，`/`,` 故意
/// 不放进这一层的分隔符里:中文病历里逗号经常身兼两职,既断句又当并列顿号用,
/// 放进来会把「青霉素过敏,否认食物过敏」这种一句里前阳后否定的写法切成两句,
/// 破坏第二层"把同一分句内的阳性/否定条目留在一起判"的设计。
///
/// **第二层——阳性分句才按顿号/逗号切成条目。** 只有第一层判定为阳性的分句
/// 才会按 `，,、` 切成 `物质(反应)` 条目,交给 `parse_allergy_item` 逐条解析;
/// 那个函数自带的条目级否定检查(不变)是第二道防线——「青霉素过敏,否认食物
/// 过敏」这种一个分句内部混了阳性和否定、且分句内没有 `；;。` 可切的写法,
/// 第一层因为分句开头是「青霉素」不会触发,靠第二层按逗号切开后逐条判否定
/// 才能把「否认食物过敏」这一条挡住。
///
/// 空分句/空条目两层都会跳过。
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
        for clause in rest.split(['；', ';', '。']) {
            let clause = clause.trim();
            if clause.is_empty() || is_allergy_negation(clause) {
                continue;
            }
            for item in clause.split(['，', ',', '、']) {
                if let Some(pair) = parse_allergy_item(item) {
                    out.push(pair);
                }
            }
        }
    }
    out
}

/// 解析一条 `青霉素(皮疹)` → `("青霉素", "皮疹")`,或裸的 `磺胺` → `("磺胺", "")`。
/// 空条目/否定式返回 None——这是 `extract_allergies_pairs` 注释里说的第二道
/// 防线。「不详」类(`is_allergy_unclear`)也返回 None,但原因不同:不是"确认
/// 无过敏",只是"不构成一条明确过敏原"(宁缺)——调用方只需要"跳过这条",不
/// 需要区分原因,所以共用同一个 `None`。同 `handoff::parse_allergy_item`。
fn parse_allergy_item(item: &str) -> Option<(String, String)> {
    let item = item
        .trim()
        .trim_matches(|c: char| c.is_whitespace() || matches!(c, '。' | '.' | ';' | '；'));
    if item.is_empty() || is_allergy_negation(item) || is_allergy_unclear(item) {
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
        panel: s
            .analyte_key
            .as_deref()
            .and_then(terminology::panel_for)
            .map(str::to_string),
        unit: s.points.last().and_then(|p| p.unit.clone()),
        ref_low: s.ref_low,
        ref_high: s.ref_high,
        values_converted: s.values_converted,
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
        // 只对自测序列重新查一次 `home_ref_range`——不是从 `aggregate.rs` 那边
        // 多穿一个字段过来的:`ref_low`/`ref_high` 已经是拿同一个查询算出来的
        // (`aggregate::build_self_measured_observation`),这里重查同一个纯函数
        // 拿它的 `source`,两边保证读到同一份结果,又不用碰 `AnalyteSeries`
        // 的形状(spine 不动)。医院化验序列没有 `home_ref_range` 可查,恒为 None。
        ref_source: s
            .self_measured
            .then_some(s.analyte_key.as_deref())
            .flatten()
            .and_then(parser::home_ref_range)
            .map(|r| r.source.to_string()),
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
/// 内容:基本信息 + 过敏史 + 在用药 + 最近关键化验(带日期与 flag)+ 我最近的变化 +
/// 我想问医生的(笔记)+ 最近就诊记录标题。全部是原文逐字内容、从原文抽出的数值/
/// 日期,或患者自己写的笔记(笔记单独标注,见 [`VisitNoteDto`])——**不生成任何
/// 解释性文字或结论**。
pub fn view_visit_summary() -> anyhow::Result<VisitSummaryDto> {
    let projection = gather()?;
    let src = source_docs(&projection.docs);
    let clinical = parser::aggregate(&src);
    let patient = crate::api::vault::patient_profile()?;

    let allergies = collect_allergies(&projection.docs);
    let active_meds = collect_active_meds(&projection.docs, &clinical.meds);

    // 每条可渲染序列取最新一个**带日期**的点,按日期倒序,同日按名字稳定排。这是
    // 「最近的变化」与「最近化验(喂纯文本)」共同的底料,截断方式不同,所以在两者
    // 分叉之前先算好、排好序,不重复写一遍取点逻辑。
    let mut all_latest_labs: Vec<VisitLabDto> = clinical
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
                values_converted: s.values_converted,
                document_id: projection.docs.get(p.source)?.document_id,
                self_measured: s.self_measured,
            })
        })
        .collect();
    all_latest_labs.sort_by(|a, b| b.date.cmp(&a.date).then_with(|| a.name.cmp(&b.name)));

    let mut recent_labs = all_latest_labs.clone();
    recent_labs.truncate(VISIT_SUMMARY_MAX_LABS);

    // 「我最近的变化」:自测的,或带异常标记的。从**未截断**的 `all_latest_labs`
    // 里选,不是从上面已经砍到 8 条的 `recent_labs` 里选——否则天天量的家测血压
    // 一旦被更晚的一次医院化验挤到前 8 名之外,这一节就会漏掉它,而这一节存在的
    // 意义恰恰是不能漏掉家测值(见 [`VisitSummaryDto::recent_changes`] 文档)。
    //
    // 判「异常」用 `H`/`L`,**不是 `flag.is_some()`**。`flag` 是化验单上印的原始
    // 记号,而化验单也会印表示正常的记号——真机上就撞到过:低密度脂蛋白胆固醇
    // 2.75(参考 ≤3.37)印着 `N`,`flag.is_some()` 为真,于是一条明确正常的化验
    // 出现在「我最近的变化」里。「单子上印了个记号」和「异常」是两回事。
    //
    // `Some("H") | Some("L")` 与 `packages/parser/src/aggregate.rs` 里 `abnormal`
    // 是同一条判据(`any_abnormal` 也这么算)——这条判据全项目只该有一种写法。
    let mut recent_changes: Vec<VisitLabDto> = all_latest_labs
        .into_iter()
        .filter(|l| l.self_measured || matches!(l.flag.as_deref(), Some("H") | Some("L")))
        .collect();
    recent_changes.truncate(VISIT_SUMMARY_MAX_CHANGES);

    let mut recent_visits = projection.visits;
    // 「复制给医生」的纯文本要过滤掉笔记(规则见 [`VisitNoteDto`] 文档),但结构化
    // 的 `recent_visits` 字段不过滤——概览「最近归档」用的是同一个字段,那里笔记
    // 该照常出现(它确实是刚存进档案的一份东西)。所以在 `recent_visits` 自己的
    // 截断**之前**先派生出纯文本要用的过滤版本,避免笔记占掉截断名额、把本该出现
    // 的真实就诊记录挤出这份文本。
    //
    // 不能靠 `VisitRecordDto::kind` 判断——一份孤零零的笔记会被 `load_archive`
    // 的就诊分组(`rebuild_encounters`)包成它自己单份的"门诊"就诊组,`kind` 因此
    // 是 `"outpatient"` 不是 `"note"`,和真实门诊记录长得一模一样。真正稳定的判断
    // 是看这条记录涵盖的文档是不是**清一色**笔记——`document_ids` 混着真实文档的
    // 就诊组照常保留(那不是"一条笔记",是一次真实就诊,只是笔记也归了进去)。
    let note_doc_ids: BTreeSet<i64> = projection
        .docs
        .iter()
        .filter(|d| d.doc_type.as_deref() == Some("note"))
        .map(|d| d.document_id)
        .collect();
    let visits_for_text: Vec<VisitRecordDto> = recent_visits
        .iter()
        // 保留条件是"至少有一份不是笔记"。`document_ids` 空列表这种理论上不该出现
        // 的边界上,`any` 老实返回 false(排除),不需要额外判断空表。
        .filter(|v| v.document_ids.iter().any(|id| !note_doc_ids.contains(id)))
        .take(VISIT_SUMMARY_MAX_VISITS)
        .cloned()
        .collect();
    recent_visits.truncate(VISIT_SUMMARY_MAX_VISITS);

    let recent_notes = collect_recent_notes(&projection.docs);

    let plain_text = render_plain_text(
        &patient,
        &allergies,
        &active_meds,
        &recent_labs,
        &visits_for_text,
    );

    Ok(VisitSummaryDto {
        patient,
        allergies,
        active_meds,
        recent_labs,
        recent_changes,
        recent_visits,
        recent_notes,
        plain_text,
    })
}

/// 逐份扫过 [`ProjectionDoc`],挑出笔记(`doc_type == "note"`),按记录日期倒序,
/// 无日期的排最后(理论上不会发生,笔记录入必填测量时间,但仍按这条通用规则处理,
/// 不假设),取前 [`VISIT_SUMMARY_MAX_NOTES`] 条。
fn collect_recent_notes(docs: &[ProjectionDoc]) -> Vec<VisitNoteDto> {
    let mut notes: Vec<&ProjectionDoc> = docs
        .iter()
        .filter(|d| d.doc_type.as_deref() == Some("note"))
        .collect();
    notes.sort_by(|a, b| match (a.date, b.date) {
        (Some(x), Some(y)) => y.cmp(&x),
        (Some(_), None) => std::cmp::Ordering::Less,
        (None, Some(_)) => std::cmp::Ordering::Greater,
        // 同无日期:按 document_id 降序,新建的记录 id 更大,排前面——与其它地方
        // "无日期排最后"里再稳定排序的取法(`gather` 的 `flat.sort_by`)同一手法。
        (None, None) => b.document_id.cmp(&a.document_id),
    });
    notes.truncate(VISIT_SUMMARY_MAX_NOTES);
    notes
        .into_iter()
        .map(|d| VisitNoteDto {
            text: d.text.clone(),
            date: d.date.map(fmt_date),
            document_id: d.document_id,
        })
        .collect()
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

    /// 目录:16 个大类(14 个检验大类 + 生命体征/体格测量),每条文案唯一
    /// (chip 靠文案本身当 key,不能撞名),顺序与 `terminology::PANEL_CATALOG`
    /// 一致(策展顺序,不是数据里第一次出现的顺序 —— 见该函数文档)。
    ///
    /// 生命体征与体格测量排在最前:手动录入的血压/心率/体重是用户**自己天天在看**
    /// 的,而化验大类隔几个月才来一次;chip 横向滚动,谁在前谁被看见。
    #[test]
    fn view_trend_panel_catalog_has_sixteen_distinct_labels_in_curated_order() {
        let catalog = view_trend_panel_catalog();
        assert_eq!(catalog.len(), 16, "实际={catalog:?}");
        let uniq: BTreeSet<&String> = catalog.iter().collect();
        assert_eq!(uniq.len(), catalog.len(), "chip 文案不能撞名:{catalog:?}");
        assert_eq!(
            catalog,
            vec![
                "生命体征",
                "体格测量",
                "血常规",
                "尿液",
                "肝功能",
                "肾功能",
                "血糖",
                "血脂",
                "电解质",
                "甲状腺功能",
                "凝血",
                "心肌标志物",
                "炎症/感染",
                "肿瘤标志物",
                "风湿免疫",
                "性激素",
            ]
        );
    }

    /// `trend_series` 把 `terminology::panel_for` 的结果原样接到 DTO 上 —— 端到端
    /// 钉一次装配路径本身没有再插一层猜测(LDL 归一化到 `ldl`,词典里 `ldl` 的
    /// panel 是「血脂」)。
    #[test]
    fn trend_series_dto_carries_panel_from_analyte_key() {
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
            .find(|s| s.analyte_key.as_deref() == Some("ldl"))
            .expect("LDL series should resolve via the terminology dictionary");
        let dto = trend_series(&docs, ldl);
        assert_eq!(dto.panel.as_deref(), Some("血脂"));
    }

    /// 家测序列的参考区间出处(`ref_source`)必须原样带到 DTO 上,且与
    /// `ref_low`/`ref_high` 出自**同一次** `home_ref_range` 查询 —— 界面能不能
    /// 证明「我们用的是官方来源」就看这个字段有没有值、值对不对。
    #[test]
    fn trend_series_dto_carries_ref_source_for_self_measured_series() {
        let text = parser::render_self_measurement_text(
            &["心率 72 /min".to_string()],
            &[parser::SelfMeasuredValue {
                analyte_key: "heart_rate".into(),
                value: 72.0,
                unit: "/min".into(),
            }],
        );
        let docs = docs_from(&[(text.as_str(), Some("2026-08-01"), "self_measurement")]);
        let src = source_docs(&docs);
        let clinical = parser::aggregate(&src);
        let hr = clinical
            .labs
            .iter()
            .find(|s| s.analyte_key.as_deref() == Some("heart_rate"))
            .expect("heart_rate series should exist");
        let dto = trend_series(&docs, hr);
        assert_eq!(
            dto.ref_source,
            parser::home_ref_range("heart_rate").map(|r| r.source.to_string()),
            "ref_source 必须和 ref_low/ref_high 出自同一次 home_ref_range 查询"
        );
        assert!(dto.ref_source.as_deref().unwrap().contains("心率"));
    }

    /// 医院化验序列的出处是化验单原件本身,不是某条可引用的指南/共识文字 ——
    /// `ref_source` 恒为 `None`,即使这条序列本身带着参考区间(那对区间来自
    /// 报告原文,不是 `home_ref_range` 给的)。
    #[test]
    fn trend_series_dto_never_carries_ref_source_for_hospital_series() {
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
            .find(|s| s.analyte_key.as_deref() == Some("ldl"))
            .expect("LDL series should resolve via the terminology dictionary");
        let dto = trend_series(&docs, ldl);
        assert!(
            dto.ref_low.is_some(),
            "这条序列本身要带着参考区间,测试才有意义"
        );
        assert!(
            dto.ref_source.is_none(),
            "医院化验序列的出处是化验单原件,不该有 ref_source"
        );
    }

    /// 没有可引用家测区间的分析物(体温/体重/血糖,见
    /// `self_entry::home_ref_range` 的文档)——`ref_low`/`ref_high`/`ref_source`
    /// 三者一起留空,不会出现「没区间却有出处」这种半吊子状态。
    #[test]
    fn trend_series_dto_has_no_ref_source_when_there_is_no_home_range() {
        let text = parser::render_self_measurement_text(
            &["体重 65 kg".to_string()],
            &[parser::SelfMeasuredValue {
                analyte_key: "body_weight".into(),
                value: 65.0,
                unit: "kg".into(),
            }],
        );
        let docs = docs_from(&[(text.as_str(), Some("2026-08-01"), "self_measurement")]);
        let src = source_docs(&docs);
        let clinical = parser::aggregate(&src);
        let weight = clinical
            .labs
            .iter()
            .find(|s| s.analyte_key.as_deref() == Some("body_weight"))
            .expect("body_weight series should exist");
        let dto = trend_series(&docs, weight);
        assert!(dto.ref_low.is_none() && dto.ref_high.is_none());
        assert!(dto.ref_source.is_none());
    }

    /// 没能归一化出 `analyte_key` 的序列(名字没进词典)拿不到 panel,`None` 是
    /// 诚实的降级 —— UI 把它归入「其他」,不是硬凑一个大类进去。这是「分类入口绝
    /// 不能让任何一条化验变得够不着」的兜底证据。
    /// **缺陷钉子(2026-08-05):趋势卡的参考带与点不同单位。**
    ///
    /// `TrendChart` 用 `refLow`/`refHigh` 画参考带、用 `points[].value` 画点。
    /// 值换算成 umol/L 而区间还是 mg/dL 时,带子画在 0.6–1.3 的高度上、点落在
    /// 106 —— 点在带外老远,而 pill 读的是 flag(正常)。图和 pill 互相打脸。
    ///
    /// 新契约:同一条序列上,区间与每一个点**必须同单位**(见
    /// `packages/parser/src/aggregate.rs` 的「哪一层用哪一套单位」)。
    #[test]
    fn trend_series_ref_band_shares_the_unit_of_its_points() {
        let docs = docs_from(&[(
            "生化检验报告单\n肌酐: 1.2 mg/dL (参考 0.6-1.3)\n",
            Some("2026-08-01"),
            "lab_report",
        )]);
        let src = source_docs(&docs);
        let clinical = parser::aggregate(&src);
        let cr = clinical
            .labs
            .iter()
            .find(|s| s.analyte_key.as_deref() == Some("creatinine"))
            .expect("creatinine series");
        let dto = trend_series(&docs, cr);

        // 患者手里那张纸印的是 `1.2 mg/dL 参考 0.6-1.3` —— 屏幕上就该是这个。
        assert_eq!(dto.unit.as_deref(), Some("mg/dL"));
        assert_eq!(dto.points[0].value, 1.2);
        assert_eq!(dto.points[0].unit.as_deref(), Some("mg/dL"));
        assert_eq!((dto.ref_low, dto.ref_high), (Some(0.6), Some(1.3)));
        assert!(!dto.values_converted, "没换算就不许标「已统一换算」");
        // 参考带包得住这个点,与 flag 的结论一致。
        assert!(dto.points[0].value >= dto.ref_low.unwrap());
        assert!(dto.points[0].value <= dto.ref_high.unwrap());
        assert_eq!(dto.points[0].flag.as_deref(), Some("N"));
    }

    /// 混了单位的一条线:轴/点/参考带一起走规范单位(否则连不成线),并且
    /// `values_converted` 必须为真 —— 屏幕上的数字用户在纸上找不到,UI 要说出来。
    #[test]
    fn trend_series_mixed_units_are_converted_and_say_so() {
        let docs = docs_from(&[
            (
                "生化检验报告单\n肌酐: 1.2 mg/dL (参考 0.6-1.3)\n",
                Some("2026-01-01"),
                "lab_report",
            ),
            (
                "生化检验报告单\n肌酐 96 umol/L 59-104\n",
                Some("2026-06-01"),
                "lab_report",
            ),
        ]);
        let src = source_docs(&docs);
        let clinical = parser::aggregate(&src);
        let cr = clinical
            .labs
            .iter()
            .find(|s| s.analyte_key.as_deref() == Some("creatinine"))
            .expect("creatinine series");
        let dto = trend_series(&docs, cr);

        assert!(dto.values_converted, "混单位必须说出来");
        assert_eq!(dto.unit.as_deref(), Some("umol/L"));
        for p in &dto.points {
            assert_eq!(p.unit.as_deref(), Some("umol/L"));
        }
        assert!((dto.points[0].value - 106.104).abs() < 0.01);
        assert_eq!((dto.ref_low, dto.ref_high), (Some(59.0), Some(104.0)));
    }

    #[test]
    fn trend_series_dto_panel_is_none_without_analyte_key() {
        let docs = docs_from(&[(
            "生化检验报告单\n某某未收录指标 3.6 mmol/L\n",
            Some("2024-06-01"),
            "lab_report",
        )]);
        let src = source_docs(&docs);
        let clinical = parser::aggregate(&src);
        let unmapped = clinical
            .labs
            .iter()
            .find(|s| s.analyte_key.is_none())
            .expect("未收录的指标名应该保留为一条 analyte_key = None 的序列");
        let dto = trend_series(&docs, unmapped);
        assert_eq!(dto.panel, None);
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

    /// 反向安全回归:「否认食物、药物过敏史」不该产出任何过敏条目。「否认」管的是
    /// **整个分句**,不是紧跟在它后面那一个顿号分隔的条目——修复前按 `、` 一刀切
    /// 再逐条判否定前缀,会把分句尾部那个"没人管"的条目读成阳性过敏,而且因为它
    /// 尾巴上带着跟标签同款的「过敏史」三个字,连"物质名"都长得像「药物过敏史」。
    /// 应急卡把"无已知过敏"印成过敏原,比少抽一条更危险:急救者会照着卡片回避或
    /// 慎用一样病人其实没有过敏史的东西。同 `handoff::` 里的
    /// `allergy_negation_scopes_the_whole_clause_not_the_first_item`/
    /// `allergy_positive_and_negation_sharing_one_clause`/
    /// `allergy_negation_prefix_variants`,验的是这份手抄副本,不是原版。
    #[test]
    fn allergy_negation_scopes_the_whole_clause_not_the_first_item() {
        assert_eq!(
            extract_allergies_pairs("过敏史:否认食物、药物过敏史。"),
            Vec::<(String, String)>::new(),
            "否认同时管着食物和药物,不是只管紧跟其后的食物"
        );
        assert_eq!(
            extract_allergies_pairs("过敏史:否认药物、食物过敏史。"),
            Vec::<(String, String)>::new(),
            "顺序调换,否认依旧管两项"
        );
        assert_eq!(
            extract_allergies_pairs("过敏史:否认食物及其他药物过敏史。"),
            Vec::<(String, String)>::new(),
            "句内本来就没有顿号——此前已经是对的,不能改坏"
        );
        assert_eq!(
            extract_allergies_pairs("过敏史:磺胺类药物(皮疹史);否认食物及其他药物过敏史。"),
            vec![("磺胺类药物".to_string(), "皮疹史".to_string())],
            "真实出院记录写法:阳性分句与否定分句共享一个字段,靠；分开"
        );
        assert_eq!(
            extract_allergies_pairs("既往史:否认肝炎、结核病史,否认食物、药物过敏史。"),
            Vec::<(String, String)>::new(),
            "过敏史标签命中的是句中「药物过敏史」尾巴,剩余部分只有一个句号"
        );
    }

    /// 同一分句内阳性 + 否定混写(分句内没有 ；;。可切),第一层因为分句开头是阳性
    /// 物质而不会触发,靠 `parse_allergy_item` 自带的条目级否定检查(第二道防线)
    /// 挡住否定的那一半。
    #[test]
    fn allergy_positive_and_negation_sharing_one_clause() {
        let pairs = extract_allergies_pairs("过敏史:青霉素过敏,否认食物过敏");
        assert_eq!(pairs.len(), 1, "实际={pairs:?}");
        assert_eq!(pairs[0].0, "青霉素过敏");
    }

    /// `未见`/`(-)`/`（-）` 是 否认 之外常见的否定写法。
    #[test]
    fn allergy_negation_prefix_variants() {
        assert!(extract_allergies_pairs("过敏史:未见明确食物、药物过敏史。").is_empty());
        assert!(extract_allergies_pairs("过敏史:(-)").is_empty());
        assert!(extract_allergies_pairs("过敏史:（-）").is_empty());
    }

    /// #65:物质名恰好以「无」开头(无花果,即无花果)不能被「无」否定检查
    /// 误伤。「无」是不是否定词要看它后面接的词,不是看它本身——见
    /// `is_allergy_negation`/`WU_NEGATION_CONTINUATIONS` 上的注释,那里也写了
    /// 为什么这张白名单宁可漏收也不要贪多(假阳性可见可质疑,假阴性会让真实
    /// 过敏原从卡片上无声消失)。同 `handoff::allergy_wu_prefix_is_not_blanket_negation`,
    /// 验的是这份手抄副本。
    #[test]
    fn allergy_wu_prefix_is_not_blanket_negation() {
        assert_eq!(
            extract_allergies_pairs("过敏史:无花果过敏。"),
            vec![("无花果过敏".to_string(), String::new())],
            "无花果过敏是阳性条目,「无」在这里是物质名的一部分"
        );
        for negated in [
            "过敏史:无。",
            "过敏史:无殊。",
            "过敏史:无特殊。",
            "过敏史:无过敏史。",
            "过敏史:无明确过敏史。",
            "过敏史:无药物过敏史。",
            "过敏史:无明显过敏史。",
            "过敏史:无已知过敏史。",
            "过敏史:无食物过敏史。",
            "过敏史:无其他过敏史。",
        ] {
            assert_eq!(
                extract_allergies_pairs(negated),
                Vec::<(String, String)>::new(),
                "应判否定:{negated}"
            );
        }
    }

    /// ②「不详」类:宁缺,不产出条目,但不是否定词(见 `ALLERGY_UNCLEAR_MARKERS`
    /// 上的注释)。同 `handoff::allergy_unclear_markers_produce_no_item`。
    #[test]
    fn allergy_unclear_markers_produce_no_item() {
        for unclear in [
            "过敏史:不详。",
            "过敏史:过敏史不详。",
            "过敏史:不知。",
            "过敏史:未知。",
            "过敏史:不清楚。",
        ] {
            assert_eq!(
                extract_allergies_pairs(unclear),
                Vec::<(String, String)>::new(),
                "「不详」类应当宁缺,不产出条目:{unclear}"
            );
        }
        assert_eq!(
            extract_allergies_pairs("过敏史:青霉素过敏,过敏史不详。"),
            vec![("青霉素过敏".to_string(), String::new())],
        );
    }

    /// 上面那条是手写合成文本;这条改用示例数据集里的**真实文档**原文
    /// (`include_str!` 直接读 `packages/parser` 的 corpus fixture,与
    /// `corpus_summary.rs` 用的是同一份,不是抄一遍手打)。
    ///
    /// 动机:应急卡「过敏史」一节是这一屏唯一「用错会当场出事」的信息(见
    /// `emergency_card_screen.dart` 顶部文档),而这份 `extract_allergies_pairs`/
    /// `parse_allergy_item` 是从 `packages/parser::handoff` **手工抄一遍**维护的
    /// 独立副本(见上面「过敏史」小节的注释),此前从未拿真实文档验过 —— 只有
    /// 合成单测。加示例数据集第 21 份文档(`2026-07-15_出院记录_冠脉支架术后.txt`,
    /// 张建国冠脉支架术后出院记录)时顺带补上这一条,同时验证阳性(磺胺类药物,
    /// 标准的「物质(反应)」写法)与阴性(食物及其他药物,标准的「否认…」写法)
    /// 两条,分属过敏史段落里的两个分句 —— 与 `corpus_summary.rs` 里
    /// `allergy_history_is_extracted_from_a_real_document` 验的是同一份原文,
    /// 这里额外确认了应急卡自己那份独立实现给出相同结果。
    #[test]
    fn allergies_from_the_real_demo_discharge_summary() {
        const REAL_DOC: &str = include_str!(
            "../../../../../packages/parser/tests/fixtures/corpus/2026-07-15_出院记录_冠脉支架术后.txt"
        );
        let docs = docs_from(&[(REAL_DOC, Some("2026-07-20"), "discharge_summary")]);
        let allergies = collect_allergies(&docs);

        let sulfa = allergies
            .iter()
            .find(|a| a.substance == "磺胺类药物")
            .unwrap_or_else(|| panic!("磺胺类药物 not extracted; got {allergies:?}"));
        assert_eq!(sulfa.reaction, "皮疹史");
        assert_eq!(sulfa.document_ids, vec![100]);

        // 「否认食物及其他药物过敏史」不该产出第二条 —— 抽错成阳性是反向的
        // 安全事故(应急救援者被卡片误导,以为病人对某样东西过敏)。
        assert_eq!(allergies.len(), 1, "实际={allergies:?}");
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
            values_converted: false,
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

    /// **缺陷钉子(2026-08-05):「复制给医生」的纯文本印出单位不一致的一对数。**
    ///
    /// 缺陷原样是 `Hemoglobin 120 g/L N [参考 11-16]` —— 值换算过、区间没有。医生
    /// 读到的是一个自相矛盾的句子。
    ///
    /// 产品负责人定的方向:显示回到用户那张纸上印的样子。所以这一行的值、单位、
    /// 参考区间三者都取印刷套。医生要能跟患者递过来的化验单逐字对上;跨院比较用的
    /// 规范套仍在 `AnalyteSeries::*_canonical`(见 `aggregate.rs` 的表)。
    #[test]
    fn doctor_plain_text_prints_one_coherent_unit_per_lab_line() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let home = tempfile::tempdir().unwrap();
        crate::api::vault::open_vault(
            home.path().join("docs").to_string_lossy().to_string(),
            home.path().join("data").to_string_lossy().to_string(),
            None,
        )
        .unwrap();

        // 一份完全正常的报告,印的是 mg/dL。
        let text = "生化检验报告单\n检验日期 2026-08-01\n肌酐: 1.2 mg/dL (参考 0.6-1.3)\n";
        crate::api::vault::ingest_bytes("化验单.txt".into(), text.as_bytes().to_vec()).unwrap();

        let visit = view_visit_summary().unwrap();
        let cr = visit
            .recent_labs
            .iter()
            .find(|l| l.name == "肌酐")
            .expect("最近化验里应有 肌酐");
        assert_eq!(cr.value, 1.2, "医生看到的必须是纸上那个数");
        assert_eq!(cr.unit.as_deref(), Some("mg/dL"));
        assert_eq!((cr.ref_low, cr.ref_high), (Some(0.6), Some(1.3)));
        assert!(!cr.values_converted);
        // 值落在区间内 —— 与 flag 同一个结论,任何下游重算都不会翻脸。
        assert!(cr.value >= cr.ref_low.unwrap() && cr.value <= cr.ref_high.unwrap());
        assert_eq!(cr.flag.as_deref(), Some("N"));

        assert!(
            visit.plain_text.contains("肌酐 1.2 mg/dL N [参考 0.6-1.3]"),
            "纯文本里值与区间必须同单位;实际:\n{}",
            visit.plain_text
        );
        assert!(
            !visit.plain_text.contains("106.104"),
            "规范单位的值不该出现在给医生的纯文本里(那张纸上没有这个数):\n{}",
            visit.plain_text
        );
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
        // 「我最近的变化」:这份化验单自己印了 `H`,不是系统编的诊室切点,该出现。
        assert!(
            visit
                .recent_changes
                .iter()
                .any(|l| l.name == "糖化血红蛋白" && l.flag.as_deref() == Some("H")),
            "带 H 标记的化验该出现在「我最近的变化」里,实际={:?}",
            visit.recent_changes
        );
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

        // 「我最近的变化」:自测那条(self_measured)该在场。医院那条这里没有印
        // 参考区间(`收缩压 140 mmHg`,没有跟着的 ref range),系统不替它编一个
        // 诊室切点,所以 flag 是 None、不进这一节——"异常标记带来的可见性"这半条
        // 规则由 `end_to_end_over_a_real_vault` 里印了 `H` 的化验单来钉。
        assert!(
            visit
                .recent_changes
                .iter()
                .any(|l| l.self_measured && l.value == 128.0),
            "自测收缩压该出现在「我最近的变化」里,实际={:?}",
            visit.recent_changes
        );
    }

    /// 「我最近的变化」不能从已经砍到 [`VISIT_SUMMARY_MAX_LABS`] 条的全量列表里筛——
    /// 天天量的自测值很容易被更晚一次的医院化验挤出前 8 名。这条测试构造出正是
    /// 这个挤出场景,钉住 `recent_changes` 绕过了这次截断(见
    /// [`VisitSummaryDto::recent_changes`] 文档)。
    #[test]
    fn recent_changes_are_not_crowded_out_by_a_full_page_of_later_hospital_labs() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let home = tempfile::tempdir().unwrap();
        crate::api::vault::open_vault(
            home.path().join("docs").to_string_lossy().to_string(),
            home.path().join("data").to_string_lossy().to_string(),
            None,
        )
        .unwrap();

        // 8 月 1 日量了一次心率(自测)。
        crate::api::vault::add_self_measurement(
            vec![SelfMeasuredValueDto {
                analyte_key: "heart_rate".into(),
                value: 88.0,
                unit: "/min".into(),
            }],
            Some("2026-08-01T08:00:00Z".into()),
        )
        .unwrap();

        // 之后医院又做了 [`VISIT_SUMMARY_MAX_LABS`] 项不同的化验,每项各自成一条独立
        // 序列,日期全部晚于自测那次——足够把自测心率挤出全量列表的前 8 名。
        // 名字用汉字序数区分(甲乙丙……),不用阿拉伯数字直接拼在名字后面——名字
        // 与后面的数值之间没有分隔符时,数字会被"未收录指标7 8.0"这类行读成同一个
        // 原始名字丢了尾号,8 项因此在 `GroupKey::Raw` 上全部撞成一条线。
        const LABELS: [&str; VISIT_SUMMARY_MAX_LABS] =
            ["甲", "乙", "丙", "丁", "戊", "己", "庚", "辛"];
        for (i, label) in LABELS.iter().enumerate() {
            let text = format!(
                "生化检验报告单\n检验日期 2026-08-{:02}\n未收录指标{label} {}.0 mmol/L\n",
                10 + i,
                i + 1,
            );
            crate::api::vault::ingest_bytes(format!("化验{i}.txt"), text.into_bytes()).unwrap();
        }

        let visit = view_visit_summary().unwrap();
        assert_eq!(
            visit.recent_labs.len(),
            VISIT_SUMMARY_MAX_LABS,
            "全量列表仍按原样截断(喂纯文本用,这条行为不该变)"
        );
        assert!(
            !visit.recent_labs.iter().any(|l| l.name == "心率"),
            "本测试要先确认挤出场景成立:8 条更晚的医院化验应该已经把自测心率挤出\
             全量列表,不然下面对 recent_changes 的断言就验证不了任何东西"
        );
        assert!(
            visit
                .recent_changes
                .iter()
                .any(|l| l.name == "心率" && l.self_measured),
            "「我最近的变化」不该受全量列表截断影响,自测心率必须仍在场,实际={:?}",
            visit.recent_changes
        );
    }

    /// 化验单上印着表示**正常**的记号(常见 `N`)时,那一条不是「变化」。
    ///
    /// 真机上撞到过:低密度脂蛋白胆固醇 2.75(参考 ≤3.37)印着 `N`,而当时的判据
    /// 是 `flag.is_some()`——「单子上印了个记号」被当成了「异常」,一条明确正常的
    /// 化验因此出现在「我最近的变化」里。判据应与 `aggregate.rs` 的 `abnormal`
    /// 一致:只认 `H`/`L`。
    ///
    /// 注意 `N` 本身仍要**原样显示**成中性 pill(见 `lab_status.dart` 文件头:认不出
    /// 的记号不吞)。这里管的只是「进不进这一节」,不是「显不显示那个记号」。
    #[test]
    fn a_lab_printed_with_a_normal_marker_is_not_a_recent_change() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let home = tempfile::tempdir().unwrap();
        crate::api::vault::open_vault(
            home.path().join("docs").to_string_lossy().to_string(),
            home.path().join("data").to_string_lossy().to_string(),
            None,
        )
        .unwrap();

        crate::api::vault::ingest_bytes(
            "生化.txt".into(),
            "生化检验报告单\n检验日期 2026-08-01\n\
             低密度脂蛋白胆固醇 2.75 mmol/L 0.00-3.37 N\n\
             甘油三酯 2.90 mmol/L 0.00-1.70 H\n"
                .into(),
        )
        .unwrap();

        let visit = view_visit_summary().unwrap();

        // 先确认场景成立:`N` 确实被读成了 flag,否则下面的断言什么都验证不了。
        let ldl = visit
            .recent_labs
            .iter()
            .find(|l| l.name.contains("低密度脂蛋白"))
            .expect("全量化验里应有低密度脂蛋白胆固醇");
        assert_eq!(
            ldl.flag.as_deref(),
            Some("N"),
            "本测试的前提是 `N` 被当成 flag 读了进来;它没进来的话这条测试是假绿的"
        );

        assert!(
            !visit
                .recent_changes
                .iter()
                .any(|l| l.name.contains("低密度脂蛋白")),
            "印着 `N`(正常)的化验不该出现在「我最近的变化」里,实际={:?}",
            visit.recent_changes
        );
        assert!(
            visit
                .recent_changes
                .iter()
                .any(|l| l.name.contains("甘油三酯")),
            "同一份单子上印着 `H` 的那条该在,不然就是把整节筛空了,实际={:?}",
            visit.recent_changes
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

        let note_id = crate::api::vault::add_note(
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

        // 但笔记本身仍然是一份可见文档(时间线/档案里看得到)——`recent_visits`
        // (结构化字段,概览「最近归档」用的就是它)里应该出现这条记录。不能拿
        // `kind == "note"` 判断:一份孤零零的笔记会被 `load_archive` 的就诊分组包成
        // 它自己单份的"门诊"就诊组,`kind` 因此是 `"outpatient"`;真正的判断是看
        // 这条记录涵盖的文档 id 里有没有笔记自己的 id。
        let visit = view_visit_summary().unwrap();
        assert_eq!(visit.patient.record_count, 1);
        assert!(
            visit
                .recent_visits
                .iter()
                .any(|v| v.document_ids.contains(&note_id)),
            "笔记该出现在 recent_visits 里(概览「最近归档」复用这个字段),实际={:?}",
            visit.recent_visits
        );
    }

    /// 笔记是患者自由文本,不是从病历原文抽出的内容——不该出现在「复制给医生」的
    /// 纯文本里(会被当成病历内容读),但要出现在 `recent_notes`(「我想问医生的」
    /// 这一节专用,只给患者自己看)。见 [`VisitNoteDto`] 文档。
    #[test]
    fn notes_never_enter_the_doctor_facing_plain_text_but_do_enter_recent_notes() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let home = tempfile::tempdir().unwrap();
        crate::api::vault::open_vault(
            home.path().join("docs").to_string_lossy().to_string(),
            home.path().join("data").to_string_lossy().to_string(),
            None,
        )
        .unwrap();

        let note_id_1 = crate::api::vault::add_note(
            "问王医生片子的事".into(),
            Some("2026-07-20T09:00:00Z".into()),
        )
        .unwrap();
        let note_id_2 =
            crate::api::vault::add_note("今天有点头晕".into(), Some("2026-08-01T09:00:00Z".into()))
                .unwrap();
        // 一份真正的就诊记录,验证过滤掉笔记不会连真实就诊也一起过滤掉。
        crate::api::vault::ingest_bytes(
            "出院小结.txt".into(),
            "出院小结\n出院日期 2026-06-01\n出院诊断:高血压\n".into(),
        )
        .unwrap();

        let visit = view_visit_summary().unwrap();

        // ── recent_notes:两条都在,按记录时间倒序,原文逐字 ──
        assert_eq!(visit.recent_notes.len(), 2, "实际={:?}", visit.recent_notes);
        assert_eq!(
            visit.recent_notes[0].text, "今天有点头晕",
            "应按日期倒序,最新的在前"
        );
        assert_eq!(visit.recent_notes[0].date.as_deref(), Some("2026-08-01"));
        assert_eq!(visit.recent_notes[1].text, "问王医生片子的事");

        // ── plain_text:两条笔记的原文都不该出现 ──
        assert!(
            !visit.plain_text.contains("问王医生片子的事"),
            "笔记不该出现在复制给医生的文本里,实际:\n{}",
            visit.plain_text
        );
        assert!(
            !visit.plain_text.contains("今天有点头晕"),
            "笔记不该出现在复制给医生的文本里,实际:\n{}",
            visit.plain_text
        );
        // 真实的就诊记录应该照常出现在【最近就诊】里,证明过滤对象是笔记本身,
        // 不是整节内容。用日期而不是"出院"这个词断言——就诊组的 `kind` 是
        // `load_archive` 按启发式判的,不保证是"住院"(实测这份出院小结被归到了
        // "门诊"),不是本测试要钉的东西,这里只关心"这份真实记录没被连坐滤掉"。
        assert!(
            visit.plain_text.contains("2026-06-01"),
            "过滤笔记不该连真实就诊也一起滤掉,实际:\n{}",
            visit.plain_text
        );

        // ── recent_visits(结构化字段,给概览「最近归档」用):两条笔记的 id 仍都
        // 在场,不受这次「复制给医生」的过滤影响。不能用 `kind == "note"` 数——
        // 见 `note_never_becomes_a_condition_or_a_lab_series` 里的同一条注释。
        let visible_doc_ids: BTreeSet<i64> = visit
            .recent_visits
            .iter()
            .flat_map(|v| v.document_ids.iter().copied())
            .collect();
        assert!(
            visible_doc_ids.contains(&note_id_1) && visible_doc_ids.contains(&note_id_2),
            "recent_visits 不该被这次改动过滤,概览「最近归档」需要看到笔记,实际={:?}",
            visit.recent_visits
        );
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
