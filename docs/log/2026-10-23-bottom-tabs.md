# 2026-10-23 · 底部四 tab:病历 / 现在 / 用药 / 我 → 修订 2(10-25)改成 病历 / 化验 / 用药 / 我

spec:`docs/superpowers/specs/2026-10-23-bottom-tabs-redesign-design.md`(稿 A;用户指令 spec 写完不等审直接实施,「只有用户能答」的问题由实施者定,§11.1 逐条标明);ADR:[0013](../ADR/0013-bottom-tabs-profile-merged-into-home.md)(Amends 0011/0012)。分支 `feat/bottom-tabs`,基于 `feat/generic-profile`。背景:用户把 Epic 全量病历装到 iPhone 14 Pro 试 #243/#247/#248 后的原话——「依据没必要列出来,点的时候显示原件就好」「现在里面很多东西不是现在的」「把药单独加一个 tab 显示最近,医生可以搜过往,过敏也移过去」「还是只有红斑狼疮的包,强行打开没有意义」「重新思考底部 tab」「太久远的化验不用展示」「化验值没有折线图不容易看」。

**做了什么**
- Rust:`package_applies`(触发词 `triggers.diagnosis_patterns` 第一次有读者 + crate 常量 `PACKAGE_ICD_PREFIXES` sle→M32),通用视图不再读 `enable/disable`;`ProfileView.packages[]`(单包路径不序列化,SLE golden 逐字节不变);包的 gc 行不再替换用药行;`RECENT_DAYS=365` 把 `family_cards` 切成 `families` / `earlier_families`;`materialize_meds`(最近 / 更早按 180 天与原文停药切,带 first/change/stopped 剂量链,过敏在同一本依据簿引出处);`MedRow` 多 `drug_key / raw_names`;parser 过敏加英文表式 / 行式 + 四种否定,`extract_allergies_pairs` 改 pub、手机 crate 的手抄副本删掉;两个 FFI `vault_profile_meds_view` / `vault_profile_lab_families`(44 号不动);术语覆盖层改成装着就装上。
- Flutter:`HomeTab` 四席;`now_screen.dart`(族卡展开 = 诊断行 → 最近的用药一行 → 化验趋势行 → 包段;通用一排;其他化验;更早的诊断 / 化验折叠;搜索)、`meds_screen.dart`(最近的用药 / 过敏 / 更早的用药 + 剂量链 + 族 chip + 搜索)、`lab_trend_row.dart`(`TrendChart` 24 高迷你线,点开 96 高 + 历年数值行)、`evidence_open.dart`(单条直开、多条弹层、`span` 字节偏移→UTF-16 对位);病历页 chip 七颗(手术 / 影像 / 病理从就诊组里抽出来平铺);删 `trends_screen.dart` / `disease_profile_card.dart` / `disease_profile_screen.dart` 与它们的测试,`ProvenanceFooter` 搬成独立 widget,`DiseaseProfileSource` 留给二维码分享;「记录一下」进「添加」弹层;埋点目录 / 集成测试的「趋势」引用改到「现在」。
- 实施中与 spec 的偏差(已回写):包的族用 `manifest.family`;「用药」tab 不做包替换;措辞「最近的用药 / 更早的用药」(「当前用药」是应急卡早有的禁词)。诊断无码落在「未归类」(李静示例)时包段独立一段排在族卡后。

**验证**
- `cargo test --workspace --no-fail-fast` 52 个测试二进制 1020 条全绿;`cargo clippy --workspace --all-targets -D warnings` 与 `cargo fmt --check` 干净;手机 crate `cargo test` 84 + `frb_dispatch_indices` 绿;`flutter analyze` 零;`flutter test` 1098 过、1 红 = `glossary_guard` 弱闸「导入」(`import_flow.dart`,PR #243 起就红,本分支没动它);`copy_unchanged` 基线前移到 cf3d925。
- 集成测试(`integration_test/`)只改了引用,**没有在模拟器上跑**。
- 模拟器真实规模(用户本人 Epic 包,686 份;结果不进仓库,见下)。

**真实包在模拟器上的发现**(iPhone 17 Pro 模拟器,新建成员导入 675 份后测,测完删成员;只记聚合,不记具体值)
- 已修:过敏列表里同一物质五六种大小写写法各占一行、「and」「reviewed allergy section in the chart」这类叙述碎片被当过敏原、行尾 `-`/`,` 换行的长列表后半截丢失 → parser 续行 / 按 and 切 / 叙述句过滤 / 小写合并(7f1452d)。独立审查另抓出「SLE」子串命中 "sleep apnea" 等 10 条,全修(22bb766)。
- 可读性 / 速度:四个 tab 首开都在 2 秒内,「现在」8 张族卡 + 更早的诊断 37 条 / 更早的化验 153 项折成两行,「用药」最近 8 / 更早 74,滚动不卡,没有溢出、没有崩溃;SLE 包没有出现(用户无 M32、无狼疮字样)。
- 留给后续(都是上游数据 / 解析缺口,不在本 spec):
  - 「未归类 · 24 条」偏大:Epic 的 Visit diagnoses 很多行没码,全落「未归类」——英文诊断名→ICD 映射缺口(与中文那条同一类)。
  - 通用一排(血常规 / 电解质 / 肝功能)在真实规模下二三十行,占「现在」大半屏;可考虑默认折叠或只展开异常项。
  - 化验上游数据:一条胆红素低值标「偏高」(flag 来自原单 / 参考区间解析)、「Not Established」被当成单位印出来——适配器或 labs parser 的既有问题。
  - 用药解析既有问题:剂量解析成 `0mg`、`bid` / `q8h` 当剂量、词典认不出的药按原文整行名(含剂型)列出——`extract_meds`。
  - 「最近的用药」= 最近一次住院的出院带药清单,与实际在服药可能不同;Epic `Patient not taking` 仍未解析。
  - 行式过敏在 Epic 的一种写法里物质与反应连成一个短语,拆不开(只在一两条上出现)。

**留的**
- Problem List `Resolved On`、Epic `Patient not taking`、中文诊断名→ICD、行式过敏跨行续写、tab 位置持久化、图片档依据画框、桌面 Tauri(ADR 0013 Consequences)。
- 集成测试没在模拟器上跑;`openRecordSheet` 走新路径(病历 → 添加 → 记录一下)未实跑。
- `glossary_guard` 弱闸「导入」仍红(#243 起)。

**修订 2(2026-10-25)**:用户装了真机 debug 包(iOS 14+ 的 debug 包不能从桌面自启,先撞了一次闪退;profile 包要自动签名覆盖才编得过,编好没装——用户叫停)后的原话:「现在 是别的是个啥 乱得很 趋势也不见了」「化验的折线是必须要有的 你实在不会 模仿 mychart 的设计都行」。照 MyChart 收口(spec「修订 2」、ADR 0013 Addendum):
- 「现在」tab 取消 → **化验**:按报告(`view_lab_reports`:一份化验文档一行,词典面板中文名 · 日期,异常徽标;表里是印刷值、定性值原样、箭头按 flag / 区间判)/ 按指标(原趋势行 + 八颗分类 chip + 搜索 + 12 个月「更早」折叠),任何指标点开 = `LabDetailScreen`(160 高 `TrendChart` + 参考带 + 每点回原件)。参考区间的出处收进 ⓘ。
- **我 → 健康摘要**:诊断按族折叠(+ 最近的用药一行 + 包段)、手术史(surgery 泳道)、植入物(Z95–Z97)、过敏、「更早的诊断」折叠。
- 诊断「最近」排除 `doc_type: other` 且标题含「摘要 / summary」的文档(Epic 患者摘要的日期是导出日)。
- 验证:`flutter test` 1098 过(两道预期红不变)、`cargo test -p profile` 与手机 crate 绿、clippy / fmt 干净;独立审查与真实数据见下。
- 修订 2 的独立审查抓出 4 严重 4 重要,全修(4a7fcac):「按报告」的正则兜底此前对所有文档 whole-doc 跑 `extract_labs`(出院小结正文的血压会冒出来当化验单)→ parser 抽出 `doc_lab_observations` 与 `aggregate` 共用;箭头区间优先、与折线页一致;自测序列 key 唯一;列表按需构建;摘要文档判定收窄到「患者 / 病历摘要」。
- 顺手:重导病历包时侧文件内容变了就重挂抽取(`updated` 计数,46ab4eb)——适配器修了化验解析后用户重导新包即可,不必删成员。
