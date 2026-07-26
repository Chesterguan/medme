> **✅ 已执行完毕(2026-07-26),本文件仅存档。** 实现结果、与本规范的三处偏离、真机验证数据见
> [2026-07-26 log](2026-07-26-doctor-12h-retention-and-delivery-gap.md)。别再照这份做。

# 2026-07-25 · 【下次任务】医生代拍模式:阅后即焚 → 12 小时本地保留

> **给下个 session 的交接。** 开头先读根 `CLAUDE.md` → 本文件 → memory `doctor-mode-12h-retention-next`。
> 分支:`feat/doc-geometry`(今晚全部移动端改动都在这;**尚未合 main**)。安卓真机(华为 Mate 9,MHA-L29)在连着,可 `adb` 直接装测。

## 一句话
把医生代拍从「用完即焚」放松成「本机最多留 12 小时(医生需 8h 内写病历),到时自动删」+「今日病历表(按病人名)」+「清空」按钮。**异步上传密文到微服务器 = 用户说『还没做』,本次不做,只留将来的话口。**

## 已定架构(用户拍板,别再推翻)
**复制 `ProfileManager` → 增强版 `ProxyPatientManager`;每个代拍病人 = 一个成员(独立 vault 路径,走现成 `openVault`,不碰 `vault.rs`);复用普通导入流程 → 姓名不匹配检查白捡。**
- **患者模式的 `ProfileManager` / `vault.rs` 一个字不动**(硬约束,用户反复强调「别弄坏现有的」)。
- 为啥不用现在的 `vault_ephemeral`:它是刻意隔离的即焚箱、单会话、且复制了一份 ingest/share 逻辑。改用「病人=成员 vault + 普通导入」更省代码,还免费拿到姓名不匹配。**本次把代拍从 `vault_ephemeral` 切走**(那文件可留着不用 / 后续删)。

## 已完成(本文件提交时已在 `feat/doc-geometry`)
- **告知文案改口径**(红线:不能承诺立刻删却留 12h)。`consent_screen.dart`:6 条→5 条大白话(拍什么/做什么用/交给谁/**存 12 小时自动删**/谁能打开),去掉「随时能喊停」(看病喊不了停=废话)。`proxy_intake_flow.dart` 横幅「用完即焚」→「本机最多留 12 小时 · 不进你自己的档案」。已 commit。

## 待实现(下次做这个)
1. **`ProxyPatientManager`(新 Dart 文件,照抄 `profile_manager.dart` 改)**:
   - 病人列表:每个 `{name, createdMs, dirId}`;持久化到 `<support>/proxy_patients.json`(独立命名空间,别和 `profiles.json` 混)。
   - **12h TTL**:`ensureLoaded` 时丢弃并删掉 `createdMs` 超 12h 的病人目录。
   - `create(name)` / `current` / `switchTo(id)` / `remove(id)` / `removeAll()`。
   - 路径:`<support 或 docs>/proxy-patients/<dirId>/vault`;**不上 iCloud 备份**(临时病人数据,隐私;`openVault` 的 `icloudContainerDir` 传 null)。
2. **重连代拍流程**(`proxy_intake_flow.dart` / `proxy_document_detail.dart`):
   - 「为病人代拍」→ `ProxyPatientManager.create` → `openVault(该病人路径, support, null)` → 同意屏 → 采集走**普通** `pickImportItems`+`ingestPendingItems`(姓名不匹配红条白捡)→ 逐份确认 → 交付 `build_encrypted_share`(带同意+已确认,现有函数)→ **不即焚**,留 12h。
   - 病人姓名:从 OCR 抽(`detected_name_for` / `parser::extract_demographics` 已有),自动命名该病人(仿 `maybeAutoNameRoot`)。
3. **医生主页 `doctor_home_screen.dart`**:加「今日病历表」列表(读 `ProxyPatientManager`,按病人名列),点进 = 打开该病人 vault 继续核对/交付;+「为病人代拍」按钮(新病人);+「清空」(单个病人 + 可选全部)。
4. **异步上传微服务器**:仅留 TODO/hook,不实现(用户说还没做)。

## 关键参考文件
- 照抄源:`apps/mobile_flutter/lib/profile_manager.dart`(186 行,成员管理全套)。
- 开箱套路:`apps/mobile_flutter/lib/vault_boot.dart`(`openCurrentProfileVault` → `openVault(docsDir,dataDir,icloud)`)。
- 普通导入 + 姓名不匹配:`import_flow.dart`(`pickImportItems`/`ingestPendingItems`/`autoNameCurrentProfileFrom`);红条 UI 在 `archive_screen.dart` 的 `_MismatchBanner`;`review_state.dart` 存 flag。
- 现有代拍(要切走):`proxy_intake_flow.dart` / `proxy_document_detail.dart` / `ephemeral_session.dart` / `rust/src/api/vault_ephemeral.rs`。
- 文案(已改):`consent_screen.dart`。

## 验证(安卓真机,华为连着)
装 build → 医生模式 →「为病人代拍」→ 同意(签名)→ 从相册选 `血常规报告1.jpg` 采集 → 确认 → 交付出口令 → **退出后重进,今日病历表里应还在(没即焚)、以病人名列出** → 12h 后自动消失 → 「清空」能删。**全程确认患者模式不受影响。**

## 硬约束
- 患者模式 `ProfileManager` / `vault.rs` 不动。
- 失败安全、不破坏正在工作的代拍。
- China-first / 纯端上 / 云只密文(见 ADR 0007、memory `ocr-v1-decisions-no-cloud`);本次上传功能不做。

---
## 今晚这条线的其它状态(供上下文)
- **OCR/布局线全做完 + 真机验过**(build 45,`feat/doc-geometry`):无 GMS 拍照解封锁、90° 转正、透视去斜、渲染横滑修「行列颠倒」。见 [2026-07-24 log](2026-07-24-ocr-banding-and-doctor-proxy.md) + [ADR 0007](../ADR/0007-android-doc-scan-degms-and-geometry.md)。
- **安卓 1.3.0 已公开发布**(main,落地页下载已是带代拍的 1.3.0 arm64)。
- **`feat/doc-geometry` 尚未合 main** —— 里面 build 40-45 的 OCR 改动 + 本次代拍文案,待验收后合。
- 遗留小项:双栏化验表配对(递减收益,缓);认字 80 分(server 模型,已 park);无-GMS 拍照需真·无 GMS 机端到端验。
