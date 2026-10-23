# 底部 tab 重构:病历 / 现在 / 用药 / 我 — 设计

日期 2026-10-23。上游:[ADR 0011](../../ADR/0011-disease-profile-skill-packages.md)、[ADR 0012](../../ADR/0012-generic-chronic-profile-layer.md)、[2026-10-21 时间线分档](2026-10-21-timeline-tiers-design.md)(#247)、[2026-10-22 通用病程档案层](2026-10-22-generic-chronic-profile-design.md)(#248)。分支 `feat/bottom-tabs`(基于 `feat/generic-profile`)。状态:**已实施**(2026-10-23,分支 `feat/bottom-tabs`,ADR [0013](../../ADR/0013-bottom-tabs-profile-merged-into-home.md))。按用户的流程指令 spec 写完不等审直接实施;「只有用户能答」的问题由实施者按 spec 原则与减法方向定,§11.1 逐条标「实施者的决定」,用户看完不认可改那里即可。实施中与 spec 的偏差:§4.4 包的族用 `manifest.family`、§5.1 不做包替换、措辞「最近的用药 / 更早的用药」(均已回写进本文)。 合成数据只用 Doe, Jane / 张建国 / 李静。

## 0. 一句话

底部从「病历 / 趋势 / 我」改成「**病历 / 现在 / 用药 / 我**」:趋势页、病程档案入口卡、档案页的「进程」「依据」两个 tab、包的「开启」按钮全部取消。「现在」只放此刻成立的东西(最近 12 个月有记录的诊断按族折叠,每族下最近化验带迷你折线);「用药」把最近的用药、过敏、可搜索的更早的用药放在一页;「依据」变成任何值点一下就打开原件并高亮;「进程」的泳道并进「病历」的筛选 chip 一排。

## 1. 意图与用户原话

用户把自己的 Epic 全量病历(675 份、诊断 677 条、化验 11666 条、用药 667 条、9 次住院)装到 iPhone 14 Pro 上试了 #243/#247/#248 三个叠放 PR,2026-10-23 反馈原话要点:

- 「依据没必要列出来,点的时候显示原件就好」
- 「现在里面很多东西不是现在的,过去吃过的药没必要显示」
- 「把药单独加一个 tab 显示最近,医生可以搜过往,过敏也移过去」
- 「还是只有红斑狼疮的包,强行打开没有意义」
- 「重新思考底部 tab」
- 「太久远的化验不用展示」
- 「化验值没有折线图不容易看」

父会话向用户提出并获认可的方向(本 spec 据此展开):四个 tab 病历/现在/用药/我;病历 = 时间线(#247)并入「进程」泳道作筛选;现在 = 只放此刻成立的东西;用药 = 当前在上、过敏紧随、下面可搜索的过往按药名聚合剂量变化;我不变;依据不做 tab;病种包只在对应族有诊断时出现在该族展开区;化验默认只看最近 12 个月有结果的项目,更早收成一行;化验行复用趋势页组件。

## 2. 现状(读代码得来,写 spec 的依据)

- 底部 tab:`main.dart` `HomeShell`,`tabScreens = [ArchiveScreen, TrendsScreen, SettingsScreen]`,常量 `HomeTab{records,trends,me,count}`(`vault_events.dart:26`),`selectedTab` 是内存里的 `ValueNotifier`,不持久化;`test/mobile_ia_test.dart` 钉「页数 == 目的地数 == HomeTab.count」。
- 趋势页 `trends_screen.dart`(1423 行):入口卡 `DiseaseProfileCard` → 「关键化验」标题 → 大类 chip `PanelChipsRow` → 快照 `KeyLabsSnapshot`(8 行封顶)→ 「只看异常」行 → `SeriesCard` 列表 → `RecentVisitsCard` → `RecordEntryCard`(记录一下)→ 来源脚注;AppBar 里有搜索框。**`SeriesCard` 没有折线**:`:722` 是一块 78×24 的空 `SizedBox` 占位,展开区 `:820` 是 82 高的空色块(注释写「Stage 2」)。真正的折线组件 `widgets/trend_chart.dart` `TrendChart({series, height=96})` 只被档案页 `profile_sections.dart:901` 用。这正是用户说「没有折线图」的原因。
- 档案页 `disease_profile_screen.dart`:三 tab 固定「现在 / 进程 / 依据」,`_kTabOfKind` 把 `family_cards/med_table/state/…` 归「现在」,`journey/series_chart` 归「进程」,`evidence` 归「依据」;通用段在前、每个装着的包一段 `_PackageHeader` 带「开启/关闭病程档案」按钮(`vault_profile_record_event('enable'|'disable')`)。入口卡 `disease_profile_card.dart` 每包一行带「开启」。
- 依据点开:`_Body._links.onOpen` 把 `ev:<doc>:<n>` 经 `documents[]` 桥映到 `document_id`,`push(DocumentDetailScreen(docId, highlight: quote))`;`document_detail.dart:616` `_HighlightedText` 用 `indexOf(quote)` 高亮**第一处**;图片档不画框只跳页;全部本地,不联网。Rust 算的 `span` 字节偏移 Dart 没用。
- 病历页 `archive_screen.dart` `ArchiveTimeline`:chip 一排 `全部/住院/急诊/门诊`(`_filter`,内存态),按月分组,住院/急诊独立卡、门诊整月折叠卡;**没有搜索框**。
- 引擎 `packages/profile/src/generic.rs`:`materialize_generic` 出 `family_cards`(族按 `last_seen` 倒序,`other` 倒二、`uncoded` 最后;每族 `labs[]` 最近值 `state::latest_point`)、`med_table`(`STALE_DAYS=180`,`stops_drug` 只认同一子句无否定的停词,`since` = 剂量键连续起点,行里有 `stopped?{at,evidence}`)、`journey`(住院/急诊/手术/影像/病理/`med:*`/`dx:*` 泳道)、`evidence`;再对每个**开着**的包 `sections_for` 叠在后面,包的 `gc` 行替换通用层同类药。`Package.triggers.diagnosis_patterns`(SLE 包是「系统性红斑狼疮/红斑狼疮/SLE/狼疮性肾炎/狼疮肾炎」五个字符串)**今天没有任何读者**。
- 诊断状态:`deid::DiagnosisItem{text,icd,unverified}`、Epic 侧文件只有 `text+icd`——**没有「活动/已解决」字段**。Epic 原文里 `Problem List as of <日期>` 表有 `Noted On / Resolved On` 两列,适配器(`myEHR/epic_adapter/extract.py` `DX_LIST_HEAD_RE`)不读那张表;`Visit diagnoses`(119 处)、`Past Medical History`(204 处,无码)、`Patient not taking`(66 处)也都压平成同一批 `diagnoses[]`/`meds[]`,区别不保留。
- 过敏:`parser::handoff::extract_allergies_pairs` 只认**中文**「过敏史」写法(含否定/不详两层保护);`AllergyItemDto{substance,reaction,document_ids}` 进 `VisitSummaryDto` 与 `EmergencyCardDto`,「给医生看」与应急卡在用。侧文件、`Extraction`、`AggregatedClinical` 都没有过敏字段。Epic 原文的过敏是一张 `Allergies / Allergen | Reactions / • 物质  反应` 表,另有一行式 `Allergies: A, B, C`——今天一条都抽不出来。
- 文案闸:`copy_unchanged_test.dart` `kBaseline='d731618'`;`glossary_guard_test.dart` 禁「导入/分享/档案/同步」等旧词(`病程档案` 例外)。FFI 新函数名必须字典序排在 `recognize_image_pp` 之后(`frb_dispatch_indices` 钉 44)。

## 3. 新信息架构

### 3.1 四个 tab 的职责边界

| tab | 回答的问题 | 放什么 | 不放什么 |
|---|---|---|---|
| **病历** | 发生过什么 | 成员行、添加 / 给医生看、还没核对、chip 一排(全部/住院/急诊/门诊/手术/影像/病理)、按月时间线 | 任何推导出来的值 |
| **现在** | 我此刻有什么 | 最近 12 个月有记录的诊断按族折叠;每族下最近化验(最近值 + 参考区间 + 迷你折线);通用一排(血常规/电解质/肝功能);对应族有诊断时该族里多一段病种包;更早的诊断/化验各收成一行 | 用药(只给最近的用药的药名,点去「用药」)、泳道、依据清单、提醒 |
| **用药** | 最近记录里有什么药、更早吃过什么、对什么过敏 | 最近的用药(180 天内有记录);过敏;可搜索的更早的用药(按药名聚合,剂量变化链) | 化验、诊断 |
| **我** | 不变 | 不变 | — |

**互不重复的原则**:一个事实只在一个 tab 上有「家」,别处只给跳转。诊断的家在「现在」;药的家在「用药」(「现在」族卡只列药名,点了去「用药」并按族筛);化验的家在「现在」;原件的家在「病历」(任何 tab 的值点一下进原件)。

### 3.2 被合并或删除的现有页面

| 现有 | 去向 |
|---|---|
| 趋势 tab(`TrendsScreen`) | **删**。关键化验快照、大类 chip、`SeriesCard` 列表 → 「现在」的化验行(§4.2);搜索框 → 「现在」AppBar;「只看异常」行 → 删(族内按偏高/偏低标记已可见,减法);`RecentVisitsCard` → 删(病历页已有);`RecordEntryCard`「记录一下」 → 移到病历页「添加」弹层里(与添加病历同一入口,2026-09-23 用户:「记录一下」不该在趋势里);来源脚注 → 「现在」页尾保留 |
| 病程档案入口卡(`DiseaseProfileCard`) | **删**,无入口卡,「现在」本身就是档案 |
| 档案页「进程」tab | **删**。住院/急诊/手术/影像/病理泳道 → 病历页 chip;用药变化泳道 → 「用药」tab 每个药的剂量变化链;诊断首次出现 → 「现在」诊断行的「首次 YYYY-MM」 |
| 档案页「依据」tab | **删**。改成点击即看原件(§7) |
| 包的「开启 / 关闭」按钮与 `enable/disable` 事件 | **按钮删**。包是否出现由触发规则决定(§4.4),不再问用户;事件类型与引擎的 `is_enabled` 保留给查看器/分享的单包路径,手机通用视图不再读它 |
| `DiseaseProfileScreen` | **删**(`profile_sections.dart` 的渲染器保留并被「现在」复用) |

桌面 Tauri、医生查看器、二维码分享、`vault_profile_view(dir, package_id)` 单包 FFI 全部不动。

## 4. 「现在」的纳入规则

一个常量 `RECENT_DAYS = 365`(界面文案「最近 12 个月」),诊断与化验共用。

### 4.1 诊断:进「现在」还是收起

- **判定只用事实,不判「活动/已解决」**:诊断 `last_seen`(它所有出处文档日期的最大值,`generic.rs` 已算)≥ `today − 365` → 进族卡;否则进页尾一行「更早的诊断 N 条」,点开按族列出同样的行。文案全程只说「N 份记录提到 · 最近 YYYY-MM」,不出现「活动」「已解决」「既往」。
- **来源**:`AggregatedClinical.conditions[]`,与 #248 相同。Epic 的 `Past Medical History`/`Visit diagnoses`/`Problem List` 今天压平成一批,本 spec **不**在 Medme 侧猜它们的区别;`Problem List` 表的 `Resolved On` 列是唯一能给「已解决」的出处,读它要改 myEHR 适配器(侧文件加可选 `resolved_on`)+ `deid::DiagnosisItem` 加 `#[serde(default)] resolved_on: Option<String>`,**留作后续**(§10 决定 3);等那条通了,规则只加一句「`resolved_on` 非空且早于今天 → 直接进『更早』」。
- 族内排序、族排序、`other` 倒二折叠、`uncoded` 最后:沿用 #248。
- 门槛(#248 的「带码诊断 <3 只出一行」)**取消**:「现在」是 tab 不是卡,没有东西就显示空态「还没有诊断或化验记录」。

### 4.2 化验:最近 12 个月有结果才进

- 一条序列(`AnalyteSeries`)的**最近有日期的点** ≥ `today − 365` → 进;否则进页尾「更早的化验 N 项」一行,点开同样的行式。自测(`self_measured`)序列同规则。
- **在族卡里**:#248 的 key→族小表不变,每族的化验行改成趋势行式(下一条);通用一排(血常规/电解质/肝功能)同样行式;**不在任何族表也不在通用 panel 的序列**(其他大类、词典认不出的)放族卡之后一段「其他化验」,同样行式、同样 12 个月规则。
- **每一行** = 名称 + 迷你折线 + 最近值(印刷值配印刷单位)+ 偏高/偏低标记;第二行:参考区间 + 日期。迷你折线 = `TrendChart(series, height: 24)` 放进 `SeriesCard:722` 那块 78×24 的空位(不新写画布,`TrendChart` 已经无文字、只靠 `height` 定尺寸)。只有 1 个点时不画线、画一个点。
- **点一行**:原地展开 `TrendChart(height: 96)` + 历年数值行(与档案页 `_SeriesCard` 相同)+ 每个点可点 → 原件(`TrendPointDto.documentId`)。这是 `SeriesCard` 展开区那个 82 高空色块本来要放的东西。
- **数据**:化验行的数据源统一用 `TrendSeriesDto`(`view_trends` 已有全部点、单位、参考区间、`documentId`),族归属用 `TrendSeriesDto.analyteKey` 查 #248 的 key→族表与 `panel`。**不**再让 Rust `family_cards.labs[]` 只给一个最近值——那条字段保留(查看器/分享还在用),手机「现在」页不读它。族→key 的表要能从 Dart 查到:加一个 FFI `vault_profile_lab_families() -> String`(JSON `{family: [key…]}`,名字排在 `recognize_image_pp` 后),一次拉、内存缓存。
- 搜索:AppBar 搜索框(沿用 `_queryCtl`),输入时整页只剩名字命中的化验行(跨族、含「更早」),与今天趋势页搜索同一体验。

### 4.3 「现在」页的结构(自上而下)

1. 族卡 × N(按 `last_seen` 倒序;每张:族名 · 诊断 M 条 · 最近 YYYY-MM;展开 → 诊断行 → 「用药:名1 · 名2 ›」一行(只名字,点去用药 tab 该族)→ 化验行 → 该族的包段(§4.4))
2. 通用一排(血常规 / 电解质 / 肝功能)
3. 其他化验(不在族表/通用 panel 的)
4. 更早的诊断 N 条(折叠一行)
5. 更早的化验 N 项(折叠一行)
6. 来源脚注(`ProvenanceFooter`)+ 免责一句(沿用档案页)

### 4.4 与 ADR 0012 两层模型的关系:包只在对应族有诊断时出现

- 通用层(族卡、化验行)**永远显示**,与 0012 决定 1 一致。
- 包层:不再有独立入口、不再要用户「开启」。一个装着的包**出现**当且仅当 `package_applies(pkg, ctx)`:保险箱任一诊断的 `raw_text` 命中包 `triggers.diagnosis_patterns` 任一项(子串,大小写不敏感)**或**任一诊断的归一后 ICD 命中 `generic_tables::PACKAGE_ICD_PREFIXES` 里该包的前缀(常量表,第一行 `("sle", &["M32"])`;放在 crate 常量里而不是包里,是为了**不重签包**)。两条任一成立即出现;都不成立 → 该包的段不算、不渲染、界面任何地方不提它。
- 出现的位置:该包所属族(包自带的 `manifest.family`,SLE 包写的是 `immune`,不另建表)的展开区末尾,一段「系统性红斑狼疮(病种包)」,内容 = 今天 `sections_for` 的 `state/status_card/score_card/checklist/reminders`;包的 `journey/series_chart/evidence` 不在「现在」渲染。
- 包的 `latest_dose` 行**不再替换**通用层同类药(#248 §4 那条作废):药在「用药」tab 全量列,包段在「现在」只出自己的状态行;`replaced_by_packages` 删掉。
- 引擎:`materialize_generic` 的 `installed` 过滤从 `is_enabled` 改成 `package_applies`;`ProfileView` 多一个 `packages: [{id, display_name, family, applies}]`(`skip_serializing_if` 空 → 单包路径不序列化,两份 SLE golden 逐字节不变);单包 `materialize(..., pkg, ...)` 不变。`enable/disable` 事件仍可写(查看器那条路),通用视图忽略。术语覆盖层(`overlay_entries`)从「开着的包」改成「装着的全部包」——覆盖层只加不改(ADR 0011 决定 6),装着就装上,不再等用户开启。
- 李静示例(中文「系统性红斑狼疮」无 ICD)靠 `diagnosis_patterns` 命中;Doe, Jane 无 M32 也无狼疮字样 → SLE 包不出现(这是用户原话「强行打开没有意义」的验收点)。

## 5. 「用药」tab

### 5.1 最近的用药(措辞:不叫「当前用药」——`mobile_ia_test`/应急卡明令禁用「当前用药/在用药」,因为 `MedSpan.status` 恒 active、不能暗示有效医嘱;段名「最近的用药」,副标「180 天内有记录」)

- 行来源:`med_table.rows[]`,**全部药、不做包替换**(#248 的「包的 `latest_dose` 行顶替通用行」只在同一页才有意义;现在药在「用药」、包段在「现在」,两处各说各的,同一药不会在同一屏出两行)。包段里的等效剂量行照旧留在「现在」的包段。
- **最近** = `stopped == null && !stale`(`days_since ≤ 180`,沿用 #248 的 `STALE_DAYS`;包的 `stale_after_days` 覆盖那条随包替换一起作废,通用层统一 180 天)。
- 每行:药名(词典名;原文名不同则小字原文)· 最近剂量 · 「记录中自 YYYY-MM-DD 起」· 「N 天前有记录」· 族标签;点开 → 剂量变化链(§5.3 同一控件)+ 每条可点原件。
- 排序:`last_seen` 倒序。空态:「最近 180 天没有用药记录」。
- 「现在」族卡里的「最近的用药:名1 · 名2 ›」只列**最近**用药的名字。

### 5.2 过敏

- 位置:最近的用药之下、更早的用药之上,一段「过敏」;每行 物质 · 反应 · 点开原件。
- 来源:`parser::extract_allergies_pairs`(今天在 `handoff.rs` 私有,手机端 `vault_projections.rs:737` 另有一份逐字副本——本次改 `pub`、删副本);「用药」tab 的过敏由 Rust `materialize_meds` 在同一本依据簿里**引出处**(物质串在该文档的那一行,`quote/span/title/date`),所以过敏行也能点开原件并高亮;「给医生看」与应急卡照旧用 `collect_allergies`。同一物质不同反应写法 → 两行(与今天同,不合并)。
- **英文识别补进 parser**(不改侧文件、不改 `Extraction`、零新字段):`extract_allergies_pairs` 加英文层,只认两种结构化写法——(a) 表式:一行 `Allergies`(可带冒号)后跟表头行含 `Allergen` 与 `Reactions`,之后每个 `•`/`·` 开头的行 = `物质  反应`(两列以 ≥2 空格分隔;反应为空允许);(b) 行式:`Allergies: A, B, C`(逗号分隔,到行尾)。否定:`No Known Allergies`、`NKDA`、`NKA`、`No known drug allergies` → 不产出条目(与中文否定层同一出口);`Allergies: Patient has no known allergies` 同。一条物质在多份文档出现 → 合并、`document_ids` 累加(今天已如此)。
- 空态文案:「记录里没找到过敏史」(不说「无过敏」——与 `is_allergy_unclear` 同一立场)。

### 5.3 更早的用药:按药名聚合、剂量变化链、可搜索

- **更早** = `stopped != null || stale`。
- 按 `drug_key`(无则 `name`)聚合,每个药一行:药名 · 最近一次剂量 · 最后记录 YYYY-MM-DD · (停药行多「病历写了停药 · 日期」)。点开 → **剂量变化链**:按时间列出该药的 `since` 起点与每个 `dose_change`(from → to · 日期),末尾若有「停」节点列出;每个节点可点原件。数据直接用 #248 `journey` 里的 `med:<drug_key>` 泳道(`MedLane.nodes`:`first/change/stopped`),不另算。
- 排序:`last_seen` 倒序。
- **搜索**:AppBar 搜索框;命中规则 = 查询串(大小写不敏感)是药名或任一 `raw_names` 的子串(`MedRow` 本次加 `drug_key`、`raw_names`);搜索时「最近」「过敏」「更早」三段都只剩命中行,段标题保留计数。这是用户原话「医生可以搜过往」的落点。
- 不做:按 ATC 分组、按族分组(族只作行尾标签);「现在」族卡跳过来时带一个预填的族筛选 chip(`vault_events.dart` 新加 `medsFilterFamily: ValueNotifier<String?>`),清掉即全部。
- 自测序列(血压/体重等 `self_measured`)在「现在」进「其他化验」段,行上保留「家测」图例;同一 12 个月规则。

### 5.4 数据接口

一个新 FFI `vault_profile_meds_view(dir) -> String`(名字排在 `recognize_image_pp` 后):返回 `profile::materialize_meds` 的 JSON `{recent: [MedRow…], earlier: [MedRow + nodes…], allergies: [{substance, reaction, evidence[]}…], evidence: [...], stale_after_days: 180}` + `documents[]` 桥;`MedRow` 改 `pub`(`generic.rs` 今天是私有的,手机 crate 调不到),最近/更早的切分在 Rust 做(规则只写一处)。首版不做缓存,真机测了 97 种药的耗时再说(§11 验收 13)。

## 6. 「病历」:进程泳道并入筛选 chip

- chip 一排 = `全部 | 住院 | 急诊 | 门诊 | 手术 | 影像 | 病理`,顺序固定,计数 0 不画(#247 规矩不变),只剩「全部」整排不画。
- 新三颗是**文档类型筛选**:`手术` = `docType == surgery`,`影像` = `imaging_report`,`病理` = `pathology`;选中时时间线只列这类文档,从就诊组里**抽出来平铺**(一份文档一行,带日期、标题、所属就诊的医院名),按月分组不变。不需要 profile 引擎——`TimelineGroupDto` 里已经有 `docType`。
- 「用药变化」「诊断首次出现」两条泳道**不**进 chip(不是文档,各自去了「用药」和「现在」)。
- 单选,与今天一样;`_filter` 类型从 `String?`(三值)扩成七值的枚举。
- 搜索:病历页**不加**搜索框(2026-09-22 用户裁定,Stage 2 搜索做出来再放回)。

## 7. 「依据」改为点击即看原件

- **哪些可点**:「现在」的每条诊断行、每条化验行展开后的每个点、通用一排的每行;「用药」的每行、剂量变化链的每个节点、每条过敏;包段里每个带 `evidence[]` 的状态行/达标项(沿用 `_EvidenceChips`,但 chip 改成行尾一个「原件 ›」小字,不再一排 `ev:` 编号)。
- **弹什么**:只有一条依据 → 直接 `push(DocumentDetailScreen(docId, highlight: quote))`(今天的路径,不改);多条(诊断有 18 份记录提到)→ 底部弹层列出「日期 · 标题 · 引文一行」,点一条进原件。
- **如何高亮**:沿用 `_HighlightedText` 的 `indexOf(quote)`;**改一处**:`EvidenceOut.span` 是 needle(药名/数值)在原文里的 **UTF-8 字节偏移**,`quote` 常是含它的整行;Dart 把字节偏移换成 UTF-16 下标后,取**包含该下标的那一处** `quote`(`lastIndexOf(quote, idx)` 且区间覆盖 idx),换算失败、找不到都退回 `indexOf` 第一处。图片档:跳到那一页不画框(三视图 spec 决定,不变)。
- **离线**:全部本地(`getDocument` 读本地保险箱,视图是纯投影),不新增任何网络请求。
- `evidence` section 引擎照出(查看器/分享用),手机「现在」「用药」只拿它建 `evidenceById` 索引,不渲染成列表。

## 8. 非目标与反目标

- **不做诊断、不贴标签**:不出现「活动」「已解决」「既往」「在吃」「已停」「控制良好」;「现在」= 「最近 12 个月有记录」,「最近的用药」= 「180 天内有记录且原文没写停」,文案只说天数与日期。
- **不编值**:每个值、日期、诊断可逐字回溯到原件;`verified:false` 的照显示并标「需核对」。
- **不引入新事件类型、不改保险箱格式、不改 `Extraction` 结构**:英文过敏走 parser 正则;包触发走 crate 常量;「现在/过往」切分是投影。
- **不改包、不重签包**:`PACKAGE_ICD_PREFIXES` 在 crate 里。
- **不上云**。
- **不做中文诊断名→ICD、不读 Problem List 的 Resolved On、不解析 `Patient not taking`**——都记缺口。
- **减法**:删多于加——趋势 tab、入口卡、两个档案 tab、开启按钮、只看异常、最近就诊卡全删;新加的是两个 tab(顶替趋势)、三颗 chip、「添加」弹层一行、两个 FFI。「只看异常」默认开着这一行为随之消失:「现在」列最近 12 个月全部序列,偏高/偏低靠行内标记。一个品牌色,颜色只说状态(偏高橙/偏低蓝/需核对琥珀),类别不上色,迷你折线不上色。
- **不定视觉**:只给结构;字号、间距、图标按 `design_tokens.dart` 现成的。

## 9. 结构稿(文字线框,393 宽;三稿只差「现在」首屏的组织方式)

共同部分:底部 `[病历] [现在] [用药] [我]`;「用药」首屏三稿相同。

```
用药(三稿相同)                                    [🔍]
最近的用药 · 6(180 天内有记录)
  华法林 4mg          记录中自 2025-01-14 起 · 12 天前   心血管 ›
  美托洛尔 25mg       记录中自 2024-03-10 起 · 12 天前   心血管 ›
  …
过敏 · 1
  青霉素 · 皮疹                                        ›
更早的用药 · 9
  伏立康唑 200mg bid  最后记录 2025-11-17 · 病历写了停药  感染 ›
  泼尼松 5mg          最后记录 2024-10-14              免疫 ›
  …
(点开一行)
  伏立康唑
    2025-06-14  记录中自此起 200mg bid               原件 ›
    2025-11-17  病历写了停药「Voriconazole discontinued」 原件 ›
```

### 稿 A · 族卡为主,化验行在族内(对现有界面改动最小)

```
现在                                              [🔍]
▸ 心血管 · 2 条诊断 · 最近 2026-09
    主动脉瓣置换术后 Z95.2 · 首次 2024-03 · 最近 2026-09 · 18 份记录 ›
    主动脉瓣狭窄 I35.0 · 首次 2024-03 · 最近 2024-03 · 2 份记录 ›
    最近的用药:华法林 · 美托洛尔 ›
    INR      ╱╲╱   2.4        偏高   2.0–3.0 · 2026-10-01
    BNP      ╲__   180 pg/mL         <100 · 2026-09-15
    肌酐     ___   1.1 mg/dL         0.6–1.2 · 2026-09-15
▸ 感染 · 1 条 · 最近 2025-11
    肺曲霉病 B44.1 …
    半乳甘露聚糖 ╲_  0.3 …
▸ 免疫 · 1 条 · 最近 2026-08            ← 只有李静这种有狼疮诊断的箱子才有
    系统性红斑狼疮 …
    补体 C3 …
    ── 系统性红斑狼疮(病种包)──          ← 包段,只在这里
    激素等效量 7.5 mg/天 · …
血常规 / 电解质 / 肝功能
    血红蛋白 ╱──  128 g/L …
其他化验 · 3
更早的诊断 · 4 条                                  ›
更早的化验 · 21 项                                 ›
来源 · 以上内容来自你的病历原件,不是诊断
```

特点:#248 稿 A 的族折叠原样保留,只是把族内化验从「最近值一行」换成趋势行、去掉用药表、加包段位置、加两条「更早」;一页看全。

### 稿 B · 化验在前,诊断族在后

```
现在                                              [🔍]
最近 12 个月的化验 · 14 项
  INR      ╱╲╱  2.4  偏高   …
  BNP      …
  …(按偏高/偏低在前、再按日期)
诊断(按族)
▸ 心血管 · 2 条 …(展开只列诊断行 + 用药名 + 包段)
▸ 感染 · 1 条 …
更早的诊断 · 4 条 ›    更早的化验 · 21 项 ›
```

特点:「哪个指标不对」第一眼可见(2026-09-22 趋势页的首屏问题);代价:化验失去族的上下文,用户问「我的心脏病怎么样」要自己对。

### 稿 C · 两段页:顶上族 chip 一排筛整页

```
现在                                              [🔍]
[全部] [心血管 2] [感染 1] [免疫 1] [其他 4]
(选「心血管」→ 下面只剩该族的诊断行、用药名、化验行、包段;「全部」= 稿 A 平铺)
```

特点:与病历页/#247 的 chip 手法一致;代价:多一层交互,族少于 3 时 chip 排是噪音。

**实施者的决定:稿 A。** 理由:对 #248 已落地界面改动最小(`_FamilyTile` 结构不动,只换子行);用户原话「我的心脏病什么都没有」的答案仍是族卡第一行;稿 C 的 chip 层在 Doe, Jane 这种 3–4 个族的箱子上是噪音。

## 10. 与 ADR 的关系、迁移与兼容

- **ADR**:新 **ADR 0013「底部四 tab:档案并入主界面,包按诊断自动出现」**,Amends 0012(不 supersede):0012 的五条决定(两层、只分组不判断、常量表、零新事件、内置包)一条不改;失效的是事实陈述「现在 / 进程 / 依据 三视图」「入口卡」和 0011 决定 3 的「入口卡 → 独立页」、决定 5 里 `enable/disable` 作为**用户动作**的那层(事件保留,手机通用视图不再读)。0011/0012 各加一段 Addendum 指向 0013。
- **SLE 包**:不改、不重签;`triggers.diagnosis_patterns` 第一次有读者;M32 前缀在 crate 常量。李静示例在「现在 → 免疫」族里看到包段;Jane/张建国看不到。
- **golden**:`golden_profile_view.json`/`_llm.json`(单包路径)逐字节不变;`golden_generic_view.json` 会变(`installed` 过滤规则变、可能加 `applies` 字段)——`UPDATE_GOLDEN=1` 后人工看 diff,diff 必须只在预期处。
- **文案闸**:新文案(tab 名「现在」「用药」、「更早的诊断」「更早的化验」「最近的用药」「更早的用药」「过敏」「记录里没找到过敏史」「最近 180 天没有用药记录」「原件」)在落地提交后把 `kBaseline` 前移;删掉的趋势页文案进 `kRemovedByDecision`;`glossary_guard` 禁词不碰(用「病历」不用「档案/文档」,用「给医生看」不用「分享」)。
- **`mobile_ia_test`**:`HomeTab.count` 3 → 4,`trends` 改名 `now`,新增 `meds`;`goToTrends()` 的调用方全部改向。
- **Analytics**:`homeTabSelected` 事件照发,tab 名多两个值;不新增事件。
- **埋点/隐私政策**:数据不出手机、不新增请求、不新增存储 → 不动 `privacy.html`(硬规矩 4 自检:没动「数据往哪走」)。
- **向后兼容**:老保险箱里已写过的 `enable/disable` 事件无害;查看器/分享的单包视图不受影响。

## 11. 留给实施者的决定与验收标准

### 11.1 决定记录(全部「实施者的决定」,用户不认可改这里)

1. **结构稿 A**(§9)。
2. **「现在」的时间窗 12 个月,诊断与化验共用一个常量**;不做用户可调。
3. **诊断「已解决」不读**:Epic `Problem List` 的 `Resolved On` 留作后续(要动 myEHR 适配器 + `DiagnosisItem` 可选字段)。
4. **包出现 = 触发词或 ICD 前缀命中**,不再要用户开启;前缀表在 crate 常量,不重签包。
5. **英文过敏走 parser 正则**(表式 + 行式 + 四种否定),不动侧文件。
6. **趋势 tab 的「只看异常」「最近就诊」删**;「记录一下」移进「添加」弹层。
7. **病历 chip 多三颗(手术/影像/病理)**,用药变化/诊断首次不进 chip。
8. **多条依据用底部弹层**,单条直接进原件;重复引文用 `span` 定位。
9. **「用药」首版不缓存**,耗时按验收 13 实测再定。
10. **「现在」族卡只列最近的用药的名字**,药的家在「用药」。
11. **措辞「最近的用药 / 更早的用药」**,不用「当前用药」(项目禁词);包段位置用 `manifest.family`;术语覆盖层按「装着」而非「开着」装。

### 11.2 验收(全部合成数据;Doe, Jane 语料按需加:1 条 12 个月前的诊断与 1 条 12 个月前的化验序列、1 段英文表式过敏 + 1 行行式过敏 + 1 行 `No Known Allergies` 诱饵)

Rust(`packages/profile`、`packages/parser`):

1. `package_applies`:李静语料 + SLE 包 → `true`(触发词);Jane 语料 + SLE 包 → `false`(无 M32、无狼疮字样);Jane 加一条 `M32.14` 诊断 → `true`(前缀);`enable/disable` 事件对结果**无影响**。
2. `materialize_generic` 对 Jane + 装着未触发的 SLE 包 → 零包段、`packages[]` 里该包 `applies:false`;两份 SLE golden 逐字节不变。
3. 「最近/更早」切分:`today` = 最后提及 +181 天 → 美托洛尔进 `past`、`+179` 进 `current`;伏立康唑(写了停药)恒 `past`;`past[].lane.nodes` 含 `first/change/stopped`,华法林链 `5mg → 4mg`。
4. 英文过敏:表式抽出 2 条(物质、反应逐字);行式抽出 3 条;`No Known Allergies` / `NKDA` 不产出;中文测试全绿不变;一条物质两份文档 → 1 条、`document_ids` 2 个。
5. 12 个月窗:一条 `last_seen` = today−366 天的诊断进 `earlier`,today−364 进族卡;化验同。

Flutter(393 宽 × 1.0/1.3/1.6 三档字号,沿用 `archive_timeline_test` 矩阵):

6. 底部四 tab,`mobile_ia_test` 过;冷启动落在「病历」。
7. 「现在」:族卡展开后每条化验行有 `TrendChart`(找得到 `CustomPaint`),单点序列只一个点;点行原地展开 96 高折线 + 数值行;「更早的化验 N 项」折叠且 N 正确;搜索「肌酐」只剩肌酐行;空箱子只出「还没有诊断或化验记录」;三档字号不溢出。
8. 「现在」李静箱子:免疫族里有包段;Jane 箱子:任何地方找不到「红斑狼疮」四个字。
9. 「用药」:最近/过敏/更早三段计数正确;搜「vori」只剩伏立康唑且三段标题还在;点开更早行看到剂量链与「原件」;空过敏显示「记录里没找到过敏史」;三档字号不溢出。
10. 原件:诊断行多依据 → 底部弹层列 N 条 → 点一条进 `DocumentDetailScreen` 且高亮引文;单依据直接进;同一引文出现两次的文档高亮在 `span` 那一处。
11. 病历 chip:七颗按计数显示;选「影像」只列影像文档行、带医院名;选「住院」行为与 #247 一致。
12. 文案:全 `lib/` 不出现「活动」「已解决」「既往」「在吃」「已停」「当前用药」「在用药」(档案/用药/现在三个文件 + 渲染树扫);`copy_unchanged` 基线前移后绿;`glossary_guard` 绿。
13. 真实规模(模拟器、用户真实包,结果不进仓库):四个 tab 首屏可读、切换无卡顿、「用药」页首次打开耗时记在汇报里;「现在」里没有 12 个月前的东西;SLE 包不出现;任何溢出/崩溃按「已修 / 留给后续」两栏汇报。

### 11.3 已知缺口(不在本 spec)

Problem List `Resolved On`、`Patient not taking`、中文诊断名→ICD、通用英文医院名、桌面 Tauri、图片档依据画框、tab 位置持久化。
