# 014 · Imaging Overhaul · 医学影像扎实化

> 影像是很多重症的核心证据,必须做扎实:**本地阅片达放射级、导出/分享在浏览器也能看、大数据不炸内存**。学 OHIF/**Cornerstone3D**(浏览器放射级引擎)+ **PocketHealth**(病人分享:链接+访问码→浏览器看,免装免注册)。

关联:[010_Imaging_DICOM](010_Imaging_DICOM.md) · [011_Storage_Sync](011_Storage_Sync.md) · [012_Viewers_and_Rendering](012_Viewers_and_Rendering.md)

---

## 1. 病根(现状)

- DICOM 每个 `.dcm` 存成**独立文档**;`study_uid`/`accession` 提取了但**没用来分组** → 真实 CT(几百切片)碎成几百文档,无法当一叠滚动看。
- 查看器 dwv 基础:不能跨切片滚、无窗位预设、无测量;小样本上采样发糊。
- **导出/分享里没有影像**(只文本)→ 医生看不到 CT/MR。**最致命。**
- 普通图片(JPG)也偏糊:缩略图/灯箱未保证原分辨率呈现。

## 2. 数据模型:Study → Series → Instance

- 导入的 DICOM 按 `StudyInstanceUID` + `SeriesInstanceUID` 聚成**一个"影像检查(imaging study)"实体**,含 series、每 series 含有序切片(按 `InstanceNumber`/`ImagePositionPatient` 排序)。
- 导入**文件夹 / zip** 的一堆 `.dcm` → 一个 study(不是 N 个文档)。
- 原始切片仍进 CAS(原件不灭);DB 加 `imaging_study` / `imaging_series` 派生表(可从事件日志重建)。时间线上一次检查 = 一张卡(可展开序列)。

## 3. 本地查看器:dwv → Cornerstone3D

放射级能力:**序列堆栈滚动**、**窗位预设**(脑/骨/肺/软组织/自定义)、缩放平移、**测量**(长度/角度/ROI)、反色、cine 播放;后续 MPR 三维重建、序列并排。
- 512×512 是 CT 标准分辨率;Cornerstone3D 渲染比 dwv 锐利,配合真实切片解决"糊"。
- 普通图片(JPG/PNG)也走同一查看器或至少**原分辨率灯箱**(不强制降采样),保证清晰。

## 4. 导出 / 分享带诊断级影像(浏览器也能看)

分两档,**按体积自动建议**:
- **轻档 · 报告 + 关键切片**:关键切片渲染成图内嵌进导出 HTML(像胶片,能打印)。适合快速出示/报销。
- **诊断档 · 完整序列**:把 **Cornerstone3D 查看器 + 原始 DICOM(加密)** 打进自包含分享文件 → 医生输口令后在浏览器**滚完整序列、调窗位、测量、下原图**。= PocketHealth 体验,但**零服务器 + 端到端加密**。

## 5. 大数据怎么办(内存不炸)—— 关键

1. **按需解码 + 有界 LRU 缓存**:只解码可见切片,滚动时解新淘旧,缓存设上限(如 200MB)。**500 切片内存也只几十 MB。** Cornerstone3D 自带图像缓存。
2. **存压缩、显示时才解码**:切片以 JPEG2000/JPEG-LS 压缩;文件里是压缩数据。**文件可大,内存恒小。**
3. **分享分档(按体积)**:
   - 中小(压缩后 < ~50–100MB)→ 自包含加密 HTML,浏览器直接开
   - 大(GB 级)→ ① 只勾选**关键序列**分享;② 或加密 DICOM 文件夹 + 查看器(选目录打开);③ 未来:托管 + 懒加载(WADO 式,像 PocketHealth,破坏零服务器,作为可选)
   - **超限提示**:"完整影像 X GB,建议只分享关键序列 / 关键图"
4. 自包含 HTML 体积上限保护:超过阈值(如 300MB)禁用诊断档、引导走关键序列或文件夹方案。

## 6. 阶段

- **P1 · 数据模型**:DICOM 按 Study/Series 分组(dicom crate 补 series_uid/instance_number;core-model 加 imaging_study/series;pipeline 聚合;时间线一次检查一张卡)。做完多切片 CT 立刻能当一叠。
- **P2 · Cornerstone3D 本地查看器**:替换 dwv;序列滚动 + 窗位预设 + 测量;JPG 原分辨率清晰呈现。
- **P3 · 导出/分享影像**:轻档(关键切片入 HTML)+ 诊断档(Cornerstone3D+加密DICOM 自包含,按需解码有界缓存)+ 体积分档与提示。

## 7. 测试数据

需**真实多切片 CT 序列**(演示堆栈滚动)+ **更高分辨率样本**;优先公开去标识数据(如 Cornerstone3D/OHIF 示例数据、pydicom/GDCM 大样本),不用合成假图。
