# 2026-10-21 · 时间线分档(住院 / 急诊 / 门诊)+ 趋势 chip「切不动」

spec:`docs/superpowers/specs/2026-10-21-timeline-tiers-design.md`(用户选稿 B)。分支 `feat/timeline-tiers`,基于 `feat/structured-import`。背景:686 份 Epic 病历导进来后首页 161 次就诊,10 次住院被按天平铺的门诊淹没;就诊卡没有医院名,因为 `extract_provider` 只认中文「…医院」。

**做了什么**
- Rust(`core-model/query.rs`):`extract_provider` 两条入口最前面加英文页眉轮 —— 含 `SHANDS AT THE UNIVERSITY OF FLORIDA` / `UF Health`(大小写不敏感)→ `UF Health Shands`;不做通用英文医院识别。急诊判据从「标题含急诊」改成 `is_emergency_title`:`(?i)急诊|emergency|\bED (?:Visit|to)\b`;`ED to Hosp-Admission` 落在出院小结窗里仍归住院(第 1 步先跑,顺序没动)。
- Flutter(`archive_screen.dart`):时间线抽成公开 `ArchiveTimeline`(只吃 `List<TimelineGroupDto>`,不碰 FFI,终于能整块 pump)。稿 B:chip 一排(全部/住院/急诊/门诊,复用 `MedChip`,计数 0 不画、只剩「全部」整排不画)→ 按月 → 住院/急诊每次一张卡、卡级左 3px 色条(住院 `seal`、急诊 `high`)→ 门诊整月一张折叠卡「门诊 N 次」→ 独立文档一张卡。住院副标 `起 → 止 · 住院 N 天 · M 份`(天数 = 出院 − 入院,同日记 1),右侧不再印入院日。筛到「门诊」各月默认展开;展开态按 `encounter.id` / 月份标签各记一套。
- 已导入的保险箱:就诊组 `provider` 是 `rebuild_encounters` 时写进表的,下一次任何导入/删除会重建并补上院名,没加「重建」入口。

**趋势页 chip「点了切不动」(真机回报,单列)**
- 复现:模拟器上 17 条序列就能复现,**与数据量无关**。点「血常规」后 chip 选中态切了、往下一屏半的折线卡也筛对了,但 chip 正下方那张「关键化验」快照卡(`KeyLabsSnapshot`,Rust `VISIT_SUMMARY_MAX_LABS` 封顶 8 行)既不认 chip 也不认搜索词,一动不动 —— 用户眼里就是没反应。8 行正好占满一屏。
- 修法(一处条件):选了大类或在搜索时快照卡整张让位,chip 正下方直接就是筛出来的那批卡;回「全部」快照卡回来。没走「按名字把快照行映射到大类」那条路:`VisitLabDto` 没有 `analyteKey`/`panel`,映射只能靠显示名,而且筛空了还得再编一句空态。
- 用户说真机上 chip 的选中态也不变。模拟器上用 CLI 造了 400 份合成化验单(12000 行、206 条序列)换进去,选中态照样切、也没有转圈 —— **那一半没复现出来**;趋势页与 `MedChip` 外面没有 IgnorePointer/AbsorbPointer/Opacity,git 里也没有这排 chip 的历史修复。chip 选中态只是 1px 描边变色 + 加粗,底下 8 行纹丝不动时很容易看成「整颗不理人」。装上这版再看;若真机上描边仍不变,需要连着 `flutter run` 看日志。
- 回归:`test/trends_panel_chip_switch_test.dart`(300 条序列整屏,断言快照让位、chip 到第一张卡之间 <120px、回「全部」快照回来)。

**验证**:`cargo test -p core-model` 全绿(query 模块 23 条,新增 4:页眉正/反、急诊判据、窗内 ED-to-admission 仍住院);`cargo clippy -p core-model --all-targets -D warnings` + `cargo fmt` 干净;`flutter analyze` 零 issue;`test/archive_timeline_test.dart` 8 条(默认折叠/色条颜色/筛选三态/急诊 0 不画 chip/住院天数/393 宽 × 1.0/1.3/1.6 全部展开不溢出)+ 趋势 4 个测试文件 19 条全绿;全量 `flutter test` 1103 过、2 红 —— `copy_unchanged_test` 与 `glossary_guard_test` 两道文案闸,在 `feat/structured-import` 上就已经红(`import_flow.dart` 的「导入 Epic 病历包」那组字;PR #243 的 analyze job 同样红),本次又给前者添了 4 个段(住院/门诊/全部/份)。闸自己的规矩是文案落地后把 `kBaseline` 前移到那次提交(2026-10-01 先例),要等 commit 与用户点头。

**留的**
- 子文档行仍只显示类型(「病历」),Epic 一次住院几十份「病程记录」分不清 —— 上一条 log 已记,这次没动。
- 溢出测试的高度给到 4000:时间线在 ListView 里只会横向溢出,给足高度是为了每张卡都建出来、点得到,不在两个 Scrollable 之间 `scrollUntilVisible`(那条路会卡死测试)。
