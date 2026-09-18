# 病程档案(Disease Profile)skill 框架 · 第一个病 SLE — 设计

日期 2026-09-16。上游:`2026-09-11-advanced-edition-overview-design.md` §C。事实依据:`.superpowers/sdd/disease-profile/fact-sheet.md`(代码,file:line)、`sle-clinical-sources.md`(临床,逐字出处;下文引用记作 §A.3/§B.2… 即该文件章节)。
用户拍板(2026-09-16):第一个病 **SLE**;方向是免疫介导慢病族(MS/MG/IBD/NMOSD/SLE),不做大众慢病;框架要 adaptive、多模态、长病程、频繁检测。

## 0. 一句话
用户 2026-09-16 拍板:界面名 **「病程档案」**;它与通用摘要**分开**——未开启任何病的包时,「看懂」只有通用摘要(化验趋势、时间线、就诊);开启后「病程档案」是「看懂」里独立的一块(入口卡 → 独立页),通用摘要不变。其余 §10 五条按推荐执行(包签名;DORIS 边界 `<5` 注中国 `≤5`;显示 x/18 数字;医生录 PGA 二期)。
**一个病 = 一个 skill 包(服务端公开静态 JSON,签名,可热更新,不含用户数据);App 只有一个渲染引擎和一个规则引擎。** 抽取用「族级」prompt(服务器分不出你是哪个病),病程档案在手机上从事件日志算出来,永远可重算。

## 1. 数据流
```
病历(图/PDF/手录) ─OCR/脱敏─> /v1/extract(族级 prompt, schema 2) ─> ExtractionAdded{schema:2} → CAS
                                                                          │
手动录入(症状/自评/复发/体重/血压) ─> DocumentAdded{doc_type=profile_event|self_measurement}
                                                                          │
                     skill 包(GET /v1/skills/sle/<ver>.json, Ed25519 签名) ─┐
                                                                          ▼
                              packages/profile::materialize(vault, package) → ProfileView(JSON) [本机、按 vault revision 缓存]
                                                                          ▼
                              Flutter 渲染引擎(7 种 section 类型) → 「看懂」页 / 医生交接单 / 提醒
```
不新增 `Event` 变体。新增 `DocType::ProfileEvent`(与 `SelfMeasurement`/`Note` 同一先例,fact-sheet §5)。`ExtractionAdded` 只把 `schema` 从 1 升到 2(同事件、同表、同同步清单)。

## 2. Skill 包格式(`skills/<id>/<version>.json`)
```json
{
  "manifest": {"id":"sle","family":"immune","version":"2026.09.1","min_engine":1,
               "display":{"name":"系统性红斑狼疮","short":"狼疮"},
               "disclaimer":"…仅整理你的病历,不做诊断…",
               "sources":[{"id":"S4","cite":"EULAR 2023 update, ARD 2024","url":"…"}]},
  "triggers": {"diagnosis_patterns":["系统性红斑狼疮","红斑狼疮","SLE","狼疮性肾炎"],
               "serology_any_two":["ana_positive","anti_dsdna_high","anti_sm_positive","low_c3","low_c4"]},
  "terms":    {"aliases":{"complement_c3":["补体C3","C3","补体 C3"]},
               "analytes":[{"key":"urine_pcr","name":"尿蛋白/肌酐比值","loinc":"2890-2","panel":"肾功能",
                            "canonical_unit":"mg/g","units":[{"unit":"mg/mmol","slope":8.84,"intercept":0}],
                            "aliases":["尿蛋白肌酐比","UPCR","尿蛋白/肌酐"],"note":"待核 LOINC"}]},
  "markers":  [{"key":"complement_c3","role":"activity","dir":"low_is_active","group":"补体"},
               {"key":"anti_dsdna","role":"serology","dir":"high_is_active","qualitative_ok":true},
               {"key":"urine_pcr","role":"organ:kidney","dir":"high_is_active"},
               {"key":"urine_protein_24h","role":"organ:kidney","dir":"high_is_active"},
               {"key":"wbc","role":"activity"},{"key":"plt","role":"activity"},
               {"key":"esr","role":"inflammation"},{"key":"crp","role":"inflammation"},
               {"key":"creatinine","role":"organ:kidney"},{"key":"egfr","role":"organ:kidney"},
               {"key":"alt","role":"drug_monitor"},{"key":"ast","role":"drug_monitor"}],
  "drugs":    [{"class":"gc","atc_prefix":"H02AB","names":["泼尼松","泼尼松龙","甲泼尼龙","地塞米松"],
                "pred_equiv":{"泼尼松":1,"泼尼松龙":1,"甲泼尼龙":1.25,"地塞米松":6.67},"pred_equiv_source":"待核"},
               {"class":"hcq","atc_prefix":"P01BA02","names":["羟氯喹","硫酸羟氯喹","纷乐"]},
               {"class":"mmf","names":["吗替麦考酚酯","霉酚酸酯","骁悉"]},{"class":"aza","names":["硫唑嘌呤"]},
               {"class":"ctx","names":["环磷酰胺"]},{"class":"mtx","names":["甲氨蝶呤"]},
               {"class":"cni","names":["他克莫司","环孢素","伏环孢素"]},
               {"class":"belimumab","names":["贝利尤单抗","倍力腾"],"infusion":{"iv":"0,2,4 周后每 4 周","sc":"每周"}},
               {"class":"telitacicept","names":["泰它西普","泰爱"],"infusion":{"sc":"每周 160 mg"}},
               {"class":"rtx","names":["利妥昔单抗","美罗华"]}],
  "rules":    { "...见 §5" },
  "views":    { "...见 §6" }
}
```
- `terms` 是**术语表运行时覆盖层**:可给已有 key 加别名,可定义新分析物(命名空间 `pkg.<id>.` 或直接给全局 key,冲突时包不能覆盖内置定义)。这是「加病不发版」成立的前提;现状 UPCR 缺失(fact-sheet §4)就靠这层补。
- 包由我们的 Ed25519 私钥签名,公钥编进 App;签名不过 = 不加载。防的是 CDN/桶被改后往规则里塞东西。
- 版本:App 只接受 `min_engine ≤ 自己的引擎版本`;新 section 类型或新规则类型才需要发版。

## 3. 族级事实 schema(extraction schema 2)
schema 1 的 `labs/meds/diagnoses/impression/notes` 全部保留;新增 `facts[]`,**类型枚举是族级的**(五个病共用),服务器从 prompt 看不出病种:
```json
{"facts":[{"type":"organ_involvement","organ":"kidney|blood|skin|joint|cns|serosa|lung|gi|eye|other","date":"","text":"狼疮性肾炎 IV 型","evidence":"原文逐字"},
          {"type":"flare","date":"","text":"病情活动加重","evidence":""},
          {"type":"hospitalization","date_start":"","date_end":"","reason":"","evidence":""},
          {"type":"biopsy","organ":"kidney","date":"","result":"ISN/RPS IV 型","evidence":""},
          {"type":"infusion","drug":"","dose":"","date":"","evidence":""},
          {"type":"dose_change","drug":"","from":"","to":"","date":"","evidence":""},
          {"type":"scale","name":"SLEDAI|PGA|EDSS|MG-ADL|Mayo|BILAG|other","value":"","date":"","evidence":""},
          {"type":"imaging_finding","modality":"MRI|CT|OCT|DXA|US|endoscopy","finding":"","date":"","evidence":""},
          {"type":"infection","date":"","text":"","evidence":""},
          {"type":"pregnancy","status":"planning|pregnant|postpartum","date":"","evidence":""},
          {"type":"vaccination","name":"","date":"","evidence":""},
          {"type":"exam_done","name":"眼底|OCT|视野|骨密度|心超","date":"","evidence":""}]}
```
规则:每条 fact 的 `evidence` 必须是原文逐字子串(与 labs 同一套 `verify`;图片模式验不过 → `unverified`,界面标「需核对」)。prompt 文件 `packages/deid/prompts/extract_v2_system.txt`,参数与 v1 共用 `extract_v1_params.json`(改名 `extract_params.json`)。`services/api/extract.py` 接受 `schema:2`;老 App 发 `schema:1` 照旧。

## 4. 本机状态:`DocType::ProfileEvent`
用户主动做的事必须落日志(同步、分享、重算都要):
```
###MEDME-PROFILE-V1###
{"kind":"enable|disable|confirm_dx|reject_dx|flare|symptom_score|pga|dismiss_reminder|drug_start|drug_stop|infusion|weight",
 "package":"sle","at":"2026-09-16","payload":{...}}
```
- 与 `self_entry.rs` 同构:`render_profile_event_text` / `parse_profile_event_payload`(版本不符返回 None,不猜)。
- `note`/`profile_event` 都不进临床聚合(fact-sheet §5 的过滤点),只进 `packages/profile`。
- 「开启 SLE 档案」= 一条 `enable`;从未开启 = 不算、不显示、不提醒。

## 5. 规则引擎(`packages/profile`,纯函数,输入 = 汇总 + facts + profile_events + 包,输出 = ProfileView)
### 5.1 识别建议(adaptive 之一)
`triggers.diagnosis_patterns` 命中任一诊断文本,**或** `serology_any_two` 里 ≥2 项成立(ANA 阳性/滴度≥1:80、抗 dsDNA 阳性或 > 本院上限、抗 Sm 阳性、C3 或 C4 < 本院下限)→ 在「看懂」页给一张「这份档案像是狼疮相关,要不要开启狼疮病程档案?」卡;用户确认才 `enable`。不自动贴标签。
### 5.2 活动度(化验可算部分)— §B.2,权重与阈值逐字
| 项 | 判定 | 分 |
|---|---|---|
| 低补体 | C3 或 C4 或 CH50 **低于该报告印的下限**(lab-relative) | 2 |
| dsDNA 升高 | 数值 > 该报告上限;定性「阳性」也计,但标「非 Farr 法,按定义有偏差」 | 2 |
| 蛋白尿 | **24h 尿蛋白 > 0.5 g**;UPCR **不能**替代计分,只单独展示 | 4 |
| 血尿 / 脓尿 | 尿沉渣 RBC / WBC > 5 /HP;标「需排除结石感染,需医生确认」 | 4 / 4 |
| 管型 | 报告出现红细胞管型/颗粒管型 | 4 |
| 白细胞减少 | WBC < 3.0 ×10⁹/L | 1 |
| 血小板减少 | PLT < 100 ×10⁹/L | 1 |
取值窗口按 SLEDAI-2K 表格原文:**评分日前 10 天内**的化验(§B.1),超窗不计。输出 `sledai_lab_part = x/18`,永远带「化验可算部分」标签,**不显示为 SLEDAI 总分**。症状项由用户/医生在 App 内按 SLEDAI-2K 条目勾选(`symptom_score` 事件)后才合成总分;总分分档用 ≤6 轻 / 7–12 中 / >12 重(§B.4:中国 2020 与 EULAR 2023 一致)。每次计分记录「用了哪几张单子」作证据链。
### 5.3 达标检查表(不自动宣布缓解)
DORIS 2021(§C.1):cSLEDAI=0(即去掉补体、dsDNA 两项后为 0)、PhGA<0.5、泼尼松 **<5 mg/d**、可用 HCQ/稳定免疫抑制剂。LLDAS(§C.2):SLEDAI-2K≤4 且无重要脏器活动、PGA≤1、泼尼松≤7.5、无新活动。界面逐条 ✔/✘/未知,PGA 没录就是「未知」。边界:按 DORIS Box 1 用 `<5`,并注「中国 2025 指南写 ≤5」。
### 5.4 用药与目标
- 激素:最近一次泼尼松等效日剂量(换算表随包,出处待核),画两条线:7.5(EULAR 2019 §C.3)与 5(EULAR 2023);≥7.5 mg 超 3 个月 → 提醒钙/维 D(§D.1);≥2.5 mg 超 3 个月且 ≥40 岁 → 提醒骨密度/FRAX(§D.1)。
- 羟氯喹:mg/kg = 日剂量 / 最近体重(自测或病历);目标 ≤5 mg/kg 实际体重(EULAR 2019/2023、中国 2025,§C.4);**国内说明书写 6.5 mg/kg 理想体重 ≤0.4 g/d,两份说明书的眼底间隔还互相矛盾(每 3 月 vs 每年)**——包里两套都带、界面显示指南值并注说明书值(§G)。眼科:AAO 2016 已被 **AAO 2025** 取代(OCT + 广角 FAF 为主,视野降为确认;东亚人多为旁中心型),基线一次,无危险因素 5 年后每年,有肾病/他莫昔芬/高龄起始从开始每年(§C.5, §D.2)。
- 免疫抑制剂/生物制剂的监测(§D):MMF、AZA 血常规 第 1 月每周、第 2–3 月每 2 周、之后每月(说明书);CNI eGFR 第 1 月每 2 周、第 1 年每 4 周、之后每季,血压第 1 月每 2 周;贝利尤 IV 0/2/4 周后每 4 周,SC 每周;泰它西普每周 160 mg;RTX 起始前查 IgG、之后定期;MTX/CTX 说明书只写「定期」→ 包里给保守默认(每月血常规肝功;CTX 每次冲击前血常规),**标「包默认,非指南数值」**。
- 提醒算法只允许两类来源,**不许按单项指标造复查间隔**(核查结论:中国 2020/2025 与 EULAR 都没有给 dsDNA/补体/尿蛋白/血常规任何单项间隔,§G):(1) **病级节律**——活动期每月复诊、稳定期每 3–6 月(中国 2020 Rec 3 / EULAR 2023),复诊时该查的一组指标由包列出(markers.role=activity/serology/organ),提醒文案是「该复诊了,通常会查 …」而不是「你的 dsDNA 过期了」;(2) **药物说明书/指南明示的频率**(§D:MMF/AZA 血常规、CNI eGFR 与血压、羟氯喹眼科、激素的钙/骨密度/心血管危险因素每年、RTX IgG、生物制剂输注周期)。判定:取该项最近一次日期(序列或 `exam_done` fact)与间隔比较,超过 ×1.2 → 「逾期」,从未有 → 「还没查过」;每条提醒带出处 id 与「指南/说明书/包默认」三选一的标签。用户 `dismiss_reminder` 后本轮不再提,下次到期再提。
### 5.5 狼疮肾炎里程碑(仅当肾受累或出现 UPCR/24h 尿蛋白)
以确诊/治疗起始(`drug_start` 或首次肾受累 fact)为 T0:3 月蛋白尿降 ≥25%、6 月 ≥50%(部分应答)、12 月 UPCR <700 mg/g,GFR ≥ 基线 80%;**完全肾应答 = 任一时点 UPCR <500 mg/g**(EULAR 2025 肾脏更新);旧口径 <500 mg/24h(EULAR 2019)与 KDIGO 2024 一并带年份(§E.2);活检指征:持续蛋白尿 ≥0.5 g/24h 或 UPCR ≥500 mg/g(§E.1)。界面画里程碑与实际值,**不下「缓解」结论**,四个阈值都带出处与年份。
### 5.6 数据完备度驱动界面(adaptive 之二)
每个 section 声明 `requires`;没数据的 section 折叠成一行「还没有 X,下次看病可以带回来」;有数据才展开。首页永远先出「待补/逾期」再出趋势。

## 6. 视图规格(渲染引擎只认 7 种 section)
| type | 数据绑定 | SLE 用法 |
|---|---|---|
| `status_card` | drugs, last_visit | 现行方案(激素等效剂量、HCQ mg/kg、免疫抑制剂/生物制剂 + 最近输注)、上次风湿科就诊 |
| `score_card` | rules.activity | 「化验可算 SLEDAI x/18」+ 用了哪几张单;有症状分才显示总分与分档 |
| `series_chart` | markers[] | 补体 C3/C4、dsDNA、尿蛋白(UPCR 与 24h 分开画)、血常规;各院参考区间用各自单子的,指南目标另画虚线;「需核对」空心点 |
| `reminders` | rules.monitoring | 待补/逾期,按包内 priority 排序 |
| `timeline` | facts(flare/hospitalization/biopsy/infusion/dose_change/infection/pregnancy) + meds | 长病程压缩到年,复发标红 |
| `checklist` | rules.states | DORIS / LLDAS 逐条 |
| `handoff` | 以上全部 | 医生交接单一页:当前活动度指标 vs 上次、现行方案、近 12 月复发、逾期监测、各院来源 |
渲染引擎是 Flutter 一套 widget,section 顺序、标题、空态文案全来自包。医生交接单走现有分享通道(二维码/授权/代拍不变),查看器同样按 `views.handoff` 渲染。

## 7. 多模态输入 → 数据
| 输入 | 路径 | 产出 |
|---|---|---|
| 化验单(图/PDF) | 现有 labs 抽取 | 序列点(含 unverified) |
| 门诊病历/出院小结 | schema 2 facts | organ_involvement / flare / dose_change / hospitalization / scale |
| 肾活检病理 | facts.biopsy | ISN/RPS 分型 |
| 眼科(眼底/OCT/视野)、骨密度、心超 | facts.exam_done + imaging_finding | 监测项「已做」+ 所见 |
| 输注/日间病房记录 | facts.infusion | 生物制剂周期 |
| 手动录入 | self_measurement / profile_event | 体重、血压、症状勾选、PGA、复发、开停药 |
| 医生(授权查看者) | 后续:`pga`/`symptom_score` 允许授权医生录入 | 暂不做 |

## 8. 隐私与对外话术
- 抽取 prompt 族级:请求里没有病种,服务端存的仍只有 token 数(fact-sheet §2)。**不许**把 `package id` 放进任何请求。
- skill 包:`GET /v1/skills/index.json`、`GET /v1/skills/{id}/{ver}.json`,无鉴权、不带账号头、可缓存;后端新路由形态(fact-sheet §7)。日志只记路径不记 IP 归属(与现状一致)。
- 档案计算、提醒、达标表全在手机;`profile_event` 与其他文档一样以密文同步。
- 隐私政策 §三.7 加一句「结构化整理还会把病程事实(复发、用药变化、检查是否做过)从脱敏后的单据里整理出来」;新增一段「病程档案在你手机上算,服务器不知道你开启了哪种病」。ADR 0011。
- 对外不许说「计算 SLEDAI」「判断缓解」;只能说「按指南把化验可算的部分整理出来、把该复查的列出来」。

## 9. 代码落点
- 新 crate `packages/profile`(规则引擎 + 包校验 + 签名验证);`packages/terminology` 加运行时覆盖层;`packages/parser` 加 facts 解析与 verify;`packages/deid/prompts/extract_v2_system.txt`;`services/api`:schema 2 透传、`/v1/skills/*`、`skills/` 目录与签名脚本(私钥不进仓库);`core-model`:`DocType::ProfileEvent`;移动端:`vault_profile_view` FRB(一个函数返回 ProfileView JSON)+ 渲染引擎 + 「看懂」页(位置等 IA 方案定)+ 交接单;查看器 `handoff` 渲染。
- 评测:`examples/demo-dataset` 加一套合成 SLE 病程(3 年、4 家医院、含活检/输注/眼科),golden ProfileView 逐字段钉住;每条规则一个阈值边界用例;抽取 v2 在 MedRepBench 上回归不能掉。

## 10. 需要你拍板的(推荐已标)
1. 包签名(推荐做,防投毒)。
2. DORIS 边界 `<5 mg` 还是中国 2025 的 `≤5`(推荐按 DORIS 原文 `<5`,界面注明差异)。
3. 「化验可算 SLEDAI x/18」是否显示数字(推荐显示,带标签;不显示分档)。
4. 医生(授权查看者)能否录 PGA/症状分(推荐第二期)。
5. 功能在界面上的名字(等词表:「病程档案」/「病情档案」/「狼疮档案」)。

## 11. 已知边界(如实写进界面与政策)
活动度只有化验可算部分;dsDNA 检测方法与 SLEDAI 定义不一致;UPCR≠24h 尿蛋白;血尿/脓尿需临床排除;指南年份不同数值不同(2019/2023/2025),包内带年份、界面显示新的并注旧的;换算表与部分中文项目名待核(§A.3、§G)。**来源文件 §G 标出的「仅经摘要管道」的值(药物说明书、中文来源)在 C4 临床核查时必须逐条重验**——研究阶段抓到过两次工具编造(羟氯喹剂量、ANA 荧光型,已剔除)。眼科、影像、输注、诊断证明等文书**无国家格式规范**,只能从样本学;先翻 `examples/demo-dataset`。

## 12. 分期(写计划时按此拆)
C1 包格式 + 加载/签名/缓存 + `/v1/skills` → C2 抽取 schema 2(prompt、verify、parser、评测回归)→ C3 `packages/profile` 规则引擎 + `ProfileEvent` → C4 SLE 包内容 + 术语覆盖层(UPCR 等)+ 临床独立核查 → C5 渲染引擎 + 看懂页 + 交接单(等 IA 定)→ C6 政策 + ADR 0011 + 模拟器 smoke。
