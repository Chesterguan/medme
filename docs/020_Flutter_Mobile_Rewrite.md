# 移动端重做:Flutter UI + Rust 核(flutter_rust_bridge)

> 2026-07-12 决定。用户批准方案 A。取代 Tauri v2 移动端(WebView 界面层造成的 PDF 白屏 /
> 文字截断 / 打包折腾等弯路)。**桌面端不变,仍用 Tauri。**

## 目标
用 **Flutter 原生 UI** 重做 iOS/安卓 app,功能与设计风格保持不变;**复用现有 Rust 数据核**
(保险箱 CAS+追加日志、DICOM 编解码、加密分享)经 `flutter_rust_bridge`(FRB v2)调用,
保证与桌面端**同一保险箱格式 → 跨设备同步天然互通**。

## 架构

```
Flutter (Dart) UI  ──FRB──▶  apps/mobile_flutter/rust  ──▶  core-model / pipeline / share / dicom / parser
   原生界面/导航/PDF查看/相机                薄封装:把 vault 操作暴露成 async Dart API
   OCR:两端都是 PP-OCRv5(见下方 2026-08-05 更正 —— 原文写的平台分流已不成立)
```

- **UI = Flutter**:所有屏幕、导航、PDF 查看(`pdfx`/`syncfusion` 等成熟插件)、图片查看、相机/相册/文件选择,全部原生组件。再无 WebView。
- **数据核 = 现有 Rust crate**,经新增的 `apps/mobile_flutter/rust` 薄封装暴露。**不重写保险箱**(否则同步断、且推倒最难最已测透的代码)。
- ~~**OCR = 平台分流**:iOS 用 Apple Vision,Android 用 `google_mlkit_text_recognition` 插件~~ **【2026-08-05 更正:此项已不成立,见文末】**。PDF 文本层抽取、DICOM 元数据仍在 Rust。

## 复用 vs 新建
- **复用(不动)**:`packages/core-model`(Vault/CAS/log/HMAC)、`packages/pipeline`(ingest 编排)、`packages/share`(加密分享+导出)、`packages/dicom`、`packages/parser`。桌面端继续用。
- **新建**:
  - `apps/mobile_flutter/rust`:FRB 封装层(crate,FFI 在 `src/api/`)。依赖上述 crate,暴露干净 async API。
  - `apps/mobile_flutter/`:Flutter 工程(FRB 生成的 Dart 绑定 + UI)。
- **已删除(功能对齐后,2026-07)**:`apps/mobile`(Tauri v2 移动端)。手机端只剩 `apps/mobile_flutter`。

## FFI API 面(`apps/mobile_flutter/rust` 暴露给 Flutter)
参考已删除的旧 Tauri `apps/mobile/src-tauri/src/commands.rs`(设计蓝本,现已随 `apps/mobile` 一并移除);FFI 现落在 `apps/mobile_flutter/rust/src/api/`。能力:
- `open_vault(docs_dir, data_dir, icloud_enabled) -> ()`(决定真相根:iCloud 容器 or 沙盒)
- `load_archive() -> Vec<TimelineGroup>`
- `get_document(id) -> DocumentDetail`
- `read_source_bytes(id) -> Vec<u8>` / `render_dicom_png(id) -> Vec<u8>`
- `ingest_file(path)` / `ingest_bytes(name, bytes)`(PDF/TXT/DICOM 走 pipeline)
- `ingest_image_with_text(name, bytes, ocr_text, confidence)`(图片:Flutter 已用 ML Kit 识别)
- `create_share(expires_days) -> ShareResult`(自包含加密 HTML)
- `export_timeline_html(from_date?, to_date?) -> ExportResult`(**带日期区间筛选**)
- `patient_profile() -> PatientProfile`
- `reset_vault()`、`load_demo_data()`
- `icloud_status()` / `enable_icloud_sync()` / `disable_icloud_sync()`(iOS)

DTO 用 FRB 的镜像结构(Rust struct → Dart class 自动生成)。

## 屏幕清单(还原现有设计:teal、卡片、底部导航)
底部导航按用户新要求调整:
1. **导入导出**(用户明确要求提升为一级 tab):相机/相册/文件导入 + 导出(时间线 HTML,带日期区间筛选,后续可加更多筛选维度)。
2. **健康档案**(时间线:就诊组 + 独立文档,点开详情)。
3. **设置**(载入示例数据 / 清空重置 / iCloud 同步 / 加密分享入口 / 关于)。
- 文档详情:内容感知渲染(化验表格/处方卡/病历)+ 原件查看(图片查看器 / PDF 插件 / DICOM 渲染锚点切片为 PNG(`renderDicomPng`),不支持的压缩格式优雅降级(仍保存原件))。

## 同步(iCloud,iOS)
真相(objects/+log/)放 iCloud ubiquity 容器,派生 db 留沙盒 —— 沿用现 Rust `icloud` 逻辑,
路径由 Flutter/iOS 配置容器 entitlement,`open_vault` 里决定根。安卓跨设备 → 后续(1.3 云盘/QR)。

## 构建/发布
- iOS:`flutter build ipa`(Flutter 标准流程,比 Tauri 顺;签名/描述文件复用现有 `MedMe App Store` + ASC key)→ TestFlight。
- 安卓:`flutter build apk`。
- Rust 库经 FRB 的 `cargokit` 在 flutter build 时自动编 iOS/安卓静态库并链接。

## 分阶段
- **P1 骨架**:`apps/mobile_flutter/rust` + `flutter create` + FRB init;跑通一个最小 Rust 调用(open_vault + record_count)在 iOS 模拟器显示。**验证工具链闭环**。
- **P2 FFI 全量**:暴露上面全部 API + DTO。
- **P3 UI**:三个 tab + 文档详情,还原设计。
- **P4 OCR/PDF/图片**:ML Kit 识别 + PDF 插件 + HEIC/图片。
- **P5 iCloud 同步**。
- **P6 导出日期筛选 + 打磨**。
- **P7 出包**:iOS TestFlight + 安卓 APK;达标后删 `apps/mobile`(Tauri)。

## 风险
- FRB iOS/安卓构建集成(cargokit)是最需要跑通的一环 → P1 先验证。
- ML Kit 中文识别质量需真机验(和之前一样,发前门槛)。
- 保留桌面同款保险箱格式是硬约束(用 FRB 复用 Rust 核天然满足)。

---

## 更正:OCR 不再平台分流(2026-08-05)

本文 2026-07-12 写的「iOS=Apple Vision / Android=ML Kit」**已经不是现状**。
当前实现:**两端都是 PP-OCRv5**,ONNX 模型经 `include_bytes!` 打进二进制
(约 20MB),`ocr_bridge.dart` 两个平台走同一条 `recognize_engine_layout`。

改变的原因(从提交历史与 issue 归纳,不是本文原作者的决定):

1. **ML Kit 文档扫描/识别依赖 GMS 按需下载的模块** —— 国内无 Google 服务的
   安卓机(2019 年后的华为纯 HMS 等)上起不来。这是「拍照打不开且不弹权限」
   那个线上 bug 的根因,而它**在有 GMS 的开发机上不复现**,连续几个版本没被修掉。
2. 模型内置后**零运行时下载、零 GMS 依赖**,与「本地优先」这条产品原则一致。

`pubspec.yaml` 现在没有任何 ML Kit 文字识别依赖;`packages/ocr` 里的
Apple Vision 分支只在 **macOS 桌面端**生效,与移动端无关。

### 附带的一条陷阱

`packages/ocr::recognize_platform_best` / `recognize_pdf_platform_best` 按
`#[cfg(target_os)]` 分流:macOS 上主用 Apple Vision,其它平台用 PP-OCRv5。
**这是 target 门控不是 feature 门控**,`default-features = false` 关不掉。

因此**在 macOS 上验证移动端 OCR 行为时,必须只调 `recognize_engine_layout`**。
已经踩过一次:`openmed/labaudit` 扫描 PDF 路径产出的 dump 是 Vision 输出,
却被当作 PP-OCR 语料支撑过一次判断。详见 `WORKLIST.md` 的「验证纪律」一节。

(另注:原文与 `packages/ocr` 里「Apple Vision 中文更强」的说法出自 issue #41,
**本仓库没有留下任何对比测试**。桌面端换成 PP-OCRv5 是否更好,至今没有人量过。)
