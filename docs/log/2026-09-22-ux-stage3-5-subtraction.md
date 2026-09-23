# 2026-09-22 · UX Stage 3.5 减法

稿子与计划:`docs/superpowers/specs/2026-09-22-ux-stage3-5-subtraction-design.md` / `docs/superpowers/plans/2026-09-22-ux-stage3-5-subtraction.md`(8 个 Task,分支 `feat/ux-stage3-5-subtraction`)。

**为什么**:用户「视觉噪音太强,像 2020 年的小程序和政务软件,不够克制,有些加深颜色的部分并没有信息」;「没有用的就删掉,有需要再加」。

**六条原则**(取代 Stage 3 brief 里与之冲突的部分):
1. 一个品牌色——渐变面、书脊、光泽块、光晕全部退场
2. 颜色只说状态——正常不上色,类别不上色
3. 状态 = 一个词 + 位置——不再整条色带,不显示「正常」二字
4. 白底黑字,只有一套浅色——细边无阴影,层级靠字号和留白
5. 图标退到线性或不用——有信息才出现
6. 首屏答一个问题——病历/趋势/给医生看各自一句话

**删了什么**(Task 2–8,按类别):
- widget:`BrandGradientBox`、`PrimaryEntryTile`、`MedDemoPill`、「看懂」占位横幅、`MedCard` 骑缝线
- `GlossIconTile` → `MedIcon`/`MedAvatar`;九档类别系统 `GlossCategory` 与 `categoryForDocType`/`VisitKind`
- 化验左色条 → 状态词 + 刻度点;化验单表格(`report_content.dart`)同规则
- 主页身份卡 `IdentityHeroCard` → `MemberHeader` 一行文字
- 病程档案入口渐变书脊与 `MedBrand.spine*`;首启三个光泽块;底栏阴影 → 顶部一道 `line`
- 令牌(零读者,Task 8):`gradientColors`/`Stops`/`Begin`/`End`、`heroGlow`、`heroTile*`(Size/LetterSize/Inset/Shadow)、`cardShadow`/`heroShadow`/`entryShadow`/`buttonShadow`/`navShadow`/`chipShadow`/`qrShadow`、`radiusHero`、`demoBorder`/`demoInk`、`MedColors.shadowColor` 与 `shadow` getter(连 `ThemeExtension` 四件套一起删)

**三道闸的变化**:
- 文案闸 `kRemovedByDecision` 登记用户点名删的四段(「找一找」「找一找还在做」「看懂」、报告页那句提示)
- 预算闸 `expectGradientBudget` → `expectSurfaceBudget`(一屏至多一张 `HeroCard`/一颗 `MedPrimaryButton`)
- 新增静态闸 `no_gradient_no_shadow_test.dart`:扫 `lib/` 源码禁止渐变/阴影;`expectNoGradientAnywhere()` 补扫渲染树——源码、渲染两层都不许漏

**与稿子的三处有意偏差**:
1. 给医生看的血压/心率:app 里是三条独立化验行,正常行不显示「正常」二字(稿子写了「正常」)
2. 还没核对的文档:结构不动,仍是月份组上方独立卡片区(稿子画进了月份组里)
3. 主按钮实色用 `sealInk`(白字 6.76:1)不用稿子的 `seal`(白字仅 3.9:1,目标用户含老年人不够)

**后面可做**:趋势页类别 chip 每类器官一个彩色小图标(用户 2026-09-22:「感觉也不错,后面可以做」)。
