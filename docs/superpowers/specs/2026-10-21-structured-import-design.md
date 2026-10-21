# 结构化导入:吃 myEHR Epic 适配器产出的包 — 设计

日期 2026-10-21。状态:**用户已拍板**(2026-10-21):Q1 zip;Q2 `deid::verify` 跑但只计数;Q3 LOINC 反查并进本次。

## 0. 一句话

MedMe 加一个入口,吃一个「包」(`manifest.json` + 每份小 PDF + 同名抽取 sidecar),把每份文档按包里**已定好**的类型/日期/标题建档、PDF 文本层照常入 FTS,再把 sidecar 原样挂成一条 `ExtractionAdded`。**零新事件类型、零新表、保险箱格式不动。**

## 1. 为什么 / 边界

- 分工已定:**myEHR 只做 ETL**(Epic 5600 页 PDF → 686 份按就诊/小节切开的小 PDF + 结构化抽取),**MedMe 是展示与加密分享层**。MedMe 今天只有「一份文件进来 → classify/guess_date」的路,包里早已算好的类型、日期、住院起止、化验 LOINC、诊断 ICD 全都没法送进来。
- 目标读者是国内医生/机构,**LOINC / ICD-10 / RxNorm 必须原样保留**(ADR 0004:core 只存码,映射在 L3 另做)。
- 包的内容是用户本人的真实病历(姓名/MRN/生日/地址)。**真实包只在用户本机与手机上流动;MedMe 仓库、测试、文档、demo 一律只用合成包(Doe, Jane)。** 真实导入由用户之后在设备上自己做,本次会话不碰 `myEHR/out_full/`。
- 不是通用 FHIR 导入。只认 myEHR 这一种包;格式由 myEHR 定,MedMe 只读。

## 2. 输入包格式(myEHR 已定,MedMe 只读)

来源:`myEHR/epic_adapter/cli.py`(manifest 写法)、`docs.py`(切分)、`extract.py`(sidecar)。合成样例:`python3 -I tests/fixtures/make_synthetic.py` → `.venv/bin/python -m epic_adapter.cli tests/fixtures/synthetic_record.txt <out> --text-only`(不含 PDF)。

一个文件夹(或把它 zip 起来,见 §5.3):

```
manifest.json
pages.txt                              # 全文,MedMe 不读
docs/<date>_<type>_<slug>.pdf          # 每份文档
docs/<date>_<type>_<slug>.extraction.json
```

`manifest.json` 里 MedMe **用到**的键:

| 键 | 用途 |
|---|---|
| `docs[].file` | 相对路径 `docs/xxx.pdf`;sidecar = 同路径把 `.pdf` 换成 `.extraction.json` |
| `docs[].sha256` | 导入前核 PDF 字节;不符 → 这份跳过并报错,**不**落库(`--text-only` 包为 `null`,整份跳过) |
| `docs[].doc_type` | `lab_report / imaging_report / clinical_note / discharge_summary / surgery / pathology / other`,全部已在 `DocType::from_str` |
| `docs[].title` | 文档标题,原样 |
| `docs[].doc_date` / `doc_date_end` | `YYYY-MM-DD`;只有 `discharge_summary` 有 `doc_date_end` |
| `docs[].pages` | 只进报告,不落库(事件没这个位) |

不用的键:`source`、`generated`、`encounters[]`、`coverage`、`docs[].encounter_title`、`docs[].dropped`——事件里没有位置,`rebuild_encounters` 自己会按住院窗口/按天重新分组(§3.3),包里的 `encounters[]` 不需要落库。

sidecar 形状与 `deid::Extraction`(`packages/deid/src/verify.rs:101`)同形,多出两个可选键:`labs[].loinc`、`meds[].rxnorm`。所有值都是 PDF 原文逐字子串(**适配器已校验**)。

## 3. 落库映射

### 3.1 每份文档走的路

```
读 PDF 字节 → 核 sha256 → Vault::import(name, "application/pdf", bytes)
  ├─ deduped 且已有 document → 状态 deduped,这份到此为止(不重复挂 extraction)
  └─ 否则 ingest_pdf(…, 覆盖: doc_type + title + date_span 来自 manifest)
       → 文本层/OCR 逐页进 ocr_result(FTS、聚合、分享正文全靠它,照旧)
       → 有文档 → 读 sidecar 原文 → add_extraction{backend:"epic-adapter", model_version:"myehr-epic-adapter", mode:"text", schema:1, result_json:<sidecar 原文>}
       → 整份无文本(StoredNoText)→ 没有 document,不挂 extraction,报告里点名
全部做完 → rebuild_encounters() 一次
```

- `ingest_pdf`(`packages/pipeline/src/lib.rs:550`,私有)加一个参数 `Option<(DocType, String)>`(类型 + 标题覆盖),有就跳过 `parser::classify`、标题用它;现有两个调用方(`ingest` :407、`merge_documents_into_pdf` :1004)传 `None`。日期覆盖沿用已有的 `date_span` 参数。**必须一次写对**:`DocumentAdded` 对同一文件 `ON CONFLICT DO NOTHING`(`materialize.rs:511`),没有第二次机会。
- 日期:`YYYY-MM-DD` → `Utc.with_ymd_and_hms(y,m,d,0,0,0)`,与 `parser::guess_date_range` 同一口径(`parser/src/lib.rs:244`)。
- 语言:仍由 `parser::detect_language(&text)` 判(Epic 全英文,会判 en,正确)。

### 3.2 sidecar 原样入 CAS;verify 只计数(用户拍板)

`result_json` 存 sidecar **原文字节**,不经 `deid::Extraction` 反序列化再序列化——那一来一回会把 `loinc` / `rxnorm` 丢掉(结构体没这两个字段)。原样存:
- `parser::extraction::labs_from_json` / `meds_from_json` 照常读得到(`serde(default)`、无 `deny_unknown_fields`,多出的键被忽略,已核 `verify.rs:8-110`);
- `loinc` / `rxnorm` / `icd` 留在 CAS 里,将来 L3 映射层直接读,不用重新导。

`deid::verify(parsed, &ocr_text, Mode::Text)` **跑,但只取 `rejected` / `unverified` 计数进报告和日志,不用它的 `extraction` 落库**。原因:`verify` 的候选集是「整行 + 按空白切出的词」(`verify.rs:505-508`),多词英文项目名(`Hemoglobin A1c`)在 Text 模式会被丢弃,拿它的产物落库等于删合法数据;而适配器已对原文做过逐字校验(`extract.py:verify_verbatim`)。计数用途是「两边文本抽取是否一致」的体检信号(`BundleReport.verify_rejected` 总数 + 每份的数进 CLI 输出),不是闸门。

### 3.5 LOINC 反查词典(用户拍板并进本次)

`labs_from_json` 今天只按名字 `terminology::resolve`;Epic 的长英文名很多认不出 → `analyte_key = None` → 不进趋势。sidecar 约 85% 的化验行带 `loinc`(含 myEHR 手工表的 37 项,已合进 sidecar,MedMe 不另处理)。改两处:
- `deid::LabItem` 加 `#[serde(default, skip_serializing_if = "String::is_empty")] pub loinc: String`——空时序列化不出现,**现有云抽取路径落库的 JSON 逐字节不变**;`verify` 不碰这个字段(它是码,不是原文)。
- `terminology::resolve_loinc(code) -> Option<Match>`:在 `build_index` 里顺手建 `loinc -> entry_idx` 表(字典 305 条带 LOINC,`14749-6` 两条重复,先到先得,记在注释里),`confidence` 1.0、`matched_alias` = 码。`labs_from_json` 中名字解析落空且 `loinc` 非空时用它;名字命中优先(名字是原文,码是适配器给的)。
- 无码、名字也认不出的行:原样透传(`analyte_key = None`),与今天一致。
- 优先级(审查第 4 条):名字**精确**命中(1.0)> LOINC 码 > 名字的剥壳/混淆/模糊命中。`deid::verify` 的产物一律清空 `loinc`(云 LLM 编的码不许落库;sidecar 不经 verify 落库,不受影响)。

### 3.3 就诊分组(现有逻辑,不改)

`discharge_summary` 带起止日 → 定义住院窗口,窗口内文档自动归入;其余按天成门诊;`other` 不是锚点(`query.rs:276-288`)。Epic 包里每次住院都有 Discharge Summary Note 带起止日、门诊都是同一天,所以**不需要**把 manifest 的 `encounters[]` 落库。`rebuild_encounters` 只在整包末尾调一次。

### 3.4 幂等 / 重跑

同一包导两次:每份 `Vault::import` 命中去重且已有 document → 报 `deduped`,**不**追加任何事件。例外(审查第 3 条):文档在、extraction 不在(上次 sidecar 缺/坏或中途被杀)且类型与 manifest 一致 → 这次补挂 extraction、算 `imported`——这才是「重跑即续传」。

同一个 PDF 若用户之前已经**手动**导过(类型/日期是 classify 猜的),这里同样命中去重、不改它的元数据——`DocumentAdded` 只写一次。报告把 deduped 的文件名列出来,用户想按包里的元数据重建就先 `delete_document` 再导一次包。不做覆盖路径。

一包导到一半被杀(手机切后台):已落库的份数再导时全部 `deduped`,剩下的照常进来——重跑即续传,不另做断点。

## 4. API

```rust
// packages/pipeline/src/bundle.rs(新模块,pub use 到 lib.rs)
pub struct BundleReport {
    pub total: usize,
    pub imported: usize,     // 新建文档且挂上 extraction
    pub deduped: usize,
    pub no_text: usize,      // 建不了文档(整份无文本层)
    pub failed: Vec<(String, String)>, // (file, 原因):sha 不符 / 读不到 / sidecar 不是合法 JSON / ingest 出错
    pub verify_rejected: usize,   // deid::verify 在 MedMe 自己抽的文本上找不到的字段总数(只计数,见 §3.2)
    pub verify_unverified: usize,
}
pub fn import_bundle(
    vault: &Vault,
    path: &Path,                                   // 文件夹,或 .zip
    progress: &mut dyn FnMut(usize /*done*/, usize /*total*/),
) -> anyhow::Result<BundleReport>;
```

- 单份失败不中止整批(与 CLI/桌面/手机 ingest 同一不变式),进 `failed`。
- `manifest.json` 读不到 / 不是 JSON → 整体 `Err`,什么都不写。
- `.zip`:**不解压到磁盘**。`import_bundle` 内部用一个「按相对路径读字节」的小抽象,文件夹实现 = `fs::read`,zip 实现 = `ZipArchive::by_name` 读进内存。先在 zip 条目里找 `manifest.json`(macOS 压缩会多一层顶级文件夹,前缀取它所在目录;跳过 `__MACOSX/`),之后只按 manifest 列出的名字读。没有临时目录 → 没有 231 MB 的明文副本留在 `data_dir`、没有清理、没有 zip-slip 面(我们从不按 zip 里的名字写文件)。单份 PDF 仍卡 `MAX_INGEST_BYTES`(200MB/份,与 `ingest` 同一闸);整包不设上限——真实包 231 MB,不自己发明限制。
- Epic 导出的 PDF 带文本层(myEHR 就是靠 `pdftotext` 切的,逐字校验也是对这份文本做的),所以 `ingest_pdf` 走文本层、不触发 OCR;万一某页没有文本层会落到 `pages_without_text`,如实进报告,不在这里补 OCR。
- sidecar 文件缺失 → 文档照常建,`failed` 记一条「无 sidecar」,`imported` 不计它。

## 5. 入口

### 5.1 CLI(先做,测试载体)
`medme --vault <dir> import-bundle <dir-or-zip>`,逐行打进度,末尾打 `BundleReport`。

### 5.2 手机 FRB + Flutter
- `apps/mobile_flutter/rust/src/api/vault.rs`:`vault_import_bundle(progress: StreamSink<DemoLoadProgressDto>, zip_path: String)`。名字按字典序排在 `recognize_image_pp` 之后(`frb_dispatch_indices` 测试守着)。**复用** `DemoLoadProgressDto{loaded,total,succeeded,error}`,不加 DTO。走 `with_state`,内部 `pipeline::import_bundle` + 完事 `rebuild_encounters`。整包在一把 vault 锁下同步做完——与 `vault_load_demo_data_sle` 完全同一手法,期间 Flutter 侧是模态进度框,用户本来也做不了别的。`flutter_rust_bridge_codegen generate` 重生成(本机 2.12.0)。
- Flutter:「添加病历」选择表(`import_flow.dart:AddSheetBody`)加第 4 项「导入 Epic 病历包(.zip)」,`ImportChoice.bundle`;`runImport` 对它单走一条:`FilePicker.pickFiles(allowedExtensions:['zip'])` → 进度对话框(照 `settings_screen.dart:_loadDemo` 的进度文案)→ 完成 SnackBar「导入 N 份,去重 M 份,失败 K 份」。`pickImportItems` 的 switch 补 `case bundle: return const []`(不可达,只为穷尽)。不进后台队列(`enqueueImport`)——那条队列是一份一份 OCR 的,整包在 Rust 里一次做完。
- 桌面 Tauri(`commands.rs:362`)后做,不在本次。

### 5.3 手机怎么拿到包(§9 Q1,我推荐 A)

| 方案 | 怎么拿 | 代价 |
|---|---|---|
| **A. zip(推荐)** | 电脑上把包文件夹压成 zip → AirDrop / iCloud Drive / 数据线拷到「文件」→ App 里选这个 zip | pipeline 加 `zip` 依赖(§6);一条路通 CLI/桌面/手机 |
| B. 选文件夹 | `FilePicker.getDirectoryPath()` | iOS 上文件夹是 security-scoped,子文件能不能读到取决于 picker 实现,file_picker 文档没承诺;686 个文件不复制也慢。不选 |
| C. 分享接收(从 AirDrop 直接跳进 App) | 加 `receive_sharing_intent` 之类插件 + iOS share extension | 新插件 + 原生改动,只为省一次「打开 App 再选文件」。以后要再加 |

## 6. 依赖变更(需说明)

- `packages/pipeline/Cargo.toml` 新增三行 `serde` / `serde_json` / `deid`——都已在 workspace 和两个 Cargo.lock 里(不触发新下载、不多链 crate),但 pipeline 自己今天没声明它们,是 manifest 改动。deid 只为复用 `parse_extraction` 做 sidecar 合法性检查,不跑 verify。
- `packages/pipeline`:**新依赖 `zip = { version = "7", default-features = false, features = ["deflate"] }`**。`flate2`/`miniz_oxide` 两个 lock 里都已有;新增的是 `zip` 自身及其小依赖(crc32fast、indexmap 等)。7.2.0 已在本机 cargo 缓存,可离线编。进 pipeline 意味着桌面与手机都会多链这一个 crate。
  - 不选 Dart 侧 `archive` 包:纯 Dart 解 231 MB 慢,且 CLI/桌面还要再写一份。

## 7. 测试(全部合成数据,Doe, Jane)

`packages/pipeline/tests/import_bundle.rs`:
1. 用 `lopdf` 现造 3 份带文本页的小 PDF + 手写 manifest + sidecar(一份 `discharge_summary` 2024-03-01..03-04 带 2 条 labs 含 `loinc`;一份 `lab_report` 2024-03-02;一份 `clinical_note` 2024-05-06 带 1 条 diagnosis 含 icd),写进 tempdir。
2. `import_bundle` 后:`document` 3 份,`doc_type`/`title`/`doc_date` 等于 manifest(不是 classify 猜的);`encounters_with_docs()` 两组:住院窗口含 lab_report,门诊一天;`extraction_json` 经 `labs_from_json` 读出 2 条,原文仍含 `"loinc"`;`ocr_text` 非空(FTS 搜得到 PDF 里的词)。
   - 单测(parser):一条 `{"name":"Some Odd Name","value":"1.1","unit":"mg/dL","loinc":"14682-9"}` 经 `labs_from_json` 得 `analyte_key == Some("creatinine")`;名字能认时名字优先;无码无名原样透传。单测(deid):`LabItem` 不带 loinc 时序列化不出现 `loinc` 键。
3. 再导一次 → `deduped == 3`,事件数不变。
4. 改一份 `sha256` → 那份进 `failed`,其余两份正常。
5. 同一包压成 zip(顶层多一层目录 + 一个 `__MACOSX/` 假条目)→ 结果与文件夹一致。
6. `frb_dispatch_indices` 仍绿;`flutter analyze` 干净。CLI 不加测试(该 crate 目前零测试,`import_bundle` 的逻辑全在 pipeline 测)。

## 8. 不做 / 留给实施

- 不落 `encounter_title` / `pages` / `coverage`(事件没位置,分组逻辑不需要)。
- 不改 `rebuild_encounters`、不加事件、不改 schema、不改隐私政策(数据不离机,路径没变)。
- 桌面入口、分享接收(C)、按包里 `encounters[].dept` 填 `Encounter.provider`:以后。
- 词典里**没有**的 LOINC(词典 310 条化验,Epic 用到的码远多于此):反查落空,原样透传。补词典条目是另一件事。
- `meds[].rxnorm` 本次只随 sidecar 进 CAS,不反查(`resolve_drug` 按名字,Epic 药名多为英文通用名,词典有部分拉丁别名)。
- 实施细节(报告文案、进度对话框样式、`bundle.rs` 内部拆分)由实施者定。

## 9. 用户拍板(2026-10-21)

- Q1 手机拿包方式:**zip**(§5.3 A)。
- Q2 `deid::verify`:**跑但只计数**,sidecar 原样存(§3.2)。
- Q3 LOINC → 词典 key 反查:**并进本次**(§3.5)。

实施计划放 `docs/superpowers/plans/2026-10-21-structured-import.md`,做完即删;收尾写 `docs/log/2026-10-21-structured-import.md`(≤40 行)。
