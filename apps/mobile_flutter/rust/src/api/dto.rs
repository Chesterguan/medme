//! FRB 友好的 DTO,直接经 `flutter_rust_bridge` 生成对应 Dart class,供
//! `api::vault` 里的全量 vault API 使用。逐字段镜像 Tauri 移动端的
//! `apps/mobile/src-tauri/src/dto.rs`(同一批字段/同一批类型),只是去掉了
//! `serde::Serialize`——FRB 直接从这些 plain struct/enum 生成绑定,不经 JSON。
use core_model::{Document, Encounter, SourceFile};

/// iCloud 同步状态(设置页开关据此渲染)。`available` = 当前能否解析到 iCloud
/// 容器(iOS-only,由 Dart 侧经 `medme/icloud` MethodChannel 判断后覆盖;Rust
/// 恒返回 false);`enabled` = 本设备是否已开启同步(Rust 据持久标记返回)。
/// 开关/迁移逻辑见 `api::vault` 的 `enable_icloud_sync` / `disable_icloud_sync`。
#[derive(Debug, Clone)]
pub struct IcloudStatusDto {
    pub available: bool,
    pub enabled: bool,
}

/// 「载入示例数据」的进度回报(`api::vault::load_demo_data` 经 `StreamSink` 逐份
/// 推给 Dart)。真机实测过全程 11 秒零反馈——不是慢,是安卓那次 22 份的循环里
/// Dart 侧原来只等一个 `Future`,中途没有任何信号可渲染。这里补一个流,让设置屏
/// 能画「正在载入 N/total」而不是一个不知道在不在跑的忙态。
///
/// **`error` 而不是让整个函数返回 `Err`**:FRB 里带 `StreamSink` 参数的函数,
/// Dart 侧签名会整个折成 `Stream<T>`——函数自身的 `Result` 只用来标记这一次
/// FFI 调用本身,`load_demo_data` 内部通过 `unawaited(...)` 发起,没有代码
/// `await` 它,一旦真返回 `Err` 就是一次悄悄丢失、连 Dart 的 `try/catch` 都接不住
/// 的异常(本工单要修的正是「失败静默不可见」,不能在同一次改动里换个地方复发)。
/// 所以 `load_demo_data` 恒返回 `Ok(())`,任何失败(保险箱未打开、磁盘写入失败等)
/// 都经这个 `error` 字段随流报出来,Dart 侧照常能 `catch`。
#[derive(Debug, Clone)]
pub struct DemoLoadProgressDto {
    /// 已处理(尝试过,含失败)的份数;发生 `error` 时为 0。
    pub loaded: i64,
    /// 总份数;发生 `error` 时为 0(还没来得及数出总数就失败了)。
    pub total: i64,
    /// 到目前为止成功入库的份数(累计)。
    pub succeeded: i64,
    /// 整个操作失败的原因;正常进行中/正常完成为 `None`。
    pub error: Option<String>,
}

#[derive(Debug, Clone)]
pub struct DocumentSummaryDto {
    pub id: i64,
    pub doc_type: String,
    pub doc_date: Option<String>,     // RFC3339
    pub doc_date_end: Option<String>, // RFC3339
    pub title: Option<String>,
    pub page_count: i32,
    /// 影像检查文档的切片数;非影像文档为 None。
    pub slice_count: Option<i32>,
}
impl From<&Document> for DocumentSummaryDto {
    fn from(d: &Document) -> Self {
        DocumentSummaryDto {
            id: d.id,
            doc_type: d.doc_type.as_str().to_string(),
            doc_date: d.doc_date.map(|x| x.to_rfc3339()),
            doc_date_end: d.doc_date_end.map(|x| x.to_rfc3339()),
            title: d.title.clone(),
            page_count: d.page_count,
            slice_count: None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct EncounterSummaryDto {
    pub id: i64,
    pub kind: String, // inpatient|outpatient|emergency|exam
    pub provider: Option<String>,
    pub start_date: Option<String>,
    pub end_date: Option<String>,
    pub title: Option<String>,
    pub transferred: bool,
    pub doc_count: i64,
}
impl EncounterSummaryDto {
    // `pub(crate)`, not `pub`: an inherent `pub fn` here would get picked up by FRB's
    // scanner as an exposed API method (it scans `crate::api` for pub symbols,
    // including inherent impl methods, not just free functions in `vault.rs`) and
    // then choke on `&Encounter` (a plain core-model type, not one of our mirrored
    // DTOs) as an unresolvable opaque type. `pub(crate)` keeps it a normal internal
    // helper, reachable from `api::vault`, invisible to codegen.
    pub(crate) fn from_encounter(e: &Encounter, doc_count: i64) -> Self {
        EncounterSummaryDto {
            id: e.id,
            kind: e.kind.as_str().to_string(),
            provider: e.provider.clone(),
            start_date: e.start_date.map(|x| x.to_rfc3339()),
            end_date: e.end_date.map(|x| x.to_rfc3339()),
            title: e.title.clone(),
            transferred: e.transferred,
            doc_count,
        }
    }
}

/// `load_archive` 返回的分组:就诊组 或 独立文档(与桌面/Tauri 移动端的
/// `TimelineGroup` 同构)。
#[derive(Debug, Clone)]
pub enum TimelineGroupDto {
    Encounter {
        encounter: EncounterSummaryDto,
        docs: Vec<DocumentSummaryDto>,
    },
    Document {
        doc: DocumentSummaryDto,
    },
}

/// 原始文件元信息(文档详情页展示来源 + 前端据此判断是否为图片以渲染缩略)。
#[derive(Debug, Clone)]
pub struct SourceFileMetaDto {
    pub id: i64,
    pub original_name: String,
    pub mime_type: String,
    pub byte_size: i64,
    pub imported_at: String,
}
impl From<&SourceFile> for SourceFileMetaDto {
    fn from(s: &SourceFile) -> Self {
        SourceFileMetaDto {
            id: s.id,
            original_name: s.original_name.clone(),
            mime_type: s.mime_type.clone(),
            byte_size: s.byte_size,
            imported_at: s.imported_at.to_rfc3339(),
        }
    }
}

/// 文档详情:类型/日期(在 document 里)+ 来源文件 + 识别文本 + 还缺哪几页。
#[derive(Debug, Clone)]
pub struct DocumentDetailDto {
    pub document: DocumentSummaryDto,
    pub source_file: SourceFileMetaDto,
    pub ocr_text: String,
    pub ocr_confidence: Option<f32>,
    pub ocr_backend: Option<String>,
    /// 这份文档里**至今没有任何识别文字**的页码(1-based,升序)。
    ///
    /// 为什么详情页需要这个:漏页这件事此前**只在导入那一刻的结果框里说过一次**
    /// ——「已识别入库,但 3 页未能识别文字」。那个框一关,信息就永远消失了:
    /// 详情页不显示、档案列表不显示,用户过一周再打开这份文档,看到的是一份
    /// 「正常」的病历,而里面有 3 页是空的。他不会知道要去补,也不会知道医生
    /// 看到的摘要少了那几页的内容。
    ///
    /// 现查现算(`page_count` 减去 `ocr_result` 里已有的页),不是把导入时的
    /// 结论存下来 —— 因为那个结论会过期:#193 之后「再导一次同一份文件」会补页,
    /// 端上的按页回填也会补页,存下来的旧值只会骗人。
    pub pages_without_text: Vec<i32>,
}

#[derive(Debug, Clone)]
pub struct ImportOutcomeDto {
    pub name: String,
    pub source_file_id: i64,
    pub status: String, // new|backfilled|deduped|stored_no_text|instance_attached|failed
    pub doc_type: Option<String>,
    /// 本次采集落库的文档 id(前端「待确认」review 队列据此显式标记新导入)。
    /// 去重/失败等没建文档的情况为 None。
    pub document_id: Option<i64>,
    /// 从本份报告文本里识别出的**患者姓名**(`parser::extract_demographics`)。
    /// 前端用它和当前成员档案名字比对——不一致就在「待确认」里标红警告(防导错人)。
    /// 识别不到为 None。
    pub detected_name: Option<String>,
    /// PDF 专属(其他文件类型恒为空):1-based 页码,列出既没有文本层、也没能
    /// 在落库时 OCR 出文字的页(移动端未链接 Rust OCR 引擎,这里几乎总是非空的
    /// "待处理"清单)。前端**必须**据此显式提示用户,不能让人以为整份 PDF 都
    /// 识别完了——这正是"混合页 PDF 静默丢数据"缺陷的修复点(见
    /// `pipeline::ingest_pdf` 文档注释)。`import_flow.dart` 用它驱动逐页 OCR
    /// 回填(`backfillPdfText`),回填后仍剩的页数进导入汇总弹窗。
    pub pages_without_text: Vec<i32>,
}

/// 一次「记录」(手动录入)里的一个数值 —— 血压一次记录有两个(收缩压+舒张压,
/// 共享同一份文档/`measuredAt`,见 `add_self_measurement` 的文档),其余四项各
/// 一个。`analyteKey`/`unit` 都是 `terminology` 词典里现成的规范键/单位
/// (`bp_systolic`/`bp_diastolic`/`heart_rate`/`body_weight`/`body_temperature`/
/// `glucose`,单位分别是 mmHg/mmHg/`/min`/kg/Cel/mmol/L)——Dart 侧只从封闭的
/// 五选一录入界面产出这个结构,不接受任意字符串(硬约束:不做手打化验值)。
/// 与 `parser::SelfMeasuredValue` 逐字段镜像,只是换成 FRB 能生成绑定的 plain
/// struct(见本文件头的取舍)。
#[derive(Debug, Clone)]
pub struct SelfMeasuredValueDto {
    pub analyte_key: String,
    pub value: f64,
    pub unit: String,
}

/// **iOS PP-OCRv5 测试路径**结果(feat/ios-pp-ocr-test 分支,探索性——ADR 0005
/// 尚未 supersede)。镜像 Dart `OcrResult`(`ocr_bridge.dart`),供
/// `recognize_image_pp` 返回,让真机能对比 Apple Vision vs PP-OCRv5 的识别质量。
#[derive(Debug, Clone)]
pub struct OcrPpResultDto {
    pub text: String,
    pub confidence: f32,
}

/// 认领结果:医生代拍的包被还原进本机保险箱之后,各类记录各有几份。
///
/// `deduped` 不是错误 —— 病人重复点同一条认领链接是常事,内容哈希会挡住,
/// UI 该说「已经在你的档案里了」而不是报错。`text_only` 则要如实告诉用户:
/// 这几份只还原了文字,原件没跟过来。
#[derive(Debug, Clone)]
pub struct ClaimResultDto {
    pub imported: i64,
    pub deduped: i64,
    pub text_only: i64,
}

/// 加密分享生成结果:口令(单独告知医生)、记录数、文件字节数、分享文件路径。
#[derive(Debug, Clone)]
pub struct ShareResultDto {
    pub passphrase: String,
    pub record_count: i64,
    pub byte_size: i64,
    pub path: String,
}

/// 二维码分享结果:一条可直接编码成二维码的 URL、带上的疾病数、以及是否仍在
/// 二维码容量内(按构造裁剪后应恒为 true,留作兜底提示)。
#[derive(Debug, Clone)]
pub struct QrShareDto {
    pub url: String,
    pub problem_count: i64,
    pub fits_qr: bool,
}

/// 时间线导出结果:未加密、可打印的自包含 HTML。与 `ShareResultDto` 不同,
/// 没有口令——导出内容不加密,靠系统「分享」sheet 直接交给医生 / 存下来打印。
#[derive(Debug, Clone)]
pub struct ExportResultDto {
    pub record_count: i64,
    pub byte_size: i64,
    pub path: String,
}

#[derive(Debug, Clone)]
pub struct PatientProfileDto {
    pub name: Option<String>,
    pub gender: Option<String>,
    pub birth_date: Option<String>,
    pub age: Option<String>,
    pub record_count: i64,
}

/// 拍前同意记录(医生代拍病人纸质材料流程):病人同意的方式(手写签名 / 按住
/// 确认)、时刻、文案版本。由 `screens/doctor/consent_screen.dart` 产出,经
/// `api::vault_ephemeral::ephemeral_create_share` 转换成
/// `medme_share::share::ShareConsent` 塞进加密分享包(见该函数的 `From` 实现)。
#[derive(Debug, Clone)]
pub struct ConsentDto {
    /// 同意时刻(UTC RFC3339)。
    pub utc_ts: String,
    /// 同意告知文案的版本号(见 `consent_screen.dart` 的 `kConsentTextVersion`)。
    pub consent_text_version: String,
    /// 手写签名 PNG 的 base64;按住确认(无签名图像)时为 `None`。
    pub signature_png_base64: Option<String>,
    /// "signature" | "press_hold"。
    pub method: String,
    /// 本次临时会话的人类可读标识,供医生/病人事后核对「哪一次代建档」
    /// (不是安全边界——临时会话的一次性随机 device_id 才是,见 `vault_ephemeral.rs`)。
    pub session_id: String,
}

/// 「病情摘要卡」(医生代拍审阅屏,选项 b):在治的病 + 关键化验 + 在用药,
/// 三十秒看懂大局。由 `api::vault_ephemeral::ephemeral_summary` 产出——把
/// `parser::assemble_summary` 的通用 `serde_json::Value`(查看器/加密分享用的同一份
/// 装配逻辑)映射成 FRB 能直接生成 Dart 绑定的定型结构。**不做 QR 分享那种带宽裁剪**
/// (`medme_share::qr::trim_summary` 的 `max_problems`/`active_meds_only` 等是为
/// 二维码容量服务的,审阅屏要的是「拍了什么就看到什么」的完整核对,不是带宽约束)——
/// 唯一的裁剪是每条化验只保留最近 4 个点,与 `notable_changes`/QR 默认档同一惯例
/// (给「趋势一眼」用,不是画完整图表)。
#[derive(Debug, Clone)]
pub struct ProxySummaryDto {
    pub problems: Vec<ProxyProblemDto>,
}

/// 一条在治问题:名字 + 状态,嵌套它的关键化验与在用药。
#[derive(Debug, Clone)]
pub struct ProxyProblemDto {
    pub term: String,
    /// "在管" | "需关注" | "其他"(未挂上具体疾病的化验/用药落这个桶,见
    /// `parser::handoff::assemble_summary` 的「其他」bucket)。
    pub status: String,
    pub warn: bool,
    pub labs: Vec<ProxyLabDto>,
    pub meds: Vec<ProxyMedDto>,
}

/// 一条化验序列:最近值 + 趋势 + 最近几个点(≤4,时间升序)。没有任何带日期的点
/// (`assemble_summary` 的 `pts` 只保留带日期的观测)时不产出——审阅屏没法从中读出
/// 「最近值」,原始识别文字仍在下方「逐份识别内容」区块里,不丢信息。
#[derive(Debug, Clone)]
pub struct ProxyLabDto {
    pub name: String,
    pub unit: Option<String>,
    pub latest_value: f64,
    pub ref_high: Option<f64>,
    pub ref_low: Option<f64>,
    /// "up" | "down" | "flat" | "single"(只有一个带日期的点,不足以判断趋势)。
    pub trend: String,
    pub recent_points: Vec<ProxyLabPointDto>,
}

#[derive(Debug, Clone)]
pub struct ProxyLabPointDto {
    /// "YYYY-MM"。
    pub month: String,
    pub value: f64,
}

/// 一条在用药:名 + 最近一次提到的剂量(若识别到)+ 是否在用。字段名 `active`
/// 而不是 `assemble_summary` json 里的 `on`——后者是 Dart 的保留字上下文关键字,
/// FRB codegen 会把它改名成 `on_`,不如从 Rust 侧就用一个干净的名字。
#[derive(Debug, Clone)]
pub struct ProxyMedDto {
    pub name: String,
    pub dose: Option<String>,
    pub active: bool,
}

/// 一份文档当前的「已确认」状态(医生代拍待确认列表)。**不**塞进共享的
/// `DocumentSummaryDto`(`vault.rs` 的正常病人档案列表也用它,这个状态只对医生
/// 代拍流程有意义)——待确认列表屏用 `document_id` 把这份状态与
/// `ephemeral_load_preview` 返回的文档列表在 Dart 侧做本地映射。由
/// `api::vault_ephemeral::ephemeral_confirmed_map` 产出。
#[derive(Debug, Clone)]
pub struct ConfirmedStatusDto {
    pub document_id: i64,
    pub confirmed: bool,
}
