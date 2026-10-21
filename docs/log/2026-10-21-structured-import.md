# 2026-10-21 · 结构化导入:吃 myEHR Epic 适配器包

spec:`docs/superpowers/specs/2026-10-21-structured-import-design.md`。背景:用户把 UF Health 的 Epic 病历(5600 页 PDF)用 myEHR 切成 686 份小 PDF + 抽取 sidecar(化验带 LOINC、诊断带 ICD-10)。分工定为 **myEHR 只做 ETL,MedMe 是展示与加密分享层**,所以 MedMe 要一个吃「包」的入口。真实包只在用户设备上流动,仓库/测试/文档只用合成数据(Doe, Jane)。

**做了什么**
- `pipeline::import_bundle(vault, 文件夹或 zip, progress) -> BundleReport`(新模块 `bundle.rs`):每份核 sha256 → `Vault::import` → `ingest_pdf`(**新增 `typed: Option<(DocType, String)>` 覆盖参数**,类型/标题/日期以 manifest 为准,不再 classify)→ sidecar **原文**作为 `result_json` 挂 `ExtractionAdded{backend:"epic-adapter", model_version:"myehr-epic-adapter", mode:"text", schema:1}` → 整包末尾 `rebuild_encounters` 一次。**零新事件类型。**
- zip 不解压到磁盘:按 manifest 列的名字 `by_name` 读进内存(没有明文临时副本、没有 zip-slip 面);manifest 在顶级子目录也认,跳过 `__MACOSX/`。
- `deid::verify` 跑但**只计数**(`verify_rejected`/`verify_unverified` 进报告与日志),不用它的产物落库:它的候选集只认整行/单词,多词英文项目名在 Text 模式会被整条丢掉;适配器已对原文逐字校验。
- LOINC 反查:`deid::LabItem.loinc`(空时不序列化,云路径落库 JSON 逐字节不变)+ `terminology::resolve_loinc(code)`(字典 305 条带码,`14749-6` 两条重复先到先得)+ `labs_from_json` 名字认不出时按码兜底(名字优先)。
- 入口:CLI `medme --vault <dir> import-bundle <dir|zip>`;FRB `vault_import_bundle(progress, path)`(复用 `DemoLoadProgressDto`,名字排在 `recognize_image_pp` 之后);Flutter「添加病历」表第 4 项「导入 Epic 病历包」→ file_picker 选 `.zip` → 模态进度框 → SnackBar。
- 依赖:`pipeline` 新声明 `serde`/`serde_json`/`deid`(workspace 早有)+ **新依赖 `zip = 7`(default-features off,只开 deflate)**。

**验证**:`cargo test --workspace` 47 个测试二进制全绿(新增 pipeline 集成测试 7 条:按 manifest 建档与就诊分组 / 幂等重导不追加事件 / 缺 sidecar 的那份重导时补挂 / 结束日早于开始日·只有结束日·`..` 路径均拒 / 坏 sha·缺文件·未知类型·坏日期各只废一份 / 无 manifest 硬错 / 带顶级目录与 `__MACOSX` 的 zip 与文件夹等价);terminology / deid / parser 各一条单测;`cargo clippy --workspace --all-targets -D warnings` 与 `cargo fmt --check` 干净;`frb_dispatch_indices` 绿;`flutter analyze` 零 issue。CLI 对 myEHR `--text-only` 合成包跑通(14 份全部如实报「manifest 没给 sha256」)。

**独立审查(code-reviewer)抓出 3 条 Important,全修、各带测试**:进度对话框用外层 context pop 根导航器,中途被深链推上来的页面会被关掉、对话框卡死 → 记对话框自己的 context 只 pop 它;流写在 `builder` 里、route 重建就再跑一遍整包 → 流只开一次,对话框读 `ValueNotifier`;文档建了但 sidecar 缺/坏(或中途被杀)再导永远 `deduped` → 去重分支里「类型一致且没 extraction」就补挂。顺带:名字模糊命中不再压过精确 LOINC 码;`verify` 清空云路径的 `loinc`;zip 取最浅 manifest、同深度两个就报错;manifest 路径拒绝绝对/`..`;结束日早于开始日、只有结束没开始都拒;FRB 错误保留 anyhow 上下文链。

**没做 / 留的**
- 桌面 Tauri 入口;分享接收(AirDrop 直接跳进 App);`meds[].rxnorm` 反查;字典外的 LOINC(字典只有 310 条化验)。
- 同一 PDF 用户之前手动导过 → 命中去重、元数据不改(`DocumentAdded` 只写一次),报告列为 deduped;想按包重建先删再导。
- 手机端 `apps/mobile_flutter/rust` 的 `cargo clippy -D warnings` 有 5 条**早于本次**的告警(`vault_cloud_*` 参数数、两处多余 `mut`、demo 循环计数),没动。
- 真实 686 份包的导入由用户把手机连上电脑后自己做;本次没碰 `out_full/`。

## 补:模拟器 smoke test 抓到的两处(2026-10-21,同日修)

- 「添加病历」sheet 加到四项后在真机 iPhone 14 Pro 溢出 86px:`showModalBottomSheet` 改 `isScrollControlled: true`,正文包 `SingleChildScrollView`。视觉溢出矩阵测试原本只 pump `AddSheetBody` 本体、不带 sheet 的 9/16 高度上限,所以没抓到。
- 整包导入完成后首页不刷新:它不走后台队列,队列那条「每份完成就 `bumpVaultRevision()`」不会发生;现在 `_runBundleImport` 成功 >0 份即 bump。
- 顺带记两条没改的观察:就诊卡片展开后每行只显示类型(病历/化验),Epic 包一次住院有几十份「病程记录 某日」会分不清,标题其实已在 `document.title`;MedMe 自家 `deid::verify` 对多词英文项目名整条判拒,导入报告里的 `verify_rejected` 偏高是这个原因,只计数不丢数据。
