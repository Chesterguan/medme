# 问题导向临床分组表 — 方法与分组依据

**版本**: 草案 v1 · 2026-07-14 · MedMe（医我）
**修订**: 2026-08-04 — 补齐缺失的 ATC 前缀（C03BA / C09B / C09DA / C09DB / A10BD / C10B）与 `C10BX03` 整码；按 WHOCC 官方定义修正 C10B 措辞；新增「已知缺口（待临床裁定）」。

## 方法（一句话）
药物→疾病一律以 **ATC（解剖-治疗-化学）分类**的类别前缀为依据（ATC 前缀即引用）；实验室→疾病一律以**具名临床指南（含年份/版本）或标准定义**为依据；两者都**不做任何臆造**，无法找到可核对来源的映射一律省略。LOINC/ATC 编码直接复用本仓库 `packages/terminology/dictionary.json` 中已从本地 OMOP 词表（LOINC/RxNorm/ATC + OMOP standard concept_id）核验过的编码。

## 分组依据（Bibliography，可在 App 中向医生展示）

**药物分类标准**
- WHO Collaborating Centre for Drug Statistics Methodology（WHOCC）：**ATC/DDD Index**。相关一级/二级组：
  - A10 Drugs used in diabetes（A10A Insulins and analogues；A10B Blood glucose lowering drugs, excl. insulins：A10BA 双胍、A10BB 磺脲、A10BD Combinations of oral blood glucose lowering drugs（口服降糖药固定复方）、A10BF α-糖苷酶抑制剂、A10BG 噻唑烷二酮、A10BH DPP-4、A10BJ GLP-1、A10BK SGLT2、A10BX 格列奈等）
  - C09 Agents acting on the renin-angiotensin system（C09A ACE inhibitors, plain；C09B ACE inhibitors, combinations（C09BA +利尿剂、C09BB +CCB、C09BX 其他）；C09C ARBs, plain；C09DA ARBs and diuretics；C09DB ARBs and calcium channel blockers）
  - C10 Lipid modifying agents（C10AA 他汀、C10AB 贝特、C10AX 其他含依折麦布/PCSK9；C10B Lipid modifying agents, combinations：C10BA Combinations of various lipid modifying agents、C10BX Lipid modifying agents in combination with other drugs——**按 WHOCC 定义两者均不限于他汀**，如 C10BA10 贝派地酸依折麦布不含他汀；C10BX03 Amlodipine and atorvastatin 以整码收录进高血压）
  - C08 Calcium channel blockers（C08CA 二氢吡啶）、C07 Beta blocking agents、C03 Diuretics（C03A Thiazides、C03BA Sulfonamides, plain（噻嗪样，吲达帕胺 C03BA11/氯噻酮 C03BA04）、C03D 醛固酮拮抗剂）、C01DA Organic nitrates
  - B01 Antithrombotic agents（B01AC 抗血小板）、B03 Antianemic preparations（B03A 铁剂、B03B B12/叶酸、B03XA EPO）
  - M04 Antigout preparations（M04AA 抑制尿酸生成、M04AB 促排泄、M04AC 秋水仙碱）
  - H03 Thyroid therapy（H03A 甲状腺制剂、H03B 抗甲状腺药）

**实验室分组指南**
- 《中国糖尿病防治指南（2024版）》，中华医学会糖尿病学分会（2020年版《中国2型糖尿病防治指南》的最新修订，已更名）。
- 《中国高血压防治指南（2024年修订版）》，中华高血压杂志 2024年第7期。
- 《中国血脂管理指南（2023年）》，中华心血管病杂志 2023;51(3)（2016年版《中国成人血脂异常防治指南》的修订更名）。
- KDIGO 2024 Clinical Practice Guideline for the Evaluation and Management of Chronic Kidney Disease（GFR G1–G5 / 白蛋白尿 A1–A3 分级）；《中国慢性肾脏病早期评价与管理指南》。
- 《甲状腺功能减退症基层诊疗指南（2019年）》，中华全科医师杂志 2019;18(11)。
- 《中国甲状腺功能亢进症和其他原因所致甲状腺毒症诊治指南（2022）》，中华医学会内分泌学分会等。
- WHO. Haemoglobin concentrations for the diagnosis of anaemia and assessment of severity（2011，WHO/NMH/NHD/MNM/11.1）——贫血 Hgb 定义切点。
- 《中国高尿酸血症与痛风诊疗指南（2019）》，中华医学会内分泌学分会。
- 《代谢相关（非酒精性）脂肪性肝病防治指南（2024年版）》，中华医学会肝病学分会（2018更新版《非酒精性脂肪性肝病防治指南》的修订更名）。

## 覆盖情况与坦白说明
- **共覆盖 10 个疾病条目**（甲状腺功能异常按甲减/甲亢拆为两条，因 ICD 与药物类别不同）：58 条实验室映射、45 条药物映射。
- **grounding 扎实**：2型糖尿病、高血压、高脂血症、CKD、甲减/甲亢、痛风/高尿酸——labs 有对应中国/国际指南章节，drugs 有干净的 ATC 前缀。
- **thin / 需注意的条目**：
  - **冠心病**：慢性冠心病缺少一份可核对的"实验室监测"中国指南；LDL-C 借《中国血脂管理指南（2023）》ASCVD 二级预防章节 grounding 扎实，但**肌钙蛋白 I/T、CK-MB、NT-proBNP 属急性冠脉综合征/心衰的事件性检查，非慢性监测项**，已在各行 source 中明确标注，未伪装成慢病监测指南。药物侧（抗血小板/他汀/β阻滞剂/ACEI-ARB/硝酸酯）ATC grounding 完整。
  - **贫血**：贫血是综合征而非单一病，Hgb 定义切点用 WHO 2011；铁蛋白/血清铁/B12/叶酸属**病因鉴别 workup panel**（缺铁性/巨幼细胞性），已在 source 中如实标注为"病因诊断"而非单一指南强制项。
  - **代谢相关脂肪性肝病**：labs（ALT/AST/GGT + FIB-4 相关的血小板）grounding 扎实；但**无任何以脂肪肝为适应证的 ATC 药物类别**——2024 指南的药物建议均指向代谢共病（二甲双胍/SGLT2/GLP-1/他汀），因此 `drugs` 留空，不臆造"保肝药"类别。
- **省略项**：未纳入无干净 ATC 类别或无具名指南来源的映射（如各类"保肝药""改善微循环药"）。

## 已知缺口（待临床裁定）

以下 5 条是 ATC 前缀补齐（2026-08-04）时逐条核过、**明知未纳入**的映射。它们不是遗忘，也不是"论证过不该加"——除特别注明外，都是**证据不足以自动决定、留待人工临床裁定**的悬案。记在这里，是因为一条只活在 commit message 里的缺口，等于没有记。

1. **`C02CA` α受体阻滞剂（乌拉地尔 C02CA06）未入高血压——暂缓待人工核。**
   本分支最初的不纳入理由是"该类同时含以 BPH 为主要用途的 α 阻滞剂"，**该理由经 WHOCC 核对不成立**：以 BPH 为主用途的 α 阻滞剂（坦索罗辛、阿夫唑嗪、特拉唑嗪、赛洛多辛）编在 `G04CA` Alpha-adrenoreceptor antagonists（G04 泌尿系统药）之下，不在 `C02CA`；而 `C02CA` 的全部 5 个成员（哌唑嗪 01、吲哚拉明 02、曲马唑嗪 03、多沙唑嗪 04、乌拉地尔 06）都挂在 **`C02 ANTIHYPERTENSIVES`** 顶层组下。因此"会错挂"这一论据无效。
   现状：**高血压泳道对整个 C02 零覆盖**（C02A 中枢性、C02C 外周性、C02D 血管平滑肌作用、C02K 其他抗高血压药全部未纳入）。C02 类在国内以可乐定、乌拉地尔、米诺地尔等二三线/特殊场景用药为主，是否整组纳入、纳入到哪一层，需要临床拍板——本次不擅自补。

2. **`C09DX04` 沙库巴曲缬沙坦（ARNI）未入高血压。**
   主适应证是 HFrEF，而本表**没有心力衰竭条目**。挂进高血压泳道，医生读到的是"这是他的降压药"，与实际用药意图不符。正解是先加一条心衰条目，而非把它塞进现有泳道。

3. **`C08D` 地尔硫䓬/维拉帕米未入高血压——同时记一处本表自身的不自洽。**
   不纳入理由是"也大量用于房颤心室率控制与血管痉挛性心绞痛，无法从 ATC 区分用药意图"。**但同一把尺子没有用在已纳入的 `C07A` β受体阻滞剂上**：C07A 同样大量用于冠心病、房颤心室率控制、心衰与甲亢（本表的甲亢条目自己就挂着 C07A），处境与 C08D 完全相同，却照挂高血压。两者必须同进同出，现状是不一致的，待临床统一裁定。

4. **CKD 泳道缺 CKD-MBD 用药：`V03AE` 磷结合剂、`H05BX` 拟钙剂。**
   labs 侧已列钙（2000-8）与无机磷（14879-1）并注明"KDIGO 2024 CKD-矿物质与骨代谢紊乱（CKD-MBD）"，drugs 侧却没有任何对应类别——同一个并发症，查得到、看不到在治什么药。`V03AE`（司维拉姆 V03AE02、碳酸镧 V03AE03、醋酸钙 V03AE07）与 `H05BX`（西那卡塞 H05BX01、依特卡肽 H05BX04）ATC 边界干净，主要待定的是这两类是否属于本表"常见慢病基层随访"的既定范围。

5. **尼可地尔 `C01DX16` / 曲美他嗪 `C01EB15` 未入冠心病。**
   两者都是国内常用的抗心绞痛药，但父类不能用作前缀：`C01DX` Other vasodilators used in cardiac diseases、`C01EB` Other cardiac preparations 都是杂类抽屉，挂前缀会把无关药物拖进冠心病泳道。整码收录（如本表 `C10AX09`、`M04AC01`、`C10BX03` 的先例）是干净的，但超出本次"补前缀"的范围，未做。
