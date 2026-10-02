# 2026-10-01 · 病程档案三视图:现在 / 进程 / 依据

spec:`docs/superpowers/specs/2026-09-30-disease-journey-three-views-design.md`。用户原话:「不做我不知道结果如何」—— D2 引擎 + D3 界面 + 李静示例一口气做完,在模拟器上截图验收。

**做了什么**
- parser:`MedSpan.mentions`(每次提及:日期/剂量/来源/路径/核对),`latest_source`/`latest_origin`。轨迹的剂量变化从这里来,`dose_change` 事实并进同一条泳道(同日同剂量按前缀去重)。
- profile:新 `state.rs`。`EvidenceBook` 统一发 `ev:<doc>:<n>`,quote 在原文里 `find` 得 span(短 token 取整行,模型抽的 evidence 原样);五种 derive 全部复用 `rules.rs` 已有求值(regimen / hcq_body / activity / eval_milestone),同一个数不算两遍。里程碑变量的截至日期取最近一次化验而非首次达标日。泳道排序:有核过变更的变量 → 事件 → 需核对 → 空。
- 包:`state_vars`、`rules.bands` 进格式;SLE 升版 2026.10.1 重签;「激素」收作 gc 别名(审查 M-1 的根治)。
- golden 两份:正则路径 + 云抽取路径(fixture 经 verify)。
- 手机端:`vault_profile_view` JSON 顶层附 `documents` 桥(index → document_id);`load_demo_data_sle` 把李静语料和模型输出副本编进二进制,fixture 经 verify 当云抽取落库、装内置签名包、写 enable/体重事件;FRB 重生成。
- Flutter:三 tab(tab 名是包给的 title);`_StateBody`/`_JourneyBody`/`_EvidenceBody`;依据 → `DocumentDetailScreen(highlight:)` 原文高亮;趋势图下加「最近 x · 日期 · 偏高/偏低 · 参考 · 最低/最高」一行(用户:「光有曲线不行」);设置页第二行示例。
- 文案闸基线前移到三视图提交(Stage 3.5 冻结到此为止);「怎么走到今天」按用户改成「进程」。

**验收(模拟器,李静)**:现在页 激素 7.5 mg/天 截至 2026-06-15 超过 90 天没有新记录;进程页 50 → 20 → 10 → 7.5、UPCR 2800 → 380;依据页每条可点,点开原件那句高亮。三问各 ≤3 次点击。

**独立审查(第二轮,D2/D3)抓出 1 Critical 8 Important,全修,各带回归测试**
- Critical:化验可算的部分分(2/18)直接套「轻度活动」分档 —— 包 bands.note 原文写明分档只用于症状项勾选后的总评分,这是替医生下结论。改为只给分数、注明「症状项未录,不分档」;0 分同样不出档名。
- 依据定位:`text.find` 取第一处,门诊号里的「88」会抢化验行的「88」。改为逐处候选打分(所在行含项目名/印刷单位各加分,数字必须独立成数),同一个值的不同项目也分得开。
- 原文里找不到的值(换算过的、模型给的)不再标「已核」;未核对的化验点依据也标未核。
- 显示值配印刷单位(`LabPoint.value` ↔ `p.unit`),不再拿规范单位配显示值(UPCR 印 g/g 时会差 1000 倍)。
- 外用激素(乳膏)剔出状态行与泳道,与 `regimen_eval` 同一条筛选。
- 激素泳道节点带药名与泼尼松等效日剂量(泼尼松 20mg 换甲泼尼龙 16mg 不是减量)。
- 其它药的 `dose_change`(吗替麦考酚酯减量)单独一条「用药调整」泳道;复发/住院按包的 `severity_high` 标红。
- 「激素」别名只认整名(「雌激素」不再是糖皮质激素);光写「激素」的原因改为「没写具体是哪一种激素」;比现行更早的历史提及不再列进「算不进现行方案」。
- FRB 派发序号:新函数名 `load_demo_data_sle` 字典序排在 `recognize_image_pp` 前面,把 iOS 直接按号调的 44 号顶走了,测试当场红;改名 `vault_load_demo_data_sle`。两个 golden 测试并行跑会互相清掉进程全局的术语覆盖层,合成一个顺序跑。

**没做 / 留的**
- 交接单 `handoff` 顶部状态变量表。
- `drug_stop`/`drug_start` fact 不存在(prompt 不许新增键),「已停」语义没有;`stale` 只说多久没新记录。
- 分档泳道为空(分数只对今天的窗口算);症状分还没进引擎,活动度只给分数不给档;`ActiveMedDto` 的 `unverified` 仍未进 App 用药列表。
- 李静 fixture 里 2025-12-05、2026-03-14 两份检验报告的 UPCR 模型没抽到(云抽取路径 golden 肾应答泳道 5 个点 vs 正则 7 个),labs 召回缺口,记。
- 示例文档标题带 `.txt`(demo 文件名),真实导入没有这个问题。
- 用户发现:`.txt` 文档的「查看原件」不能预览(只有图片/PDF/DICOM 查看器)。稍后解决。
