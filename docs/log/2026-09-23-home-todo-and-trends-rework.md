# 2026-09-23 · 首页待办与趋势重整

稿子与计划:`docs/superpowers/specs/2026-09-23-home-todo-and-trends-rework-design.md` / `docs/superpowers/plans/2026-09-23-home-todo-and-trends-rework.md`(7 个 Task,分支 `feat/ia-rework`,上游减法 PR #229 之后)。

**为什么**:用户 2026-09-23「自己记的东西把真事件淹了;只有一个数不叫趋势;点类别下面不跟着变;趋势和病历重合;首页应该是『接下来要干什么』;记录一下不该在趋势里」。原则:每页只答一个问题——病历答「接下来要干什么、最近发生了什么」,趋势答「哪个指标在变、往哪走」,添加答「把东西放进来」。

**做了什么**(Task 1–6):
- Rust 三个只读投影(不碰 vault 格式):`TimelineGroupDto::SelfWeek`(自测按 ISO 周折叠)、`view_abnormal_30d`(30 天内 H/L 化验数,自测不算)、`vault_profile_due_reminders`(已开启档案的到期提醒,`state` 恒 never/overdue)。
- 首页新增「待办」卡:`PendingReviewBanner`/`ImportQueueCard` 原样并入 + 档案到期 + 30 天异常,四类都没有时整块不画。
- 时间线自测记录按周折成一行(`SelfWeekRows`),展开看每条。
- 「添加」四选一加第四项「记录一下」(沿用趋势页原两句文案),趋势页删除录入卡。
- 趋势页重整:`KeyLabsSnapshot`+`SeriesCard` 合成 `TrendRow`(迷你折线,点开展开);类别 chip 与「只看异常」开关叠加;≥2 次才算趋势,单次序列折进页尾;删 `RecentVisitsCard`。
- 收尾(本 Task):闸对账、清扫两处过期注释、regenerate FRB、全量测试。

**与 spec 的偏差(controller ruling)**:
1. 首页待办不含 pending 档案提醒(spec 表格写了三档,收窄成两档——pending 规则没核实,不该催人)。
2. 「记录一下」沿用趋势页原文案,零新增文案。
3. `_abnormalOnly` 默认关(不是 spec 假定的开):合并列表已把异常排前面,默认再藏一半正常项反而分不清「只测一次」和「趋势」。
4. 「只看异常」chip 搜索时整颗隐藏——搜索优先于过滤,不然搜得到却被过滤成空白。
5. `TrendRow` 展开区(出处引文/查看原件)只在展开态渲染,折叠时不占地方。

**闸**:`kAddedByDecision` 新增 11 段(月/日/自测/次/最近/天有/项偏高或偏低/最近|30/只看异常/只测过一次的/项),逐条对应计划允许的 5 句新字;`kRemovedByDecision` 追加 `KeyLabsSnapshot`/`RecentVisitsCard`/`_AbnormalOnlyRow` 整块删除带走的 11 段字面量。Task 7 闸对账:两表逐条核对基线→HEAD 的实际 diff,一一对应,无多余登记。

**没做**:笔记折叠;按条深链到档案提醒(`DiseaseProfileScreen` 没有该参数,点进去是整页);上次给医生看的时间(没有这个数据);`SelfWeekRows` 排版复刻 `archive_screen.dart` 的 `_SubDocList`,两者结构重复;`self_week_groups` 里每份自测文档 `ocr_text` 被读两次(一次解析数值,`doc_summary` 内部取院名又读一次)。
