# ADR 0007 · 安卓文档扫描去 GMS 化 + 文档几何(边缘/透视/朝向)进共享 Rust 核

Status: Accepted · Date: 2026-07-25 · 承接 [0006](0006-ios-ocr-pp-ocrv5.md);**补记 [0005](0005-ocr-per-platform-native.md) 的移动 Android 那行已被 supersede**(见 Context)

## Context

**先补一笔已发生的决定(build 38,`feat/doctor-mode-v2`→main,2026-07-24):移动 Android 图片 OCR 已从 ML Kit 改为 PP-OCRv5**,与 iOS 同引擎同模型(经 FRB `recognize_image_pp`,`packages/ocr` 的 `engine` 路径 + 高图纵向切片 `predict_lines`)。这连同 [0006](0006-ios-ocr-pp-ocrv5.md)(iOS)一起,把 [0005](0005-ocr-per-platform-native.md)「移动 iOS=Vision / Android=ML Kit」两行都 supersede 了 —— **现在两个移动平台都走 Rust PP-OCRv5**;ML Kit 依赖仅留作回退。安卓侧打包 `libc++_shared.so`(arm64-v8a)修 PP 真机崩溃,只出 arm64(arm64 是安卓主流)。真机(华为 Mate 9 / Android 8)全代拍闭环 + OCR 验通。

**本 ADR 的正题 —— 采集期的「文档几何」缺口,2026-07-25 真机暴露:**

1. **安卓拍照依赖 GMS(致命)**:采集用 `cunning_document_scanner`,其安卓端包 **ML Kit 文档扫描器(`com.google.mlkit.vision.documentscanner` / `GmsDocumentScanning`)**。查证(官方文档):**该 API 纯 Google Play 服务交付,无内置/离线版**(与 ML Kit 文字识别有内置版不同),模型+UI+逻辑全靠 GMS 按需下载。→ **无 GMS 的国产机(华为纯 HMS)或墙了 Google 网络的大陆环境,拍照永久打不开。** China-first 产品这是核心阻塞,不是 edge。用户第一次拍照「打不开相机」正是模块没下完;cunning 自带兜底 `DocumentScannerActivity` 只是**手动拖四角**(上游 OpenCV 被删),不是自动扫描。
2. **歪/斜图渲染塌**:导入已拍的歪图,识别对但版面重建(按 y 分行/按 x 对列)要求行大致水平 → 歪了就塌。iOS 导入有原生 rectify(`VNDetectDocumentSegmentation`+透视校正),**安卓导入没有**。
3. **90° 躺倒**:整张转 90° 的图,两端**都**不会自动转正(透视校正纠斜不纠朝向)。

调研(独立 agent,逐条核官方源,见 [log 2026-07-25](../log/2026-07-25-android-doc-scan-research.md)):现代扫描 App 是 **端上 CV + 小型 DL** 混合;PP 系有原生的**文档方向分类**(`PP-LCNet_x1_0_doc_ori`,7MB,判 0/90/180/270,99% 准)与**去弯曲**(UVDoc,30MB)模型,且 **oar-ocr 的 `OAROCRBuilder` 原生支持** `with_document_image_orientation_classification` / `with_document_image_rectification` 挂这些模型。

## Decision

**采集期文档几何处理,按「能共享的进 Rust 核、iOS 已有原生的不重建」分层:**

- **无 GMS 拍照(相机打不开)= 只安卓修。** iOS 用苹果原生 VisionKit(`VNDocumentCameraViewController`),不依赖 GMS、本来就好,**不动**。安卓改为**不依赖 GMS 的采集**:自建相机 + 文档几何在 Rust 核做(边缘检测→最大四边形→透视拉正),或先用免-GMS 方案过渡。保留 cunning 手动裁剪作兜底。
- **90° 朝向自动转正 = iOS 安卓都修。** 用 `PP-LCNet_x1_0_doc_ori`(7MB ONNX)接进 `packages/ocr` 的 pipeline(oar-ocr `with_document_image_orientation_classification`)。**两端都走 `recognize_image_pp` → 一处改动两端受益**,同时修「躺倒渲染塌」。
- **边缘/透视校正**:安卓新建(相机+导入都缺),实现放 Rust 核(纯 Rust `imageproc`/裁剪版 OpenCV,先 spike 选一),**跨平台可复用**;**iOS 保持原生 rectify 不动**(不重建能用的东西)。以后想统一再评估。
- **去弯曲(UVDoc,30MB)先不做**:等真实病历(折叠出院小结)证明透视校正不够再加 —— 体积对「精简出包」目标是真代价,不提前塞。
- **绝不走云**:文档几何全端上(与 [ocr 第一版决定] 一致,云 OCR/处理是原则性禁区)。

## Consequences

- (+) 安卓在无 GMS / 墙 Google 的国产机上也能拍照采集 —— China-first 的核心能力补齐。
- (+) 朝向修复一处落地、两端受益,顺带修掉「躺倒/歪图渲染塌」。
- (+) 几何进 Rust 核,与既有 PP-OCR(ONNX)架构一条心,桌面端也能复用。
- (−) 体积:doc-ori +7MB(两端);安卓自建扫描 + 几何增加代码与包体;UVDoc 若加另 +30MB(故延后)。
- (−) 安卓自建相机/几何是真投入(调研估边缘+透视 1.5–2.5 周、朝向 2–3 天、采集 UI+接线 ~1 周,合计 ~3–4 周);第一版不全做也能发(有手动兜底 + 导入通道)。
- **未变**:桌面 macOS/Windows/CLI 各行(0005/0006)不变;iOS 采集与 rectify 原生不动;云禁区不变。
