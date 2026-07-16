# 012 · Viewers & Rendering · 查看器与呈现架构

> 数据呈现有**两个正交维度**:① 原始文件**格式** → 对应 Viewer(看原件,专业性底线);② 内容**类型** → 结构化富渲染(便于读/搜/分析)。原件是真相,结构化是辅助,永远可溯源。救命的东西不含糊。

关联:[007_UI_Guidelines](007_UI_Guidelines.md) · [010_Imaging_DICOM](010_Imaging_DICOM.md) · [011_Storage_Sync](011_Storage_Sync.md) · 记忆 `medme-content-aware-rendering`

---

## 1. 存储恒定:存文件

- 恒定规则:**存文件**(CAS,不可变)。有源文件 → 存源文件;派生产物(OCR 文本、预览)也存 CAS,可重建。
- 上传时**双路由**:
  - 按**格式**(mime/magic)→ 决定原件 Viewer(维度 A)。
  - 按**内容类型**(classify)→ 决定结构化渲染(维度 B)。
- 无源文件(未来:结构化录入/导入)→ 仅按内容富渲染(无维度 A)。

## 2. 维度 A — 格式 → 原件 Viewer

| 格式 | mime | Viewer | 状态 |
|---|---|---|---|
| PDF | application/pdf | 内嵌 iframe / 全屏 | ✅ |
| DICOM | application/dicom | **自研 canvas 阅片器**(内联 cornerstonejs `dicom-parser` 1.8.12 解析 + `openDicomViewer` 画布:窗宽窗位 / 缩放 / 平移);分享查看器已上线 | ✅ 分享查看器 |
| 图片 | image/* | 缩放/平移全屏灯箱 | ✅ |
| 纯文本 | text/plain | 文本渲染 | ✅ |
| DOCX | ...officedocument... | 文本抽取渲染(暂无版式) | 待 |

原则:**原件永远一键可看**(医生核验真报告)。Viewer 用对格式的 **bundled** 工具,轻量不臃肿。

## 3. 维度 B — 内容类型 → 结构化渲染

由 `ReportContent` 按 `doc_type` 分发到专门渲染器:

| doc_type | 渲染 | 状态 |
|---|---|---|
| lab_report | **表格**:指标 · 结果 · 单位 · 参考范围 · ↑↓ 状态色;跨时间**趋势**(v0.2) | ✅表格 / 趋势待 |
| prescription | **用药清单**:药名 · 规格 · 用法用量 · 数量 | 🔧 |
| imaging_report | **分节**:检查所见 / 诊断意见(印象) | 🔧 |
| pathology | **分节**:大体所见 / 镜下所见 / 病理诊断 / 建议 | 🔧 |
| discharge_summary | **分节**:诊断 / 主诉现病史 / 住院经过 / 出院医嘱 | 🔧 |
| clinical_note | **分节**:主诉 / 现病史 / 查体 / 诊断 / 处理 | 🔧 |
| surgery | **分节**:术前诊断 / 手术名称 / 麻醉 / 手术经过 | 🔧 |
| other/unknown | 通用:章节标题加粗 + 段落(现有启发式) | ✅ |

实现:一个 `renderByType(doc_type, text)` 分发;各渲染器从 OCR/原文文本按**章节标题/表格**结构解析(v0.1 启发式),v0.2 由结构化抽取(`clinical_event`)驱动更准。**忠实**:不臆造数值,低置信/解析失败**退回原文文本**(绝不比原文糟),并始终可看原件。

## 4. 详情页布局

- **原件为附件**(缩略图/文件条 → 全屏 Viewer,维度 A)+ **结构化视图为主**(维度 B)。二者并存,按需切换。
- 影像类:原件 Viewer(自研 dicom-parser canvas 阅片器)是主角;文本类:结构化视图是主角。

## 4a. 分享查看器(`web/hosted-viewer/index.html`)

自包含加密分享页在原件列表之上还渲染**医生视图 summary**:疾病泳道时间轴 + 化验/用药趋势 + 一键复制的院外病历文本(`buildEMRFromSummary`),以及**影像检查分区**(「影像检查 · 按时间」,按部位分组,同部位跨时间看变化)。交互:浮动**「↑ 返回时间轴」**回顶按钮、**内嵌 PDF 预览**(`openPdfViewer`,CSP 仅放行 `frame-src data:`)、以及全屏图片灯箱(照片 / DICOM 关键切片 PNG,可切原始分辨率)。有 summary 时「全部原件」默认折叠,医生先看泳道 + 影像,原件按需展开、泳道证据可跳回对应原件。

> 医生 summary 的数据契约与渲染规范由 [030_Clinical_Handoff](030_Clinical_Handoff.md) 拥有(此处只描述查看器如何呈现)。

## 5. 原则(定调)

1. **原件是真相,结构化是辅助**;每条渲染值可溯源回原件位置(v0.2 `source_span`)。
2. **轻量但专业**:对的工具、忠实渲染、低置信标注;不为炫技加重量。
3. **不死板**:同一数据双视图共存;格式/类型自动判、可回退。
4. **第一天就要对**:救命数据不含糊;先覆盖常见类型的专业渲染,再逐步更好。

## 6. 阶段

- **现在**:补齐维度B 的 `renderByType`(处方用药清单 / 病理·影像·出院·病历·手术分节);完成维度A 的 DICOM viewer(自研 dicom-parser canvas,已在分享查看器上线)。
- 接续:化验趋势图;`source_span` 溯源高亮;DOCX 版式;结构化抽取(v0.2)驱动更准渲染。
