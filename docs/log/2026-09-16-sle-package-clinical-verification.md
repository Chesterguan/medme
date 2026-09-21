# SLE 包 2026.09.1 —— 临床独立核查(Task 19)

**日期:** 2026-09-18 · **分支:** `feat/advanced-a` · **基线:** `3626024`
**核查人:** 独立 agent,没有写包的上下文(CLAUDE.md 硬规矩第 3 条)

抽取脚本(brief Step 1)在包里数出 **91 个带标量的对象**,其中 **56 个含数值**。
下面逐条核到 `sle-clinical-sources.md` 的行号与该行的标记;凡是标「仅经摘要管道」、
出自药品说明书(L1–L8)或中文来源(S9/S10/S16)的,一律**重新打开一手页面**逐字比对。

## 方法上的一条决定

**没有用 WebFetch。** 那个工具用小模型总结页面 —— 正是源文件开头点名「抓到过两次编造」
的那条管道。全部改成 `curl` 取原始页面 + `pdftotext` + `grep` 逐字串;S1 的表格是扫描图,
`pdftotext` 取不出,改成 `pdftoppm` 渲染成图直接看。中间没有模型。

## 一、逐条核查表

`标记` = 该行在 `sle-clinical-sources.md` 里的置信度标记。`一手复核` = 这次自己打开原始页面的结果。

### rules.activity(S1 = SLEDAI-2K,Table 2 是扫描图,渲染成 200 dpi 图直接读)

| 包内位置 | 值 | 出处 | 源文件行 | 标记 | 一手复核 | 结论 |
|---|---|---|---|---|---|---|
| `rules.activity` | `window_days:10` | S1 | 190 | VERBATIM | ✅ 表头逐字「…or in the preceding 10 days.」 | MATCH |
| `rules.activity` | `max:18` | S1 | 240 | 算术 | ✅ 2+2+4+4+4+4+1+1,八个权重逐个在图上核过 | MATCH |
| `activity.items[0]` low_complement | `weight:2` | S1 | 217 | VERBATIM | ✅ 图上 weight 2 | MATCH |
| `activity.items[1]` dsdna_high | `weight:2` | S1 | 218 | VERBATIM | ✅ | MATCH |
| `activity.items[2]` proteinuria | `weight:4` `threshold:0.5 g/24h` | S1 | 210 | VERBATIM | ✅ 「>0.5 gram/24 hours」 | MATCH |
| `activity.items[3]` hematuria | `weight:4` `threshold:5 /[HPF]` | S1 | 209 | VERBATIM | ✅ 「>5 red blood cells/high power field」 | MATCH |
| `activity.items[4]` pyuria | `weight:4` `threshold:5 /[HPF]` | S1 | 211 | VERBATIM | ✅ | MATCH |
| `activity.items[5]` casts | `weight:4` | S1 | 208 | VERBATIM | ✅ 「Heme-granular or red blood cell casts.」 | MATCH |
| `activity.items[6]` leukopenia | `weight:1` `threshold:3.0 10*9/L` | S1 | 221/237 | VERBATIM+已标矛盾 | ✅ 表上印「< 3,000 … / x10⁹/L」,包按 3.0 实现并把矛盾写进 note | MATCH |
| `activity.items[7]` thrombocytopenia | `weight:1` `threshold:100 10*9/L` | S1 | 220/238 | 同上 | ✅ | MATCH |

### rules.bands(S10 = 2020 中国指南)

| 包内位置 | 值 | 出处 | 源文件行 | 标记 | 一手复核 | 结论 |
|---|---|---|---|---|---|---|
| `bands.bands[0..2]` | `max:6` / `7–12` / `min:13` | S10 | 254 | VERBATIM | ✅ PMC9524765 推荐 3 逐字「mild activity (SLEDAI-2000 ≤ 6), moderate activity (SLEDAI-2000 7–12), and severe activity (SLEDAI-2000 > 12)」 | MATCH |

`>12` 写成 `min:13` 是整数权重下的等价改写,note 里说明了。S4 图 1(行 255)给出同一组切点,行 329 一带核过。

### rules.targets

| 包内位置 | 值 | 出处 | 源文件行 | 标记 | 一手复核 | 结论 |
|---|---|---|---|---|---|---|
| `targets.gc[0]` | `7.5` | S3 | 317 | VERBATIM | ✅ EULAR 2019 rec 2.2.3 逐字 | MATCH |
| `targets.gc[1]` | `5` | S4 | 319 | VERBATIM | ✅ EULAR 2023 rec 2 逐字「maintenance dose of ≤5 mg/day」 | MATCH |
| `targets.hcq` | `target:5` `real_body_weight` | S4 | 329 | VERBATIM | ✅ 「target dose of 5 mg/kg real body weight/day」 | MATCH |
| `targets.hcq` | `ceiling_mg:400` | S4 | 330 | VERBATIM | ✅ 「but not exceeding 400 mg/day」 | MATCH |
| — corroborate | S9 | 402 | VERBATIM(中文来源,必复核) | ✅ PMC12495991 推荐 5 逐字「The recommended dose is 5 mg/kg/d (real body weight), not exceeding 400 mg/d.」 | MATCH |
| `targets.hcq.label_rule` | `6.5 mg/kg` / `理想体重` / `0.4 g/日` / 两个眼科间隔 | L8 | 416–417 | **VERBATIM(page-summariser;verify)** | ❌ **一手件一个都没拿到** | **无法核实 → 整块改 `null`** |

### rules.states

| 包内位置 | 值 | 出处 | 源文件行 | 标记 | 一手复核 | 结论 |
|---|---|---|---|---|---|---|
| `states[0].items[0]` csledai_zero | `value:0` | S5 | 268 | VERBATIM | ✅ Box 1「Clinical SLEDAI=0.」 | MATCH |
| `states[0].items[1]` phga | `value:0.5` | S5 | 269 | VERBATIM | ✅「Physician Global Assessment <0.5 (0–3).」 | MATCH |
| `states[0].items[2]` pred | `value:5` | S5 | 271 | VERBATIM | ✅「prednisolone <5 mg/day」 | MATCH |
| `states[0].items[3]` therapy | `kind:manual` | S5 | 271 | VERBATIM | ✅ | MATCH |
| `states[1].items[0]` sledai_le4 | `value:4` | S6 | 290 | VERBATIM(转载) | ✅ PMC5359963「SLEDAI-2 K ≤4」 | MATCH |
| `states[1].items[2]` pga_le1 | `value:1` | S6 | 290 | VERBATIM | ✅「SELENA)-SLEDAI PGA (scale 0–3) ≤1」 | MATCH |
| `states[1].items[3]` pred_le75 | `value:7.5` | S6 | 290 | VERBATIM | ✅「prednisolone (or equivalent) dose ≤7.5 mg daily」 | MATCH |
| `states[1].items[1,4,5]` | `kind:manual` | S6 | 290 | VERBATIM | ✅ | MATCH |

`csledai_zero.exclude` 那句映射源里标 PARAPHRASE(行 284),包的 note 已如实说明;它不引入新数值,保留。

### rules.monitoring —— 疾病节律(S9/S10,中文来源,必复核)

| 包内位置 | 值 | 出处 | 源文件行 | 标记 | 一手复核 | 结论 |
|---|---|---|---|---|---|---|
| `monitoring[0]` visit_active | `every_days:30` | S9 | 73 | VERBATIM | ✅ PMC12495991 推荐 3 逐字「at least once a month for patients with active SLE」 | MATCH(月→30 天是包内换算,note 已写) |
| `monitoring[1]` visit_stable | `every_days:90` | S9 | 73 | VERBATIM | ✅「once every 3 to 6 months for patients with stable SLE」 | MATCH(取更密一端) |
| corroborate 两条 | S10 | 66 | VERBATIM | ✅ PMC9524765 推荐 3 逐字「at least every month, and every 3–6months for patients with stable disease」 | MATCH |

### rules.monitoring —— 药品说明书排期(L1–L6,brief 交接单第 3 位,逐条开 DailyMed 原页)

| 包内位置 | 值 | 出处 | 源文件行 | 标记 | 一手复核(setid 已核对) | 结论 |
|---|---|---|---|---|---|---|
| `mmf_cbc.phases[0..2]` | 7 / 14 / 30 天 | L1 | 430 | VERBATIM(摘要管道) | ✅ 逐字命中「Consider monitoring with complete blood counts weekly for the first month, twice monthly for the second and third months, and monthly for the remainder of the first year.」 | MATCH |
| `mmf_cbc.phases[3]` | `every_days:30` `package_default` `pending` | L1 | — | 包作者外推 | ✅ 说明书第一年之后确实没有任何间隔 | MATCH(身份标注正确) |
| `aza_cbc.phases[0..2]` | 7 / 14 / 30 天 | L2 | 455 | VERBATIM(摘要管道) | ⚠️ 数字全对,但**引文抄错了出处** | **MISMATCH(引文)→ 已改** |
| `cni_egfr.phases[0..2]` | 14 / 28 / 90 天 | L3 | 480 | VERBATIM | ✅ 逐字命中 | MATCH(⚠️ 我第一轮「补」的那个逗号补错了,见 §九 F1,已改回) |
| `cni_bp.phases[0]` | 14 天 | L3 | 481 | VERBATIM | ✅「Monitor blood pressure every two weeks for the first month after initiating LUPKYNIS, and as clinically indicated thereafter.」 | MATCH |
| `csa_bp_scr.phases[0..1]` | 14 / 30 天 | L4 | 494 | VERBATIM | ✅ NEORAL「Special Monitoring of Rheumatoid Arthritis Patients」节逐字命中 | MATCH |
| `rtx_hbv` | 一次性动作 | L6 | 544–545 | VERBATIM | ✅ 黑框与 §2.1 两句都逐字命中 | MATCH |

**L2 的问题(本次唯一的引文性 MISMATCH):** 包里 note 抄的是
「Patients on **azathioprine tablets** should have…」。L2 声明的 setid 是
`aaa6c540-…`(IMURAN),那一页上写的是「Patients on **IMURAN** should have…」;
「azathioprine tablets」那句出自另一份仿制药说明书 `00e3b33f-…`,**没有在
`manifest.sources` 里声明**。三档天数(7/14/30)两份完全一致,所以**数值 MATCH**,
改的是引文,让它对得上自己的出处 id。

### rules.monitoring —— 指南类

| 包内位置 | 值 | 出处 | 源文件行 | 标记 | 一手复核 | 结论 |
|---|---|---|---|---|---|---|
| `hcq_eye` | 无数值(`phases:[]`,pending) | S14 | 396 | VERBATIM(摘要) | ✅ PubMed 41232611 结构化摘要逐字命中「Annual screening with OCT and FAF is recommended while using HCQ, but may be deferred during the first 5 years if there are no significant risk factors.」 | MATCH;但 note 里转述的 L8 两个间隔已删(见下) |
| `gc_ca_vitd` | `min_daily_pred_equiv:7.5` `min_days:91` | S12 | 364 | VERBATIM | ✅ PMC2095301 rec 6a 逐字「prednisone ⩾7.5 mg daily … more than 3 months」 | MATCH(>3 月→91 天,含/不含的处理 note 已写) |
| `gc_dxa` | `min_daily_pred_equiv:2.5` `min_days:91` | S13 | 366 | VERBATIM(摘要) | ✅ 已刊全文逐字「>3 months treatment with glucocorticoids (GCs) ≥2.5 mg daily」 | MATCH |
| `gc_dxa` | `min_age:null` | S13 | 367 | **VERBATIM from a third-party summary** | ⚠️ **翻案,见下** | 保持 `null`,理由改写,整条转 `verified` |
| `gc_cv_annual.phases[0]` | `every_days:365` | S2 | 56 | VERBATIM | ✅ PMC2952401 rec 2 逐字「At baseline and during follow-up at least once a year」 | MATCH |
| `rtx_igg` | 无数值(pending) | R1 | 552 | VERBATIM | ✅ Frontiers 开放全文逐字命中「…serum IgG levels <6 g/L and measurement of immunoglobulin levels before the initiation and periodically or before each RTX cycle has been recommended.」 | MATCH,且确认是**综述** → `basis:"literature"` 正确 |
| `mtx_labs` / `ctx_cbc` | `every_days:30` / 无 | PKG | 468–469 / 442 | 说明书明确「无间隔」 | ✅ 两份说明书确实只写 periodically / essential | MATCH(package_default + pending 标注正确) |

### rules.milestones(S8 = EULAR 2025 LN,version of record PDF)

| 包内位置 | 值 | 出处 | 源文件行 | 标记 | 一手复核 | 结论 |
|---|---|---|---|---|---|---|
| `milestones[0]` | `drop_pct:25` `by_days:90` | S8 | 638 | VERBATIM | ✅ rec 2 逐字「reduction in proteinuria of at least 25% by 3 months」 | MATCH |
| `milestones[1]` | `drop_pct:50` `by_days:180` | S8 | 638/641 | VERBATIM | ✅「50% by 6 months」/「(partial response)」 | MATCH |
| `milestones[2]` | `threshold:700 mg/g` `by_days:365` | S8 | 638 | VERBATIM | ✅「a UPCR target <700 mg/g by 12 months」 | MATCH |
| `milestones[3]` | `threshold:500 mg/g` | S8 | 641 | VERBATIM | ✅「Complete renal response should be deﬁned as UPCR <500 mg/g at any time point.」 | MATCH |
| `milestones[4]` | `threshold:500 mg/24h` | S3 | 653 | VERBATIM | ✅ EULAR 2019 narrative 逐字「complete renal remission (proteinuria <500 mg/24 hours and SCr within 10% from baseline)」 | MATCH |
| `milestones[5]` | `pct:80` | S8 | 644 | VERBATIM | ✅「stabilisation (if not improvement) of GFR to ≥80% of baseline value」 | MATCH |
| `milestones[6].any_of[0,1]` | `0.5 g/24h` / `500 mg/g` | S8 | 626 | VERBATIM | ✅ rec 1 逐字「(≥0.5 g/24 h or urine protein-creatinine ratio [UPCR] ≥500 mg/g)」 | MATCH |
| `milestones[*].from` | `baseline_window_days:30`、药物清单 | PKG | — | 包定口径 | ✅ note 已如实声明「起算日口径是包定的,不是指南给的」 | MATCH |

### terms / drugs

| 包内位置 | 值 | 出处 | 源文件行 | 标记 | 一手复核 | 结论 |
|---|---|---|---|---|---|---|
| `terms.analytes[0].loinc` | 原 `null` | — | — | 待核 | ✅ NLM Clinical Table Search Service:**13945-1**,PROPERTY=Naric | **已填**(新出处 S17) |
| `terms.analytes[1].loinc` | 原 `null` | — | — | 待核 | ✅ **5821-4**,PROPERTY=Naric | **已填** |
| `terms.analytes[*].units` | slope 1 / intercept 0 | — | — | 恒等 | ✅ `/[HPF]` 与 `/HP` 是同一量的两种写法 | MATCH |
| `drugs[gc].pred_equiv` | 原 `null` | — | 94 点名未转录 | 待核 | ✅ **拿到了**,见下 | **已填**(出处 S10) |
| `drugs[belimumab].infusion` | 10 mg/kg q2w×3→q4w;SC 200/400 | L5 | 505–507 | VERBATIM | ✅ DailyMed §2.2「10 mg/kg at 2‑week intervals for the first 3 doses and at 4‑week intervals thereafter」;§2.3 Table 1「200 mg once weekly」/「400 mg once weekly for 4 doses, followed by 200 mg once weekly」 | MATCH |
| `drugs[telitacicept].infusion` | 每周 160 mg | L7 | 529 | VERBATIM | ✅ PubMed 41092329 摘要逐字「receive telitacicept (160 mg) or placebo subcutaneously once weekly for 52 weeks」 | MATCH |

## 二、brief Step 2 的三个专问

**(i) §G.1「do not ship」的值有没有进包?** 没有,**0 条**。逐条扫过五档 SLEDAI 分级、
GIOP 复查 1–2 年、ACR 甲氨蝶呤间隔、CPIC 基因型剂量、NUDT15 频率、KDIGO/中国 CNI 谷浓度、
NIH 环磷酰胺 g/m²、MMF REMS、EULAR 2016 阿司匹林剂量、AAO 2016 风险百分比、抗核糖体 P。
唯一一处字面命中是 `mtx_labs.note` 里「常被引用的 ACR 2–4 周 / 8–12 周 / 12 周那套**核不实**」
—— 那是在说明为什么**不用**它,不是在用它。

**(ii) 每条 monitoring 的 `basis` 标得对不对?** 16 条(含档级)全对。
`guideline` 五条都指向指南原文(S9/S12/S13/S2/S14),`label` 五条都指向说明书(L1–L4/L6),
`literature` 一条指向 R1 —— **已一手确认 R1 是综述,不是指南也不是说明书**(brief 第 7 条通过),
其余 `package_default`。没有把综述的建议说成指南。

**(iii) 有没有判定用的数值来自 `verify_status:"pending"` 的字段?** **没有。**
pending 的四条(`hcq_eye`、`rtx_igg`、`mtx_labs`、`ctx_cbc`)要么 `phases:[]`,
要么该档自己标着 pending 只显示不算到期;`mmf_cbc.phases[3]` 是档级 pending,同理。
原来的 `label_rule` 也不参与任何判定(有专门的测试钉着),现已整块删除。

## 三、翻案与改动

### 1. 羟氯喹说明书(`targets.hcq.label_rule`)→ `null`,整块撤掉

brief 的第一优先级。四条路都没拿到一手件:

| 试过的 URL | 失败方式 |
|---|---|
| `https://www.nmpa.gov.cn/datasearch/home-index.html`、`/datasearch/search-result.html`、`/datasearch/face3/base.jsp` | **HTTP 412**,返回 JS 反爬验证页 |
| `https://www.shzxzy.com/`、`http://www.zhongxipharm.com/`(中西三维/中西制药) | **连接失败(HTTP 000)** |
| `https://www.sanofi.cn/zh/products`(0.2 g Plaquenil 进口方) | **404**;站点根可达但无说明书 |
| 检索 | 只返回药品信息站(familydoctor / jianke / 39药品通 / 昌盛大药房),brief 明令不许用 |

按 brief:「核不到:整个 `label_rule` 改成 `null`,界面上那句『说明书写的和指南不一样』就不显示。」
连带做了三件事:

- `manifest.sources` 删掉 **L8**(没人再引用它,与 Task 18 删 S11 同一理由);
- `hcq_eye.note` 里转述的那两个间隔(「定期(每3月)」「每年至少检查一次」)**一并删掉** ——
  `note` 会原样印到用户眼前,留着等于换个地方说同一句没核过的话;补上了 S9 推荐 5 的逐字眼科间隔;
- 测试 `the_package_insert_numbers_never_drive_a_judgement` 从「只许待在文案里」**收紧成全包禁字**。

### 2. `gc_dxa.min_age` —— 值仍是 `null`,但理由完全反了

拿到 ACR 2022 GIOP **已刊全文**(eScholarship `qt10w6f17t`,PubMed 上挂的免费全文链接)。
三句原文:

> 「As soon as possible after initiation of ≥2.5 mg/day GC treatment for >3 months, screening for
> fracture risk in patients ≥40 years of age should be assessed by using FRAX and by performing BMD
> using dual-energy x-ray absorptiometry (DXA) with vertebral fracture assessment (VFA) testing or
> spinal x-rays.」
> 「BMD with VFA or spinal x-rays are strongly recommended, and, for adults ≥40 years old, **FRAX
> analysis is also recommended**.」
> 「BMD with VFA testing or spinal x-ray **is advised in patients <40 years**, as FRAX is not
> validated in this population.」

即:**「≥40 岁」只挂在 FRAX 上,不挂在骨密度上**。guidelinecentral 那句摘要本身**并没有编造**
(它逐字来自指南),但它把两件事并成一句,读起来像骨密度也按 40 岁卡。

所以 `min_age` 保持 `null` **不是因为核不到,而是因为核到了以后不该填** —— 拿 40 岁当门槛会把
SLE 最主要的发病年龄段挡在一条强推荐之外。相应地:

- `verify_status` `pending` → **`verified`**(人群阈值与年龄的处理现在都有一手出处);
- `action` 改成「做一次骨密度(DXA,含椎体骨折评估);满 40 岁的话还要加做 FRAX 骨折风险评估」
  —— 年龄的真实作用要让用户看得见;
- S13 的 `cite`/`url` 换成拿得到的全文。

**副产品:§G.1 里「GIOP 复查每 1–2 年」这条『核不实』现在可核了** —— 原文表 1 写着
「BMD with VFA or spinal x-ray every 1–2 years during GC treatment」。但那是个**区间**,
取 365 还是 730 是判断,不是转录,本包不替医生选,仍然不写。留给后续任务。

### 3. 泼尼松等效换算表(brief 的必办项)—— 拿到了

**首选来源就打开了**:S10 开放全文 PMC9524765,**Table 3「Equivalent dose of commonly used
glucocorticoids」**(源文件 §G 行 94 说中文版是「表 2」;PMC 英文版共 5 张表,这张是 Table 3)。
逐字等效剂量(mg):

| Drug category | Drug name | Equivalent dose (mg) |
|---|---|---|
| Short-term effects | Hydrocortisone | 20 |
| | Cortisone | 25 |
| | Prednisone | 5 |
| Intermediate-term effects | Prednisolone | 5 |
| | Methylprednisolone | 4 |
| Long-term effects | Triamcinolone acetonide | 4 |
| | Betamethasone | 0.60 |
| | Dexamethasone | 0.75 |

引擎(`rules.rs::gc_daily_mg`)要的是**乘到泼尼松的系数**,所以包里存 `5 ÷ 等效剂量`:
氢化可的松 0.25、可的松 0.2、泼尼松 1、泼尼松龙 1、甲泼尼龙 1.25、曲安西龙 1.25、
地塞米松 6.666666666666667、倍他米松 8.333333333333334。这是对逐字数值的算术换算
(与 `activity.max=18` 同一种做法),没有引入新数;测试逐行验 `等效剂量 × 系数 == 5`。

**⚠️ 顺手堵掉一个会被这次改动引入的错:**「可的松」是「氢化可的松」的子串,而引擎按
「最长的键赢」匹配。表里不单列氢化可的松,氢化可的松就会套用可的松的 0.2,**算低 20%**。
氢化可的松不在 `drugs[gc].names` 里,但 ATC `H02AB09` 命中 `atc_prefix: "H02AB"`,照样进这一类。
已单列并加了专门的测试。

### 4. 填表引爆了 Task 18 留的绊线 —— 一并修了根

Task 18 在 `a_route_the_parser_already_swallowed_is_invisible_to_this_layer` 里写明:
「**填表之前必须先让途径到达这一层**」。填完表后它如期变红:

词典把「地塞米松注射液」归一成规范名「地塞米松」,剂型门(`GC_INJECTION`)只看得见规范名,
于是一次静脉冲击会被按口服换算成 **5 mg × 6.667 = 33.3 mg/天「泼尼松等效」**,并直接进
DORIS `<5 mg` / LLDAS `≤7.5 mg` / `gc_ca_vitd` / `gc_dxa`。在表还是 `null` 的时候,这一条是
被「换算表待核」**偶然**挡住的 —— 表一填,那层保护就没了。

根治点不在包,在数据流:`MedSpan` 丢掉了原样写法。已补:

- `parser::MedSpan` 新增 `raw_names: Vec<String>`(每份文档上**原样写的**名字,`BTreeSet` 去重定序);
- `profile::rules::form_haystack` 一起看它。

**仍然缺的那一半**(写在剂量**之后**的途径,如「甲泼尼龙片 40mg 每日一次 静滴」)被
`meds.rs::strip_trailing_route` 剥掉,`raw_names` 也救不了 —— 已写成一条**钉住今天真实行为**
的测试 `a_route_written_after_the_dose_is_still_invisible_to_this_layer`,修好那天它会红。
根治要 parser 把 `route` 一路带出来,列进交接清单。

### 5. 顺带修的两处引文失真

- `aza_cbc.note`:引文换成 L2 声明的那份 setid(IMURAN)自己的原话(见上表)。
- `cni_egfr.note`:原页是「through the first year**,** and quarterly thereafter」,包里漏了逗号。
  数值无关,但这一行自称 VERBATIM。

### 6. `label_rule: null` 时不该再举「待核」旗(踩到同一个坑)

`label_rule` 改 `null` 后,卡上出现了 `label_rule: null` 配 `label_rule_pending: true` ——
界面上是一面**指向空处**的「待核」。原因是 `serde_json::Value::get` 对 JSON `null` 返回
`Some(Value::Null)`,与 Task 14 m1 在 `min_age` 上踩的是**同一个坑**。已显式滤掉 null。

## 四、包的改动清单

| # | 位置 | 改动 |
|---|---|---|
| 1 | `rules.targets.hcq.label_rule` | 整块 → `null`,新增 `label_rule_note` 记下试过哪些一手来源、怎么失败的 |
| 2 | `manifest.sources` | 删 `L8`;新增 `S17`(LOINC);`S13` 换成可打开的全文 URL + 改 cite;`R1` 补 URL |
| 3 | `drugs[gc].pred_equiv` / `pred_equiv_source` | `null` → 8 个系数 + `S10`,note 写清逐字表与换算方式 |
| 4 | `terms.analytes[*].loinc` | `null` → `13945-1` / `5821-4`,note 点名 `S17` |
| 5 | `monitoring.gc_dxa` | `verify_status` → `verified`;`action` 加 FRAX 年龄条件;note 重写(`min_age` 仍 `null`) |
| 6 | `monitoring.hcq_eye.note` | 删掉 L8 的两个间隔,补 S9 推荐 5 逐字 |
| 7 | `monitoring.aza_cbc.note` | 引文换成 IMURAN 原话 |
| 8 | `monitoring.cni_egfr.note` | 补一个逗号 |

引擎与测试:`parser::MedSpan.raw_names` 新增、`form_haystack` 一起看、`label_rule` 滤 null;
10 条测试跟着改语义(不是放宽:`the_package_insert_numbers_never_drive_a_judgement` 反而**收紧**了),
新增 `hydrocortisone_is_not_swallowed_by_the_cortisone_key` 与
`a_route_written_after_the_dose_is_still_invisible_to_this_layer` 两条。

## 五、golden diff

`UPDATE_GOLDEN=1` 重生成,32 行变动,临床结论没有反向变化:

1. `hcq.label_rule` → `null`,`label_rule_pending` `true` → `false`(不再举空旗);
2. `gc_dxa`:`state` `pending` → **`never`**、`pending` `true` → `false`、`verify_status` → `verified`,
   `action`/`note` 换新。它在提醒列表里从最后一档升到「还没查过」那一档,排序从
   `[gc_ca_vitd, gc_cv_annual, mmf_cbc, hcq_eye, gc_dxa]` 变成
   `[gc_ca_vitd, gc_dxa, gc_cv_annual, mmf_cbc, hcq_eye]`
   (2026-09-18 终审 M4 订正:原先这两行写成 `visit_active`,那一条从来没在清单里出现过;
   逐字核回 `a721fc1` 与 `a721fc1^` 两版 golden 的 `reminders` 块);
3. `sources`:`L8` 消失,`S17` 出现,`S13`/`R1` 的 cite/url 更新;
4. `hcq_eye.note` 换新。

语料里那位患者吃的是泼尼松 7.5 mg qd(系数 1.0),`daily_pred_equiv_mg` 仍是 7.5,**没变**。

## 六、还剩哪些 `null`/pending,谁去核、怎么核

| 项 | 状态 | 怎么收尾 |
|---|---|---|
| **羟氯喹中文说明书**(`label_rule`) | `null`,L8 已删 | 要**人拿药盒里那张纸**(0.1 g 与 0.2 g 两个规格)或在能过 NMPA 反爬的环境里打开说明书数据库,逐字录入并把规格与批准文号写进 cite。程序化抓取这条路走不通(412) |
| `hcq_eye` | `pending`,`phases:[]` | 三份可核来源(AAO 2025 / EULAR 2019 / 中国 2025)本身就给三种间隔,且都按「有无危险因素」分档,而**档案里没有危险因素**。要落成到期日,得先让档案能记录肾病/黄斑病/他莫昔芬/起始年龄 |
| `rtx_igg` | `pending`,`phases:[]` | 原文只有「periodically / before each cycle」,没有天数。除非找到给数的一手来源,否则应长期保持 |
| `mtx_labs` / `ctx_cbc` | `pending`,`package_default` | 两份说明书确认没有间隔;ACR 那套 2–4/8–12/12 周仍追不到一手页。要改成 `label`/`guideline` 必须先拿到一手数 |
| **GIOP 骨密度复查间隔** | 不写 | 原文有「every 1–2 years」(本次核到),但取哪一端是临床判断,需要拍板而不是转录 |
| **S16(中国 2019 LN 指南)** | 只出现在 note,cite 已自述是转引 | 本次再试 `rs.yiigle.com` / 中华医学杂志仍取不到(SPA 空壳、nhc.gov.cn 412)。它引的两个数(>0.5 g/24 h、>500 mg/g)与 S8 一手核过的完全一致,所以不影响任何判定 |
| **`/HP` 别名归错**(词典项,brief 点名要记) | 未修,根治点在内置词典 | 内置 `urine_rbc_count` 的 `aliases` 含**「尿红细胞」**,`units` 只有 `/uL` 和 `10*6/L`;真实报告印「尿红细胞 8 个/HP」时,内置优先吃掉它,而包的 `urine_rbc_hpf`(带 `/HP`、带 SLEDAI >5 的阈值)拿不到值 → **血尿那 4 分静默算不出来**。`urine_wbc_count` 没有裸别名「尿白细胞」,暴露面小一些。**LOINC 正好给了拆分的官方依据**:按面积计数是 13945-1(Naric),按体积是 5808-1,本来就是两个码。修法是把内置拆成两条、按**印刷单位**分流,不是在包里加别名(包抢不走内置) |
| **写在剂量之后的给药途径** | 已钉测试,未修 | `meds.rs::strip_trailing_route` 剥掉后没人接住。根治:`MedObservation` 加 `route`,一路带到 `MedSpan`。在那之前,「甲泼尼龙片 40mg 每日一次 静滴」会按口服换算 |

## 七、数字

- 核查对象 **91** 个带标量的对象(含数值的 **56** 个),**一条没跳过**
- 一手页面复核 **22** 份:DailyMed ×7、PMC ×5、PubMed ×3、机构仓储/出版方 PDF ×6、NLM LOINC ×1
- **值**的判定:MATCH **90** 个对象;无法核实 **1** 个(`targets.hcq.label_rule`,已改 `null`)
- 另查出**不改变数值**的缺陷 **2** 处:L2 引文抄了别的 setid、
  `gc_dxa.min_age` 的**理由**是错的(值恰好该保持 `null`,但原因完全相反)
- 因核查而改动:包 **8** 处、引擎 **3** 处、测试 4 个文件、golden **1** 份
- 仍 pending/`null`:**7** 项(上表)
- 取不到一手件:**2** 类(L8 中文说明书、S16 指南自身页面)
- **我自己引入、被复核抓出来的缺陷:3 处**(见 §九)

## 八、门禁

全部前台跑(数字为 fix round 1 之后):

- `cargo test -p profile` —— **205 passed / 0 failed**
- `cargo test -p parser` —— **211 passed / 0 failed**
- `cargo test --workspace` —— **888 passed / 0 failed / 9 ignored**
- `cargo fmt --all --check` —— 干净
- `cargo clippy -p parser -p profile --all-targets -- -D warnings` —— 干净
- `python3 scripts/sign_skill.py --selftest` —— **6/6**(每次重签之前都跑)

包已用 `scripts/sign_skill.py` 重签。私钥 `~/.medme_skill_signing_key` 全程只被脚本读,
没有打印、复制、移动,也没有进仓库。

## 九、fix round 1 —— 独立复核抓出来的、我自己引入的三处

复核人(又一个独立 agent)判定核查本身站得住:抽查的 6 份一手来源 100% 复现,
0 条编造或放水。但抓出 3 处**是我这一轮改出来的**问题 —— 印证了 CLAUDE.md 硬规矩第 3 条
那句「三轮核查抓出 5 条硬错误,**包括我『修正』时新引入的错误**」。

### C1(Critical)—— 剂型门的粒度错了,一次历史冲击会永久挡住今天的口服剂量

我给 `MedSpan` 加的 `raw_names` 是**整条 span 的历史并集**(一个 drug_key 的所有 mention),
而 `latest_dose` 取的是**最近一条**医嘱 —— 两者不同源。于是「冲击 → 口服维持」
(**SLE 最常见的激素用法**)里那一次冲击会让今天的口服剂量永远算不出来,卡上还把今天那片
8 mg 口服药标成「注射剂型」,`gc_ca_vitd` 与 `gc_dxa` 两条强推荐从 `never` 掉到 `unknown`
—— **掉下去的恰恰是需要过冲击、激素负荷最重的那群人**。

方向上它是 fail-safe(不会算出错的数,只会算不出来),但这是本轮 commit 之后的出厂行为。
**没被测出来的原因**:`testdata/corpus/` 里的激素只有「泼尼松片」,新填的那张表在 golden
里一次都没执行过;我新加的两条用例又都是**单文档**,碰不到合并。

**修法**:`MedBuilder` 跟着 `best_dose` 一起记 `best_raw_name`(**同一条 mention** 的原样写法),
`MedSpan` 出 `latest_raw_name`,`form_haystack` 只看它。`raw_names` 保留(additive),
并在 doc 注释里写明它是历史并集、**不许**用来判断「今天在用什么」。
新增两条探针:`one_pulse_in_the_history_does_not_block_todays_oral_dose`(正向)与
`a_pulse_as_the_newest_order_is_still_not_read_as_a_daily_oral_dose`(反向),
外加提醒侧的 `a_pulse_in_the_history_does_not_silence_the_steroid_reminders`。
`corpus_summary` 5 条数字未变。

### I1(Important)—— 我「补」的那个逗号把引文挪到了它没声明的那一节

自取 LUPKYNIS 原页确认复核人是对的:同一句在 **HIGHLIGHTS 区**(offset 2712)带逗号
「…through the first year**,** and quarterly thereafter.」,在 **§2.3 正文**(offset 10703)
**不带逗号**。包里 note 自称「L3 §2.3 逐字」,所以**改之前那句才是对的**;我那一下
「补逗号」把它换成了另一节的句子,却仍挂着 §2.3 的出处 —— 和我这轮刚修好的 `aza_cbc`
是**同一类缺陷**。已改回,并在 note 里写明两版的差别,免得下一个人再「补」一次。

### I2(Important)—— S13 的 cite 与 url 指向两本不同的期刊

我填的 eScholarship URL 取回的是同步发表的 *Arthritis Rheumatol* 2023;75(12):2088–2102
(doi 10.1002/art.42646),而 cite 写的是 *Arthritis Care Res* 75:2405–19(doi 10.1002/acr.25240)。
内容同一篇(PDF 自己写着「published simultaneously in *Arthritis Care & Research*」),
但照 cite 的页码/DOI 去那个 URL 上找不到。已在 cite 里补上实际读的那一份的完整坐标。

### 四条 Minor,全修了

| # | 问题 | 修法 |
|---|---|---|
| M1 | 测试名说 `keeps_the_pending_flag`,断言却是 `pending == false` | 改名 `…_drops_the_pending_flag` |
| M2 | 注释写「收紧成**全包**禁字」,代码只走了 `rules` | `walk(&src_json(), "pkg")` |
| M3 | `6.5` 的禁字是字面量,写成「6.5 mg/kg」(带空格)能绕过 | 先去掉全部空白再比,并加禁中文写法 |
| M4 | `gc_dxa.note` 的归纳句把限定词丢了(<40 岁的骨密度原文是 *is advised*;*strongly recommended* 那句带「with one or more osteoporotic risk factors」) | 归纳句加回限定词,逐字原句本来就在同一条 note 里 |

**一条都没留。** golden 因 M4 与 I2 两处文案改动重生成,diff **仅 2 行**,
`daily_pred_equiv_mg` 等所有数值一个没动。
