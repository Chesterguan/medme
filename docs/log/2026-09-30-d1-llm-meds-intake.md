# 2026-09-30 · D1:云抽取的 meds 接进解析链

**为什么**:模型早就回了 `meds`,`aggregate` 只读 `labs`;用药单还是正则,「片」那种换行事故(见 2026-09-28 log 与 `24aab6a`)模型本可避免。三视图 spec 的「现在」层要的是能推剂量变化的数据,正则给不了。

**做了什么**:`parser::meds_from_json`(每条拼成「药名 剂量 频次」一行复用 `extract_meds`,不另写正则);`aggregate` 有 JSON 且非空就用、否则退正则,不按 doc_type 过滤;`MedSpan.unverified`。facts 不加层——`Ctx::build` 早就在读 `deid::Fact`,spec §5 已改回现实。

**评测**:李静 15 份 × DeepSeek `deepseek-flash` schema 2,原始输出入库为 fixture(`packages/profile/testdata/extractions/`),测试跑 `deid::verify` 后逐条核(`profile/tests/llm_fixtures.rs`,9 过 1 ignore):
- 处方 6 味药剂量频次:全中(20mg qd / 0.75g bid / 0.2g bid;7.5mg qd / 0.5g bid / 0.2g qd)。
- 住院(含起止日)、肾活检、贝利尤单抗输注、激素与 MMF 两次减量、OCT/视野:全中。7 份化验单 meds 均为空。
- 召回缺口:眼科报告的「眼底」exam_done——模型抽到了,但 evidence 把原文跨行的一句拼成一行,verify 逐字规则丢掉。测试 `#[ignore]` 记名;修法在 verify(允许跨换行匹配)或 prompt,不在 D1。
- 顺带看到:模型在处方里把碳酸钙片也列进 meds(原文有),出院记录把甲泼尼龙冲击记成 infusion、NIH 活动指数记成 scale——都是原文有的,按「下界断言」不算错。

**下一步**:D2 状态变量与依据回链(spec §2–§4)。verify 跨换行那条单独排。
