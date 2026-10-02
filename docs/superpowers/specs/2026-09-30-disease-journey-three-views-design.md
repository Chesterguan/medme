# 病程档案 · 三个视图(现在 / 进程 / 依据)— 设计

增补 [2026-09-16 病程档案 skill 框架](2026-09-16-disease-profile-skill-framework-design.md) 的 §6 视图规格,其余章节不变。日期 2026-09-30。

## 0. 一句话

**一份事件日志,三个投影。** 「现在」是状态变量折叠到今天;「进程」是状态变量的变更日志;「依据」是每个值、每次变更点回去的原件位置。三者同源,规则引擎仍是纯函数,不加事件类型。

定位:记录类产品(含 MedMe 保险箱本体)解决 record collection + timeline;病程档案解决 **state reconstruction + clinical trajectory + provenance**。

## 1. 为什么现在做

- 原 §6 把七种 section 摊在一页:status/score/checklist 是状态,timeline/series 是轨迹,`evidence` 子串和 `SourceOut` 是依据。原料齐,层次没立起来,依据只是一行灰字。
- 「记录中出现的药物」只能说「最后一次出现 2026-07-15,无法判断是否已停药」。这是列表,不是状态。状态要成立,必须从 `dose_change` / `drug_start` / `drug_stop` 这类 fact 推出「现在 10mg,自 6 月 20 日起,依据两份文档」。
- 这些 fact 只有模型抽得出。现状:schema 1 的 `meds` 服务端已回传但 `aggregate` 不读(只读 `labs`,[aggregate.rs:769](../../../packages/parser/src/aggregate.rs));schema 2 的 `facts` 服务端已接、prompt 已写,**客户端零消费**。用 LLM 而不用它的输出,没有意义。

## 2. 状态变量(state variable)

每个病种包声明自己的状态变量;引擎不认识具体病。

```json
{"key":"gc_pred_equiv_mg_per_day","label":"激素(泼尼松等效)","unit":"mg/天",
 "derive":"latest_dose","drug_class":"gc",
 "stale_after_days":90}
```

求值结果(`ProfileView` 新 section `state`,每变量一行):

```json
{"key":"gc_pred_equiv_mg_per_day","value":"10","unit":"mg/天",
 "as_of":"2026-06-20","stale":false,
 "evidence":["ev:doc42:l17","ev:doc39:l8"],
 "note":null}
```

- `as_of` = 最近一条支持该值的证据日期。`stale` = 今天 − as_of > `stale_after_days`,界面写「3 个月没有新记录」,不写「可能已停药」。
- `derive` 是包可选的有限枚举(引擎实现,包只选):`latest_dose`(按 drug_class 取最近一次 dose_change/drug_start/处方剂量,drug_stop 后为「已停」)、`latest_value`(某 marker 最近值)、`band`(活动度分档,复用 §5.2)、`ratio_to_weight`(HCQ mg/kg,复用 §5.4)、`milestone`(肾应答,复用 §5.5)。
- SLE 第一批四个变量:激素等效日剂量、HCQ mg/kg、活动度(化验可算)分档、肾应答里程碑。
- **不下结论。** 变量只陈述已知值与截至日期;DORIS/LLDAS 仍是逐条 ✔/✘/未知的 checklist。

## 3. 轨迹 = 变更日志

轨迹节点由引擎从状态变量求值过程**顺带**产出,不单独抽取:

```json
{"at":"2026-06-20","var":"gc_pred_equiv_mg_per_day","from":"30","to":"10",
 "kind":"dose_change","evidence":["ev:doc42:l17"]}
```

- 每个状态变量一条泳道;`flare` / `hospitalization` / `infusion` / `biopsy` / `infection` 这些 fact 是不改变量值的事件节点,各自一条泳道。
- 长病程压缩到年,复发标红,与原 §6 timeline 规则一致;原 timeline section 由此替代。
- 排序、并道、空道折叠都在渲染层;引擎只出节点列表。

## 4. 依据(evidence link)

```json
{"id":"ev:doc42:l17","doc":42,"date":"2026-06-20","title":"门诊病历_风湿科",
 "quote":"泼尼松减至 10mg qd","span":[812,824],
 "origin":"llm|regex|self_entry","verified":true}
```

- `quote` 是原文逐字子串,来自现有 `verify`;图片档验不过 → `verified:false`,界面「需核对」,**仍显示**。
- `origin` 必填:医生要知道这条是模型读的还是规则读的。
- 从任何状态值、任何轨迹节点一次点击到依据页;依据页一次点击到原件,原件里高亮 `span`(文本档直接高亮;图片档跳到那一页,不画框)。
- 依据是「只输出原文逐字」这条原则的界面形态,不能做成折叠的一行引用。

## 5. 前置:把模型输出接进 aggregate

- schema 1 `meds` → `MedObservation`:有云抽取且非空时优先,空或验不过退回正则(与 labs 同一套规则与同一份「零条也退回」的教训)。
- schema 2 `facts`:`profile::rules::Ctx::build` 已直接读 `deid::Fact`(含 `unverified`),不再加 parser 层类型(那是第三次解析同一份 JSON)。verify 在 `vault_cloud_commit_extraction` 落盘前已做,parser/profile 不重做。
- 正则路径保留为退路,昨天修的换行/冒号补丁继续有效。

## 6. 验收

三个问题,各 ≤3 次点击,用李静三年 SLE 语料(`examples/demo-dataset/generate_sle.sh`)答:
1. 「我现在激素多少、从什么时候起」→ 现在页第一行。
2. 「为什么从 30 降到 10」→ 轨迹页激素泳道那个节点。
3. 「给我看写着 10mg 的那份原件」→ 节点 → 依据 → 原件高亮。

答不上任一条,就还是「记录 + 时间轴」加了三个 tab。golden `ProfileView` 逐字段钉住(含 `state`、`journey`、`evidence` 三段);每个 `derive` 一个边界用例(停药、同日两份文档、证据只有图片档)。

## 7. 界面名字

对用户不用 Clinical state / Journey / Evidence。三个 tab 叫「现在」「进程」「依据」(词表定稿前的占位,按减法口径:一个词说一件事)。

## 8. 代码落点与分期

- **D1 数据**(已完成 2026-09-30):`parser::meds_from_json`;`aggregate` 优先 JSON meds、零条退回正则;`MedSpan.unverified`;李静语料 DeepSeek fixture + 召回测试(`profile/tests/llm_fixtures.rs`)。不跑 MedRepBench(labs 路径未动)。
- **D2 引擎**(已完成 2026-10-01):`packages/profile/src/state.rs`:`state`/`journey`/`evidence` 三段进 `ProfileView`;`derive` 五种;包格式加 `state_vars` 与 `rules.bands`;SLE 包 2026.10.1 声明四个变量、「激素」作 gc 别名;`MedSpan.mentions` 给轨迹用;两份 golden(正则 / 云抽取)。
- **D3 界面**(已完成 2026-10-01,交接单部分未做):病程档案页三 tab(tab 名来自包);渲染引擎加三种 section;依据点开原件高亮;趋势图下加数值行;「李静·狼疮」示例(语料 + 模型输出当云抽取)。医生交接单 `handoff` 顶部改成状态变量表 → 下一步。
- 三步各自独立验收,D1 不依赖 D2/D3。

## 9. 已拍板(2026-09-30)

1. `stale_after_days` **由包给,按该病指南的复诊节律**,不由引擎统一。每个病种包各自声明,SLE 取稳定期复诊 90 天;引擎没拿到就当未声明,不显示陈旧标记。
2. 图片档依据第一版只跳到那一页,不画框。
3. 「进程」泳道默认展开:**有高质量数据的先展示**。排序键:已逐字校验且有变更的变量 → 复发/住院 → 其余折叠成一行。「需核对」的节点不参与排序权重。
