# 通用病程档案层:不靠包,任何慢性病自动有 — 设计

日期 2026-10-22。上游:[ADR 0011](../../ADR/0011-disease-profile-skill-packages.md)、[2026-09-16 病程档案 skill 框架](2026-09-16-disease-profile-skill-framework-design.md)、[2026-09-30 三视图](2026-09-30-disease-journey-three-views-design.md)、[2026-10-21 结构化导入](2026-10-21-structured-import-design.md)。状态:**已收口**(2026-10-22)——§9 的 9 个问题里第 2 题由用户拍板,其余 8 题是父会话按「建造者可自定」替用户定的,各处标明。只写 spec,不碰代码。已过一轮独立 builder check(2026-10-22),其纠正已并入。

## 0. 一句话

病程档案拆成两层:**通用层**从保险箱里已有的诊断(ICD-10)、用药、化验(LOINC)、就诊/手术/影像直接推出「现在 / 进程 / 依据」,不需要任何包;**病种包**退到第二层,只写指南规则(阈值、评分、目标、复诊节律),叠在通用层上。三视图引擎不变、仍是纯函数,只是多了一个不依赖包的输入。包同时内置进 App,首启先装内置、再联网更新。

## 1. 为什么现在做

- 用户把自己的 UF Health Epic 全量病历(5600 页 → 675 份文档,诊断 677 条带 ICD-10,化验 11666 条约 85% 带 LOINC,用药 667 条,9 次住院含瓣膜置换与曲霉菌感染)导进 MedMe 之后,打开「趋势」只看到一张卡:「可以整理系统性红斑狼疮」。他的心脏病、感染,什么都没有。
- 用户 2026-10-22 原话:「包不需要这么细,否则要做很多很多包;我这也算慢性病,不应该不考虑。」
- 现状(读代码核过):
  - `packages/profile::materialize(docs, events, pkg, today)` **必须有包**;没包就没有 `Ctx`、没有三视图(`lib.rs`)。手机侧 `vault_profile_view(dir, package_id)` 没缓存包直接报错、包没 `enable` 直接返回空 sections(`vault_profile.rs:55-82`)。入口卡 `disease_profile_card.dart` 三态里第一态就是「一个包都没装上 → 还没准备好」。
  - 包只有 SLE 一个(`skills/index.src.json`),从 `api.medmenow.com` 拉到缓存;App 不内置(`vault_profile.rs:23` 的 `SLE_PACKAGE_ENVELOPE` 只给「李静示例」用,`vault.rs:1647`,首启不装)。
  - 三视图引擎(`state.rs`:`StateVar` 五种 `derive`、泳道、`EvidenceBook`)本身**不认识具体病**,但它的输入全来自包:状态变量由包的 `state_vars` 声明,药类由包的 `drugs` 定义,泳道里的住院/复发来自 schema 2 的 `facts`。
- 结构化导入已经把码送进了 CAS,但**两条没接到下游**:
  - 诊断:sidecar 的 `diagnoses[].icd` 落在 CAS 里,`aggregate` 的 `conditions` **只走正则路径** `extract_conditions`(`extraction.rs:4-5` 明写「diagnoses 仍走正则」),而正则只认中文「诊断:」标签(`conditions.rs:88`)。英文 Epic 病历 → 零条诊断。677 条 ICD-10 今天谁也读不到。
  - 用药:`meds_from_json` 读名字/剂量;`meds[].rxnorm` 不读。英文药名靠词典别名命中,命不中就按原文名分组(`drug_key = None`,`atc = None`)。
  - 化验:`loinc` 反查已做(2026-10-21),这条通了。

## 2. 两层模型

```
                 ┌──────────────────────────────────────────────┐
  保险箱投影 ───▶│ 通用层(packages/profile::generic,不读包)      │──▶ 通用 sections
  docs/events/  │  诊断→族 · 用药→现在/自何时 · 化验→族小表     │     (现在/进程/依据)
  encounters    │  住院/急诊/手术/影像→进程                        │
                └──────────────┬───────────────────────────────┘
                               │ 同一份 Ctx、同一本 EvidenceBook
                 ┌─────────────▼────────────────────────────────┐
  已验签且开着的包 ▶│ 病种包层(今天的 rules.rs / state.rs,不变)     │──▶ 包 sections 叠进同一份视图
                │  阈值 · 评分 · 目标 · 复诊节律 · 换算表 · 里程碑  │
                └──────────────────────────────────────────────┘
```

### 2.1 边界:什么归通用层,什么只许包写

| | 通用层(不靠包) | 病种包(只写规则) |
|---|---|---|
| 诊断 | 按 ICD-10 归族,列出原文、首次/最近出现、出处 | `triggers` 建议开启;确认/排除诊断事件 |
| 用药 | 每个药「最近剂量 · 自何日起 · 多久没新记录」,剂量变化节点,原文写了的停药 | 药类(`gc`/`hcq`)、泼尼松等效换算、mg/kg 目标、说明书监测频率 |
| 化验 | 按词典 key 归到族小表,给最近值 + 印刷参考区间 + 趋势入口 | 指南阈值(低补体、UPCR <500)、评分项、目标线 |
| 进程 | 住院/急诊/手术/影像/病理/用药变化/诊断首次出现 泳道 | 复发、活检、输注、感染等 **facts** 泳道(schema 2,只有模型抽得出) |
| 提醒 | **没有**(通用层不发明任何复查间隔,ADR 0011 决定 8) | 病级节律 + 说明书频率 |
| 结论 | **没有**:不说「在吃」「已停」「活动期」「慢性」 | 仍然没有(Hit/Missed/Unknown) |

硬线:通用层只做**分组与折叠**(把已有的值按族摆好、按时间排好),不做任何需要临床出处的判断。凡是要引指南的数,一律留给包。

### 2.2 与 ADR 0011 的关系:增补,不 supersede

ADR 0011 的八条决定(签名包、引擎纯函数、零新事件、术语覆盖层只加不改、从不下结论、提醒只认两类来源)**全部保留**,通用层一条都不违反。失效的只有两句**事实陈述**:

- 0011 决定 3「加一个病 = 发一个包」的隐含前提「没包 = 没档案」;
- 09-16 spec §0「未开启任何包时『看懂』只有通用摘要」,以及入口卡第一态「没包 → 还没准备好」。

写法:新 ADR **0012「通用病程档案层」**,Status: Accepted,Amends 0011(Nygard 允许 amend 不 supersede);0011 加一段 Addendum 指向 0012,原文不改。理由:0011 的决策骨架(规则必须可 golden 测试、包必须签名、引擎不下结论)正是通用层也要遵守的;supersede 会让下一个人以为包那套作废了。

## 3. 通用层的数据来源与推导规则

### 3.0 前置(D0):把码接到下游

今天 sidecar 的 ICD 和 RxNorm 在 CAS 里睡觉。通用层的头两样(诊断族、用药)都踩在这上面,所以 D0 先于一切:

1. `parser::extraction` 加 `diagnoses_from_json`(与 `labs_from_json`/`meds_from_json` 同形):读 `diagnoses[].text` + `icd`,产出 `ConditionMention{raw_text, icd_code, section: Some("extraction")}`。接进 `aggregate.rs` 的 conditions 循环(今天 `:1060` 附近只跑正则):**按文档**决定——这份文档有抽取 JSON 且 `diagnoses` 非空 → 只用 JSON;空或无 JSON → 正则(与 labs/meds **同一条**「零条也退回」规矩)。
2. ICD 码的可信度:云抽取路径 `deid::verify` 已经逐字核 `DiagnosisItem.icd`(`verify.rs:775`,Text 模式核不上整条丢、Image 模式标 `unverified`),模型编的码进不了库;sidecar 路径不经 verify 落库(2026-10-21 §3.2),码由适配器对原文核过。两条路通用层都**直接信 `icd_code`**,`unverified` 的照 `EvidenceBook` 规矩标「需核对」。
3. `terminology::resolve_rxnorm(code)`:与 `resolve_loinc` 同一手法(词典 239 条 drug 带 `codes.rxnorm`,建反查表);`meds_from_json` 名字认不出且 `rxnorm` 非空时用它。名字优先、码兜底、`deid::verify` 产物清空 `rxnorm`——三条与 LOINC 那次逐字一样。
4. `AggregatedCondition` 已有 `icd_code`(「第一条非空」合并),但它**只按 `raw_text` 精确去重**、只有 `onset` 与 `sources`(`aggregate.rs:219`)——没有「最近出现日」「次数」。通用层在它之上再合并一层(§3.1 第 2 条),不改 parser。

### 3.1 诊断 → 族

**输入**:`AggregatedClinical.conditions[]`(`raw_text`、`icd_code`、`onset`、`sources`)+ `SourceDoc.date`。

**码的归一**:大写;去空白;第 4 位不是 `.` 且长度 >3 时在第 3 位后补 `.`(Epic 无点写法 `I350` → `I35.0`;国内 `I10.x00` 保留原样,比较时只看 `.` 前 3 位与 `.` 后第 1 位)。归一失败(不是 `[A-Z]\d\d` 开头)→ 当作无码。

**归族算法**(一条诊断只归一个主族,可选一个第二族):

1. 在**覆盖表**里按**最长前缀**匹配(表里既有 3 位 `I33` 也有 4 位 `N39.0`、`B44.1`;`E11.2` 这种按 `.` 后一位匹配);命中 → 取该行的主族/第二族。
2. 没命中 → 按前 3 位落**章节表**;章节表只有主族。
3. 无码 → `uncoded`。

覆盖表草案(每行只出现一次,主族/第二族写死,实现者建成 ≤40 行 `const` 表,进 `packages/profile`,不进包):

| 前缀 | 主族 | 第二族 | 为什么 |
|---|---|---|---|
| `Z95` | cardio | — | 心脏装置/人工瓣膜,章节 Z 本来进 other |
| `Q20`–`Q28` | cardio | — | 先天性心脏 |
| `I33` | cardio | infection | 感染性心内膜炎 |
| `J15`–`J18` | infection | respiratory | 肺炎 |
| `N39.0` | infection | renal | 尿路感染 |
| `T81.4` | infection | — | 术后感染 |
| `B44` | infection | respiratory | 曲霉病(`B44.1` 肺曲霉病含在内) |
| `N17`–`N19` | renal | — | 肾衰/CKD(已在章节内,列出只为注释) |
| `E10.2` / `E11.2` | renal | endocrine | 糖尿病肾病 |
| `M05`–`M06` | immune | — | RA |
| `G35` | immune | neuro | MS |
| `G36.0` | immune | neuro | NMOSD |
| `G70` | immune | neuro | MG |
| `K50`–`K51` | immune | digestive | IBD |
| `L40` | immune | — | 银屑病 |

章节表:`A00–B99`→infection;`C00–D48`→oncology;`D50–D77`→blood;`D80–D89`→immune;`E00–E90`→endocrine;`G00–G99`→neuro;`I00–I99`→cardio;`J00–J99`→respiratory;`K00–K93`→digestive;`M30–M36`→immune;其余 `M`→musculoskeletal;`N00–N39`→renal;其余章节(F、H、L、N40+、O、P、Q、R、S、T、Z…)→other。覆盖表再加一行:`Z79.01`(长期抗凝)→cardio;其余 `Z79` 留在 other(父会话决定,§9 第 4 条)。

**合并与计数**(在 `AggregatedCondition` 之上):有码的按归一后的码合并成一条「诊断」,`raw_text` 的不同写法列在它下面(`Chronic kidney disease` 与 `CKD stage 3` 同码 → 一条);无码的按 `raw_text` 各一条。每条:首次出现 = 合并后最早的 `onset`;最近出现 = 它所有 `sources` 文档日期的最大值;次数 = `sources` 去重后的**文档数**(界面就叫「N 份记录提到」,不叫「次」)。

**排序**:族按「最近出现日」倒序,无日期的排最后,并列按文档数再按族 key;`other` 固定倒数第二且**首屏折叠成一行「其他 N 条」**(父会话决定)、`uncoded` 固定最后。族内诊断同规则。每族一张卡:族名、诊断条数、每条诊断的原文 + 码 + 首次 + 最近 + 文档数。不判「慢性/急性」「活动/既往」——把判断留给人。

### 3.2 用药 → 现在在吃什么、从哪天起

**输入**:`AggregatedClinical.meds[]`(`MedSpan`:`mentions[]` 按日期升序、`latest_dose`/`latest_raw_name`/`latest_source`、`start`/`end`、`atc`)。`MedSpan.status` 恒为 `"active"`、`end` 只是最近一次提及——parser 从不推停药(`aggregate.rs` 模块头),通用层也不推。

每个药一行,四个字段,全部可逐字回溯:

| 字段 | 推导 | 依据 |
|---|---|---|
| 最近剂量 | `latest_dose`(`latest_raw_name` 配套) | `latest_source` 那份文档含药名且含剂量数字的那一行(`state.rs::cite_span`,今天是私有 fn,改 `pub(crate)`) |
| 记录中自何日起(界面措辞逐字「记录中自 2026-04-18 起」;依据条目注明「该剂量连续出现的起点」;不说「开始吃」——父会话决定,§9 第 9 条) | 只看**有日期且有剂量**的提及;从最后一次往前数,**剂量键**连续相同的最早那次的日期。剂量键 = 剂量字符串里第一个数字 + 紧跟的单位 token(`5mg`、`5 mg qd`、`5mg daily` 同键;频次不进键);全部无日期 → 空 | 该次提及的文档 |
| 首次出现 | `start`(无日期提及不算) | 首次提及的文档 |
| 多久没新记录 | `today − end`;超过阈值标 `stale` | — |

- **停药判定**:通用层**只认写在原文里的停药**。算法:对每次提及,按 `cite_span` 同一手法在 `source` 文档正文里找「含 `raw_name` 的那一行」,该行(或 schema 2 `dose_change` fact 的 `to`)匹配 `停用|停药|停服|已停|(?i)\b(discontinued|stopped|stop taking|dc'd|d/c'd)\b` 之一 → 该次提及标「停」。裸 `d/c`、`discharge`、`stopped smoking` 不算(词边界 + 不收裸 `d/c`)。最后一次有日期的提及若是「停」→ 该药行显示「病历写了停药 · 日期 · 依据」,排到列表末尾,「自何日起」留空;**停之后又出现带剂量的提及** → 回到正常行,停那一次只留在进程泳道里当一个节点。**不认**「最近一次用药清单里没有它」——那是推断,ADR 0011 决定 7 禁止。Epic 的 `Patient not taking` 标记今天抽取不出来(sidecar 没这个字段),记为已知缺口。
- **stale 阈值**:通用层默认 **180 天**(父会话决定:慢病门诊常隔 3–6 个月,90 天误报太多)。文案只说「N 天没有新记录」,不说「可能已停」(与三视图 spec §2 一致)。包的 `state_vars[].stale_after_days` 对该药类**覆盖**通用默认。
- 剔除:外用/局部制剂的筛选 `rules::is_nonsystemic_gc_name` 今天只对激素;通用层不扩,原样列出。
- 剂量变化节点:相邻两次**有日期有剂量**的提及剂量键不同 → 一个 `dose_change` 节点(`from`/`to`/日期/依据)。这正是 `state.rs` 今天给包药类做的事,抽成对**所有** `MedSpan` 跑一遍。
- 用药与族挂钩:按 `MedSpan.atc` 前缀打族标签,只用于首屏计数和折叠。前缀表(≤15 行,与族表同一文件):`C*`、`B01*`→cardio;`J01*`、`J04*`、`J05*`→infection,`J02*`→infection 并加小标「抗真菌」;`R*`→respiratory;`A10*`、`H03*`→endocrine;`H02*`、`L04*`→immune;`N03*`、`N04*`、`N07*`→neuro(`N02` 止痛、`N05`/`N06` 精神类→other,不往「神经」里扫);`L01*`→oncology;其余→other。`atc = None`(词典认不出)→ other,原文名照列。

### 3.3 化验 → 按词典 key 分组、与族挂钩的小表

**输入**:`AggregatedClinical.labs[]`(`AnalyteSeries`:`analyte_key`、`group_name`、点列含印刷值/单位/参考区间/来源)。`analyte_key` 来自词典(名字或 LOINC 反查);认不出的序列**不进族表**,留在趋势页「未识别」桶里,通用层不另造。

**不是一病一表**,是一张几十行的「key → 族」小表,叠在词典 `panel` 之上:

1. **panel 兜底**(`terminology::panel_for`,16 个大类已有):`心肌标志物`、`凝血`→cardio;`肾功能`→renal;`血糖`、`甲状腺功能`、`血脂`→endocrine;`炎症/感染`→infection;`风湿免疫`→immune;`血常规`、`电解质`、`肝功能`、`尿液`→**通用**(每族首屏都看得到的一小排,不归任何族)。注意 `panel_for` 只查内置词典、不查包的覆盖层(`terminology/lib.rs:~1160`);包加的分析物(UPCR)靠包自己的 `markers` 展示,通用层不管。
2. **key 覆盖表**(草案;✗ = 词典今天**没有**这个 key,要先补词典,补不了就不进第一版):

| 族 | key | 备注 |
|---|---|---|
| cardio | `bnp` ✓、`nt_probnp` ✓、`troponin_i/t` ✓、`hs_troponin_i/t` ✓、`inr` ✓、`pt` ✓、`creatinine` ✓、`potassium` ✓、`ldl` ✓、`hba1c` ✓ | INR 对瓣膜/抗凝人群是核心;肌酐、钾出现在两个族里允许 |
| infection | `crp` ✓、`hscrp` ✓、`esr` ✓、`wbc` ✓、`il6` ✓、`lactate` ✓(无 panel)、`procalcitonin` ✗(本轮补) | 培养类是文本结论不是数值,**不进序列**,在「依据」里按文档列(§4) |
| infection·抗真菌 | `galactomannan` ✓(词典**无 LOINC**,只能靠名字命中,语料得印已知别名)、`beta_d_glucan` ✓、`voriconazole_level` ✗(本轮补) | 伏立康唑谷浓度 key 本轮补(LOINC 逐条核,核不到留空不编) |
| renal | `creatinine` ✓、`egfr` ✓、`urine_acr` ✓、`urine_pcr` ✓、`uric_acid` ✓、`phosphate` ✓、`pth` ✓(无 panel) | |
| endocrine | `hba1c` ✓、`glucose` ✓、`tsh` ✓、`ldl` ✓、`hdl` ✓、`triglycerides` ✓、`vitamin_d_25oh` ✓(无 panel) | |
| immune | `crp` ✓、`esr` ✓、`ferritin` ✓(无 panel);`complement_c3/c4`、`anti_dsdna` 由 SLE 包定义 | 包的 `markers` 叠在这上面,包有的以包为准 |
| 药物浓度(跨族) | `tacrolimus_level` ✗、`digoxin_level` ✗、`voriconazole_level` ✗(三个本轮补) | 词典里 `tacrolimus`/`digoxin` 是**药**条目(category drug,无 LOINC),不是血药浓度化验;三个 `*_level` 本轮补进词典后这一行才开 |

- 同一个 key 可以出现在多个族,**序列只有一份**,表只是指针。
- 每行显示:最近值(**印刷值配印刷单位**,审查 I-4)、印刷参考区间、日期、偏高/偏低标记(来自报告自己的 flag 或与印刷区间比,与趋势页同一逻辑)、点进趋势页。**不画指南目标线**——那是包的事。
- 这张表是**展示分组**,不是临床断言;但它仍是对外产出。发布前**两道核查**(父会话决定):先派只读 subagent 把族覆盖表、ATC 前缀表、化验小表逐条核到码表(ICD/ATC/LOINC),再把核过的三张表交用户自己过一遍。

### 3.4 住院 / 急诊 / 手术 / 影像 / 病理 → 进程

**输入**(新):`core-model` 的 `Encounter`(`kind: Inpatient|Emergency|Outpatient|Exam`、`provider`、`start_date`/`end_date`、`title`)+ 该次就诊的文档 id 列表,来源 `Vault::encounters_with_docs()`(就是时间线页用的那份;`rebuild_encounters` 对 Epic 包已验证:出院小结起止日定住院窗口、`ED Visit`/`ED to Hosp-Admission` 判急诊,见 2026-10-21 timeline-tiers log)。手机侧 `vault_projections::gather_for_profile`(`:530`)今天只带 docs 与 events,要加 encounters 并把文档 id 映射成 `SourceDoc::index`。引擎侧加一个输入类型(§8.1 决定 1)。

| 泳道 | 节点来源 | 节点内容 | 依据 |
|---|---|---|---|
| 住院 | `Encounter.kind == Inpatient` | 起止日、天数(出院 − 入院,同日记 1,与时间线页同口径)、医院名、文档数;出院小结标题 | 出院小结那份文档(整份,`span: None`) |
| 急诊 | `Encounter.kind == Emergency` | 日期、医院名 | 急诊记录那份 |
| 手术 | `doc_type == surgery` 的文档 | 日期、标题原文 | 该文档 |
| 影像 | `doc_type == imaging_report` | 日期、标题、结论段 | 该文档,span = 结论段 |
| 病理 | `doc_type == pathology` | 日期、标题、结论段 | 该文档 |
| 用药变化 | §3.2 的 `dose_change` 与「停」节点,每个药一条子泳道 | from → to / 停 | 两份文档 |
| 诊断首次出现 | 每族一条:族内每条诊断的首次出现 | 原文 + 码 | 首次提及的文档 |

- 结论段用 `handoff::imaging_impression` / `pathology_impression`——两者今天是 **private fn**(`handoff.rs:692,699`)且标签表**只认中文**(`imaging_label_re`,`:617-625`,印象/结论/所见…);本次开 `pub` 并加英文 `IMPRESSION:|FINDINGS:|CONCLUSION:` 标签(父会话决定):通用摘要与医生查看器会跟着认英文,可接受,但要带单测,且**中文路径的输出逐字不变**(现有 handoff 测试必须全绿)。
- 泳道排序沿用三视图 spec §9 决定 3:有核过节点的先、住院/急诊标 `severity: high`、空道折叠。长病程压缩到年(`rules::timeline_section` 已有的按年分桶)。
- 不从出院小结正文里抽「手术名称」「主要诊断」——那是 schema 2 facts 的事(模型抽),通用层只用文档级元数据。Epic 包的手术文档已经是独立 `surgery` 类型(manifest 给的),够用。

## 4. 三视图在通用层各显示什么 + section 契约

| 视图 | 通用层 | 留给包 |
|---|---|---|
| **现在** | ① 族卡(§3.1);② 用药表(§3.2);③ 每族化验小表最近值(§3.3);④ 通用一排(血常规/电解质/肝功能最近值) | 状态变量(激素等效量、mg/kg、活动度分、里程碑)、达标 checklist、提醒 |
| **进程** | §3.4 七种泳道 | facts 泳道(复发/活检/输注/感染/妊娠)、包药类的等效剂量节点 |
| **依据** | 同一本 `EvidenceBook`:每个值/节点一条 `ev:<doc>:<n>`,点开原件高亮;培养报告、出院小结这类整份依据 `span: None`、只跳到文档 | 同 |

**Section 契约**(Rust 与 Flutter 按这个对齐;`view.rs` 今天 7 + 3 种 kind,未知 kind 渲染层跳过,所以新 kind 要同时加渲染器):

| kind | id | body | 归哪个 tab |
|---|---|---|---|
| `family_cards`(新) | `general_families` | `families[]{key,label,count,last_seen,diagnoses[]{code,texts[],first_seen,last_seen,doc_count,evidence[],unverified}, meds_count, labs[]{key,label,value,unit,ref,date,flag,evidence}}`,末尾 `common_labs[]` 同 labs 形 | 现在 |
| `med_table`(新) | `general_meds` | `rows[]{name,raw_name,dose,since,first_seen,last_seen,days_since,stale,stopped{at,evidence}?,family,evidence[]}` | 现在 |
| `journey`(复用) | `general_journey` | 与今天 `Lane`/`Node` 同形;泳道 key 用 `enc_inpatient`/`enc_emergency`/`surgery`/`imaging`/`pathology`/`med:<drug_key>`/`dx:<family>` | 进程 |
| `evidence`(复用) | `general_evidence` | 同今天 | 依据 |

- 每个 section 带 `package_id`:通用层恒为 `"general"`,包段为包 id。Flutter 三 tab 的触发条件从 `enabled && any(kind=='state')` 改成 `any(kind ∈ {state, family_cards})`;tab 名通用层写死「现在 / 进程 / 依据」,包段仍用包的 title。
- 包开着时,它的 `latest_dose`(`drug_class: gc`)行**替换**通用层对同一批药的行(同一药不出两行)。替换键:对每个 `MedSpan` 跑 `rules::drug_class(pkg, m)`(`regimen_eval` 用的同一个函数),命中的从 `med_table` 里去掉。
- `today`、`stale`、`verified`、`origin` 的语义全部沿用 `state.rs`,不另起一套。

**开启 / 隐藏**:通用层**没有 enable、也没有隐藏开关**,永远显示(父会话决定,YAGNI;要关再加,届时复用 `enable`/`disable` + `package = "general"`,零新事件,`profile::is_enabled` 取反即可)——「任何慢性病自动有」是用户原话;包没开、甚至一个包都没装,通用段照出。**门槛**(父会话决定):带码诊断少于 3 条时,入口卡只出一行「已有 N 条诊断记录」,不展开族 chip;一条诊断一种药都没有时写「还没有诊断或用药记录」。档案页本身不设门槛。

**多包并存**:每个开着的包仍各算各的 sections(今天的行为),叠进同一份视图时按 `package_id` 分段,通用段在最前。

**FFI**:新函数 `vault_profile_view_general(dir) -> String`(名字字典序在 `recognize_image_pp` 之后,`frb_dispatch_indices` 守着):不查包、不查 enable,算通用段;再对缓存里每个**开着**的包追加它的 sections;顶层 `documents[]` 桥与今天 `vault_profile_view` 同一段代码。老的 `vault_profile_view(dir, package_id)` 保留给查看器/分享。

## 5. 内置包:skills/ 进 App、首启先装内置再联网

现状:`vault_profile.rs:23` 已用 `include_str!` 把 `skills/sle/2026.10.1.json`(51 KB)编进手机 Rust crate,但只在「李静示例」里 `cache_store` 一次(`vault.rs:1647`,`Downgrade` 当成功)。

做法(最短路径,不走 Flutter assets):

1. 内置清单:`apps/mobile_flutter/rust/src/api/builtin_skills.rs`,一个 `&[(&str /*id*/, &str /*envelope*/)]`,每个包一行 `include_str!("../../../../../skills/<id>/<ver>.json")`。`skills/index.src.json` 加包 = 加一行。`repo_packages_verify` 测试加一条:内置清单与 `index.json` 的 id/version **逐一相等**,少一个、版本不一致都红。
2. 首启(或每次开箱,幂等):对内置清单每项 `profile::cache_store(dir, envelope)`;`Ok` 与 `Err(Downgrade)` 都算成功(缓存里已有更新的);其它错误只打日志。放在 `vault_profile_refresh_terms` 之前,与 `vault_boot.dart:213` 同一处触发。
3. 之后 `SkillPackages.refreshIndex()` 照旧:联网拉清单 → 验签 → 装更高版本;单调版本闸保证线上包只会把内置包**往前**推,永远不会被内置包拉回去(内置版本 ≤ 线上版本是发布纪律,由第 1 条的测试在仓库侧守)。
4. **验签与防降级一个字节不改**:内置包走的是同一个 `cache_store`,同一把公钥、同一个 `min_engine` 闸、同一个单调闸。内置≠免检。
5. 同意门:内置安装是本地文件写入,不联网,**不受** `FirstRunConsent` 门限制;联网更新仍受(`skill_packages.dart` 类文档)。
6. 桌面 Tauri 不在本次。

## 6. 非目标与反目标

- **不做诊断、不贴标签**:不出现「慢性病」「活动期」「已停药」「在吃」「控制良好」;只出现日期、次数、原文、码。停药只转述原文写了的那一行。
- **不编值**:每个数值、每条诊断、每个日期都必须逐字回溯到某份原件(`EvidenceBook.verified` 的规则原样适用;原文里找不到的一律 `verified:false` 并标「需核对」,仍显示)。族表、ATC 前缀表、化验小表是**分组**,不产生任何新数值。
- **不发明复查间隔**:通用层零提醒(ADR 0011 决定 8)。
- **不做中文诊断名 → ICD 映射**、不做通用英文医院名识别、不做 Epic `Patient not taking` 解析——都记为缺口,不在本 spec。
- **不改保险箱格式**:零新 `Event` 变体、零新表;通用层是纯投影,输入都是今天已经落库的东西(ADR 0003)。
- **不上云**:通用层全部在手机上算;不新增任何请求(包的联网更新是今天就有的那一条,不算新增)。
- **不替代趋势页**:化验小表只给最近值 + 跳转;曲线仍在趋势页。
- **不做桌面**。

## 7. 给用户选的结构稿(文字线框,只定结构不定视觉;视觉交设计师)

### 稿 A · 一张入口卡,首屏按族折叠

```
趋势 tab
┌ 病程档案 ─────────────────────────────┐
│ 心血管 3 · 感染 2 · 肾 1 · 内分泌 1 · 其他 4 │  ← 族 chip 行,按最近出现排
│ 用药 12 种 · 3 种超过 180 天没新记录      │
│ 最近住院 2026-07-02 → 07-11 · UF Health   │
│ 狼疮档案:已开启 · 待补 2 项  (有包才有这行)│
│                                 [打开] │
└──────────────────────────────────────┘
关键化验 … (今天的内容不动)

档案页(三 tab:现在 / 进程 / 依据)
现在
  ▸ 心血管 · 3 条诊断 · 最近 2026-09-12        [展开]
      主动脉瓣置换术后 Z95.2 · 首次 2024-03 · 最近 2026-09 · 18 份记录提到
      …
      用药:华法林 5mg · 记录中自 2026-04-18 起 · 12 天前有记录
      化验:INR 2.4 (2026-10-01) · BNP 180 (…) · 肌酐 …
  ▸ 感染 · 2 条 · 最近 2026-08-30               [展开]
      肺曲霉病 B44.1 …  伏立康唑 200mg bid · 记录中自 … 起 · 半乳甘露聚糖 …
  ▸ 肾 …  ▸ 内分泌 …  · 其他 4 条(折叠一行)· 未归类(没有码)…
  通用一排:血常规 / 电解质 / 肝功能 最近值
  ── 系统性红斑狼疮(病种包)──  ← 包开着时才有这一段,内容=今天的 state 行
进程:住院 / 急诊 / 手术 / 影像 / 用药变化 / 诊断首次出现(+ 包的 facts 泳道)
依据:同今天
```
特点:一个入口、一页看全;包是页内一段。入口卡从「每包一张」改成**一张**:标题永远「病程档案」,正文是通用摘要,每个装着的包各占一行(没开启 → 那行是「开启」按钮);一条诊断、一种药都没有 → 卡上只写「还没有诊断或用药记录」。

### 稿 B · 入口按族一张卡,各进各的三视图

```
趋势 tab
┌ 心血管 ── 3 条诊断 · 用药 4 · INR 2.4 ──────┐
┌ 感染 ──── 2 条 · 伏立康唑 · 半乳甘露聚糖 0.3 ─┐
┌ 肾 ────── 1 条 · 肌酐 1.1 ──────────────────┐
┌ 免疫 ──── SLE 包 · 激素 7.5 mg/天 · 待补 2 项 ┐   ← 包附着在它的族卡上
┌ 其他 / 未归类 ── 折叠 ─────────────────────┐
关键化验 …

族档案页(三 tab,只装这一族的诊断/用药/化验/进程;「进程」里住院/手术泳道全族共享)
```
特点:每个族像一个「病」,与今天「一病一卡」的心智一致;包自然落到免疫族。代价:住院/手术这类跨族节点每页重复出现;趋势 tab 首屏被 5–8 张卡占满,关键化验被推下去(与 2026-09-22 减法方向有张力)。

### 稿 C · 入口卡不动,档案首屏是「现在」总表

```
趋势 tab:入口卡同稿 A

档案页 · 现在
  用药(12)                                  ← 先药后诊断:医生第一眼要看的
    华法林 5mg      自 2026-04-18   12 天前   [心血管]
    伏立康唑 200mg  自 2026-06-02   40 天前   [感染·抗真菌]
    美托洛尔 25mg   …                        [心血管]
    …(超过 180 天没新记录的沉到底、灰字)
  诊断(按族)
    心血管(3)· 感染(2)· 肾(1)· …   [各自展开]
  化验(按族小表)
    心血管:INR · BNP · 肌酐 · 钾     感染:CRP · 半乳甘露聚糖 · WBC   …
  ── 病种包段(同稿 A)──
进程 / 依据:同稿 A
```
特点:与 ADR 0011 决定 3「现行方案在最前」一致,药表是主角、族只是标签;最像一张交接单。代价:族这个概念变弱,用户问「我的心脏病怎么样」要自己在三张表里按标签找。

**用户拍板(2026-10-22):稿 A。**理由:用户的问题是「我的心脏病什么都没有」——答案应该是一行「心血管 · 3 条 · 最近 9 月」而不是一张药表;且对今天的界面改动最小。

## 8. 留给实现者的决定与验收标准

### 8.1 决定(实现者可自行定,但要在计划里写明)

1. **引擎输入形状**:`materialize_generic` 加一个 `GenericInput { encounters: Vec<EncounterRef{kind,start,end,provider,title,doc_indices}> }`,还是给 `SourceDoc` 加 `date_end` + `encounter_kind`?倾向前者:encounter 是 core-model 的东西,parser 不该知道。数据源固定是 `Vault::encounters_with_docs()`。
2. **代码位置**:`packages/profile/src/generic.rs`(复用 `Ctx`、`EvidenceBook`、`Node`/`Lane`;`cite`/`cite_span` 开 `pub(crate)`),对外 `materialize_generic(docs, encounters, events, enabled_pkgs: &[Package], today) -> ProfileView`;今天的 `materialize(…, pkg, …)` 保留给单包测试与查看器。
3. **三张表**的形式:`const` 表在 `generic.rs`(不是包,不下发,不签名,改它就是发版),不走 JSON。
4. **D0 的「零条退回」**:按文档判,见 §3.0 第 1 条。
5. **ProfileView 形状**:不改顶层,section 加 `package_id` 字段(§4 契约);`Section.id` 用 `general_*`。
6. 入口卡按选定的稿改;稿 A 是「一张卡 + 每包一行」。
7. 词典本轮**全补**(父会话决定):`voriconazole`(drug,ATC J02AC03,RxNorm 待核;没有它验收 #3 过不了)、`lisinopril`、`procalcitonin`、`tacrolimus_level`/`digoxin_level`/`voriconazole_level`(LOINC 逐条核,核不到的留空不编)。

### 8.2 验收(全部合成数据,不用真实病历)

**语料**:新建 `examples/demo-dataset/generate_jane.sh`(与 `generate_sle.sh` 同手法,heredoc 产文本,`extract_fixtures.py` 抬进 `packages/profile/testdata/corpus-jane/`),患者 **Doe, Jane**(与 `pipeline/tests/import_bundle.rs` 同名,英文病历):

- 2024-03 住院 9 天:主动脉瓣狭窄 `I35.0` → 瓣膜置换手术文档(`surgery`)→ 出院诊断 `Z95.2`;出院带药华法林 5mg、美托洛尔 25mg。
- 2024-03 → 2026-09 门诊 8 次,每次病历重复当前用药清单;**2025-01-14 那次门诊**的清单第一次写华法林 4mg(剂量变化节点);INR 序列 10 点(LOINC 6301-6)、BNP 4 点、肌酐 6 点。
- 2025-06 急诊 1 次 → 住院 12 天:肺曲霉病 `B44.1`;伏立康唑 200mg bid 起;半乳甘露聚糖 3 点(印词典别名)、CRP 5 点;2025-11 一份病历逐字写 `Voriconazole discontinued`。
- 1 份影像(CT 胸部,带 `IMPRESSION:` 段)、1 份病理。
- 1 条没有码的诊断(落 `uncoded`)、1 条词典认不出的药(落 `other`,原文名);同一诊断两种写法同一码(验合并)。
- 同一包走 `import_bundle`(sidecar 带 `icd`/`loinc`/`rxnorm`)与纯文本两条路都要跑。

**golden**:`packages/profile/testdata/golden_generic_view.json`,逐字段钉住(`UPDATE_GOLDEN=1` 后人工看 diff,与 SLE golden 同规矩)。

**必须过的断言**(每条一个测试):

1. 族卡:`cardio` 含 `I35.0` 与 `Z95.2`(覆盖表生效),`infection` 含 `B44.1`(第二族 respiratory 灰字),无码那条在 `uncoded`,没有一条诊断出现在两个主族;两种写法同码合并成一条、`doc_count` 为两者之和。
2. 用药:华法林行 最近剂量 `4mg`、自何日起 = 2025-01-14;首次出现 = 2024-03;`dose_change` 节点 `5mg → 4mg` 带两份依据;`5mg qd` 与 `5 mg daily` 不产生节点。
3. 停药:伏立康唑行标「病历写了停药」,依据 quote 逐字含 `discontinued`;**没有**任何药因为「清单里不再出现」被标停;语料里加一行 `d/c summary reviewed` 不触发。
4. stale:把 `today` 设到最后一次提及 +181 天,美托洛尔 `stale: true`;+179 天 `false`;文案不含「停」字。
5. 化验小表:`cardio` 行含 `inr`/`bnp`/`creatinine` 最近值,值与印刷单位来自同一个 `LabPoint`;`infection` 含 `galactomannan`;`voriconazole_level` key 不存在时该行**不出现**(不出空行、不报错)。
6. 进程:住院泳道 2 个节点(天数 9、12)、急诊 1、手术 1、影像 1、病理 1;住院/急诊 `severity: high`。影像节点 text = `IMPRESSION:` 段;`handoff` 现有中文测试全绿、通用摘要中文 golden 逐字节不变。
7. 依据:`family_cards`/`med_table`/`journey` 引用的每个 `ev:` id 都在 `evidence` 段里;整份依据 `span: None`;原文找不到的值 `verified:false`。
8. 包叠加:同一语料 + SLE 包开着 → 通用段在前、包段在后;华法林不受影响;包的 `gc` 行替换掉通用层的泼尼松行(语料里加一条泼尼松即可验)。
9. 无包、无任何 `ProfileEvent` → 通用段照出;装了 SLE 包但没 `enable` → 通用段照出、包段不出(这是本 spec 的核心断言)。
10. D0:`diagnoses_from_json` 三条——有码读码、无 JSON 退回正则、JSON 零条退回正则;`resolve_rxnorm` 名字优先/码兜底/verify 清空。
11. 内置包:`cache_store` 内置信封两次(第二次 `Downgrade`)都算成功;内置清单与 `index.json` 不一致测试红;线上更高版本能覆盖内置、更低版本被拒。
12. `cargo test -p profile` 两份 SLE golden **逐字节不变**——通用层不许改动包那条路的任何输出。
13. Flutter:393×852 三档字号,稿 A 每一屏不溢出(沿用 `archive_timeline_test` 的矩阵);带码诊断 2 条的箱子入口卡只出「已有 2 条诊断记录」一行、3 条出族 chip;一条诊断一种药都没有的箱子只出「还没有诊断或用药记录」。
14. 措辞:用药行文案逐字是「记录中自 YYYY-MM-DD 起」;全视图不出现「开始吃」「已停」「在吃」(文案闸 `glossary_guard_test` 加这几个禁词)。

## 9. 拍板记录(2026-10-22)

第 2 条由**用户**拍板;其余 8 条由**父会话**按「建造者可自定」替用户定,不是用户原话,用户不认可时改这里即可。

1. 隐藏开关:**不加**,永远显示;空箱子卡上只写「还没有诊断或用药记录」。(父会话)
2. 结构稿:**A**——一张入口卡,首屏按族折叠,病种包作页内一段。(**用户**)
3. 用药 stale 默认 **180 天**,包可覆盖。(父会话)
4. `Z79.01` 长期抗凝→心血管,其余 `Z79`→其他;「其他」首屏折叠成一行。(父会话)
5. 三张表发布前两道核查:只读 subagent 逐条核到码表 → 用户自己过一遍。(父会话)
6. 影像/病理认英文 `IMPRESSION:`/`FINDINGS:`/`CONCLUSION:`;连带通用摘要与查看器可接受,带单测,中文路径不变。(父会话)
7. 词典本轮全补:伏立康唑、procalcitonin、lisinopril、三个血药浓度 key。(父会话)
8. 门槛:带码诊断少于 3 条时入口卡只出一行「已有 N 条诊断记录」,不展开族。(父会话)
9. 措辞「记录中自 2026-04-18 起」,依据里注明「该剂量连续出现的起点」,不说「开始吃」。(父会话)

硬前置不变(§3.0、§3.4):sidecar 的 `diagnoses[].icd` 与 `meds[].rxnorm` 今天没人读、引擎不收 encounter、`imaging_impression` 私有且只认中文——实施计划第一步。
