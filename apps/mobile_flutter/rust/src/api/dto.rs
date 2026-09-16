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
    /// 云抽取(`extraction` 表,schema v6)读出的条目数,**三态**:
    /// `None` = 还没跑过 / 被拒发 / 离线;`Some(0)` = 跑过了,一条都没读出来;
    /// `Some(n)` = 读出 n 条。
    ///
    /// 前端(`doc_labels.dart` 的 `docRowLabel`)靠它区分「待归类」的两种成因:
    /// 还没轮到 vs 整理过但白跑。原先两种都显示「待归类」,用户看到的是一份
    /// 永远停在待归类的文档,分不清是还在跑还是失败了(冒烟 friction 2)。
    pub extraction_item_count: Option<i32>,
    /// 这份病历上印的**机构名**(「北京协和医院」),取自它自己的 OCR 文本,用的是
    /// `extract_provider_clean` —— 就诊组头上那个 `extract_provider` 的**不带噪**变体
    /// (页脚签名切不准时它返回 `None`,而不是「王涛北京协和医院」)。
    /// 文档里确实没有机构(自测记录、笔记)时也是 `None` —— 编一个院名比空着糟。
    ///
    /// 存在的理由:`document` 表里没有这一列,而档案行此前显示的是
    /// `image_picker_….jpg`。前端(`doc_labels.dart` 的 `docDisplayTitle`)拿它
    /// 拼出「协和医院 · 化验」,不用再把一个临时文件名端给用户看。
    pub provider: Option<String>,
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
            extraction_item_count: None,
            provider: None,
        }
    }
}

/// 一份云抽取结果 JSON 里「读出了多少条」。labs/meds/diagnoses 各算一条,
/// `impression` 非空再算一条 —— 只给了一句印象也是读出了内容,报 0 就是在
/// 对用户说谎。
///
/// JSON 解析不出来(格式不对/被拒收/老 schema)同样返回 0:抽取确实跑过,
/// 但没产出任何能用的东西,下游 `parser` 那边也一样会退回正则。
fn extraction_item_count(json: &str) -> i32 {
    let Ok(e) = deid::parse_extraction(json) else {
        return 0;
    };
    let n = e.labs.len() + e.meds.len() + e.diagnoses.len();
    (n + usize::from(!e.impression.trim().is_empty())) as i32
}

/// 时间线/档案列表用的文档摘要:影像 study 补切片数,再补云抽取条目数。
///
/// `vault.rs` 与 `vault_ephemeral.rs` 原先各抄了一份逐字相同的实现;合并成这一份,
/// 免得下次加字段又只加在其中一边(医生预览时间线和病人档案列表就会不一致)。
pub(crate) fn doc_summary(v: &core_model::Vault, d: &Document) -> DocumentSummaryDto {
    let mut s = DocumentSummaryDto::from(d);
    if d.doc_type == core_model::DocType::ImagingReport {
        if let Ok(n) = v.imaging_instance_count(d.id) {
            if n > 0 {
                s.slice_count = Some(n as i32);
            }
        }
    }
    s.extraction_item_count = v
        .extraction_json(d.id)
        .ok()
        .flatten()
        .map(|j| extraction_item_count(&j));
    // ponytail: 每份文档读一次全文再跑一遍正则(上面读 extraction_json 已经是每份
    // 一次查询)。档案列表撑到上千份还嫌慢的话,把院名在落库时算好存进
    // `document`——那是加一列 + 一次迁移,现在还不值得。
    s.provider = v
        .ocr_text(d.id)
        .ok()
        .as_deref()
        // `_clean`,不是带噪那个:标题抽不到院名还有「化验」顶着,不会塌 ——
        // 那就别把页脚签名里的审核医师名字当成这份病历的名字(见那边的文档)。
        .and_then(core_model::extract_provider_clean);
    s
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

/// 文档详情:类型/日期(在 document 里)+ 来源文件 + 识别文本。
#[derive(Debug, Clone)]
pub struct DocumentDetailDto {
    pub document: DocumentSummaryDto,
    pub source_file: SourceFileMetaDto,
    pub ocr_text: String,
    pub ocr_confidence: Option<f32>,
    pub ocr_backend: Option<String>,
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
    /// 每行的检测框(识别引擎 working frame 像素坐标,origin 左上)。云抽取
    /// 图片档脱敏靠它定位要涂黑的区域(`deid::redact_boxes`);文本档忽略。
    pub lines: Vec<OcrLineDto>,
    /// `lines` 所在那张 working frame 的宽高(像素)——识别引擎内部预处理(降采样/
    /// 90°摆正/去斜)之后的图,**不是原图尺寸**。调用 `vault_cloud_prepare_extraction`
    /// 时必须原样传这两个数作 `page_w`/`page_h`;传原始图片宽高会导致涂黑框整体
    /// 算错坐标系(静默漏涂 PHI),传原图尺寸这类明显不对的值不会有任何报错提示。
    pub frame_w: f32,
    pub frame_h: f32,
}

/// [`OcrPpResultDto::lines`] 的一行:文本 + 检测框。
#[derive(Debug, Clone)]
pub struct OcrLineDto {
    pub text: String,
    pub left: f32,
    pub top: f32,
    pub right: f32,
    pub bottom: f32,
}

/// 要涂黑的矩形(与 [`OcrLineDto`] 同一坐标系——同一次识别的 working frame)。
#[derive(Debug, Clone)]
pub struct RectDto {
    pub left: f32,
    pub top: f32,
    pub right: f32,
    pub bottom: f32,
}

/// `vault_cloud_prepare_extraction` 的产出:脱敏后待发云端的文本、要涂黑的框
/// (图片档,文本档为空)、还原映射(JSON,**永不离开手机**——只用来把云端结果里
/// 的占位符/偏移日期换回真值,见 `vault_cloud_commit_extraction`)。
#[derive(Debug, Clone)]
pub struct CloudExtractionRequestDto {
    pub payload_text: String,
    pub paint: Vec<RectDto>,
    pub restore_map_json: String,
}

/// `vault_cloud_commit_extraction` 的产出:这次落盘的化验条数、因未过校验被丢弃的
/// 条数(文本档)、未能校验但保留的条数(图片档,见 `deid::verify`)。
#[derive(Debug, Clone)]
pub struct CloudExtractionResultDto {
    pub labs: i64,
    pub rejected: i64,
    pub unverified: i64,
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

/// 「多张照片合并成一份」的结果(`api::vault::merge_photos_into_document`)。
/// 合成的 PDF 走与桌面上传扫描版 PDF 相同的入库路径,`pages_without_text` 与
/// `ImportOutcomeDto` 同一口径(1-based、没识别出文字的页)——`import_flow.dart`
/// 的既有回填逻辑(`backfillPagesWithoutText`)可以原样复用,不用另写一套。
#[derive(Debug, Clone)]
pub struct MergeOutcomeDto {
    /// 合并出的新文档 id——原来那几份各自的 id 已经不在库里了(墓碑掉了,原始
    /// 字节仍在 CAS,只是不再对应任何文档)。
    pub document_id: i64,
    pub page_count: i32,
    pub pages_without_text: Vec<i32>,
    /// 合并前源文档的份数(即调用方传入 `document_ids` 的长度),供前端汇总
    /// 文案「已合并 N 张为一份」。
    pub merged_count: i64,
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

/// 一条云同步事件的加密信封(`api::vault_sync::sync_export_events` 产出 /
/// `sync_import_events` 消费)。`device_id`/`seq` 明文携带(服务端按
/// `(device_id, seq)` 去重/排序、Dart 侧按 `device_seq_map` 过滤都不需要解密);
/// `ciphertext` 是整条 `core_model::LogEntry` 的 JSON 序列化经档案密钥 AEAD
/// 加密的结果(AAD = `device_id:seq`),真正敏感的内容(含本机真实的
/// `event_id` 与真实时间戳)都在这里面。**`event_id` 这个字段本身是服务端看到的
/// HMAC 马甲**(`sync::event_id_for_wire`),不是本机内容哈希——服务端只拿它当一个
/// 不透明校验值存,dedup 靠 `(device_id, seq)`;`sync_import_events` 不读这个字段。
///
/// **`ts` 恒为常量 `"0"`**(最终评审 I4):服务端排序从来只看
/// `(device_id, seq)`,而一串明文时间戳等于白送一条「这个人什么时候、多久一次
/// 产生病历事件」的时间线。真实 `ts` 在 `ciphertext` 里的 `LogEntry` 上,解密后
/// 原样恢复;`sync_import_events` 同样不读信封上的这个字段。
#[derive(Debug, Clone)]
pub struct SyncEventDto {
    pub device_id: String,
    pub seq: i64,
    pub event_id: String,
    pub ts: String,
    pub ciphertext: Vec<u8>,
}

/// `core_model::sync_io::PeerAppendOutcome` 的 FRB 镜像,外加 `undecodable`。
/// 五个计数不互斥,Dart 侧都要看:`applied`/`skipped_existing`/`out_of_order`
/// 是磁盘层面的去重/排序结果,`out_of_order` 提示调用方该把这个 device 的拉取
/// 水位下调重推;`untrusted` 是 MAC/链校验层面的隔离计数(错误账号密钥或被
/// 篡改),不看这个字段、只盯 `device_seq_map`(可信水位)会导致"越推越推不动"
/// 的死循环。`undecodable` 是 `sync_import_events` 自己这一层的计数(在交给
/// `append_peer_entries` 之前就没能解密/反序列化/信封校验通过的条目数,按设备
/// 只算撞到的第一条——见该函数文档),非零说明有台设备卡在了某条解不开的事件
/// 上,该设备后面还有条目排队等着,不是"已经全部同步完"。
#[derive(Debug, Clone)]
pub struct SyncImportOutcomeDto {
    pub applied: u32,
    pub skipped_existing: u32,
    pub out_of_order: u32,
    pub untrusted: u32,
    pub undecodable: u32,
}

#[cfg(test)]
mod tests {
    use crate::api::vault::VAULT_TEST_LOCK as TEST_LOCK;

    /// 档案行上的标题要能说出「在哪家医院」——而院名只印在纸上,`document` 表里
    /// 没有这一列。这里钉住 `doc_summary` 真的从这份文档自己的 OCR 文本里把它捞
    /// 出来(同 `rebuild_encounters` 给就诊组取 provider 的那个函数),而不是
    /// 让前端只能显示一个 `image_picker_xxx.jpg`。
    ///
    /// 第二份文档(自测记录那种没有机构的文本)必须是 `None` —— 编一个医院名比
    /// 空着糟得多。
    #[test]
    fn doc_summary_reads_the_hospital_off_the_documents_own_text() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let home = tempfile::tempdir().unwrap();
        crate::api::vault::open_vault(
            home.path().join("docs").to_string_lossy().to_string(),
            home.path().join("data").to_string_lossy().to_string(),
            None,
        )
        .unwrap();

        let with_provider = "北京协和医院\n生化检验报告单\n检验日期 2023-05-10\n\
糖化血红蛋白 7.1 % H 4-6.5\n";
        let without = "血压记录\n2023-05-11 收缩压 128 mmHg 舒张压 82 mmHg\n";
        let a = crate::api::vault::ingest_bytes(
            "image_picker_A1B2.txt".into(),
            with_provider.as_bytes().to_vec(),
        )
        .unwrap();
        let b = crate::api::vault::ingest_bytes("自测.txt".into(), without.as_bytes().to_vec())
            .unwrap();

        let by_id = |id: i64| {
            crate::api::vault::get_document(id)
                .unwrap_or_else(|e| panic!("读文档 {id} 失败:{e}"))
                .document
        };
        assert_eq!(
            by_id(a.document_id.expect("建了文档")).provider.as_deref(),
            Some("北京协和医院"),
        );
        assert_eq!(by_id(b.document_id.expect("建了文档")).provider, None);

        // 页脚签名那一串切不准(`审核者:王涛北京协和医院`)——**标题宁可不要院名**。
        // 就诊卡那条路仍然接受带噪(见 `core_model::extract_provider` 的取舍),
        // 这里走的是 `_clean`,两条路要的东西不一样。
        let signature_only = "血常规检验报告单\n检验日期 2023-05-12\n\
白细胞 6.1 10^9/L 3.5-9.5\n审核者:王涛北京协和医院医疗文书专用章\n";
        let c = crate::api::vault::ingest_bytes(
            "IMG_0042.txt".into(),
            signature_only.as_bytes().to_vec(),
        )
        .unwrap();
        assert_eq!(by_id(c.document_id.expect("建了文档")).provider, None);
    }
}
