# 2026-10-22 · 通用病程档案层:不靠病种包,任何慢性病自动有

spec:`docs/superpowers/specs/2026-10-22-generic-chronic-profile-design.md`(用户拍板稿 A);ADR:[0012](../ADR/0012-generic-chronic-profile-layer.md)(Amends 0011)。分支 `feat/generic-profile`,基于 `feat/timeline-tiers`。背景:Epic 全量病历导进来后「趋势」只有一张「可以整理 SLE」,心脏病与感染什么都没有;用户原话「包不需要这么细,我这也算慢性病」。

**做了什么**
- D0 硬前置(sidecar 的码之前没人读):`parser::diagnoses_from_json` 接进 `aggregate`(有抽取 JSON 且 `diagnoses` 非空只用 JSON,零条退回正则,与 labs/meds 同一条规矩);`deid::MedItem.rxnorm` + `terminology::resolve_rxnorm` + `meds::from_parts` 码兜底,`verify` 产物清码;`handoff` 结论段认英文 `IMPRESSION/FINDINGS/CONCLUSION`(大小写不敏感,英文签名脚注当终止行),两个 fn 开 `pub`,中文用例逐字不变。
- 词典补 5 条:voriconazole(J02AC03)、lisinopril(C09AA03)、tacrolimus_level(11253-2)、digoxin_level(10535-3)、voriconazole_level(38370-3);降钙素原早就有(key `pct`),spec 的「✗」是 key 名没对上。
- `packages/profile`:`generic_tables.rs` 三张 const 表(ICD 覆盖表 + 章节表 / ATC 前缀 / 化验 key → 族)+ `generic.rs` 的 `materialize_generic(docs, encounters, events, installed, today)`:`family_cards`(按归一后的码合并,族按最近出现日倒序,other 倒数第二、uncoded 最后,每族化验小表最近值)、`med_table`(「记录中自 YYYY-MM-DD 起」= 剂量键连续出现的起点;180 天 stale;停药只认含药名那行写了 `停用|discontinued|…` 整词,裸 d/c、discharge、stopped smoking 不算;**不从清单里消失推停药**)、`journey`(住院/急诊/手术/影像/病理/`med:*`/`dx:*` 泳道,住院天数与时间线页同口径,止早于起记 1 天,整份依据 `span: null`)、`evidence`。`materialize` 拆出 `sections_for`,一份 `Ctx` 给每个开着的包各算一遍叠在后面;包的 `latest_dose` 状态行替换通用层同类药的行。`Section.package_id` 用 Option 不序列化 → 两份 SLE golden 逐字节不变。
- 语料:Doe, Jane(`examples/demo-dataset/generate_jane.sh` 直接写 `testdata/corpus-jane/`,文本 + Epic 适配器样式 sidecar,`deid::verify` 钉 sidecar 逐字在文本里);golden `golden_generic_view.json`;pipeline 集成测试走 `import_bundle` → `encounters_with_docs` → 通用层。
- 手机:`builtin_skills.rs`(内置包逐字节编进二进制,测试钉内置清单 ↔ `index.json` 逐一相等)+ `vault_profile_install_builtin`(开箱时先装,再重装术语覆盖层)+ `vault_profile_view_general`(通用段 + 开着的包段 + `packages[]` + `documents[]`);Flutter 稿 A:一张入口卡(族 chip 行 / 用药 N 种 / 最近住院 / 每包一行,门槛:带码 <3 只出「已有 N 条诊断记录」,空箱子「还没有诊断或用药记录」),档案页固定「现在 / 进程 / 依据」三 tab,通用段在前、每包一段在后;`family_cards` / `med_table` 渲染器。

**三张表核查(只读 subagent 逐条核到 ICD-10/ATC/LOINC)**:覆盖表 17 行、ATC 15 行无一错;补 J12–J14(病毒/肺炎链球菌/流感嗜血杆菌肺炎)、L02(肿瘤内分泌治疗);Z79.01 是 ICD-10-CM 独有;章节边界与 ICD-10 块无一处不符,已知边角(CM 的 D49、D3A/C7A/C7B 归一失败当无码;G00–G09 只进神经;N30–N39 也叫「肾」)接受;伏立康唑浓度原留空的 LOINC 在 loinc.org 核到 38370-3。第二道(用户自己过一遍)待做。

**验证**:`cargo test --workspace` 49 个测试二进制全绿(998 条);`cargo clippy --workspace --all-targets -D warnings` 与 `cargo fmt --check` 干净;手机 crate `cargo test` 84 + frb_dispatch_indices 绿(下标 44 不动),clippy 只剩 2026-10-21 记过的 5 条旧告警;`flutter analyze` 零 issue;`flutter test` 全量 1111 过、1 红 = `glossary_guard` 弱闸「导入」(`import_flow.dart`,PR #243 起就红,本分支没动它);文案闸基线挪到稿 A 落地提交 d731618。

**独立审查(code-reviewer,整分支)抓出 1 Critical 2 Important,全修、各带回归测试**:停药判定只看「含药名的行有停词」会把「Do not stop taking warfarin」「不可自行停药」「Aspirin stopped; continue metoprolol」都标成停 → 改成同一子句 + 停词前无否定(`stops_drug`,语料加了两条诱饵行);通用段与包段各自从 1 编依据号,界面合并后点开错的那句 → 共用一本 `EvidenceBook`(单包路径不变,SLE golden 不动);缺出院日写「住院 1 天」是编数 → 只写「起日 · 住院」。Minor 留着:ICD-10-CM 第三位带字母的码(D3A/M1A)归一失败当无码;`dose_key` 对 `.5mg`/`2.50mg`/`1,000 mg`/「毫克」会出假的剂量变化;未来日期的文档 `days_since` 为负;入口卡对形状错误的 JSON(families 不是数组)会抛;在「进程/依据」tab 开关包会跳回「现在」。

**留的**
- 中文诊断名 → ICD 映射、通用英文医院名识别、Epic `Patient not taking` 解析、桌面 Tauri 都没做(spec §6)。
- 有化验无诊断的族不单独出卡;化验行参考区间是解析后的数(`2-3`,不是印刷的 `2.0-3.0`)。
- 「开始吃/已停/在吃」没进全局文案闸(别的屏合法地说「正在吃的药」),只在档案三个文件与渲染树上扫。
- 真机未验;模拟器上的 Jane/真实 Epic 箱子截图留给用户装包后看。
