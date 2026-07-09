# 013 · Mobile App & Desktop Sync · 手机端与桌面同步规划

> 目标:iOS / Android 手机 App,**采集为主、查看为辅**,与桌面**共享同一套 Rust 内核与存储**,做到"一处改动、两端同步更新"。手机与桌面通过**同一个事件溯源保险箱**(放在云同步文件夹)保持数据一致,零服务器。

关联:[011_Storage_Sync](011_Storage_Sync.md) · [012_Viewers_and_Rendering](012_Viewers_and_Rendering.md) · 记忆 `medme-v1-milestone-and-decisions` `medme-real-data-sources`

---

## 1. 定位:手机端要薄

真实场景:病人手里是**手机拍的报告照片 + PDF**,看病时未必带电脑。所以手机端的核心价值是**采集**(随手拍、随手存),查看/管理仍以桌面为主(屏幕大、阅片舒服)。

手机端三件事,按优先级:
1. **采集**(P1):拍照 / 扫描 / 从相册或文件选 → 存进保险箱。**一次配置**(指向云盘里的保险箱),之后自动。
2. **查看**(P2):浏览时间线、看报告与影像(复用桌面查看器)。
3. **分享**(P3):就地生成端到端加密分享给医生(复用桌面 `share` 逻辑)。

## 2. 技术选型:一套代码,两端同步

**Tauri v2 mobile**(iOS/Android)。理由:桌面已是 Tauri v2(Rust + React),**Rust 工作区与 React 前端可直接复用** → 功能改一次两端都有,这正是"桌面同步更新"的关键。

```
apps/
  desktop/     ← 现有(Tauri v2 desktop)
  mobile/      ← 新增(Tauri v2 iOS/Android),复用下面的 crates 与共享前端
packages/      ← Rust 内核:core-model / parser / pipeline / ocr / dicom(两端共用)
packages/ui/   ← 抽出的共享前端(时间线/查看器/渲染),平台自适应布局(可选,渐进抽取)
```

- **Rust 内核 100% 复用**:`core-model`(事件日志+CAS+DB)、`parser`、`pipeline`、`dicom` 与平台无关,直接编译到 iOS/Android(ARM)。
- **前端**:先各写各的壳,把 `Timeline / DocumentView / ReportContent / DicomViewer / docmeta` 等渲染逐步抽到 `packages/ui` 共享,移动端只做布局适配(触屏、单列、底部导航)。
- **功能同步策略**:核心逻辑住在共享 crates/组件里,新功能落一次、两端 rebuild 即得;平台专属只剩相机、文件访问、导航壳。

## 3. 数据同步:靠架构,不靠服务器

v1.0 的存储本就是**为同步而设计**的(见 011):

- 保险箱 = `objects/`(CAS,内容不可变)+ `log/*.jsonl`(追加式事件)+ `medme.db`(派生,可重建)。
- **多端指向同一个云同步文件夹**(iCloud Drive / 后续第三方云):
  - `objects/` 内容寻址 → 同一文件哈希一致,天然去重、无冲突。
  - `log/` 追加式 → 各设备各写各的事件段(按 `device_id` 命名分段,如 `log/<device>-000001.jsonl`),**只追加、不改写 → 无写冲突**。
  - `medme.db` 是本地派生缓存,**不入云同步**(各端各自 rebuild),避免二进制冲突。
- 冲突处理:因为只追加,合并 = 把各端日志段并起来重放。**最终一致**,无需服务器仲裁。

> 关键改造:把当前单一 `log/000001.jsonl` 改为**按设备分段**(`log/<device_id>-*.jsonl`),`materialize` 读取全部段合并重放。`meta` 表的 watermark 也按段记录。这是支持多端的最小必要改动。

## 4. 手机端难点与决策

| 难点 | 决策 |
|---|---|
| **OCR 算力** | 手机端**先只采集、存原件(StoredNoText)**,OCR 交给桌面在导入时补齐(pipeline 已支持 backfill)。若要端上 OCR,再评估 oar-ocr 在移动 ARM 的模型体积/速度。 |
| **文件/云访问(iOS 沙盒)** | 用 iCloud 容器 + security-scoped bookmark 指向保险箱;Android 用 SAF/共享存储。一次授权、持久化书签。 |
| **相机/扫描** | Tauri 相机插件或原生;导出图片走 pipeline `ingest`。文档矫正复用桌面 OCR 预处理(去阴影/纠偏)。 |
| **Tauri v2 mobile 成熟度** | 先做最薄的采集闭环验证可行性,再扩查看/分享。 |
| **DICOM** | 手机端 v1 不做影像阅片(算力/交互),仅采集与列表;阅片留桌面。 |

## 5. 分期

- **P1 · 采集闭环(手机→保险箱)**:一次配置指向云盘保险箱;拍照/选文件 → `ingest` 存入 → 事件写本设备日志段。桌面重启/实时读到即同步。**先验证 Tauri mobile + 云文件访问 + 日志分段。**
- **P2 · 查看**:抽共享前端渲染,手机端浏览时间线 + 看文本/图片报告。
- **P3 · 分享**:手机端复用 `share` 生成端到端加密文件 + 口令。
- **前置改造**:日志按 `device_id` 分段(§3),这是多端同步的地基,应在 P1 前落地。

## 6. 对桌面的影响(现在就该做的最小改动)

1. **日志分段**:`core-model` 写事件时用 `log/<device_id>-<seq>.jsonl`;`rebuild_from_log` 扫描并按时间合并所有段。(桌面单机无感,但为多端铺路。)
2. `device_id` 已在 `meta` 表,复用。
3. 其余(采集/查看/分享/加密)手机端**复用桌面已有实现**,不重造。

> 一句话:手机端不是"再做一个 app",是**把现有 Rust 内核 + 前端搬到移动壳里,补上相机与云文件访问**;数据靠事件溯源 + 云文件夹自然同步。功能因共享代码而始终对齐。
