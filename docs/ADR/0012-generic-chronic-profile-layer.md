# ADR 0012 · 通用病程档案层:不靠病种包,任何慢性病自动有

Status: Accepted · Date: 2026-10-22

**Amends**:[0011](0011-disease-profile-skill-packages.md)(增补,不 supersede)

## Context

0011 把「一个病 = 一个签名包」立成骨架,隐含前提是「没包 = 没档案」。用户把 UF Health 的
Epic 全量病历导进来之后(677 条带 ICD-10 的诊断、11666 条化验 85% 带 LOINC、9 次住院含瓣膜置换
与曲霉菌感染),「趋势」只看到一张卡「可以整理系统性红斑狼疮」——他的心脏病、感染什么都没有。
用户 2026-10-22 原话:「包不需要这么细,否则要做很多很多包;我这也算慢性病,不应该不考虑。」
同时结构化导入送进 CAS 的 `diagnoses[].icd` 与 `meds[].rxnorm` 一直没有读者。

## Decision

1. **档案拆两层。** 通用层从保险箱已有的诊断(ICD-10)、用药、化验(LOINC)、就诊/手术/影像
   直接推出「现在 / 进程 / 依据」,不需要任何包、没有开关、永远显示;病种包退到第二层,
   只写指南规则(阈值、评分、目标、复诊节律),作档案页内的一段叠在通用层之后。
2. **通用层只做分组与折叠,不做任何需要临床出处的判断。** 诊断按 ICD-10 归族(覆盖表最长前缀
   → 章节表),用药只说「最近剂量 · 记录中自何日起 · 多久没新记录」,停药只认原文写了的那一行
   (`停用|discontinued|…` 整词),**不从「清单里不再出现」推停药**;化验按词典 key 挂到族的小表
   只给最近值 + 印刷参考区间。凡要引指南的数一律留给包。0011 的八条决定全部保留。
3. **三张表是 crate 里的 `const`,不是包。** 不下发、不签名,改它就是发版;发布前经只读
   subagent 逐条核到 ICD-10/ATC/LOINC 码表(结论在 log)。
4. **零新事件、零新表、不上云。** 通用层是纯投影(`profile::materialize_generic`),输入全是今天
   已落库的东西;引擎多收一个 `EncounterRef`(core-model 的就诊投影),parser 不认识 encounter。
5. **包内置进 App。** `skills/<id>/<ver>.json` 逐字节编进二进制,首启先装内置、再联网更新;
   内置走同一个 `cache_store`(同一把公钥、同一个 `min_engine` 闸、同一个单调闸),内置 ≠ 免检;
   内置版本与 `skills/index.json` 逐一相等由测试在仓库侧守。

## 考虑过的替代方案

- **每个慢病发一个包**:用户明确拒绝——包要做很多很多个,而且绝大多数病没有可引用的指南规则,
  包里会只剩「诊断名 + 药名」这种本来就在病历里的东西。
- **通用层也做成可下发的 JSON 表**:三张表一年改不了几次,下发/签名/版本闸的全部机关只为几十行
  常量,不值;改表就发版。
- **通用层推「在吃 / 已停」**:被否——那是 0011 决定 7 禁止的结论;原文没写停就只能说「N 天没有
  新记录」。

## Consequences

- 0011 决定 3「加一个病 = 发一个包」的隐含前提「没包 = 没档案」、09-16 spec §0「未开启任何包时
  『看懂』只有通用摘要」、入口卡第一态「没包 → 还没准备好」三句事实陈述**不再成立**;决策骨架不变。
- `Section` 多一个 `package_id`(通用层恒 `general`,包段为包 id),单包路径不序列化它,两份 SLE
  golden 逐字节不变;新 section kind `family_cards` / `med_table`,老渲染器跳过未知 kind。
- 英文病历的诊断从此有读者:`aggregate` 按文档二选一(有抽取 JSON 且 `diagnoses` 非空只用 JSON,
  零条退回正则);`meds[].rxnorm` 名字优先、码兜底、`verify` 产物清码——与 LOINC 那次逐字一样。
- 结论段认英文 `IMPRESSION/FINDINGS/CONCLUSION`,通用摘要与查看器跟着认,中文路径输出不变。
- 已知缺口(不在本 ADR):中文诊断名 → ICD 映射;通用英文医院名识别;Epic `Patient not taking`
  解析;桌面 Tauri;有化验无诊断的族不单独出卡。

## 参考

- 设计:[2026-10-22-generic-chronic-profile-design](../superpowers/specs/2026-10-22-generic-chronic-profile-design.md)
- 工程日志:[2026-10-22-generic-chronic-profile](../log/2026-10-22-generic-chronic-profile.md)
