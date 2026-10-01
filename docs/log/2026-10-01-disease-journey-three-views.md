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

**没做 / 留的**
- 交接单 `handoff` 顶部状态变量表。
- `drug_stop`/`drug_start` fact 不存在(prompt 不许新增键),「已停」语义没有;`stale` 只说多久没新记录。
- 分档泳道为空(分数只对今天的窗口算);`ActiveMedDto` 的 `unverified` 仍未进 App 用药列表。
- 李静 fixture 里 2025-12-05、2026-03-14 两份检验报告的 UPCR 模型没抽到(云抽取路径 golden 肾应答泳道 5 个点 vs 正则 7 个),labs 召回缺口,记。
- 示例文档标题带 `.txt`(demo 文件名),真实导入没有这个问题。
- 用户发现:`.txt` 文档的「查看原件」不能预览(只有图片/PDF/DICOM 查看器)。稍后解决。
