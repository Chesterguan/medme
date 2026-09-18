# UX Stage 3 · 视觉层 tokens 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 mockup v24 认可的视觉层(色/形/字/品牌)落到 Flutter app 上,**一个结构不改、一个字不改**。

**Architecture:** 三层落法。(1) `lib/design_tokens.dart` + `lib/theme.dart` 是全部数值的**唯一**出处 —— 屏和 widget 里不许出现任何裸色值(现状已经是零裸色值,这条是守住它)。(2) 四个共用 widget 承载 mockup 的三种新视觉语言:光泽图标块 `GlossIconTile`、品牌渐变面 `BrandGradientBox`(`HeroCard` / `PrimaryEntryTile` / `MedPrimaryButton` 三个用法)、病历本条 `RecordBookStrip`、长文本行 `LongTextRow`。(3) 每屏只做「把现有 widget 换成共用 widget、把现有色换成 token」,不动 widget 树的层级、不动任何 `Text()` 的字符串。

**Tech Stack:** Flutter(SDK `^3.12.2`,`flutter` 在 `/Users/ziyuanguan/flutter/bin/flutter`)、`ThemeExtension` 令牌、`flutter_test` widget test、`CustomPainter`(渐变书脊、折线)。无新依赖。

**Spec:** `/Volumes/extraSupply/Projects/Medme-ux-stage1/.superpowers/sdd/ux-overhaul/stage3-visual-tokens-brief.md`
**Mockup(逐屏视觉的正本):** `/private/tmp/claude-501/-Volumes-extraSupply-Projects-Medme/6fb778b0-c9b5-404d-ae65-0c0319ec1c97/scratchpad/mockups/medme-ui-directions.html`(artifact v24)
**Logo 源文件:** `/private/tmp/claude-501/-Volumes-extraSupply-Projects-Medme/6fb778b0-c9b5-404d-ae65-0c0319ec1c97/scratchpad/mockups/logo112.png`
**Worktree:** `/Volumes/extraSupply/Projects/Medme-adv-a`(分支 `feat/advanced-a`,基线 `2a629a2`);app 在 `apps/mobile_flutter`,**下文所有路径都相对这个目录**。

---

## Global Constraints

每个 Task 的要求都隐含包含这一节。色值一律逐字抄自 brief,不许四舍五入、不许「调一点更好看」。

### 硬禁止

- **一个用户可见的字符串都不许改。** 不加字、不删字、不换词、不调标点。Stage 3 只改颜色/形状/字体/图标块。文案是 Stage 1 已经定死的(`test/glossary_guard_test.dart` 是它的闸)。
- **不许动结构。** 不增删屏、不增删卡、不调顺序、不把两栏改成一栏(除了 brief 明确要求的「长文本行不用两栏」,而那处**现在已经是一栏**,见 `lib/widgets/profile_sections.dart:280` `_ItemRow` 的类文档)。
- **屏和 widget 里不许出现裸色值。** `Color(0x…)` 只许出现在 `lib/design_tokens.dart` 与 `lib/theme.dart`;`Colors.*` 只许用 `white` / `black` / `transparent`。(现状已经做到,Task 1 把 `lib/main.dart` 残留的两处 `Colors.redAccent` / `Colors.teal` 收干净。)
- **不用粉彩、不用印章、不用旋转戳。**
- **不加依赖。**

### 色(brief §色,逐字)

- 底 `#F1F4F8`(实心,不渐变);surface `#fff`;ink `#101A23`;ink2 `#3A4A57`;ink3 `#657581`;分隔线 `#EEF2F5`。
- 品牌渐变(**仅**主卡、主入口块、主按钮):`#1FB0C6 → #1789C1 → #16508E`,135°,stop `0% / 50% / 100%`。
- 主卡光晕:`rgba(255,255,255,.22)` 在右上。
- seal `#1789C1`;sealInk `#0E6285`(链接 / 主要文字强调)。
- 类别色(光泽图标块,150° 渐变):
  | 类别 | 起 | 止 | 同色投影(mockup `--s`) |
  |---|---|---|---|
  | 化验 lab | `#25B5C2` | `#0B7A87` | `rgba(14,138,150,.35)` |
  | 门诊 clinic | `#4A90E8` | `#1A5BC0` | `rgba(31,111,210,.35)` |
  | 影像 imaging | `#9A7BE0` | `#5B3FAE` | `rgba(106,77,191,.35)` |
  | 用药 med | `#F4A04A` | `#D0661A` | `rgba(224,122,37,.35)` |
  | 笔记 note | `#5CC28A` | `#227A4C` | `rgba(47,143,91,.35)` |
  | 警示 alert | `#F06A86` | `#B92A4A` | `rgba(207,58,90,.35)` |
  | 中性 neutral | `#8A98A4` | `#4A5A67` | `rgba(74,90,103,.3)` |
  | 品牌 brand(成员头像、默认) | `#1FB0C6` | `#16508E` | `rgba(23,137,193,.35)` |
  | 处理中 busy(mockup `.doc.busy`) | `#B7C2CC` | `#8A98A4` | `rgba(74,90,103,.2)` |
- 状态:
  | 档 | 文 | 底 | 左色条 | pill 文(mockup) |
  |---|---|---|---|---|
  | 偏高 | `#C25E18` | `#FDE3CC` | `#E07A25` | `#9A4A12` |
  | 偏低 | `#1F5FB8` | `#DCE8FB` | `#1F6FD2` | `#1F5FB8` |
  | 正常 | `#227A4C` | 无底(透明) | `#2F8F5B` | `#227A4C` |
  | 危急 | `#BE123C` | `#FBDDE4` | `#CF3A5A` | `#BE123C` |
  | 示例 | `#657581` | 白底 + 虚线框 `#B7C2CC` | — | — |
  | 看一眼 chk(mockup `.pill.chk`) | `#3A4A57` | `#E6EBF0` | — | — |
- 横幅:蓝 `#DDEDF8` / 文 `#0E6285`;琥珀 `#FBE7D2` / 文 `#9A4A12`。
- 仅 mockup 有、brief 未列(照 mockup 用):病程时间轴竖线 `#DCE3EA`;趋势行展开区底 `#F7FAFC`。

### 形(brief §形,逐字)

- 圆角:主卡 `22` / 卡 `20` / 入口块 `18` / 横幅 `16` / 图标块 `12` / 药丸按钮 `999`。
- 卡:**无边框**,阴影 `0 6px 18px rgba(16,26,35,.08)`;主卡阴影 `0 14px 30px rgba(22,80,142,.32)`。
- mockup 另有两档品牌阴影:主入口块 `0 12px 26px rgba(22,80,142,.32)`;主按钮 `0 10px 24px rgba(22,80,142,.3)`;底栏 `0 -6px 18px rgba(16,26,35,.06)`;小 chip `0 3px 10px rgba(16,26,35,.06)`;二维码 `0 6px 18px rgba(16,26,35,.1)`。
- **光泽图标块**(3D 图标语言):`44×44`,渐变 `150°`,`inset 0 1px 0 rgba(255,255,255,.45)` + `inset 0 -1px 0 rgba(0,0,0,.10)` + 同色投影 `0 5px 12px`;白色线图标 `22px`、描边 `1.9`。
- **病历本条**:左 `34px` 渐变书脊(`180° #1FB0C6→#16508E`,细横纹 `rgba(255,255,255,.14)`,`2px` 实 / `9px` 周期)+ 真 logo `40px` + 标题/副标 + 右列大数。
- 趋势行:名称 | `78×24` 小折线 | 最近值,第二行历年数值;行尾 `▾`,点开原地展开 `82px` 大图。**Stage 3 只管这一行的样式,真折线是 Stage 2。**
- 化验行:左 `4px` 色条 + 偏高/偏低标签 + 彩色数值,单位小字可折到数值下一行。
- 长文本行(诊断、用药、检查):图标块 + 全宽一项一行,不用两栏。

### 字(brief §字)

- 中文:系统苹方(iOS)/ 系统默认(Android),**不打包 Noto**。
- 数字与字母:Manrope,只用 `500` / `600` 两个字重,tabular figures。
- 字重:`400` 正文 / `500` 强调 / `600` 标题 / `700` 只给大数字 → **见「已知分歧 3」:mockup 实际渲染里没有一处 Latin/数字用 700,本计划一律用 600 封顶。**
- 字号:标题 `26`,正文 `16`,行元数据 `13`,横幅小字 `13`。

### 品牌(brief §品牌)

- 真 logo(毛笔「医」)出现在:主页顶栏 `30px`、病历本书脊旁 `40px`、病程档案页头(`30px`,同顶栏)、首启场景中央 `104px`;圆角 `22%`。
- **一屏只一处品牌渐变面**(见「已知分歧 1」的收口)。
- 动效:**只有**折线描画一次(reduced-motion 下关闭);**无逐卡淡入**。
- 「出码给医生看」按钮在「给医生看」页**固定底部**。

### 每屏的品牌渐变预算(从 mockup 模板逐屏数出来,测试按这张表断言)

| 屏 | 模板 | `HeroCard` | `PrimaryEntryTile` | `MedPrimaryButton` |
|---|---|---|---|---|
| 病历(主页) | `s1` | 1 | 1(「添加」) | 0 |
| 趋势 | `s2` | 0 | 0 | 0 |
| 病程档案 | `s3` | 0 | 0 | 0 |
| 给医生看 | `s4` | 0 | 0 | 1(「出码给医生看」,固定底部) |
| 我 | `s5` | 0 | 0 | 0 |
| 添加 sheet | `s6` | 0 | 0 | 0 |
| 还没核对 | `s7` | 0 | 0 | 1(「没问题」) |
| 一份病历 | `s8` | 0 | 0 | 0 |
| 成员页 | `s10` | 0 | 0 | 0 |
| 设一个口令 | `s12` | 0 | 0 | 1(「我抄好了」) |
| 出码 | `s13` | 0 | 0 | 1(在首次那张 sheet 上) |
| 代拍 | `s14` | 1 | 0 | 0 |
| 换新手机 | `s15` | 1 | 0 | 0 |
| 首次启动 | `s16` | 0 | 0 | 1(「开始使用」) |
| 云端整理 sheet | `s17` | 0 | 0 | 1(「开,帮我整理」) |

### 每个 Task 的收尾

`/Users/ziyuanguan/flutter/bin/flutter analyze` 干净 + 该 Task 的测试绿 + 一次 commit,commit message 末尾**必须**带这两行:

```
Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
```

**构建纪律**(`apps/mobile_flutter/CLAUDE.md`):日常只跑 `flutter analyze` / `flutter test`;不跑 release、不跑全 ABI;任何预计超过 5 分钟的命令先停下来报给用户。

---

## 已知分歧(mockup vs brief)—— 本计划的收口

1. **「一屏只一处品牌渐变」 vs `s1` 上有两处。** brief 同时写了「品牌渐变(仅主卡、主入口块、主按钮)」和「一屏只一处品牌渐变」,而 `s1` 模板里 `.hero`(主卡)和 `.qa.pri`(「添加」入口块)都是渐变。**收口:**「一处」指的是**一个渐变卡面**;主入口块和药丸主按钮是**控件**,各自独立限一个。测试按上面那张预算表断言三个计数,而不是断言「渐变总数 ≤ 1」。
2. **「每屏恰好一个渐变 hero」 vs mockup 里大多数屏一个都没有。** 15 个模板里只有 `s1` / `s14` / `s15` 有 `.hero`。**收口:** 测试断言的是预算表里那一屏**期望的确切数**(0 或 1),不是一律 1。
3. **Manrope 700。** mockup 的 `<link>` 拉了 `500;600;700`,brief 的字重表也写「700 只给大数字」,但 brief 的打包规则写「打包 2 个字重」。逐条核 mockup CSS:`.top h3` 的 700 被后面 `.top h3{font-size:26px;font-weight:600}` 覆盖;唯一剩下的 700 是 `.tile.logo span`(主卡头像里的**汉字**,走系统字体不走 Manrope)。**收口:** 不打包 700,大数字用 600。
4. **Google Fonts 已不再提供 Manrope 静态字重。** `google/fonts` 的 `ofl/manrope/` 只剩一个可变字体 `Manrope[wght].ttf`(164 KB,已核 HTTP 200);`static/Manrope-Medium.ttf` 等路径 404。**收口:** 打包这**一个**可变字体文件,在 `MedType` 里用 `FontVariation('wght', 500/600)` 钉死轴值。体积与两个静态实例相当,字重仍然只有 500/600 两档,brief 「只用两个字重」的意图不变。
5. **「正常」pill 在 mockup 里没有 CSS 规则。** `s2` / `s4` 模板用了 `<span class="pill ok">正常</span>`,但样式表里没有 `.pill.ok` —— 渲染出来是黑字无底;brief 给了 正常 文 `#227A4C` 和条 `#2F8F5B`,没给底。**收口:** 正常 pill = 透明底 + `#227A4C` 文字(只用 brief 里有的色),左色条 `#2F8F5B`。**这一条请 founder 点头** —— 另一个合理答案是「正常干脆不画 pill」(现有代码的 `MedColors.normalIsUncolored` 就是这条老规矩),但那会删掉屏上已有的字,越了 Stage 3 的界。
6. **危急 pill 的文字色。** mockup `.pill.cr` 用 `#A60F33`(一个 brief 里没有的更深的红),而数值色 `.lr.cr .v` 用 `#BE123C`。**收口:** 统一用 brief 的 `#BE123C`;它压 `#FBDDE4` 的对比度 4.9:1,过 AA,不需要那个更深的色。同理 偏高 pill 用 brief 里已有的琥珀横幅文字色 `#9A4A12`(与 mockup `.pill.hi` 一致)。
7. **页面副标题的灰。** mockup `.top .sub` / `.read .src` 用 `#4A5A67`(brief 只把它列为中性图标块的渐变止色),brief 的 ink2 是 `#3A4A57`。**收口:** 用 brief 的 `#3A4A57`(更深、对比度更好,肉眼几乎无差)。
8. **「看一眼」chk pill。** mockup `.pill.chk` = `#E6EBF0` 底 / `#3A4A57` 文,brief 没列。现有代码用的是 sealWash 底 + sealInk 文。**收口:** 照 mockup 改成灰的一对 —— 它是「不确定」不是「主色动作」,与蓝色横幅区分开更对。
9. **卡片边框。** brief 明确「卡:无边框」,mockup 里 `.card` 也确实无边框;而本计划的验收要求里有一句「非 hero 卡用彩色描边」。**收口:** 非 hero 卡一律**无边框**白底 + `0 6px 18px rgba(16,26,35,.08)` 阴影;一张卡身上唯一允许的颜色是**左侧色条**(化验/趋势行)、**渐变书脊**(病历本条)、或**光泽图标块** —— 绝不是品牌渐变填充,也不是描边。现有唯一一处彩色描边(`lib/widgets/disease_profile_card.dart:243` 的 `borderColor: c.seal`)在 Task 12 改成病历本条。
10. **`paper` 与设计系统 v1 打架。** 现有 `test/design_tokens_test.dart` 把 `paper` 钉在 `#F6F8FA`,出处是 `DESIGN-SYSTEM-v1.html`;brief 要 `#F1F4F8`。**收口:** Stage 3 brief **supersede** DESIGN-SYSTEM-v1 的色板部分;Task 1 重写那个测试,把 spec 表换成 brief 的值,并在文件头注明被谁取代。

---


### 控制者裁定(2026-09-18,执行前)
- 分歧 6「正常」pill:透明底 + `#227A4C` 文字,保留「正常」两个字。
- 对比度:主卡沿用 mockup 的白字压品牌渐变;主标题 26/600 与次级文字 ≥15/600 一律放在渐变的中段到深段(文字块靠左、靠下,光晕在右上),按大字号 AA(≥3:1)验收;Task 4 Step 4 的「站不住就停下来报」改为按本裁定执行并在测试里断言次级文字字号 ≥15 且字重 600。
- 分歧 5:打包单个 Manrope 可变字体,`FontVariation('wght', 500/600)`。
- 分歧 10:Stage 3 brief 取代 DESIGN-SYSTEM v1 色板,Task 1 重写旧测试并注明出处。
- 其余分歧按计划所写收口。

## File Structure

**新建(4 个 lib 文件 + 1 个测试 helper + 2 个资源):**

| 路径 | 职责 |
|---|---|
| `lib/widgets/gloss_tile.dart` | `GlossCategory` 枚举 + `GlossIconTile`(44×44 光泽图标块)。全 app 的图标底块只此一家。 |
| `lib/widgets/brand_gradient.dart` | `BrandGradientBox`(唯一画品牌渐变的 widget)+ `HeroCard` + `PrimaryEntryTile` + `MedPrimaryButton`。**品牌渐变只从这个文件出去。** |
| `lib/widgets/record_book_strip.dart` | `RecordBookStrip`(病程档案的病历本条,含 34px 渐变书脊 `CustomPainter`)。 |
| `lib/widgets/long_text_row.dart` | `LongTextRow`(图标块 + 全宽一项一行)。 |
| `test/stage3_visual_helpers.dart` | `pumpStage3()` / `expectGradientBudget()` —— 每个屏测试都用,不各写一遍。 |
| `assets/fonts/Manrope[wght].ttf` | 可变字体,只用 wght 500/600。 |
| `assets/brand/logo112.png` | 真 logo(毛笔「医」)。 |

**改(不新建):**

- `lib/design_tokens.dart` —— `MedColors.light` 改 5 个色值;新增 `MedBrand`(渐变/阴影/类别色/状态条/横幅,全 `static const`,**不进 `ThemeExtension`** —— 那需要 4 份 copyWith/lerp/==/hashCode 样板,而这些值不随主题变);`MedType` 改字号字重加 Manrope;`MedShape` 加 4 档圆角。
- `lib/theme.dart` —— `scaffoldBackgroundColor`、`cardTheme`(去边框、换阴影)、`fontFamily`、`navigationBarTheme`。
- `lib/widgets/med_card.dart` —— `MedCard` 去边框换阴影;`MedPill` 换状态配色;新增 `MedBanner`。
- `lib/widgets/lab_status.dart` —— `labStatusColor` / `labStripeColor` / `labPill` / `LabLine`(4px 左色条)。
- 屏:`archive_screen.dart`、`trends_screen.dart`、`for_doctor_screen.dart`、`document_detail.dart`、`emergency_card_screen.dart`、`settings_screen.dart`、`member_detail_screen.dart`、`account_screen.dart`、`qr_share_screen.dart`、`qr_notice_sheet.dart`、`cloud_extract_ask_sheet.dart`、`first_run_consent.dart`、`disease_profile_screen.dart`、`doctor/doctor_home_screen.dart`。
- widget:`identity_hero_card.dart`、`disease_profile_card.dart`、`profile_sections.dart`、`member_switcher.dart`、`backup_status_line.dart`、`trend_chart.dart`。
- `lib/main.dart` —— 收掉两处 `Colors.*` 裸色;底栏样式。
- `pubspec.yaml` —— fonts + assets。

**删:** 无。

---

### Task 1: 令牌层 —— 把 brief 的数值全部落进 `design_tokens.dart` / `theme.dart`

**Files:**
- Modify: `lib/design_tokens.dart`
- Modify: `lib/theme.dart`
- Modify: `lib/main.dart:796`、`lib/main.dart:817`(两处裸 `Colors.*`)
- Test: `test/design_tokens_test.dart`(重写 spec 表)、`test/no_raw_colors_test.dart`(新建)

**Interfaces:**
- Produces:
  - `MedColors.light` 字段值改动:`paper = Color(0xFFF1F4F8)`、`high = Color(0xFFC25E18)`、`highWash = Color(0xFFFDE3CC)`、`low = Color(0xFF1F5FB8)`、`lowWash = Color(0xFFDCE8FB)`、`criticalWash = Color(0xFFFBDDE4)`。其余字段(`ink` `ink2` `ink3` `surface` `line` `line2` `seal` `sealInk` `sealWash` `critical` `proxy*` `shadowColor`)**不动**。
  - 新 `class MedBrand`(全 `static const`,字段名见 Step 3)。
  - `MedType`:`title`(26·w600)、`subtitle`(19·w600)、`body`(16·w400)、`secondary`(13·w400)、`caption`(12·w500)、`value`(16·w500·tabular)、`display`(30·w600·tabular);新增 `static const String family = 'Manrope'`、`static const List<FontVariation> w500 / w600`。
  - `MedShape`:新增 `radiusHero = 22`、`radiusEntry = 18`、`radiusBanner = 16`、`radiusTile = 12`;`radiusCard = 20`、`radiusPill = 999`、`radiusBlock = 14`、`radiusControl = 10`、间距阶 `s1…s6` 全部保留不动。

- [ ] **Step 1: 写失败的测试 —— 把 brief 的色值钉死**

把 `test/design_tokens_test.dart` 顶部的 `specLight` 表整个换成 brief 的值,并在文件头加一段说明「本表的正本已由 Stage 3 brief 取代 DESIGN-SYSTEM-v1」。新表:

```dart
/// 正本 = `stage3-visual-tokens-brief.md`(mockup v24,2026-09-17 认可)。
/// **它 supersede 了 DESIGN-SYSTEM-v1.html 的色板** —— 底色、偏高/偏低/危急三档
/// 都换了值。改这张表 = 改设计,不是改代码。
const Map<String, int> specLight = {
  'ink': 0xFF101A23,
  'ink-2': 0xFF3A4A57,
  'ink-3': 0xFF657581,
  'paper': 0xFFF1F4F8,
  'surface': 0xFFFFFFFF,
  'line': 0xFFE3E9EE,
  'line-2': 0xFFEEF2F5,
  'seal': 0xFF1789C1,
  'seal-ink': 0xFF0E6285,
  'seal-wash': 0xFFEAF5FA,
  'low': 0xFF1F5FB8,
  'low-wash': 0xFFDCE8FB,
  'high': 0xFFC25E18,
  'high-wash': 0xFFFDE3CC,
  'critical': 0xFFBE123C,
  'critical-wash': 0xFFFBDDE4,
};
```

在同一文件末尾追加三组新断言:

```dart
group('MedBrand —— Stage 3 brief §色 / §形', () {
  test('品牌渐变 135°,三段,逐字', () {
    expect(MedBrand.gradientColors, [
      const Color(0xFF1FB0C6),
      const Color(0xFF1789C1),
      const Color(0xFF16508E),
    ]);
    expect(MedBrand.gradientStops, [0.0, 0.5, 1.0]);
    // 135° = 左上 → 右下。
    expect(MedBrand.gradientBegin, Alignment.topLeft);
    expect(MedBrand.gradientEnd, Alignment.bottomRight);
    expect(MedBrand.heroGlow, const Color(0x38FFFFFF)); // rgba(255,255,255,.22)
  });

  test('九档类别渐变与同色投影', () {
    expect(MedBrand.tile(GlossCategory.lab),
        (const Color(0xFF25B5C2), const Color(0xFF0B7A87), const Color(0x5A0E8A96)));
    expect(MedBrand.tile(GlossCategory.clinic),
        (const Color(0xFF4A90E8), const Color(0xFF1A5BC0), const Color(0x5A1F6FD2)));
    expect(MedBrand.tile(GlossCategory.imaging),
        (const Color(0xFF9A7BE0), const Color(0xFF5B3FAE), const Color(0x5A6A4DBF)));
    expect(MedBrand.tile(GlossCategory.med),
        (const Color(0xFFF4A04A), const Color(0xFFD0661A), const Color(0x5AE07A25)));
    expect(MedBrand.tile(GlossCategory.note),
        (const Color(0xFF5CC28A), const Color(0xFF227A4C), const Color(0x5A2F8F5B)));
    expect(MedBrand.tile(GlossCategory.alert),
        (const Color(0xFFF06A86), const Color(0xFFB92A4A), const Color(0x5ACF3A5A)));
    expect(MedBrand.tile(GlossCategory.neutral),
        (const Color(0xFF8A98A4), const Color(0xFF4A5A67), const Color(0x4D4A5A67)));
    expect(MedBrand.tile(GlossCategory.brand),
        (const Color(0xFF1FB0C6), const Color(0xFF16508E), const Color(0x5A1789C1)));
    expect(MedBrand.tile(GlossCategory.busy),
        (const Color(0xFFB7C2CC), const Color(0xFF8A98A4), const Color(0x334A5A67)));
  });

  test('状态左色条、横幅、示例框、看一眼', () {
    expect(MedBrand.barHigh, const Color(0xFFE07A25));
    expect(MedBrand.barLow, const Color(0xFF1F6FD2));
    expect(MedBrand.barNormal, const Color(0xFF2F8F5B));
    expect(MedBrand.barCritical, const Color(0xFFCF3A5A));
    expect(MedBrand.normalInk, const Color(0xFF227A4C));
    expect(MedBrand.pillHighInk, const Color(0xFF9A4A12));
    expect(MedBrand.bannerBlue, const Color(0xFFDDEDF8));
    expect(MedBrand.bannerBlueInk, const Color(0xFF0E6285));
    expect(MedBrand.bannerAmber, const Color(0xFFFBE7D2));
    expect(MedBrand.bannerAmberInk, const Color(0xFF9A4A12));
    expect(MedBrand.demoBorder, const Color(0xFFB7C2CC));
    expect(MedBrand.demoInk, const Color(0xFF657581));
    expect(MedBrand.checkWash, const Color(0xFFE6EBF0));
    expect(MedBrand.checkInk, const Color(0xFF3A4A57));
    expect(MedBrand.timelineLine, const Color(0xFFDCE3EA));
    expect(MedBrand.expandedChartBg, const Color(0xFFF7FAFC));
  });

  test('五档阴影,逐字', () {
    expect(MedBrand.cardShadow.single.blurRadius, 18);
    expect(MedBrand.cardShadow.single.offset, const Offset(0, 6));
    expect(MedBrand.cardShadow.single.color, const Color(0x14101A23)); // rgba(16,26,35,.08)
    expect(MedBrand.heroShadow.single.blurRadius, 30);
    expect(MedBrand.heroShadow.single.offset, const Offset(0, 14));
    expect(MedBrand.heroShadow.single.color, const Color(0x5216508E)); // rgba(22,80,142,.32)
    expect(MedBrand.entryShadow.single.blurRadius, 26);
    expect(MedBrand.entryShadow.single.offset, const Offset(0, 12));
    expect(MedBrand.buttonShadow.single.blurRadius, 24);
    expect(MedBrand.buttonShadow.single.offset, const Offset(0, 10));
    expect(MedBrand.buttonShadow.single.color, const Color(0x4D16508E)); // rgba(22,80,142,.3)
    expect(MedBrand.navShadow.single.offset, const Offset(0, -6));
  });
});

group('MedShape / MedType —— Stage 3 brief §形 §字', () {
  test('六档圆角', () {
    expect(MedShape.radiusHero, 22);
    expect(MedShape.radiusCard, 20);
    expect(MedShape.radiusEntry, 18);
    expect(MedShape.radiusBanner, 16);
    expect(MedShape.radiusTile, 12);
    expect(MedShape.radiusPill, 999);
  });

  test('字号字重', () {
    expect(MedType.title.fontSize, 26);
    expect(MedType.title.fontWeight, FontWeight.w600);
    expect(MedType.body.fontSize, 16);
    expect(MedType.body.fontWeight, FontWeight.w400);
    expect(MedType.secondary.fontSize, 13);
    expect(MedType.value.fontSize, 16);
    expect(MedType.value.fontWeight, FontWeight.w500);
    expect(MedType.value.fontFeatures, MedType.tabular);
    expect(MedType.display.fontSize, 30);
    expect(MedType.display.fontWeight, FontWeight.w600);
    // 700 不许出现:mockup 里没有一处 Latin/数字用它(见计划「已知分歧 3」)。
    for (final s in [MedType.display, MedType.value, MedType.title,
                     MedType.subtitle, MedType.body, MedType.secondary, MedType.caption]) {
      expect(s.fontWeight!.index, lessThanOrEqualTo(FontWeight.w600.index));
    }
  });

  test('底色是实心 #F1F4F8,主题拿的就是它', () {
    expect(MedMe.theme().scaffoldBackgroundColor, const Color(0xFFF1F4F8));
  });

  test('卡片无边框', () {
    final shape = MedMe.theme().cardTheme.shape! as RoundedRectangleBorder;
    expect(shape.side, BorderSide.none);
  });
});
```

新建 `test/no_raw_colors_test.dart`:

```dart
// 裸色值闸:屏和 widget 里不许出现任何 `Color(0x…)`,也不许用 Material 的命名色
// (白/黑/透明除外)。色板的唯一出处是 design_tokens.dart / theme.dart。
//
// 这条闸同时兑现 brief 的「不用粉彩」—— 粉彩进不来代码的路只有一条:有人手写
// 一个 Color(0xFF…)。堵住这条路,剩下的就只有令牌里那几十个经过审的值。
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

const _allowedFiles = {'lib/design_tokens.dart', 'lib/theme.dart'};
final _rawHex = RegExp(r'Color\(0x');
final _namedColor = RegExp(r'Colors\.(?!white|black|transparent)[a-z]');

void main() {
  test('lib 里只有令牌文件持有裸色值', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      if (f.path.startsWith('lib/src/rust')) continue;   // FRB 生成物
      if (_allowedFiles.contains(f.path)) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;  // 注释里可以讲历史
        if (_rawHex.hasMatch(line) || _namedColor.hasMatch(line)) {
          offenders.add('${f.path}:${i + 1}  ${line.trim()}');
        }
      }
    }
    expect(offenders, isEmpty, reason: '裸色值:\n${offenders.join('\n')}');
  });
}
```

- [ ] **Step 2: 跑测试确认它红**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/design_tokens_test.dart test/no_raw_colors_test.dart
```
预期:`design_tokens_test.dart` 在 `paper` / `high` / `low` / `critical-wash` 四处失败,`MedBrand` 未定义导致编译错;`no_raw_colors_test.dart` 报 `lib/main.dart:796` 与 `lib/main.dart:817`。

- [ ] **Step 3: 改 `design_tokens.dart`**

改 `MedColors.light` 的六个字段(见 Interfaces)。`MedColors.dark` **一个字不动** —— 深色主题没挂,改它等于改一个没人看的东西。

在文件末尾追加:

```dart
/// 光泽图标块的九档类别。**这是 app 里唯一的「图标底色」词表** —— 加一档等于
/// 加一个语义,要先在 brief 里有。
enum GlossCategory { lab, clinic, imaging, med, note, alert, neutral, brand, busy }

/// Stage 3 视觉层:渐变、阴影、类别色、状态条、横幅。
///
/// **不做成 `ThemeExtension`**:这些值不随明暗主题变(app 只挂了浅色),而
/// `ThemeExtension` 每加一个字段要在 copyWith / lerp / == / hashCode 四处各补一行。
/// 三十多个字段 = 一百多行纯样板,换不来任何东西。
///
/// 正本 `stage3-visual-tokens-brief.md`;每个值在 `test/design_tokens_test.dart`
/// 里逐一断言。
class MedBrand {
  MedBrand._();

  // ── 品牌渐变 ────────────────────────────────────────────
  /// 135°,三段。**只许 `BrandGradientBox` 用**(见 `widgets/brand_gradient.dart`)。
  static const List<Color> gradientColors = [
    Color(0xFF1FB0C6), Color(0xFF1789C1), Color(0xFF16508E),
  ];
  static const List<double> gradientStops = [0.0, 0.5, 1.0];
  static const Alignment gradientBegin = Alignment.topLeft;
  static const Alignment gradientEnd = Alignment.bottomRight;

  /// 主卡右上那团弱光晕。
  static const Color heroGlow = Color(0x38FFFFFF);          // rgba(255,255,255,.22)

  /// 病历本书脊:180°(上 → 下),两段。
  static const List<Color> spineColors = [Color(0xFF1FB0C6), Color(0xFF16508E)];
  /// 书脊上的细横纹:2px 实、9px 周期。
  static const Color spineStripe = Color(0x24FFFFFF);       // rgba(255,255,255,.14)
  static const double spineStripeOn = 2;
  static const double spineStripePeriod = 9;
  static const double spineWidth = 34;

  // ── 类别色 ──────────────────────────────────────────────
  /// 返回 (起色, 止色, 同色投影)。渐变角度一律 150°。
  static (Color, Color, Color) tile(GlossCategory c) => switch (c) {
    GlossCategory.lab =>     (Color(0xFF25B5C2), Color(0xFF0B7A87), Color(0x5A0E8A96)),
    GlossCategory.clinic =>  (Color(0xFF4A90E8), Color(0xFF1A5BC0), Color(0x5A1F6FD2)),
    GlossCategory.imaging => (Color(0xFF9A7BE0), Color(0xFF5B3FAE), Color(0x5A6A4DBF)),
    GlossCategory.med =>     (Color(0xFFF4A04A), Color(0xFFD0661A), Color(0x5AE07A25)),
    GlossCategory.note =>    (Color(0xFF5CC28A), Color(0xFF227A4C), Color(0x5A2F8F5B)),
    GlossCategory.alert =>   (Color(0xFFF06A86), Color(0xFFB92A4A), Color(0x5ACF3A5A)),
    GlossCategory.neutral => (Color(0xFF8A98A4), Color(0xFF4A5A67), Color(0x4D4A5A67)),
    GlossCategory.brand =>   (Color(0xFF1FB0C6), Color(0xFF16508E), Color(0x5A1789C1)),
    GlossCategory.busy =>    (Color(0xFFB7C2CC), Color(0xFF8A98A4), Color(0x334A5A67)),
  };

  /// 光泽块的两道内高光/内暗边,与 44×44、圆角 12、白线图标 22/1.9 一起,
  /// 构成 brief §形 的「3D 图标语言」。
  static const Color glossTop = Color(0x73FFFFFF);          // inset rgba(255,255,255,.45)
  static const Color glossBottom = Color(0x1A000000);       // inset rgba(0,0,0,.10)
  static const double tileSize = 44;
  static const double tileIconSize = 22;
  static const double tileIconStroke = 1.9;

  // ── 状态 ────────────────────────────────────────────────
  static const Color barHigh = Color(0xFFE07A25);
  static const Color barLow = Color(0xFF1F6FD2);
  static const Color barNormal = Color(0xFF2F8F5B);
  static const Color barCritical = Color(0xFFCF3A5A);
  /// 「正常」的文字色。**底是透明的** —— brief 只给了文和条,没给底(见计划「已知分歧 5」)。
  static const Color normalInk = Color(0xFF227A4C);
  /// 「偏高」pill 压在 `highWash` 上的那档更深的琥珀(与琥珀横幅同色)。
  static const Color pillHighInk = Color(0xFF9A4A12);

  static const Color bannerBlue = Color(0xFFDDEDF8);
  static const Color bannerBlueInk = Color(0xFF0E6285);
  static const Color bannerAmber = Color(0xFFFBE7D2);
  static const Color bannerAmberInk = Color(0xFF9A4A12);

  static const Color demoBorder = Color(0xFFB7C2CC);
  static const Color demoInk = Color(0xFF657581);
  static const Color checkWash = Color(0xFFE6EBF0);
  static const Color checkInk = Color(0xFF3A4A57);

  static const Color timelineLine = Color(0xFFDCE3EA);
  static const Color expandedChartBg = Color(0xFFF7FAFC);

  // ── 阴影(五档,逐字抄 mockup)────────────────────────────
  static const List<BoxShadow> cardShadow = [
    BoxShadow(color: Color(0x14101A23), offset: Offset(0, 6), blurRadius: 18),
  ];
  static const List<BoxShadow> heroShadow = [
    BoxShadow(color: Color(0x5216508E), offset: Offset(0, 14), blurRadius: 30),
  ];
  static const List<BoxShadow> entryShadow = [
    BoxShadow(color: Color(0x5216508E), offset: Offset(0, 12), blurRadius: 26),
  ];
  static const List<BoxShadow> buttonShadow = [
    BoxShadow(color: Color(0x4D16508E), offset: Offset(0, 10), blurRadius: 24),
  ];
  static const List<BoxShadow> navShadow = [
    BoxShadow(color: Color(0x0F101A23), offset: Offset(0, -6), blurRadius: 18),
  ];
  static const List<BoxShadow> chipShadow = [
    BoxShadow(color: Color(0x0F101A23), offset: Offset(0, 3), blurRadius: 10),
  ];
  static const List<BoxShadow> qrShadow = [
    BoxShadow(color: Color(0x1A101A23), offset: Offset(0, 6), blurRadius: 18),
  ];

  /// 光泽块的同色投影,统一 `0 5px 12px`,颜色由 [tile] 的第三项给。
  static List<BoxShadow> tileShadow(Color c) =>
      [BoxShadow(color: c, offset: const Offset(0, 5), blurRadius: 12)];
}
```

`MedType` 改字号(名字全部保留,只换值),并加字体声明:

```dart
class MedType {
  MedType._();

  /// 数字与字母的字体。中文不走它 —— Manrope 没有汉字,Flutter 会自动回落到
  /// `fontFamilyFallback` 里的系统苹方 / 系统默认。**不打包 Noto**(brief §字)。
  static const String family = 'Manrope';
  static const List<String> fallback = ['PingFang SC', 'Heiti SC', 'sans-serif'];

  /// 可变字体的轴值。Google Fonts 已不再提供 Manrope 静态字重,只有一个
  /// `Manrope[wght].ttf`;钉轴值比指望平台自动映射 `fontWeight` 更稳。
  static const List<FontVariation> w500 = [FontVariation('wght', 500)];
  static const List<FontVariation> w600 = [FontVariation('wght', 600)];

  /// 30 · 600 · tabular —— 单指标大数(趋势主卡、急救卡)。
  static const TextStyle display = TextStyle(
    fontSize: 30, fontWeight: FontWeight.w600,
    fontVariations: w600, fontFeatures: tabular,
  );

  /// 26 · 600 —— 页面标题(brief §字:标题 26)。
  static const TextStyle title = TextStyle(
    fontSize: 26, fontWeight: FontWeight.w600, fontVariations: w600,
  );

  /// 19 · 600 —— 底部 sheet 的标题、卡片标题(mockup `.sheet h4`)。
  static const TextStyle subtitle = TextStyle(
    fontSize: 19, fontWeight: FontWeight.w600, fontVariations: w600,
  );

  /// 16 · 400 —— 正文(brief §字:正文 16)。
  static const TextStyle body = TextStyle(fontSize: 16);

  /// 16 · 500 · tabular —— 化验/趋势的数值(mockup `.lr .v` / `.tr .v`)。
  static const TextStyle value = TextStyle(
    fontSize: 16, fontWeight: FontWeight.w500,
    fontVariations: w500, fontFeatures: tabular,
  );

  /// 13 · 400 —— 行元数据、横幅小字(brief §字:两处都是 13)。
  static const TextStyle secondary = TextStyle(fontSize: 13);

  /// 12 · 500 —— 状态 pill、底栏标签。
  static const TextStyle caption = TextStyle(
    fontSize: 12, fontWeight: FontWeight.w500, fontVariations: w500,
  );

  static const double minFontSize = 12;
  static const List<FontFeature> tabular = [FontFeature.tabularFigures()];
}
```

`MedShape` 追加四档圆角(`radiusCard` / `radiusBlock` / `radiusControl` / `radiusPill` / `s1…s6` 全部保留):

```dart
  /// 22 —— 主卡(品牌渐变那张)。全 app 最大的一档。
  static const double radiusHero = 22;
  /// 18 —— 入口块(主页两个方块、病历本条)。
  static const double radiusEntry = 18;
  /// 16 —— 横幅、输入框面板、二维码框。
  static const double radiusBanner = 16;
  /// 12 —— 光泽图标块。
  static const double radiusTile = 12;
```

- [ ] **Step 4: 改 `theme.dart`**

只改这五处,其余一字不动:

```dart
      scaffoldBackgroundColor: c.paper,            // 值已经跟着 MedColors 变成 #F1F4F8
```

```dart
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: MedType.family,
      fontFamilyFallback: MedType.fallback,
    );
```

```dart
      // brief §形:卡**无边框**,靠阴影分层(旧规范是反过来的:靠边框不靠阴影)。
      cardTheme: CardThemeData(
        color: c.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MedShape.radiusCard),
          side: BorderSide.none,
        ),
        margin: EdgeInsets.zero,
      ),
```

```dart
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: c.surface,
        indicatorColor: Colors.transparent,   // mockup 底栏没有药丸指示块,靠颜色区分
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        labelTextStyle: WidgetStatePropertyAll(MedType.caption),
      ),
```

最后把 `MedMe` 那几个旧常量对齐令牌(它们还被未迁移的屏引用,这一步让它们不再自成一套色):

```dart
  static const Color teal = Color(0xFF1789C1);       // = seal,不动
  static const Color tealDark = Color(0xFF0E6285);   // 原 #1560A8 → sealInk
  static const Color tealSoft = Color(0xFFEAF5FA);   // 原 #E6F6FA → sealWash
  static const Color bg = Color(0xFFF1F4F8);         // 原 #F6F8FB → paper
  static const Color line = Color(0xFFEEF2F5);       // 原 #E2E8F0 → line2(分隔线)
  static const Color ink = Color(0xFF101A23);        // 原 #1E293B
  static const Color faint = Color(0xFF657581);      // 原 #5F7390 → ink3
  static const Color danger = Color(0xFFBE123C);     // 不动
```

- [ ] **Step 5: 收掉 `main.dart` 两处裸色**

`lib/main.dart:796`:`Colors.redAccent` → `MedColors.of(context).critical`(把那个 `const TextStyle` 去掉 const)。
`lib/main.dart:817`:`Colors.teal` → `MedColors.of(context).seal`(同样去 const)。

- [ ] **Step 6: 跑测试确认绿**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/design_tokens_test.dart test/no_raw_colors_test.dart
```
预期:两个文件全绿。再跑一次全量看有没有别处被色值变化震到:
```bash
/Users/ziyuanguan/flutter/bin/flutter test
```
若 `identity_hero_card_test.dart` 的对比度断言红 —— **不要在这个 Task 改它**,记下来,Task 4 会把那张卡换成 `HeroCard`、对比度断言跟着搬。临时用 `skip: '见 Task 4:换 HeroCard 后重写'` 标注。

- [ ] **Step 7: Commit**

```bash
git add lib/design_tokens.dart lib/theme.dart lib/main.dart \
        test/design_tokens_test.dart test/no_raw_colors_test.dart
git commit -m "$(cat <<'MSG'
feat(ui): Stage 3 令牌层 —— 落 mockup v24 的色/形/字

底色换 #F1F4F8、偏高/偏低/危急三档换 brief 的值、卡片去边框换 0 6px 18px 阴影;
新增 MedBrand(品牌渐变 / 九档类别渐变 / 状态左色条 / 横幅 / 五档阴影),不做成
ThemeExtension —— 这些值不随明暗主题变,做成扩展要多写一百多行样板。

字阶按 brief 重排:标题 26、正文 16、行元数据 13,700 字重整条去掉(mockup 里
没有一处 Latin/数字真的用到它)。

加裸色值闸 test/no_raw_colors_test.dart:屏和 widget 里不许出现 Color(0x…),
顺手收掉 main.dart 残留的两处 Colors.*。这条闸就是「不用粉彩」的落地方式。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
MSG
)"
```

---

### Task 2: 字体 —— 打包 Manrope(只 500/600),中文走系统,不打包 Noto

**Files:**
- Create: `assets/fonts/Manrope[wght].ttf`(下载)
- Create: `assets/fonts/OFL.txt`(下载,字体许可证要随包走)
- Modify: `pubspec.yaml`(`flutter:` 下的 `fonts:` 段)
- Test: `test/fonts_test.dart`(新建)

**Interfaces:**
- Consumes: Task 1 的 `MedType.family` = `'Manrope'`、`MedType.fallback`、`MedType.w500` / `w600`。
- Produces: 字族 `Manrope` 可用;`pubspec.yaml` 里只有这一个字族。

- [ ] **Step 1: 写失败的测试**

新建 `test/fonts_test.dart`:

```dart
// 字体闸。brief §字:数字/字母 = Manrope(只 500、600),中文 = 系统苹方 /
// 系统默认,**不打包 Noto**。
//
// 为什么要测:打包一份中文字体是 20 MB 起步的事,而它会在某次「顺手修一下字重」
// 里悄悄进来。这个测试扫 pubspec,不扫渲染 —— 渲染看不出字体是打包的还是系统的。
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';

void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();

  test('不打包任何中文字体', () {
    for (final banned in ['Noto', 'noto', 'SourceHan', 'PingFang.ttf', 'HarmonyOS']) {
      expect(pubspec.contains(banned), isFalse, reason: '$banned 不该进包');
    }
  });

  test('只打包 Manrope 一个字族', () {
    final families = RegExp(r'^\s*- family:\s*(\S+)', multiLine: true)
        .allMatches(pubspec).map((m) => m.group(1)).toList();
    expect(families, ['Manrope']);
  });

  test('字体文件真的在,且只有一个 ttf', () {
    final ttfs = Directory('assets/fonts').listSync()
        .where((f) => f.path.endsWith('.ttf')).map((f) => f.path).toList();
    expect(ttfs, ['assets/fonts/Manrope[wght].ttf']);
  });

  test('MedType 只用 500 / 600 两档轴值', () {
    const styles = <TextStyle>[
      MedType.display, MedType.title, MedType.subtitle,
      MedType.body, MedType.value, MedType.secondary, MedType.caption,
    ];
    for (final s in styles) {
      for (final v in s.fontVariations ?? const <FontVariation>[]) {
        expect(v.axis, 'wght');
        expect(v.value, anyOf(500.0, 600.0), reason: '只许 500 / 600');
      }
    }
  });

  test('数值样式一律带 tabular figures —— 小数点要对齐', () {
    expect(MedType.value.fontFeatures, contains(const FontFeature.tabularFigures()));
    expect(MedType.display.fontFeatures, contains(const FontFeature.tabularFigures()));
  });

  test('主题把 Manrope 挂上去,中文回落到系统', () {
    final t = MedMe.theme();
    expect(t.textTheme.bodyMedium!.fontFamily, 'Manrope');
    expect(t.textTheme.bodyMedium!.fontFamilyFallback, contains('PingFang SC'));
  });
}
```

> 顶部还要 `import 'package:mobile_flutter/theme.dart';`(`MedMe.theme()`)。

- [ ] **Step 2: 跑测试确认它红**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/fonts_test.dart
```
预期:「只打包 Manrope 一个字族」失败(现在 `pubspec.yaml` 里一个 `family:` 都没有,列表是空的);「字体文件真的在」失败(`assets/fonts` 不存在)。

- [ ] **Step 3: 下载字体**

Google Fonts 的 `ofl/manrope/` 现在**只有可变字体**,静态字重(`static/Manrope-Medium.ttf` 之类)已经 404 —— 见计划「已知分歧 4」。

```bash
mkdir -p assets/fonts
curl -sSL -o 'assets/fonts/Manrope[wght].ttf' \
  'https://github.com/google/fonts/raw/main/ofl/manrope/Manrope%5Bwght%5D.ttf'
curl -sSL -o assets/fonts/OFL.txt \
  'https://github.com/google/fonts/raw/main/ofl/manrope/OFL.txt'
ls -l assets/fonts   # Manrope[wght].ttf 应该是 164700 字节
```

- [ ] **Step 4: 声明进 `pubspec.yaml`**

在 `flutter:` 段里、`assets:` 之后加(把文件尾那一整块注释掉的 `# fonts:` 示例删掉,别留两份说明):

```yaml
  # 数字与字母用 Manrope,中文用系统字体(见 lib/design_tokens.dart 的 MedType)。
  # **可变字体,一个文件**:Google Fonts 已不再提供 Manrope 的静态字重,只有
  # Manrope[wght].ttf。字重靠 TextStyle.fontVariations 钉 wght 轴,只用 500 / 600
  # 两档 —— 见 test/fonts_test.dart。不打包任何中文字体(那是 20 MB 起步的事)。
  fonts:
    - family: Manrope
      fonts:
        - asset: assets/fonts/Manrope[wght].ttf
```

- [ ] **Step 5: 跑测试确认绿**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/fonts_test.dart
/Users/ziyuanguan/flutter/bin/flutter analyze
```
预期:全绿、analyze 无告警。

- [ ] **Step 6: Commit**

```bash
git add 'assets/fonts/Manrope[wght].ttf' assets/fonts/OFL.txt pubspec.yaml test/fonts_test.dart
git commit -m "$(cat <<'MSG'
feat(ui): 打包 Manrope(可变字体,只用 wght 500/600),中文走系统字体

brief §字要求「打包 2 个字重」,但 Google Fonts 的 ofl/manrope 现在只剩一个可变
字体,静态字重路径已 404。改为打包这一个文件(164 KB,与两个静态实例体积相当),
字重在 MedType 里用 FontVariation 钉死 500 / 600 两档,意图不变。

test/fonts_test.dart 守三件事:不打包任何中文字体、只有 Manrope 一个字族、数值
样式一律带 tabular figures。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
MSG
)"
```

---

### Task 3: 共用 widget —— `GlossIconTile`(44×44 光泽图标块)

**Files:**
- Create: `lib/widgets/gloss_tile.dart`
- Test: `test/gloss_tile_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `GlossCategory`、`MedBrand.tile()`、`MedBrand.glossTop` / `glossBottom` / `tileSize` / `tileIconSize` / `tileShadow()`、`MedShape.radiusTile`。
- Produces:
  ```dart
  class GlossIconTile extends StatelessWidget {
    const GlossIconTile({super.key, required this.icon, this.category = GlossCategory.brand, this.size = MedBrand.tileSize});
    const GlossIconTile.letter({super.key, required this.letter, this.category = GlossCategory.brand, this.size = MedBrand.tileSize});
    final IconData? icon;      // icon 与 letter 二选一
    final String? letter;
    final GlossCategory category;
    final double size;         // 首启场景要 52 / 56 / 40,所以可调;默认 44
  }
  ```

- [ ] **Step 1: 写失败的测试**

新建 `test/gloss_tile_test.dart`:

```dart
// 光泽图标块是 brief §形 里的「我们的 3D 图标语言」—— 全 app 的图标底块只此一家。
// 这个测试钉住它的几何与三层光泽,免得后来有人「简化成一个纯色方块」。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/widgets/gloss_tile.dart';

Future<BoxDecoration> _decoOf(WidgetTester tester, Widget tile) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: tile))));
  final box = tester.widget<Container>(
    find.descendant(of: find.byType(GlossIconTile), matching: find.byType(Container)).first,
  );
  return box.decoration! as BoxDecoration;
}

void main() {
  testWidgets('44×44、圆角 12、150° 渐变、同色投影', (tester) async {
    final d = await _decoOf(tester, const GlossIconTile(icon: Icons.science_outlined, category: GlossCategory.lab));
    final size = tester.getSize(find.byType(GlossIconTile));
    expect(size, const Size(44, 44));
    expect(d.borderRadius, BorderRadius.circular(MedShape.radiusTile));

    final g = d.gradient! as LinearGradient;
    final (a, b, s) = MedBrand.tile(GlossCategory.lab);
    expect(g.colors, [a, b]);
    // 150°:CSS 的 0° 朝上、顺时针;150° ≈ 从左上偏上 → 右下偏下。
    expect(g.transform, isA<GradientRotation>());

    expect(d.boxShadow!.single.color, s);
    expect(d.boxShadow!.single.offset, const Offset(0, 5));
    expect(d.boxShadow!.single.blurRadius, 12);
  });

  testWidgets('两道内光泽:顶 rgba(255,255,255,.45)、底 rgba(0,0,0,.10)', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: GlossIconTile(icon: Icons.science_outlined))),
    ));
    // 内高光用一道 1px 的 Container 叠在顶/底 —— Flutter 没有 inset box-shadow。
    final highlights = tester.widgetList<DecoratedBox>(find.descendant(
      of: find.byType(GlossIconTile), matching: find.byType(DecoratedBox),
    )).map((w) => (w.decoration as BoxDecoration).color).toList();
    expect(highlights, containsAll(<Color>[MedBrand.glossTop, MedBrand.glossBottom]));
  });

  testWidgets('白色线图标 22px', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: GlossIconTile(icon: Icons.science_outlined))),
    ));
    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.size, MedBrand.tileIconSize);
    expect(icon.color, Colors.white);
  });

  testWidgets('字母款:成员头像用品牌渐变 + 白字', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: GlossIconTile.letter(letter: '张'))),
    ));
    expect(find.text('张'), findsOneWidget);
    expect(tester.widget<Text>(find.text('张')).style!.color, Colors.white);
    final d = await _decoOf(tester, const GlossIconTile.letter(letter: '张'));
    final (a, b, _) = MedBrand.tile(GlossCategory.brand);
    expect((d.gradient! as LinearGradient).colors, [a, b]);
  });

  testWidgets('九档类别各有各的渐变,没有两档撞色', (tester) async {
    final seen = <List<Color>>[];
    for (final cat in GlossCategory.values) {
      final (a, b, _) = MedBrand.tile(cat);
      seen.add([a, b]);
    }
    expect(seen.toSet().length, GlossCategory.values.length);
  });

  testWidgets('2.0 字号下不溢出(块是固定尺寸,图标不跟着放大)', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
        child: const Scaffold(body: Center(child: GlossIconTile.letter(letter: '张'))),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(GlossIconTile)), const Size(44, 44));
  });
}
```

- [ ] **Step 2: 跑测试确认它红**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/gloss_tile_test.dart
```
预期:编译失败,`gloss_tile.dart` 不存在。

- [ ] **Step 3: 写实现**

新建 `lib/widgets/gloss_tile.dart`:

```dart
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// 光泽图标块 —— brief §形 里的「我们的 3D 图标语言」,**全 app 的图标底块只此一家**。
///
/// 44×44、圆角 12、150° 类别渐变,加三层光:顶部一道白色内高光、底部一道黑色内暗边、
/// 外面一团同色投影。CSS 那边是 `inset box-shadow`,Flutter 没有这个东西,所以两道
/// 内光用 1px 高的 `DecoratedBox` 贴在上下沿 —— 视觉等价,不用 `CustomPainter`。
///
/// [size] 可调只为首启那一屏:`s16` 的场景里三个小块是 52 / 56 / 40。别的地方一律用
/// 默认的 44,**不要**为了「这里挤一点」就调小它。
class GlossIconTile extends StatelessWidget {
  const GlossIconTile({
    super.key,
    required IconData this.icon,
    this.category = GlossCategory.brand,
    this.size = MedBrand.tileSize,
  }) : letter = null;

  /// 字母款:成员头像。底色固定走品牌渐变(brief §色:成员头像 = 品牌渐变)。
  const GlossIconTile.letter({
    super.key,
    required String this.letter,
    this.category = GlossCategory.brand,
    this.size = MedBrand.tileSize,
  }) : icon = null;

  final IconData? icon;
  final String? letter;
  final GlossCategory category;
  final double size;

  @override
  Widget build(BuildContext context) {
    final (a, b, shadow) = MedBrand.tile(category);
    // CSS 的 `linear-gradient(150deg, …)`:0° 朝上、顺时针。Flutter 的
    // topCenter→bottomCenter 是 180°,所以要旋转 (150-180) = -30°。
    const rotation = -30 * math.pi / 180;
    final radius = MedShape.radiusTile * (size / MedBrand.tileSize);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          colors: [a, b],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          transform: const GradientRotation(rotation),
        ),
        boxShadow: MedBrand.tileShadow(shadow),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 顶部内高光。
            Positioned(top: 0, left: 0, right: 0, child: DecoratedBox(
              decoration: const BoxDecoration(color: MedBrand.glossTop),
              child: const SizedBox(height: 1, width: double.infinity),
            )),
            // 底部内暗边。
            Positioned(bottom: 0, left: 0, right: 0, child: DecoratedBox(
              decoration: const BoxDecoration(color: MedBrand.glossBottom),
              child: const SizedBox(height: 1, width: double.infinity),
            )),
            if (icon != null)
              Icon(icon, size: MedBrand.tileIconSize * (size / MedBrand.tileSize), color: Colors.white)
            else
              // **不跟系统字号放大**:块是固定尺寸,字放大就溢出。这是唯一一处
              // 允许关掉字号缩放的地方 —— 它是个图形,不是要读的正文。
              MediaQuery.withNoTextScaling(
                child: Text(
                  letter!,
                  style: MedType.subtitle.copyWith(color: Colors.white, fontSize: size * 0.41),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: 跑测试确认绿**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/gloss_tile_test.dart
/Users/ziyuanguan/flutter/bin/flutter analyze
```

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/gloss_tile.dart test/gloss_tile_test.dart
git commit -m "$(cat <<'MSG'
feat(ui): GlossIconTile —— 44×44 光泽图标块,全 app 唯一的图标底块

brief §形 的「3D 图标语言」:150° 类别渐变 + 顶部白内高光 + 底部黑内暗边 +
同色投影 0 5px 12px,白线图标 22px。九档类别(化验/门诊/影像/用药/笔记/警示/
中性/品牌/处理中)各一套色,测试断言没有两档撞色。

内高光用两道 1px 的 DecoratedBox 贴上下沿 —— Flutter 没有 inset box-shadow,
这比为一道光写 CustomPainter 短得多。

字母款(成员头像)关掉字号缩放:块是固定尺寸,它是图形不是正文。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
MSG
)"
```

---

### Task 4: 共用 widget —— `BrandGradientBox` / `HeroCard` / `PrimaryEntryTile` / `MedPrimaryButton` + 屏测试 helper

**Files:**
- Create: `lib/widgets/brand_gradient.dart`
- Create: `test/stage3_visual_helpers.dart`
- Modify: `lib/widgets/identity_hero_card.dart`(内部换成 `HeroCard`,类名与构造参数**一个不动**)
- Test: `test/brand_gradient_test.dart`(新建)、`test/identity_hero_card_test.dart`(改对比度断言的取色出处)

**Interfaces:**
- Consumes: `MedBrand.gradientColors` / `gradientStops` / `gradientBegin` / `gradientEnd` / `heroGlow` / `heroShadow` / `entryShadow` / `buttonShadow`、`MedShape.radiusHero` / `radiusEntry` / `radiusPill`、`GlossIconTile`。
- Produces:
  ```dart
  /// 全 app 唯一画品牌渐变的 widget。任何别处出现 MedBrand.gradientColors 都是 bug。
  class BrandGradientBox extends StatelessWidget {
    const BrandGradientBox({super.key, required this.child, required this.radius,
        required this.shadow, this.glow = false, this.onTap});
    final Widget child; final double radius;
    final List<BoxShadow> shadow; final bool glow; final VoidCallback? onTap;
  }

  /// 主卡:一屏至多一张。radius 22 + heroShadow + 右上光晕。
  class HeroCard extends StatelessWidget {
    const HeroCard({super.key, required this.child, this.onTap, this.semanticLabel});
  }

  /// 主入口块:一屏至多一个(s1 的「添加」)。radius 18 + entryShadow。
  class PrimaryEntryTile extends StatelessWidget {
    const PrimaryEntryTile({super.key, required this.icon, required this.label, this.onTap});
    final IconData icon; final String label; final VoidCallback? onTap;
  }

  /// 主按钮:药丸,radius 999 + buttonShadow,17·w500 白字。
  class MedPrimaryButton extends StatelessWidget {
    const MedPrimaryButton({super.key, required this.label, this.icon, this.onPressed});
  }

  /// 次按钮(mockup `.btn.sec`):白底 + 1.5px #1789C1 描边 + #0E6285 字,无阴影。
  class MedSecondaryButton extends StatelessWidget {
    const MedSecondaryButton({super.key, required this.label, this.icon, this.onPressed});
  }
  ```
- Produces(测试 helper,`test/stage3_visual_helpers.dart`):
  ```dart
  Future<void> pumpStage3(WidgetTester tester, Widget screen, {Size size = const Size(400, 800), double textScale = 1.0});
  void expectGradientBudget({int hero = 0, int entry = 0, int button = 0});
  void expectNoGradientInsideCards();
  Future<void> expectNoOverflowAtBothSizes(WidgetTester tester, Widget screen);
  ```

- [ ] **Step 1: 写失败的测试**

新建 `test/brand_gradient_test.dart`:

```dart
// 品牌渐变的看门测试。brief §品牌:「一屏只一处品牌渐变」——「一处」按计划的收口
// 指一个渐变**卡面**;主入口块和主按钮是控件,各自独立限一个(见计划「已知分歧 1」)。
//
// 能这样断言的前提是:**渐变只从 BrandGradientBox 出去**。所以这里先钉住这一点,
// 屏测试才有得数。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/widgets/brand_gradient.dart';

void main() {
  testWidgets('渐变 135°、三段、0/.5/1', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(
      body: HeroCard(child: Text('x')),
    )));
    final box = tester.widget<Container>(find.descendant(
      of: find.byType(BrandGradientBox), matching: find.byType(Container)).first);
    final g = (box.decoration! as BoxDecoration).gradient! as LinearGradient;
    expect(g.colors, MedBrand.gradientColors);
    expect(g.stops, MedBrand.gradientStops);
    expect(g.begin, Alignment.topLeft);    // 135° = 左上 → 右下
    expect(g.end, Alignment.bottomRight);
  });

  testWidgets('HeroCard:圆角 22、主卡阴影、右上一团光晕', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: HeroCard(child: Text('x')))));
    final box = tester.widget<Container>(find.descendant(
      of: find.byType(BrandGradientBox), matching: find.byType(Container)).first);
    final d = box.decoration! as BoxDecoration;
    expect(d.borderRadius, BorderRadius.circular(MedShape.radiusHero));
    expect(d.boxShadow, MedBrand.heroShadow);
    // 光晕:一个用 heroGlow 起色的 RadialGradient,对齐右上。
    final glow = tester.widgetList<Container>(find.descendant(
      of: find.byType(HeroCard), matching: find.byType(Container)))
      .map((w) => w.decoration).whereType<BoxDecoration>()
      .firstWhere((d) => d.gradient is RadialGradient);
    expect((glow.gradient! as RadialGradient).colors.first, MedBrand.heroGlow);
  });

  testWidgets('PrimaryEntryTile:圆角 18、入口块阴影、白图标 34', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(
      body: PrimaryEntryTile(icon: Icons.add_a_photo_outlined, label: '添加'))));
    final box = tester.widget<Container>(find.descendant(
      of: find.byType(BrandGradientBox), matching: find.byType(Container)).first);
    final d = box.decoration! as BoxDecoration;
    expect(d.borderRadius, BorderRadius.circular(MedShape.radiusEntry));
    expect(d.boxShadow, MedBrand.entryShadow);
    expect(tester.widget<Icon>(find.byType(Icon)).size, 34);
    expect(tester.widget<Icon>(find.byType(Icon)).color, Colors.white);
  });

  testWidgets('MedPrimaryButton:药丸、按钮阴影、17·w500 白字', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(
      body: MedPrimaryButton(label: '出码给医生看', icon: Icons.qr_code_2_outlined))));
    final box = tester.widget<Container>(find.descendant(
      of: find.byType(BrandGradientBox), matching: find.byType(Container)).first);
    final d = box.decoration! as BoxDecoration;
    expect(d.borderRadius, BorderRadius.circular(MedShape.radiusPill));
    expect(d.boxShadow, MedBrand.buttonShadow);
    final t = tester.widget<Text>(find.text('出码给医生看'));
    expect(t.style!.fontSize, 17);
    expect(t.style!.fontWeight, FontWeight.w500);
    expect(t.style!.color, Colors.white);
  });

  testWidgets('MedSecondaryButton:白底 + 1.5px seal 描边 + sealInk 字,无阴影', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(
      body: MedSecondaryButton(label: '先不出'))));
    expect(find.byType(BrandGradientBox), findsNothing);  // 次按钮不许有渐变
    final d = tester.widget<Container>(find.descendant(
      of: find.byType(MedSecondaryButton), matching: find.byType(Container)).first)
      .decoration! as BoxDecoration;
    expect(d.color, Colors.white);
    expect(d.border!.top.color, MedColors.light.seal);
    expect(d.border!.top.width, 1.5);
    expect(d.boxShadow, anyOf(isNull, isEmpty));
    expect(tester.widget<Text>(find.text('先不出')).style!.color, MedColors.light.sealInk);
  });

  testWidgets('2.0 字号、360×640 下按钮不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
      child: const Scaffold(body: Center(child: MedPrimaryButton(label: '出码给医生看'))),
    )));
    expect(tester.takeException(), isNull);
  });
}
```

- [ ] **Step 2: 跑测试确认它红**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/brand_gradient_test.dart
```
预期:编译失败,`brand_gradient.dart` 不存在。

- [ ] **Step 3: 写 `lib/widgets/brand_gradient.dart`**

```dart
import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// **全 app 唯一画品牌渐变的 widget。**
///
/// brief §品牌「一屏只一处品牌渐变」只有在渐变有唯一出口时才数得清。所以任何地方
/// 想要那三段蓝,都必须经过这里;`MedBrand.gradientColors` 出现在别的文件里就是 bug
/// (`test/no_raw_colors_test.dart` 挡不住这个,靠 code review 和屏测试的计数)。
///
/// 三个用法各有各的圆角与阴影:主卡 22 / 主入口块 18 / 主按钮 999。
class BrandGradientBox extends StatelessWidget {
  const BrandGradientBox({
    super.key,
    required this.child,
    required this.radius,
    required this.shadow,
    this.glow = false,
    this.onTap,
    this.semanticLabel,
  });

  final Widget child;
  final double radius;
  final List<BoxShadow> shadow;

  /// 右上那团弱光晕。**只有主卡有**(brief §色)。
  final bool glow;

  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    Widget content = child;
    if (glow) {
      content = Stack(children: [
        // 装饰性,不承载信息,不受对比度规则约束。
        Positioned(
          right: -60, top: -80,
          child: IgnorePointer(child: Container(
            width: 220, height: 220,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [MedBrand.heroGlow, Color(0x00FFFFFF)],
                stops: [0.0, 0.62],
              ),
            ),
          )),
        ),
        content,
      ]);
    }

    final box = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          colors: MedBrand.gradientColors,
          stops: MedBrand.gradientStops,
          begin: MedBrand.gradientBegin,
          end: MedBrand.gradientEnd,
        ),
        boxShadow: shadow,
      ),
      // 裁住光晕那团故意画到边界外的圆。
      clipBehavior: Clip.antiAlias,
      child: content,
    );

    if (onTap == null) return _semantics(box);
    return _semantics(Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(radius),
        splashColor: Colors.white.withValues(alpha: 0.08),
        highlightColor: Colors.white.withValues(alpha: 0.04),
        child: box,
      ),
    ));
  }

  Widget _semantics(Widget w) => semanticLabel == null
      ? w
      : Semantics(button: onTap != null, label: semanticLabel, child: w);
}

/// 主卡。**一屏至多一张**(见计划的「每屏品牌渐变预算」表)。
class HeroCard extends StatelessWidget {
  const HeroCard({super.key, required this.child, this.onTap, this.semanticLabel});

  final Widget child;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => BrandGradientBox(
    radius: MedShape.radiusHero,
    shadow: MedBrand.heroShadow,
    glow: true,
    onTap: onTap,
    semanticLabel: semanticLabel,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),  // mockup `.hero`
      child: child,
    ),
  );
}

/// 主入口块(`s1` 的「添加」)。**一屏至多一个。**
class PrimaryEntryTile extends StatelessWidget {
  const PrimaryEntryTile({super.key, required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => BrandGradientBox(
    radius: MedShape.radiusEntry,
    shadow: MedBrand.entryShadow,
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 11),   // mockup `.qa`
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 34, color: Colors.white),
        const SizedBox(height: 6),
        Text(label, textAlign: TextAlign.center,
          style: MedType.body.copyWith(color: Colors.white, fontWeight: FontWeight.w500,
              fontVariations: MedType.w500)),
      ]),
    ),
  );
}

/// 主按钮(mockup `.btn`):药丸、渐变、17·w500 白字。
class MedPrimaryButton extends StatelessWidget {
  const MedPrimaryButton({super.key, required this.label, this.icon, this.onPressed});

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => BrandGradientBox(
    radius: MedShape.radiusPill,
    shadow: MedBrand.buttonShadow,
    onTap: onPressed,
    child: Padding(
      padding: const EdgeInsets.all(13),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        if (icon != null) ...[Icon(icon, size: 20, color: Colors.white), const SizedBox(width: 8)],
        Flexible(child: Text(label, textAlign: TextAlign.center,
          style: MedType.body.copyWith(fontSize: 17, fontWeight: FontWeight.w500,
              fontVariations: MedType.w500, color: Colors.white))),
      ]),
    ),
  );
}

/// 次按钮(mockup `.btn.sec`):白底 + 1.5px seal 描边 + sealInk 字,**无阴影、无渐变**。
class MedSecondaryButton extends StatelessWidget {
  const MedSecondaryButton({super.key, required this.label, this.icon, this.onPressed});

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(MedShape.radiusPill),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(MedShape.radiusPill),
            border: Border.all(color: c.seal, width: 1.5),
          ),
          padding: const EdgeInsets.all(13),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (icon != null) ...[Icon(icon, size: 20, color: c.sealInk), const SizedBox(width: 8)],
            Flexible(child: Text(label, textAlign: TextAlign.center,
              style: MedType.body.copyWith(fontSize: 17, fontWeight: FontWeight.w500,
                  fontVariations: MedType.w500, color: c.sealInk))),
          ]),
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: 把 `IdentityHeroCard` 换成 `HeroCard` 的壳**

`lib/widgets/identity_hero_card.dart`:**类名、构造参数、每一个 `Text()` 的字符串一个不动**,只把 `build()` 里那层手写的 `Container`+`ClipRRect`+`Ink`+`Stack` 换成 `HeroCard`,并按 mockup `s1` 的 `.hero` 重排里面的排版:

- 头像:`ClipRRect`+`Container` → 白底 54×54 圆角 14 的方块,里面是 `initial`,字色 `MedColors.light.seal`,字重 600(mockup `.tile` / `.tile.logo span`;白块上放渐变文字在 Flutter 里要 `ShaderMask`,**不值得**,用实色 seal)。阴影 `inset 0 -2px 0` 同样用一道 2px 的底边 `Container` 代替。
- 姓名:`MedType.subtitle`(19·600)→ 改成 `fontSize: 21`(mockup `.hero .name`),色 `Colors.white`。**仍然不设 maxLines/ellipsis**(既有需求第四条)。
- 元信息 `subParts.join(' · ')`:`MedType.secondary.copyWith(fontSize: 14, color: Colors.white.withValues(alpha: 0.88), fontFeatures: MedType.tabular)`。
- 分隔线:`Container(height: 1, color: Colors.white.withValues(alpha: 0.35))`(mockup `.hero .rule`)。
- 「最近就诊 · …」那一行:左边标签 14 白 .88,右边 `recentVisitText` 用 `MedType.value.copyWith(fontSize: 22, fontWeight: FontWeight.w600, fontVariations: MedType.w600, color: Colors.white)`(mockup `.hero .rule b`)。
- 切换图标 `Icons.unfold_more` → 色 `Colors.white.withValues(alpha: 0.9)`,大小 20。
- 删掉整个 `IdentityHeroPalette` 类 —— 它推导的深色渐变已经被品牌渐变取代。`test/identity_hero_card_test.dart` 里凡是引用 `IdentityHeroPalette.*` 的断言,改成对白字压 `MedBrand.gradientColors` 三段的对比度断言(最亮的一段是 `#1FB0C6`,白字压它 2.4:1 —— **不够 AA**,所以姓名那一行必须落在渐变的中段以后;实测办法:断言渐变 `begin` 是 `topLeft`、头像占住左上、姓名右移,或直接把对比度断言换成「非装饰性文字一律 `Colors.white` 压 `#1789C1` 及更深段」并在测试里注明这条几何前提)。
  > **如果这条几何论证站不住**(白压 `#1789C1` 是 3.90:1,仍低于 AA 4.5),停下来报给用户:mockup 的主卡就是白字压这条渐变,这是 mockup 与项目既有无障碍红线的冲突,不是本 Task 能自己拍板的。

- [ ] **Step 5: 写测试 helper `test/stage3_visual_helpers.dart`**

```dart
// 每屏视觉测试的共用工具。三件事:按两种屏幕尺寸 + 2.0 字号 pump、数品牌渐变的
// 预算、确认卡里没有渐变。写一遍,十几个屏测试共用。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/brand_gradient.dart';
import 'package:mobile_flutter/widgets/med_card.dart';

/// 真机两个尺寸:大屏 400×800、小屏 360×640(brief 没给,取 Android 常见下限)。
const kStage3Sizes = [Size(400, 800), Size(360, 640)];

Future<void> pumpStage3(
  WidgetTester tester,
  Widget screen, {
  Size size = const Size(400, 800),
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: MedMe.theme(),
    home: MediaQuery(
      data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
      child: screen,
    ),
  ));
  await tester.pump();
}

/// brief §品牌「一屏只一处品牌渐变」的可执行形式。默认三个都是 0 —— 调用方只写
/// 它这一屏真正有的那几个,写漏了测试就红。
void expectGradientBudget({int hero = 0, int entry = 0, int button = 0}) {
  expect(find.byType(HeroCard), findsNWidgets(hero), reason: '主卡数不对');
  expect(find.byType(PrimaryEntryTile), findsNWidgets(entry), reason: '主入口块数不对');
  expect(find.byType(MedPrimaryButton), findsNWidgets(button), reason: '主按钮数不对');
}

/// brief §形「卡无边框」+「渐变只给主卡/主入口块/主按钮」的另一半:
/// **任何一张 MedCard 里都不许有品牌渐变。**
void expectNoGradientInsideCards() {
  expect(
    find.descendant(of: find.byType(MedCard), matching: find.byType(BrandGradientBox)),
    findsNothing,
    reason: '卡里出现了品牌渐变 —— 卡只能是白底 + 阴影',
  );
  expect(
    find.descendant(of: find.byType(Card), matching: find.byType(BrandGradientBox)),
    findsNothing,
  );
}

/// 2.0 字号 × 两个尺寸,四次 pump,一次溢出都不许有。
Future<void> expectNoOverflowAtBothSizes(WidgetTester tester, Widget screen) async {
  for (final size in kStage3Sizes) {
    for (final scale in [1.0, 2.0]) {
      await pumpStage3(tester, screen, size: size, textScale: scale);
      expect(tester.takeException(), isNull,
          reason: '$size @ ${scale}x 溢出了');
    }
  }
}
```

- [ ] **Step 6: 跑测试确认绿**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/brand_gradient_test.dart test/identity_hero_card_test.dart
/Users/ziyuanguan/flutter/bin/flutter analyze
```

- [ ] **Step 7: Commit**

```bash
git add lib/widgets/brand_gradient.dart lib/widgets/identity_hero_card.dart \
        test/brand_gradient_test.dart test/identity_hero_card_test.dart test/stage3_visual_helpers.dart
git commit -m "$(cat <<'MSG'
feat(ui): BrandGradientBox —— 品牌渐变的唯一出口,主卡/主入口块/主按钮三个用法

brief 的「一屏只一处品牌渐变」只有在渐变有唯一出口时才数得清,所以把三段蓝
(#1FB0C6 → #1789C1 → #16508E, 135°)收进一个 widget,主卡 22 / 入口块 18 /
按钮 999 三档圆角与三档阴影从它出去。IdentityHeroCard 换成这层壳,原来那套
自己推导的深色渐变(IdentityHeroPalette)整个删掉。

加 test/stage3_visual_helpers.dart:expectGradientBudget() 按每屏预算表数三个
计数,expectNoGradientInsideCards() 守「卡里不许有渐变」,
expectNoOverflowAtBothSizes() 跑 400×800 / 360×640 × 1.0 / 2.0 字号四次。
十几个屏测试共用,不各写一遍。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
MSG
)"
```

---

### Task 5: 共用 widget —— `RecordBookStrip`(病历本条)+ `LongTextRow`(长文本行)

**Files:**
- Create: `lib/widgets/record_book_strip.dart`
- Create: `lib/widgets/long_text_row.dart`
- Test: `test/record_book_strip_test.dart`、`test/long_text_row_test.dart`

**Interfaces:**
- Consumes: `MedBrand.spineColors` / `spineStripe` / `spineStripeOn` / `spineStripePeriod` / `spineWidth`、`MedBrand.cardShadow`、`MedShape.radiusEntry`、`GlossIconTile`、Task 7 的 `BrandLogo`(**Task 7 还没做,本 Task 先接受一个 `Widget? logo` 参数,Task 7 再把 `BrandLogo` 传进去**)。
- Produces:
  ```dart
  /// 病程档案的入口条(mockup `.book`)。左 34px 渐变书脊 + logo 40 + 标题/副标 + 右列大数。
  class RecordBookStrip extends StatelessWidget {
    const RecordBookStrip({super.key, required this.title, required this.subtitle,
        this.bigNumber, this.bigNumberSuffix, this.bigNumberCaption,
        this.titleTrailing, this.logo, this.onTap});
    final String title, subtitle;
    final String? bigNumber, bigNumberSuffix, bigNumberCaption;
    final Widget? titleTrailing;   // 「示例」pill
    final Widget? logo;            // Task 7 传 BrandLogo(size: 40)
    final VoidCallback? onTap;
  }

  /// 长文本行(mockup `.blk`)。图标块 + 全宽一项一行,不用两栏。
  class LongTextRow extends StatelessWidget {
    const LongTextRow({super.key, required this.category, required this.icon, required this.items});
    final GlossCategory category; final IconData icon;
    final List<({String text, String? meta})> items;
  }
  ```

- [ ] **Step 1: 写失败的测试**

新建 `test/record_book_strip_test.dart`:

```dart
// 病历本条(brief §形「病历本条」)。它是「病程档案」在趋势页的入口,形状**故意**
// 和主页的成员主卡不一样 —— 一个是渐变卡面,一个是白卡 + 渐变书脊。所以这里同时
// 断言:它不是 HeroCard,也不含 BrandGradientBox。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/widgets/brand_gradient.dart';
import 'package:mobile_flutter/widgets/record_book_strip.dart';

void main() {
  const strip = RecordBookStrip(
    title: '病程档案 · 狼疮', subtitle: '2 项该复查 · 复诊 8 月 12 日',
    bigNumber: '4', bigNumberSuffix: '/18', bigNumberCaption: '化验可算活动度',
  );

  testWidgets('白底、圆角 18、标准卡阴影 —— 不是渐变卡面', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: strip)));
    expect(find.byType(BrandGradientBox), findsNothing);
    final d = tester.widget<Container>(find.descendant(
      of: find.byType(RecordBookStrip), matching: find.byType(Container)).first)
      .decoration! as BoxDecoration;
    expect(d.color, Colors.white);
    expect(d.borderRadius, BorderRadius.circular(MedShape.radiusEntry));
    expect(d.boxShadow, MedBrand.cardShadow);
    expect(d.border, isNull);   // brief §形:卡无边框
  });

  testWidgets('左 34px 书脊,180° 两段渐变', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: strip)));
    final spine = find.byKey(const ValueKey('record-book-spine'));
    expect(tester.getSize(spine).width, MedBrand.spineWidth);
    final g = (tester.widget<DecoratedBox>(spine).decoration as BoxDecoration).gradient!
        as LinearGradient;
    expect(g.colors, MedBrand.spineColors);
    expect(g.begin, Alignment.topCenter);   // 180° = 上 → 下
    expect(g.end, Alignment.bottomCenter);
  });

  testWidgets('右列大数 22·600 seal 色 + 小字说明', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: strip)));
    final big = tester.widget<Text>(find.text('4'));
    expect(big.style!.fontSize, 22);
    expect(big.style!.fontWeight, FontWeight.w600);
    expect(big.style!.color, MedColors.light.seal);
    expect(find.text('/18'), findsOneWidget);
    expect(find.text('化验可算活动度'), findsOneWidget);
  });

  testWidgets('标题副标太长时省略,不撑破布局', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
      child: const Scaffold(body: strip),
    )));
    expect(tester.takeException(), isNull);
  });
}
```

新建 `test/long_text_row_test.dart`:

```dart
// 长文本行(brief §形:「长文本行(诊断、用药、检查):图标块 + 全宽一项一行,
// 不用两栏」)。两栏会把长句从中间切断 —— `s4` 故意放了 12 种药、6 个诊断来看这件事。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/widgets/gloss_tile.dart';
import 'package:mobile_flutter/widgets/long_text_row.dart';

void main() {
  const row = LongTextRow(
    category: GlossCategory.med, icon: Icons.medication_outlined,
    items: [
      (text: '氯吡格雷', meta: '75 mg 每日,至 2027 年 7 月'),
      (text: '二甲双胍缓释片', meta: '0.5 g 每日 2 次'),
    ],
  );

  testWidgets('一个图标块 + 每项各占一行', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: row)));
    expect(find.byType(GlossIconTile), findsOneWidget);
    expect(tester.widget<GlossIconTile>(find.byType(GlossIconTile)).category, GlossCategory.med);
    // 两项的 y 不同 = 各占一行(不是两栏并排)。
    expect(tester.getTopLeft(find.text('氯吡格雷')).dy,
        lessThan(tester.getTopLeft(find.text('二甲双胍缓释片')).dy));
  });

  testWidgets('正文左、说明右,说明不换行、正文可换行', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: row)));
    final meta = tester.widget<Text>(find.text('75 mg 每日,至 2027 年 7 月'));
    expect(meta.style!.fontSize, 13);
    expect(meta.style!.color, MedColors.light.ink3);
    expect(meta.softWrap, isFalse);                 // mockup `white-space:nowrap`
    expect(tester.widget<Text>(find.text('氯吡格雷')).style!.fontSize, 15);
  });

  testWidgets('小屏 2.0 字号不溢出 —— 说明挤不下时折到下一行', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
      child: const Scaffold(body: SingleChildScrollView(child: row)),
    )));
    expect(tester.takeException(), isNull);
  });
}
```

- [ ] **Step 2: 跑测试确认它红**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/record_book_strip_test.dart test/long_text_row_test.dart
```
预期:两个文件都编译失败。

- [ ] **Step 3: 写 `lib/widgets/record_book_strip.dart`**

```dart
import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// 病历本条(brief §形「病历本条」;mockup `.book`)。
///
/// **形状故意和主页那张成员主卡不一样**:主卡是整面渐变,这里是白卡 + 左侧一条
/// 34px 的渐变书脊。两个都是「入口」,但一个是「你是谁」,一个是「一本病程档案」——
/// 长得一样就分不出点进去会到哪。
class RecordBookStrip extends StatelessWidget {
  const RecordBookStrip({
    super.key,
    required this.title,
    required this.subtitle,
    this.bigNumber,
    this.bigNumberSuffix,
    this.bigNumberCaption,
    this.titleTrailing,
    this.logo,
    this.onTap,
  });

  final String title;
  final String subtitle;

  /// 右列那个大数。没有就整列不画 —— 不摆一个「—」占位。
  final String? bigNumber;
  final String? bigNumberSuffix;
  final String? bigNumberCaption;

  /// 标题后面那枚 pill(「示例」)。
  final Widget? titleTrailing;

  /// 书脊旁的真 logo,40px(brief §品牌)。Task 7 起由调用方传 `BrandLogo(size: 40)`。
  final Widget? logo;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(MedShape.radiusEntry),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(MedShape.radiusEntry),
            boxShadow: MedBrand.cardShadow,
          ),
          clipBehavior: Clip.antiAlias,
          child: IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const _Spine(),
              if (logo != null) Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Center(child: logo!),
              ) else const SizedBox(width: 12),
              Expanded(child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: MedType.body.copyWith(fontWeight: FontWeight.w600,
                            fontVariations: MedType.w600, height: 1.25))),
                      if (titleTrailing != null) ...[const SizedBox(width: 6), titleTrailing!],
                    ]),
                    Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: MedType.caption.copyWith(color: c.ink3, fontWeight: FontWeight.w400)),
                  ],
                ),
              )),
              if (bigNumber != null) Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 14, 0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text.rich(TextSpan(children: [
                      TextSpan(text: bigNumber),
                      if (bigNumberSuffix != null) TextSpan(text: bigNumberSuffix,
                        style: MedType.caption.copyWith(color: c.ink3, fontWeight: FontWeight.w400)),
                    ]), style: MedType.value.copyWith(fontSize: 22, fontWeight: FontWeight.w600,
                        fontVariations: MedType.w600, color: c.seal, height: 1)),
                    if (bigNumberCaption != null)
                      Text(bigNumberCaption!, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: MedType.caption.copyWith(color: c.ink3, fontSize: 11,
                            fontWeight: FontWeight.w400)),
                  ],
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// 34px 书脊:180° 两段渐变 + 细横纹(2px 实 / 9px 周期)。
///
/// 横纹用 `CustomPainter` 画,不用 `Image`、不加依赖 —— 就是一组等距的横条。
class _Spine extends StatelessWidget {
  const _Spine();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    key: const ValueKey('record-book-spine'),
    decoration: const BoxDecoration(gradient: LinearGradient(
      colors: MedBrand.spineColors,
      begin: Alignment.topCenter, end: Alignment.bottomCenter,
    )),
    child: CustomPaint(
      painter: _StripePainter(),
      child: const SizedBox(width: MedBrand.spineWidth, height: double.infinity),
    ),
  );
}

class _StripePainter extends CustomPainter {
  const _StripePainter();

  @override
  void paint(Canvas canvas, Size size) {
    // mockup:`repeating-linear-gradient(180deg, rgba(255,255,255,.14) 0 2px,
    // transparent 2px 9px)`,整层再乘 opacity .6。
    final paint = Paint()..color = MedBrand.spineStripe.withValues(
        alpha: MedBrand.spineStripe.a * 0.6);
    for (var y = 0.0; y < size.height; y += MedBrand.spineStripePeriod) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, MedBrand.spineStripeOn), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _StripePainter old) => false;
}
```

- [ ] **Step 4: 写 `lib/widgets/long_text_row.dart`**

```dart
import 'package:flutter/material.dart';

import '../design_tokens.dart';
import 'gloss_tile.dart';

/// 长文本行(brief §形:图标块 + 全宽一项一行,**不用两栏**;mockup `.blk`)。
///
/// 为什么不用两栏:`s4` 故意塞了 12 种药和 6 个诊断,两栏会把「氯吡格雷 75 mg
/// 每日,至 2027 年 7 月」这种句子从中间切断。一项一行,说明靠右且不换行,挤不下
/// 时整条折到下一行 —— 折行比截断好。
class LongTextRow extends StatelessWidget {
  const LongTextRow({
    super.key,
    required this.category,
    required this.icon,
    required this.items,
  });

  final GlossCategory category;
  final IconData icon;

  /// `text` 是内容(可换行),`meta` 是右边那截说明(不换行,可以整条折下去)。
  final List<({String text, String? meta})> items;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        GlossIconTile(icon: icon, category: category),
        const SizedBox(width: MedShape.s2),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              // Wrap:说明挤不下时整条掉到下一行,而不是把左边的内容压成一列字。
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.end,
                spacing: 10,
                runSpacing: 2,
                children: [
                  Text(item.text, style: MedType.body.copyWith(fontSize: 15, height: 1.5)),
                  if (item.meta != null)
                    Text(item.meta!, softWrap: false,
                      style: MedType.secondary.copyWith(color: c.ink3)),
                ],
              ),
            ),
        ])),
      ]),
    );
  }
}
```

- [ ] **Step 5: 跑测试确认绿**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/record_book_strip_test.dart test/long_text_row_test.dart
/Users/ziyuanguan/flutter/bin/flutter analyze
```

- [ ] **Step 6: Commit**

```bash
git add lib/widgets/record_book_strip.dart lib/widgets/long_text_row.dart \
        test/record_book_strip_test.dart test/long_text_row_test.dart
git commit -m "$(cat <<'MSG'
feat(ui): RecordBookStrip 与 LongTextRow 两个共用 widget

病历本条(mockup .book):白卡 + 左 34px 渐变书脊(180°,细横纹 2px/9px 用
CustomPainter 画,不加依赖)+ logo 位 + 右列大数。形状故意和主页成员主卡不一样 ——
一个是整面渐变,一个是白卡带书脊,长得一样就分不出点进去会到哪。

长文本行(mockup .blk):图标块 + 一项一行,说明用 Wrap 靠右,挤不下时整条折到
下一行而不是把内容截断。s4 那 12 种药 6 个诊断就是为看这件事放的。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
MSG
)"
```

---

### Task 6: 共用 widget —— `MedCard` 去边框、`MedPill` 换状态配色、新增 `MedBanner`、化验行 4px 左色条

**Files:**
- Modify: `lib/widgets/med_card.dart`(`MedCard` / `MedPill`,新增 `MedBanner` / `MedDemoPill`)
- Modify: `lib/widgets/lab_status.dart`(`labStatusColor` / `labStripeColor` / `labPill` / `LabLine`)
- Test: `test/med_card_test.dart`(改)、`test/lab_row_visual_test.dart`(新建)

**Interfaces:**
- Consumes: `MedBrand.cardShadow` / `barHigh` / `barLow` / `barNormal` / `barCritical` / `normalInk` / `pillHighInk` / `banner*` / `demo*` / `check*`、`MedShape.radiusCard` / `radiusBanner`、`GlossIconTile`。
- Produces:
  ```dart
  // MedCard:borderColor / borderWidth 两个参数**删掉**(brief §形:卡无边框)。
  class MedCard extends StatelessWidget {
    const MedCard({super.key, required this.child, this.perforated = false, this.background});
  }

  /// 横幅(mockup `.banner`)。蓝 / 琥珀两种,圆角 16,左边一枚光泽图标块。
  class MedBanner extends StatelessWidget {
    const MedBanner({super.key, required this.icon, required this.iconCategory,
        required this.title, this.subtitle, this.amber = false, this.onTap});
  }

  /// 「示例」pill(mockup `.pill.demo`):白底 + 虚线框 #B7C2CC + #657581 字。
  class MedDemoPill extends StatelessWidget { const MedDemoPill({super.key, required this.text}); }
  ```

- [ ] **Step 1: 写失败的测试**

改 `test/med_card_test.dart`,加三组:

```dart
  testWidgets('卡无边框、圆角 20、阴影 0 6px 18px', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: MedCard(child: Text('x')))));
    final d = tester.widget<Container>(find.descendant(
      of: find.byType(MedCard), matching: find.byType(Container)).first)
      .decoration! as BoxDecoration;
    expect(d.border, isNull, reason: 'brief §形:卡无边框');
    expect(d.borderRadius, BorderRadius.circular(MedShape.radiusCard));
    expect(d.boxShadow, MedBrand.cardShadow);
    expect(d.color, Colors.white);
  });

  testWidgets('MedBanner:蓝 #DDEDF8 / 文 #0E6285,琥珀 #FBE7D2 / 文 #9A4A12,圆角 16', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Column(children: [
      MedBanner(icon: Icons.cloud_outlined, iconCategory: GlossCategory.lab,
                title: '云端', subtitle: '已备份,刚刚'),
      MedBanner(icon: Icons.warning_amber_outlined, iconCategory: GlossCategory.med,
                title: '2 份还没核对', subtitle: '扫描件,识别出的字有几处不确定', amber: true),
    ]))));
    final decos = tester.widgetList<Container>(find.descendant(
      of: find.byType(MedBanner), matching: find.byType(Container)))
      .map((w) => w.decoration).whereType<BoxDecoration>()
      .where((d) => d.borderRadius == BorderRadius.circular(MedShape.radiusBanner)).toList();
    expect(decos.map((d) => d.color), [MedBrand.bannerBlue, MedBrand.bannerAmber]);
    expect(tester.widget<Text>(find.text('云端')).style!.color, MedBrand.bannerBlueInk);
    expect(tester.widget<Text>(find.text('2 份还没核对')).style!.color, MedBrand.bannerAmberInk);
    expect(tester.widget<Text>(find.text('已备份,刚刚')).style!.fontSize, 13);
    expect(find.byType(GlossIconTile), findsNWidgets(2));
  });

  testWidgets('MedDemoPill:白底 + 虚线框 + 灰字', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: MedDemoPill(text: '示例'))));
    expect(tester.widget<Text>(find.text('示例')).style!.color, MedBrand.demoInk);
    expect(find.byType(CustomPaint), findsWidgets);   // 虚线自己画
  });
```

新建 `test/lab_row_visual_test.dart`:

```dart
// 化验行(brief §形:「左 4px 色条 + 偏高/偏低标签 + 彩色数值,单位小字可折到
// 数值下一行」)。色条与 pill **同时**编码状态:色盲用户读 pill,正常视力扫色条。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/widgets/lab_status.dart';

void main() {
  testWidgets('四档左色条:偏高 #E07A25、偏低 #1F6FD2、正常 #2F8F5B、危急 #CF3A5A', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) { ctx = c; return const SizedBox(); })));
    expect(labStripeColor(ctx, LabStatus.high), MedBrand.barHigh);
    expect(labStripeColor(ctx, LabStatus.low), MedBrand.barLow);
    expect(labStripeColor(ctx, LabStatus.normal), MedBrand.barNormal);
    expect(labStripeColor(ctx, LabStatus.critical), MedBrand.barCritical);
  });

  testWidgets('数值色用 brief 的四档文字色', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) { ctx = c; return const SizedBox(); })));
    expect(labStatusColor(ctx, LabStatus.high), const Color(0xFFC25E18));
    expect(labStatusColor(ctx, LabStatus.low), const Color(0xFF1F5FB8));
    expect(labStatusColor(ctx, LabStatus.normal), MedBrand.normalInk);
    expect(labStatusColor(ctx, LabStatus.critical), const Color(0xFFBE123C));
  });

  testWidgets('左色条宽 4px(brief 说 4,旧代码是 3)', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: LabLine(
      name: '肌酐', value: '112', unit: 'μmol/L', flag: 'H', meta: '参考 57–97'))));
    final border = (tester.widget<Container>(find.descendant(
      of: find.byType(LabLine), matching: find.byType(Container)).first)
      .decoration! as BoxDecoration).border!;
    expect(border.left.width, 4);
    expect(border.left.color, MedBrand.barHigh);
  });

  testWidgets('偏高 pill 用 #9A4A12 压 #FDE3CC —— 不是数值那档橙', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: LabLine(
      name: '肌酐', value: '112', unit: 'μmol/L', flag: 'H'))));
    expect(tester.widget<Text>(find.text('偏高')).style!.color, MedBrand.pillHighInk);
  });

  testWidgets('小屏 2.0 字号:单位折到数值下一行,不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
      child: const Scaffold(body: SingleChildScrollView(child: LabLine(
        name: '估算肾小球滤过率', value: '63', unit: 'ml/min/1.73m²', flag: 'L',
        meta: '参考 >90'))),
    )));
    expect(tester.takeException(), isNull);
  });
}
```

> `LabLine` 的构造参数按 `lib/widgets/lab_status.dart:170` 现有签名写;`LabStatus.normal` 若现有枚举里没有,用它现有的那一档名字(读代码为准,**不要新增枚举值**)。

- [ ] **Step 2: 跑测试确认它红**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/med_card_test.dart test/lab_row_visual_test.dart
```

- [ ] **Step 3: 改 `lib/widgets/med_card.dart`**

1. `MedCard`:删 `borderColor` / `borderWidth` 两个参数,`decoration` 改成
   ```dart
   decoration: BoxDecoration(
     color: background ?? c.surface,
     borderRadius: BorderRadius.circular(MedShape.radiusCard),
     boxShadow: MedBrand.cardShadow,
   ),
   ```
   类文档里那段「层次靠边框不靠阴影」整段重写成:brief §形 反过来了 —— 卡无边框,靠 `0 6px 18px rgba(16,26,35,.08)` 分层。
   唯一的调用方 `lib/widgets/disease_profile_card.dart:243`(`borderColor: c.seal`)在 Task 12 改成 `RecordBookStrip`;**本 Task 先把那一行的参数删掉**让它编译过,视觉在 Task 12 补齐。
2. `MedPill`:构造不变,但加两个命名构造给状态用 —— 不要让每个调用方自己配色:
   ```dart
   /// 「示例」标(mockup `.pill.demo`):白底 + 虚线框,**不是**实心 pill。
   class MedDemoPill extends StatelessWidget { … CustomPaint 画 1px 虚线圆角框 … }
   ```
3. 新增 `MedBanner`:
   ```dart
   /// 横幅(mockup `.banner`):圆角 16,左边一枚光泽图标块,标题 16·600 用对应的
   /// 横幅文字色,副标 13 用 ink2,右边一枚 `›`(**只在 onTap 非空时画** —— 沿用
   /// PendingReviewBanner 既有那条规矩:没有去处就不画箭头)。
   class MedBanner extends StatelessWidget {
     const MedBanner({super.key, required this.icon, required this.iconCategory,
         required this.title, this.subtitle, this.amber = false, this.onTap});
     final IconData icon; final GlossCategory iconCategory;
     final String title; final String? subtitle;
     final bool amber; final VoidCallback? onTap;

     @override
     Widget build(BuildContext context) {
       final c = MedColors.of(context);
       final bg = amber ? MedBrand.bannerAmber : MedBrand.bannerBlue;
       final ink = amber ? MedBrand.bannerAmberInk : MedBrand.bannerBlueInk;
       return Material(type: MaterialType.transparency, child: InkWell(
         onTap: onTap,
         borderRadius: BorderRadius.circular(MedShape.radiusBanner),
         child: Container(
           decoration: BoxDecoration(color: bg,
               borderRadius: BorderRadius.circular(MedShape.radiusBanner)),
           padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
           child: Row(children: [
             GlossIconTile(icon: icon, category: iconCategory),
             const SizedBox(width: MedShape.s2),
             Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
               Text(title, style: MedType.body.copyWith(color: ink,
                   fontWeight: FontWeight.w600, fontVariations: MedType.w600)),
               if (subtitle != null) Text(subtitle!,
                   style: MedType.secondary.copyWith(color: c.ink2)),
             ])),
             if (onTap != null) Icon(Icons.chevron_right, size: 18, color: ink),
           ]),
         ),
       ));
     }
   }
   ```

- [ ] **Step 4: 改 `lib/widgets/lab_status.dart`**

- `labStripeColor`:四档返回 `MedBrand.barHigh` / `barLow` / `barNormal` / `barCritical`。
- `labStatusColor`:`normal` 那档从「继承正文」改成 `MedBrand.normalInk`;其余三档跟着 `MedColors` 已经改过的值走(`high` / `low` / `critical`),**代码不用动**。
- `labPill`(`lab_status.dart:109`):`high` 的 `foreground` 从 `c.high` 换成 `MedBrand.pillHighInk`;`unknown`(即「看一眼」那档,`lab_status.dart:121`)背景换 `MedBrand.checkWash`、前景换 `MedBrand.checkInk`;若有 `normal` 档,背景 `Colors.transparent`、前景 `MedBrand.normalInk`。
- `LabLine`(`lab_status.dart:232`):`BorderSide(color: …, width: 3)` → `width: 4`。
- `LabLine` 里 `lab_status.dart:218` 的 `MedPill(text: '需核对', foreground: c.sealInk, background: c.sealWash)` → `foreground: MedBrand.checkInk, background: MedBrand.checkWash`。**字符串 `'需核对'` 不动。**
- 数值 + 单位那一段(`lab_status.dart:246`–`264`):数值用 `MedType.value`,单位用 `MedType.caption.copyWith(fontSize: 12, color: c.ink3, fontWeight: FontWeight.w400)`,两者放进一个 `Wrap(alignment: WrapAlignment.end, spacing: 4)` —— 这就是 brief 的「单位小字可折到数值下一行」。
- `MedColors.normalIsUncolored` 那条静态说明**删掉**:brief 给了正常的文字色和色条,旧规矩已经被取代。把它换成一行注释指向 Stage 3 brief。

- [ ] **Step 5: 跑测试确认绿**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/med_card_test.dart test/lab_row_visual_test.dart \
  test/report_content_lab_table_overflow_test.dart test/lab_line_row_overflow_test.dart
/Users/ziyuanguan/flutter/bin/flutter analyze
```
两个既有的溢出测试必须仍然绿 —— 它们守的就是这一行在极端内容下不炸。

- [ ] **Step 6: Commit**

```bash
git add lib/widgets/med_card.dart lib/widgets/lab_status.dart lib/widgets/disease_profile_card.dart \
        test/med_card_test.dart test/lab_row_visual_test.dart
git commit -m "$(cat <<'MSG'
feat(ui): 卡去边框换阴影、新增 MedBanner、化验行左色条加到 4px

brief §形 把分层规则整个翻过来了:旧规范是「靠边框不靠阴影」,新的是「卡无边框,
0 6px 18px rgba(16,26,35,.08)」。MedCard 的 borderColor/borderWidth 两个参数删掉。

新增 MedBanner(mockup .banner):蓝 #DDEDF8/#0E6285、琥珀 #FBE7D2/#9A4A12,圆角
16,左边一枚光泽图标块,箭头只在有去处时画(沿用 PendingReviewBanner 的老规矩)。

化验行:左色条 3px → 4px,四档色换成 brief 的值;正常从「不上色」改成 #227A4C +
色条 #2F8F5B —— brief 给了这两个值,旧的 normalIsUncolored 规矩被取代。偏高 pill
用 #9A4A12 压 #FDE3CC(比数值那档橙深一档,压浅底才够对比度)。单位小字改用 Wrap,
挤不下时折到数值下一行。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
MSG
)"
```

---

### Task 7: 品牌 —— 真 logo 进包 + `BrandLogo` widget + 四处摆位

**Files:**
- Create: `assets/brand/logo112.png`(从 mockup 目录拷)
- Create: `lib/widgets/brand_logo.dart`
- Modify: `pubspec.yaml`(`assets:` 段)
- Modify: `lib/widgets/record_book_strip.dart`(默认 `logo` 传 `BrandLogo(size: 40)`)
- Test: `test/brand_logo_test.dart`(新建)

**Interfaces:**
- Produces:
  ```dart
  /// 真 logo(毛笔「医」)。brief §品牌:圆角 22%,四处摆位 30 / 40 / 30 / 104。
  class BrandLogo extends StatelessWidget {
    const BrandLogo({super.key, this.size = 30});
    static const String assetPath = 'assets/brand/logo112.png';
    static const double topBar = 30;      // 主页顶栏 / 病程档案页头
    static const double bookSpine = 40;   // 病历本条书脊旁
    static const double splash = 104;     // 首启场景中央
  }
  ```

- [ ] **Step 1: 写失败的测试**

新建 `test/brand_logo_test.dart`:

```dart
// 品牌资源闸。brief §品牌 规定 logo 出现在四处、圆角 22%。
//
// 「用到没用到」的断言在 test/stage3_screens_test.dart(Task 16)—— 那里屏都做完了。
// 这里只守资源本身:文件在、声明了、圆角对、四档尺寸是 brief 的数。
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/widgets/brand_logo.dart';

void main() {
  test('logo 文件在,且声明进了 pubspec', () {
    expect(File(BrandLogo.assetPath).existsSync(), isTrue);
    expect(File('pubspec.yaml').readAsStringSync(), contains(BrandLogo.assetPath));
  });

  test('四档尺寸就是 brief 的数', () {
    expect(BrandLogo.topBar, 30);
    expect(BrandLogo.bookSpine, 40);
    expect(BrandLogo.splash, 104);
  });

  testWidgets('圆角 22%,不是圆形也不是直角', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(
      body: Center(child: BrandLogo(size: 100)))));
    final clip = tester.widget<ClipRRect>(find.descendant(
      of: find.byType(BrandLogo), matching: find.byType(ClipRRect)));
    expect(clip.borderRadius, BorderRadius.circular(22));   // 22% × 100
    expect(tester.getSize(find.byType(BrandLogo)), const Size(100, 100));
  });

  testWidgets('默认 30px(主页顶栏那一档)', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Center(child: BrandLogo()))));
    expect(tester.getSize(find.byType(BrandLogo)), const Size(30, 30));
  });
}
```

- [ ] **Step 2: 跑测试确认它红**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/brand_logo_test.dart
```

- [ ] **Step 3: 拷资源 + 声明**

```bash
mkdir -p assets/brand
cp '/private/tmp/claude-501/-Volumes-extraSupply-Projects-Medme/6fb778b0-c9b5-404d-ae65-0c0319ec1c97/scratchpad/mockups/logo112.png' \
   assets/brand/logo112.png
ls -l assets/brand/logo112.png   # 应该是 12310 字节
```

`pubspec.yaml` 的 `assets:` 段改成:

```yaml
  assets:
    - assets/icon/app_icon.png
    # 真 logo(毛笔「医」)。brief §品牌:出现在主页顶栏 30、病历本书脊旁 40、
    # 病程档案页头 30、首启场景中央 104,圆角一律 22%。见 lib/widgets/brand_logo.dart。
    - assets/brand/logo112.png
```

- [ ] **Step 4: 写 `lib/widgets/brand_logo.dart`**

```dart
import 'package:flutter/material.dart';

/// 真 logo(毛笔「医」)。**brief §品牌 只允许它出现在四处**:
///
///  · 主页顶栏 [topBar] 30 —— `archive_screen.dart` 的标题行;
///  · 病历本条书脊旁 [bookSpine] 40 —— `record_book_strip.dart`;
///  · 病程档案页头 [topBar] 30 —— `disease_profile_screen.dart`;
///  · 首启场景中央 [splash] 104 —— `first_run_consent.dart`。
///
/// 别处想放品牌,用品牌渐变(`BrandGradientBox`),不要再摆一个 logo —— 到处都是
/// 的标志等于没有标志。
///
/// **不是 app 图标**:`assets/icon/app_icon.png` 是启动/桌面图标,那一张继续用在
/// `main.dart` 的启动画面上,两者不互换。
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.size = topBar});

  static const String assetPath = 'assets/brand/logo112.png';

  static const double topBar = 30;
  static const double bookSpine = 40;
  static const double splash = 104;

  final double size;

  @override
  Widget build(BuildContext context) => ClipRRect(
    // brief §品牌:圆角 22%(相对边长),不是固定 px —— 104 那档要跟着大。
    borderRadius: BorderRadius.circular(size * 0.22),
    child: Image.asset(assetPath, width: size, height: size, fit: BoxFit.cover),
  );
}
```

- [ ] **Step 5: 把它接进 `RecordBookStrip`**

`lib/widgets/record_book_strip.dart`:`logo` 参数的默认值改成 `const BrandLogo(size: BrandLogo.bookSpine)` —— 调用方不用每次传。类文档里那句「Task 7 起由调用方传」删掉。
`test/record_book_strip_test.dart` 加一条:`expect(find.byType(BrandLogo), findsOneWidget);`

- [ ] **Step 6: 跑测试确认绿**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/brand_logo_test.dart test/record_book_strip_test.dart
/Users/ziyuanguan/flutter/bin/flutter analyze
```

- [ ] **Step 7: Commit**

```bash
git add assets/brand/logo112.png pubspec.yaml lib/widgets/brand_logo.dart \
        lib/widgets/record_book_strip.dart test/brand_logo_test.dart test/record_book_strip_test.dart
git commit -m "$(cat <<'MSG'
feat(ui): 真 logo 进包,BrandLogo 只许出现在 brief 规定的四处

毛笔「医」字 logo 从 mockup 目录进 assets/brand/。BrandLogo 提供三档尺寸常量
(顶栏 30 / 书脊旁 40 / 首启 104),圆角按 22% 边长算 —— 固定 px 在 104 那档会
看着不对。

类文档写死了四个允许的位置,别处要品牌用渐变不要再摆 logo。它也不是 app 图标:
assets/icon/app_icon.png 继续管启动画面,两张不互换。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
MSG
)"
```

---

### Task 8: 屏 —— 「病历」主页(mockup `s1`)+ 底栏

**Files:**
- Modify: `lib/screens/archive_screen.dart`(`HomeTiles`:892、`_Tile`:928、`PendingReviewBanner`:984、`MonthHeader`:1042、`_TimelineItem`:491、`_SubDocList`:625、`_PendingCard`:717、`_MismatchBanner`:838)
- Modify: `lib/main.dart`(底栏 `NavigationBar` 的包装,685–695 行附近)
- Test: `test/archive_visual_test.dart`(新建);`test/archive_header_test.dart`(既有,必须仍绿)

**mockup 模板:** `s1`。**渐变预算:** `hero: 1, entry: 1, button: 0`。

**Interfaces:**
- Consumes: `HeroCard`(经 `IdentityHeroCard`)、`PrimaryEntryTile`、`GlossIconTile`、`MedBanner`、`MedCard`、`MedDemoPill`、`BrandLogo`、`pumpStage3` / `expectGradientBudget` / `expectNoGradientInsideCards` / `expectNoOverflowAtBothSizes`。
- Produces:`HomeTiles` / `PendingReviewBanner` / `MonthHeader` 的**类名与构造参数一个不动**,只换内部实现。

- [ ] **Step 1: 写失败的测试**

新建 `test/archive_visual_test.dart`:

```dart
// 「病历」主页的视觉验收(mockup s1)。**只测视觉,不测行为** —— 行为归
// archive_header_test.dart / mobile_ia_test.dart 管。
//
// 这一屏是唯一同时有主卡和主入口块的屏,所以渐变预算 hero:1 entry:1。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/screens/archive_screen.dart';
import 'package:mobile_flutter/widgets/brand_gradient.dart';
import 'package:mobile_flutter/widgets/gloss_tile.dart';
import 'package:mobile_flutter/widgets/identity_hero_card.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'stage3_visual_helpers.dart';

// 整屏 pump 要 FFI,测试环境没有原生库 —— 和 HomeTiles / ForDoctorActions 一样,
// 把这一屏的纯 widget 部件各自 pump(既有先例见 for_doctor_screen.dart:210 注释)。
Widget _homeBlock() => Scaffold(
  backgroundColor: MedColors.light.paper,
  body: ListView(padding: const EdgeInsets.all(MedShape.s3), children: [
    IdentityHeroCard(name: '张建国', gender: '男', age: '61 岁', recordCount: 31,
        recentVisitDate: '2026-07-20', onSwitchMember: () {}),
    const SizedBox(height: MedShape.s2),
    HomeTiles(onAdd: () {}, onForDoctor: () {}),
    const SizedBox(height: MedShape.s2),
    PendingReviewBanner(count: 2, onTap: () {}),
    MonthHeader(label: '2026 年 8 月', onSearch: () {}),
  ]),
);

void main() {
  testWidgets('渐变预算:一张主卡、一个主入口块、零个主按钮', (tester) async {
    await pumpStage3(tester, _homeBlock());
    expectGradientBudget(hero: 1, entry: 1);
    expectNoGradientInsideCards();
  });

  testWidgets('「添加」是渐变入口块,「给医生看」是白块 + 门诊光泽图标', (tester) async {
    await pumpStage3(tester, _homeBlock());
    expect(find.descendant(of: find.byType(PrimaryEntryTile), matching: find.text('添加')),
        findsOneWidget);
    final forDoctorTile = find.ancestor(of: find.text('给医生看'), matching: find.byType(GlossIconTile));
    expect(find.descendant(of: find.byType(HomeTiles), matching: find.byType(GlossIconTile)),
        findsOneWidget);
    expect(tester.widgetList<GlossIconTile>(find.descendant(
      of: find.byType(HomeTiles), matching: find.byType(GlossIconTile))).single.category,
      GlossCategory.clinic);
  });

  testWidgets('「还没核对」是琥珀横幅 + 用药图标块', (tester) async {
    await pumpStage3(tester, _homeBlock());
    expect(tester.widget<Text>(find.text('2 份还没核对')).style!.color, MedBrand.bannerAmberInk);
    expect(tester.widgetList<GlossIconTile>(find.descendant(
      of: find.byType(PendingReviewBanner), matching: find.byType(GlossIconTile))).single.category,
      GlossCategory.med);
  });

  testWidgets('月份标题 15 号 ink2,「找一找」14·500 seal', (tester) async {
    await pumpStage3(tester, _homeBlock());
    expect(tester.widget<Text>(find.text('2026 年 8 月')).style!.fontSize, 15);
    expect(tester.widget<Text>(find.text('2026 年 8 月')).style!.color, MedColors.light.ink2);
    final search = tester.widget<Text>(find.text('找一找'));
    expect(search.style!.fontSize, 14);
    expect(search.style!.color, MedColors.light.seal);
  });

  testWidgets('底色是实心 #F1F4F8,没有第二个渐变面', (tester) async {
    await pumpStage3(tester, _homeBlock());
    expect(tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        const Color(0xFFF1F4F8));
    expect(find.byType(BrandGradientBox), findsNWidgets(2));  // 主卡 + 主入口块
  });

  testWidgets('400×800 与 360×640 × 1.0/2.0 字号全部不溢出', (tester) async {
    await expectNoOverflowAtBothSizes(tester, _homeBlock());
  });
}
```

- [ ] **Step 2: 跑测试确认它红**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/archive_visual_test.dart
```
预期:渐变预算那条红(`PrimaryEntryTile` 是 0),光泽图标块那几条红。

- [ ] **Step 3: 改 `HomeTiles` / `_Tile`(`archive_screen.dart:892`)**

```dart
class HomeTiles extends StatelessWidget {
  const HomeTiles({super.key, this.onAdd, this.onForDoctor});

  final VoidCallback? onAdd;
  final VoidCallback? onForDoctor;

  @override
  Widget build(BuildContext context) => Row(children: [
    // mockup `s1` 的 `.qa.pri`:主入口块,整块品牌渐变。**一屏只此一个。**
    Expanded(child: PrimaryEntryTile(
      icon: Icons.add_a_photo_outlined, label: '添加', onTap: onAdd)),
    const SizedBox(width: 14),   // mockup `.tiles{gap:14px}`
    // mockup 的 `.qa`:白块 + 一枚光泽图标块。
    Expanded(child: _Tile(
      icon: Icons.assignment_outlined, category: GlossCategory.clinic,
      label: '给医生看', onTap: onForDoctor)),
  ]);
}

class _Tile extends StatelessWidget {
  const _Tile({required this.icon, required this.category, required this.label, this.onTap});

  final IconData icon;
  final GlossCategory category;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    borderRadius: BorderRadius.circular(MedShape.radiusEntry),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(MedShape.radiusEntry),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 11),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(MedShape.radiusEntry),
          boxShadow: MedBrand.cardShadow,
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          GlossIconTile(icon: icon, category: category),
          const SizedBox(height: 6),
          Text(label, textAlign: TextAlign.center,
            style: MedType.body.copyWith(fontWeight: FontWeight.w500,
                fontVariations: MedType.w500)),
        ]),
      ),
    ),
  );
}
```

- [ ] **Step 4: 改 `PendingReviewBanner`(`archive_screen.dart:984`)**

整个 `build()` 换成一行(`count == 0` 那条早退保留):

```dart
    if (count == 0) return const SizedBox.shrink();
    return MedBanner(
      icon: Icons.warning_amber_outlined,
      iconCategory: GlossCategory.med,
      amber: true,
      title: '$count 份还没核对',
      subtitle: '扫描件,识别出的字有几处不确定',
      onTap: onTap,
    );
```
**两个字符串一个字不动。**

- [ ] **Step 5: 改 `MonthHeader`(`archive_screen.dart:1042`)与文档行**

`MonthHeader`:标题 `MedType.body.copyWith(fontSize: 15, color: c.ink2)`;「找一找」`MedType.secondary.copyWith(fontSize: 14, color: c.seal, fontWeight: FontWeight.w500, fontVariations: MedType.w500)`;外层 padding 改成 `EdgeInsets.fromLTRB(4, MedShape.s4, 4, MedShape.s1)`(mockup `.sec{padding:0 4px}`)。

`_TimelineItem`(`archive_screen.dart:491`)里 `archive_screen.dart:545` 那个 `Container`(`c.sealWash` 底 + `Icon(icon, size: 20, color: c.seal)`)换成 `GlossIconTile(icon: icon, category: <按类>)`。类别映射写成一个文件内的小函数,**不新建文件**:

```dart
/// 文档类型 → 光泽图标块的类别色(brief §色 的类别色表)。
GlossCategory _categoryOf(DocKind kind) => switch (kind) {
  DocKind.lab => GlossCategory.lab,
  DocKind.clinic || DocKind.discharge => GlossCategory.clinic,
  DocKind.imaging => GlossCategory.imaging,
  DocKind.prescription => GlossCategory.med,
  DocKind.note => GlossCategory.note,
  _ => GlossCategory.neutral,
};
```
> `DocKind` 的真实枚举名与成员**读 `lib/doc_labels.dart` 为准**;这里的 `switch` 必须覆盖它现有的每一档,不要新增。
> 「处理中」那一行(mockup `.doc.busy`,现有代码里对应正在识别的那条)用 `GlossCategory.busy`,标题色 `c.ink3`、字重 400。

行内字号:标题 `MedType.body.copyWith(fontWeight: FontWeight.w500, fontVariations: MedType.w500, height: 1.3)`,`maxLines: 2`;日期与摘要 `MedType.secondary.copyWith(color: c.ink3)`;分隔线 `c.line2`。

`_PendingCard`(717)与 `_MismatchBanner`(838)里剩余的 `sealWash` 图标底一并换成对应类别的 `GlossIconTile`。

- [ ] **Step 6: 底栏(`lib/main.dart:685`)**

`DecoratedBox` 的装饰换成 `BoxDecoration(color: Colors.white, boxShadow: MedBrand.navShadow)`(mockup `.nav`);`NavigationBar` 的 `indicatorColor` 已在 Task 1 设成透明;选中/未选中色靠 `NavigationBarThemeData` 的 `iconTheme` 补:

```dart
        iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
          size: 22,
          color: states.contains(WidgetState.selected)
              ? MedColors.light.seal            // mockup `.nav .on`
              : const Color(0xFF8A98A4),        // mockup `.nav span`
        )),
```
(这段在 `theme.dart` 里,属于令牌文件,允许写裸色值;或者用 `MedBrand.tile(GlossCategory.neutral).$1` 取同一个 `#8A98A4` —— **优先后者**,少一个裸色值。)

- [ ] **Step 7: 跑测试确认绿**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/archive_visual_test.dart test/archive_header_test.dart \
  test/mobile_ia_test.dart test/no_raw_colors_test.dart
/Users/ziyuanguan/flutter/bin/flutter analyze
```

- [ ] **Step 8: Commit**

```bash
git add lib/screens/archive_screen.dart lib/main.dart test/archive_visual_test.dart
git commit -m "$(cat <<'MSG'
feat(ui): 「病历」主页落 mockup s1 的视觉

主卡走 HeroCard;「添加」变成整块品牌渐变的主入口块,「给医生看」是白块 + 门诊色
光泽图标块 —— 这一屏是全 app 唯一同时有主卡和主入口块的屏,测试按预算表钉死
hero:1 entry:1。

「还没核对」换成琥珀横幅(MedBanner),文档行的图标底从 sealWash 方块换成按类别
上色的光泽图标块,「识别中」那行用 busy 灰。底栏换成 mockup 的白底 + 向上阴影。

一个字符串没改;archive_header_test / mobile_ia_test 原样绿。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
MSG
)"
```

---

### Task 9: 屏 —— 「趋势」(mockup `s2`):病历本条 + 趋势行 + 「看懂」蓝横幅

**Files:**
- Modify: `lib/screens/trends_screen.dart`(`KeyLabsSnapshot`:1081、`RecentVisitsCard`:1151、`_VisitCard`:1213、`_SectionHeader`:1323、`UnderstandBanner`:1364、`_PanelChip`:621、`_PanelChipsRow`:535、`RecordEntryCard`:1392、`SeriesCard`:668)
- Modify: `lib/widgets/disease_profile_card.dart`(`_EntryCard`:213 → `RecordBookStrip`)
- Test: `test/trends_visual_test.dart`(新建);`test/trends_screen_test.dart`、`test/disease_profile_card_test.dart`(既有,必须仍绿)

**mockup 模板:** `s2`。**渐变预算:** `hero: 0, entry: 0, button: 0` —— 这一屏一个品牌渐变面都没有,顶上那条是**病历本条**(白卡 + 渐变书脊)。

**Interfaces:**
- Consumes: `RecordBookStrip`、`MedCard`、`MedBanner`、`MedPill` / `MedDemoPill`、`GlossIconTile`、`LabLine`、`stage3_visual_helpers.dart`。

- [ ] **Step 1: 写失败的测试**

新建 `test/trends_visual_test.dart`:

```dart
// 「趋势」页的视觉验收(mockup s2)。这一屏**一个品牌渐变面都没有** —— 顶上那条
// 是病历本条(白卡 + 34px 渐变书脊),形状故意和主页的成员主卡不一样。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/screens/trends_screen.dart';
import 'package:mobile_flutter/widgets/brand_gradient.dart';
import 'package:mobile_flutter/widgets/record_book_strip.dart';
import 'stage3_visual_helpers.dart';

void main() {
  testWidgets('零个渐变面;病程档案入口是病历本条', (tester) async {
    await pumpStage3(tester, const Scaffold(body: SingleChildScrollView(child: Column(children: [
      RecordBookStrip(title: '病程档案 · 狼疮', subtitle: '2 项该复查 · 复诊 8 月 12 日',
          bigNumber: '4', bigNumberSuffix: '/18', bigNumberCaption: '化验可算活动度'),
    ]))));
    expectGradientBudget();                      // 三个全 0
    expect(find.byType(BrandGradientBox), findsNothing);
    expect(find.byType(RecordBookStrip), findsOneWidget);
  });

  testWidgets('「看懂」是蓝横幅:底 #DDEDF8、小标题 #0E6285', (tester) async {
    await pumpStage3(tester, const Scaffold(body: UnderstandBanner(
      text: '肌酐四年缓慢上升,eGFR 渐降。', source: '该报告「提示」一栏')));
    final d = tester.widgetList<Container>(find.descendant(
      of: find.byType(UnderstandBanner), matching: find.byType(Container)))
      .map((w) => w.decoration).whereType<BoxDecoration>().first;
    expect(d.color, MedBrand.bannerBlue);
    expect(d.borderRadius, BorderRadius.circular(MedShape.radiusBanner));
  });

  testWidgets('面板 chip:白底药丸 + 小阴影,选中是 seal 实底白字', (tester) async {
    await pumpStage3(tester, const Scaffold(body: _ChipsProbe()));
    // 未选中
    final off = tester.widgetList<Container>(find.byType(Container))
      .map((w) => w.decoration).whereType<BoxDecoration>()
      .firstWhere((d) => d.color == Colors.white && d.boxShadow == MedBrand.chipShadow);
    expect(off.borderRadius, BorderRadius.circular(MedShape.radiusPill));
    // 选中
    expect(tester.widgetList<Container>(find.byType(Container))
      .map((w) => w.decoration).whereType<BoxDecoration>()
      .any((d) => d.color == MedColors.light.seal), isTrue);
  });

  testWidgets('两个尺寸 × 两档字号不溢出', (tester) async {
    await expectNoOverflowAtBothSizes(tester, const Scaffold(body: SingleChildScrollView(
      child: RecordBookStrip(title: '病程档案 · 狼疮', subtitle: '2 项该复查 · 复诊 8 月 12 日',
          bigNumber: '4', bigNumberSuffix: '/18', bigNumberCaption: '化验可算活动度'))));
  });
}
```

> `_ChipsProbe` 是这个测试文件里自己写的一个小 widget,直接放两枚 `_PanelChip`(若它是私有的,就把 `_PanelChipsRow` 拿来 pump —— 读 `trends_screen.dart:535` 的构造参数为准)。`UnderstandBanner` 的构造参数同样读 `trends_screen.dart:1364`,**不要改它的签名**。

- [ ] **Step 2: 跑测试确认它红**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/trends_visual_test.dart
```

- [ ] **Step 3: 病程档案入口换成病历本条**

`lib/widgets/disease_profile_card.dart:213` 的 `_EntryCard`:把 `MedCard(borderColor: c.seal, …)` 整个换成 `RecordBookStrip`。映射(**字符串一个不动**,只换容器):
- `title` ← 原 `title`;`subtitle` ← 原 `subtitle`;
- `titleTrailing` ← 原来那枚「示例」pill(若有)→ `MedDemoPill`;
- `bigNumber` / `bigNumberSuffix` / `bigNumberCaption` ← 原 `row` 里那条摘要拆出来的数(**若现有 `row` 不是「数 + 说明」的形状,就整条传 `subtitle`,右列不画** —— 不编一个数出来);
- `onTap` ← 原 `onTap`;原 `action`(「开启」按钮)与 `chevron` 保持原逻辑,放在 `RecordBookStrip` 下面独立一行,**不塞进条里**。
- 删掉 `ProfileIconTile` 在这里的用法(书脊 + logo 取代了它)。

- [ ] **Step 4: 趋势行与化验行**

`KeyLabsSnapshot`(1081):`MedCard` 内的 `Divider(color: c.line2)` 保留;`LabLine` 已在 Task 6 改好,这里只把外层 `Padding(horizontal: MedShape.s2)` 改成 `EdgeInsets.zero` —— 4px 色条要贴着卡边(mockup `.lr{border-left:4px}` 就在卡的边上)。

`SeriesCard`(668)按 mockup `.tr` 重排为三列:名称(含 pill)| 78×24 小折线 | 数值 + `▾`;第二行历年数值 `MedType.caption.copyWith(color: c.ink3, fontFeatures: MedType.tabular, fontWeight: FontWeight.w400)`,`gridColumn` 跨满。
**折线本身不画** —— brief 说「Stage 2 画真折线,Stage 3 只样式化这一行」。这一版放 `SizedBox(width: 78, height: 24)` 占位,并在 `SeriesCard` 里留一句注释:
```dart
// 78×24 的小折线占位。**Stage 3 只管这一行的样式**;真折线(数据 → 路径)是
// Stage 2 的活,到时候把这个 SizedBox 换成 TrendChart 的 mini 版即可,行的布局不用动。
```
展开区(mockup `.xp`)底色 `MedBrand.expandedChartBg`、左色条同本行状态色、高度 82。

`_VisitCard`(1213)与 `RecentVisitsCard`(1151):图标底换 `GlossIconTile(category: _categoryOf(...))`(与 Task 8 同一映射,**从 `archive_screen.dart` 导出那个函数复用,不要复制一份** —— 把它提到 `lib/doc_labels.dart` 里,那是它本来该在的地方)。

`UnderstandBanner`(1364):底 `MedBrand.bannerBlue`、圆角 `MedShape.radiusBanner`、小标题 `MedType.caption.copyWith(color: MedBrand.bannerBlueInk, fontWeight: FontWeight.w400)`、正文 `MedType.body.copyWith(fontSize: 15, height: 1.55)`、出处 `MedType.caption.copyWith(color: c.ink2, fontWeight: FontWeight.w400)`。

`_PanelChip`(621)/`_PanelChipsRow`(535):药丸 `MedShape.radiusPill`,未选中 = 白底 + `MedBrand.chipShadow` + `MedType.secondary.copyWith(fontSize: 14, color: c.ink2)`,选中 = `c.seal` 底 + 白字。

`_SectionHeader`(1323):与 `MonthHeader` 同一档 —— 15 号 `ink2` 左、14·500 `seal` 右,padding `0 4`。

`RecordEntryCard`(1392):「记录一下」那颗是 mockup 的 `.btn.ghost` —— 透明底、`c.seal` 字、字重 400、无阴影。**不要**用 `MedPrimaryButton`(那会让这一屏的渐变预算变成 1)。

- [ ] **Step 5: 跑测试确认绿**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/trends_visual_test.dart test/trends_screen_test.dart \
  test/disease_profile_card_test.dart test/visit_card_dedup_test.dart test/no_raw_colors_test.dart
/Users/ziyuanguan/flutter/bin/flutter analyze
```

- [ ] **Step 6: Commit**

```bash
git add lib/screens/trends_screen.dart lib/widgets/disease_profile_card.dart lib/doc_labels.dart \
        test/trends_visual_test.dart
git commit -m "$(cat <<'MSG'
feat(ui): 「趋势」页落 mockup s2 —— 病历本条、趋势行、蓝色「看懂」横幅

病程档案入口从「主色描边的卡」换成病历本条(白卡 + 34px 渐变书脊 + logo + 右列
大数)。这一屏的渐变预算是 0/0/0:书脊不是卡面,测试按这个数钉死。

趋势行按 mockup .tr 重排成 名称|78×24 小折线|数值 三列,折线先放占位 —— brief
明说 Stage 3 只管这一行的样式,真折线是 Stage 2;到时换掉占位即可,布局不用动。

「看懂」换蓝横幅,面板 chip 换白底药丸 + 小阴影,「记录一下」保持 ghost 按钮(用
主按钮会让这屏多出一处品牌渐变)。文档类型→类别色的映射提到 doc_labels.dart,
和主页共用一份。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
MSG
)"
```

---

### Task 10: 屏 —— 「给医生看」(`s4`)+「一份病历」(`s8`)+ 急救卡

**Files:**
- Modify: `lib/screens/for_doctor_screen.dart`(`_ForDoctorScreenState`:43、`ForDoctorActions`:210)
- Modify: `lib/screens/document_detail.dart`(`_DetailBody`:235)
- Modify: `lib/screens/emergency_card_screen.dart`(`_BloodTypeCard`:227、`_AllergySection`:275、`_MedsSection`:329、`_ConditionSection`:373、`_ExtrasSection`:421、`_SourceRow`:601)
- Test: `test/for_doctor_visual_test.dart`(新建);`test/for_doctor_screen_test.dart`、`test/report_content_test.dart`、`test/emergency_card_refresh_test.dart`(既有,必须仍绿)

**mockup 模板:** `s4`、`s8`。**渐变预算:** `s4` = `hero:0, entry:0, button:1`(「出码给医生看」,**固定底部**);`s8` = 全 0。

- [ ] **Step 1: 写失败的测试**

新建 `test/for_doctor_visual_test.dart`:

```dart
// 「给医生看」(s4):长清单那一屏。brief §品牌 最后一条:「出码给医生看」按钮
// **固定底部**,内容再长也在。s4 模板里那句 `.fixed` 小字就是在说这件事。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/screens/for_doctor_screen.dart';
import 'package:mobile_flutter/widgets/brand_gradient.dart';
import 'package:mobile_flutter/widgets/gloss_tile.dart';
import 'package:mobile_flutter/widgets/long_text_row.dart';
import 'stage3_visual_helpers.dart';

void main() {
  testWidgets('渐变预算:零主卡、零入口块、一颗主按钮', (tester) async {
    await pumpStage3(tester, Scaffold(
      body: const SingleChildScrollView(child: ForDoctorActions()),
      bottomNavigationBar: const SafeArea(child: Padding(
        padding: EdgeInsets.all(MedShape.s3),
        child: MedPrimaryButton(label: '出码给医生看', icon: Icons.qr_code_2_outlined))),
    ));
    expectGradientBudget(button: 1);
    expectNoGradientInsideCards();
  });

  testWidgets('主按钮在 bottomNavigationBar 里 —— 滚动不会把它带走', (tester) async {
    await pumpStage3(tester, Scaffold(
      body: const SingleChildScrollView(child: SizedBox(height: 3000)),
      bottomNavigationBar: const SafeArea(child: Padding(
        padding: EdgeInsets.all(MedShape.s3),
        child: MedPrimaryButton(label: '出码给医生看'))),
    ));
    final before = tester.getTopLeft(find.byType(MedPrimaryButton));
    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -1200));
    await tester.pump();
    expect(tester.getTopLeft(find.byType(MedPrimaryButton)), before, reason: '按钮跟着滚了');
  });

  testWidgets('三条入口:导出=中性块、急救卡=警示块、代拍=蓝横幅', (tester) async {
    await pumpStage3(tester, const Scaffold(body: SingleChildScrollView(child: ForDoctorActions())));
    final cats = tester.widgetList<GlossIconTile>(find.byType(GlossIconTile))
        .map((w) => w.category).toList();
    expect(cats, containsAll(<GlossCategory>[GlossCategory.neutral, GlossCategory.alert]));
    // 文案一个字不动 —— 这三句是 Stage 1 定死的。
    expect(find.text('导出文件'), findsOneWidget);
    expect(find.text('急救卡'), findsOneWidget);
    expect(find.text('我是医生,替病人代拍'), findsOneWidget);
    expect(find.text('病人不用装 App、不用账号'), findsOneWidget);
  });

  testWidgets('长清单用 LongTextRow,一项一行,12 项不溢出', (tester) async {
    const meds = LongTextRow(category: GlossCategory.med, icon: Icons.medication_outlined,
      items: [
        (text: '阿司匹林肠溶片', meta: '100 mg 每日'),
        (text: '氯吡格雷', meta: '75 mg 每日,至 2027 年 7 月'),
        (text: '阿托伐他汀', meta: '20 mg 每晚'),
        (text: '氨氯地平', meta: '5 mg 早晚'),
        (text: '美托洛尔', meta: '剂量未记'),
        (text: '二甲双胍缓释片', meta: '0.5 g 每日 2 次'),
        (text: '达格列净', meta: '10 mg 每日'),
        (text: '非布司他', meta: '40 mg 每日'),
        (text: '泼尼松', meta: '7.5 mg 每日'),
        (text: '羟氯喹', meta: '400 mg 每日'),
        (text: '吗替麦考酚酯', meta: '1.5 g 每日'),
        (text: '贝利尤单抗', meta: '每 4 周'),
      ]);
    await expectNoOverflowAtBothSizes(tester,
        const Scaffold(body: SingleChildScrollView(child: meds)));
  });
}
```

- [ ] **Step 2: 跑测试确认它红**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/for_doctor_visual_test.dart
```

- [ ] **Step 3: `for_doctor_screen.dart` —— 主按钮固定底部**

`_ForDoctorScreenState.build()`:「出码给医生看」那颗按钮从正文里移出来,放进 `Scaffold.bottomNavigationBar`:

```dart
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(MedShape.s3, 0, MedShape.s3, MedShape.s2),
        // brief §品牌 最后一条:这颗按钮固定在底部,内容再长也在。
        // s4 的正文是全 app 最长的一屏(12 种药 + 6 个诊断),滚到底才看见主动作
        // 等于没有主动作。
        child: MedPrimaryButton(
          label: '出码给医生看',
          icon: Icons.qr_code_2_outlined,
          onPressed: _onShowQr,     // ← 沿用现有那个回调,名字读代码为准
        ),
      ),
```
**按钮的文字一个字不动。** 若现在这颗按钮根本不在这一屏(读代码确认 —— 它可能在 `ForDoctorActions` 里或是 `FilledButton`),那就**只换容器与位置,不新增按钮**。

`ForDoctorActions`(210)三条 `ListTile` 的 `leading` 换成光泽图标块,底部两条换成 mockup `s4` 的白色入口块 + 蓝横幅:
- 「导出文件」→ `GlossIconTile(icon: Icons.print_outlined, category: GlossCategory.neutral)`
- 「急救卡」→ `GlossIconTile(icon: Icons.favorite_outline, category: GlossCategory.alert)`
- 「我是医生,替病人代拍」→ `MedBanner(icon: Icons.photo_camera_outlined, iconCategory: GlossCategory.brand, title: '我是医生,替病人代拍', subtitle: '病人不用装 App、不用账号', onTap: onProxy)`
**四句文案一个字不动。**

正文里的诊断 / 用药 / 检查三段(`_ForDoctorScreenState` 里渲染 summary 的那几处)换成 `LongTextRow`:诊断 `GlossCategory.clinic` + `Icons.monitor_heart_outlined`,过敏 `GlossCategory.alert` + `Icons.warning_amber_outlined`,用药 `GlossCategory.med` + `Icons.medication_outlined`,检查影像 `GlossCategory.imaging` + `Icons.image_outlined`。

- [ ] **Step 4: `document_detail.dart`(`s8`)**

`_DetailBody`(235):
- 顶部「表格 / 文字 / 原件」三段切换换成 mockup `.tab2`:药丸 chip,白底 + `MedBrand.chipShadow`,选中 `c.seal` 底白字(与 Task 9 的 `_PanelChip` 同一形状 —— **把 `_PanelChip` 从 `trends_screen.dart` 提到 `lib/widgets/med_card.dart` 改名 `MedChip` 共用,不要复制**)。
- 化验表沿用 Task 6 改好的 `LabLine`,外层 `MedCard` 的横向 padding 去掉,让 4px 色条贴边。
- 「报告上的提示」那块换 `UnderstandBanner` 同款蓝横幅(**把 `UnderstandBanner` 也提到 `med_card.dart`,改名 `MedReadBanner`;`trends_screen.dart` 的导出名保留一个 `typedef` 或直接改引用** —— 读代码挑代价小的那条)。
- 「看这几项的趋势」保持 ghost 按钮。

- [ ] **Step 5: 急救卡**

`emergency_card_screen.dart` 五个 section 的图标底换光泽图标块(血型=品牌、过敏=警示、用药=用药、诊断=门诊、其他=中性);卡片跟着 `MedCard` 自动去边框;大字沿用 `MedType.display`。`EmergencyBigCardScreen`(687)那一屏是给急救人员看的高对比页,**只换字体与圆角,不加渐变、不加图标块**。

- [ ] **Step 6: 跑测试确认绿**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/for_doctor_visual_test.dart test/for_doctor_screen_test.dart \
  test/for_doctor_refresh_test.dart test/report_content_test.dart test/emergency_card_refresh_test.dart \
  test/emergency_card_allergy_wording_test.dart test/glossary_guard_test.dart
/Users/ziyuanguan/flutter/bin/flutter analyze
```

- [ ] **Step 7: Commit**

```bash
git add lib/screens/for_doctor_screen.dart lib/screens/document_detail.dart \
        lib/screens/emergency_card_screen.dart lib/screens/trends_screen.dart \
        lib/widgets/med_card.dart test/for_doctor_visual_test.dart
git commit -m "$(cat <<'MSG'
feat(ui): 「给医生看」「一份病历」「急救卡」落 mockup s4/s8

「出码给医生看」挪进 bottomNavigationBar —— brief §品牌 最后一条要求它固定底部,
s4 是全 app 最长的一屏(12 种药 6 个诊断),滚到底才看见主动作等于没有主动作。
测试拖 1200px 后断言按钮没动。

诊断/过敏/用药/检查四段换 LongTextRow(图标块 + 一项一行);三条入口换成光泽图标
块和蓝横幅。一份病历页的三段切换与「报告上的提示」与趋势页共用同一个 chip 和蓝
横幅 —— 把 _PanelChip / UnderstandBanner 提到 med_card.dart,不复制两份。

急救卡只换图标底和圆角;大字卡(给急救人员看的高对比页)一个渐变都不加。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
MSG
)"
```

---

### Task 11: 屏 —— 「我」(`s5`)+「成员页」(`s10`)+ 成员切换器 + 备份状态行

**Files:**
- Modify: `lib/screens/settings_screen.dart`(`_SectionLabel`:249、`_SettingsGroup`:270、`_SettingsRow`:291、`_InfoRow`:388、`MembersCard`:412、`AboutScreen`:486)
- Modify: `lib/screens/member_detail_screen.dart`(`_MemberDetailScreenState`:168)
- Modify: `lib/widgets/member_switcher.dart`(`showMemberSwitcherSheet`:33 里的 `CircleAvatar`:82)
- Modify: `lib/widgets/backup_status_line.dart`(`_BackupStatusLineState.build`:171)
- Test: `test/settings_visual_test.dart`(新建);`test/members_card_test.dart`、`test/member_detail_screen_test.dart`、`test/backup_status_line_test.dart`、`test/member_switcher_*`(既有,必须仍绿)

**mockup 模板:** `s5`、`s10`。**渐变预算:** 两屏都是全 0。

- [ ] **Step 1: 写失败的测试**

新建 `test/settings_visual_test.dart`:

```dart
// 「我」(s5)与「成员页」(s10)。两屏一个品牌渐变面都没有 —— 成员头像那几个
// 小方块是**光泽图标块**(brief §色:成员头像 = 品牌渐变),不是 hero。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/screens/settings_screen.dart';
import 'package:mobile_flutter/widgets/gloss_tile.dart';
import 'stage3_visual_helpers.dart';

void main() {
  testWidgets('成员头像是品牌渐变的光泽方块,不是 CircleAvatar', (tester) async {
    await pumpStage3(tester, Scaffold(body: MembersCard(
      members: [/* 读 members_card_test.dart 里现成的假 Profile 构造 */],
      countOf: (_) => 31, onOpen: (_) {}, onAdd: () {})));
    expect(find.byType(CircleAvatar), findsNothing, reason: 'mockup 里是圆角方块不是圆');
    expect(tester.widgetList<GlossIconTile>(find.byType(GlossIconTile))
        .any((w) => w.category == GlossCategory.brand), isTrue);
  });

  testWidgets('零个品牌渐变面', (tester) async {
    await pumpStage3(tester, Scaffold(body: MembersCard(
      members: const [], countOf: (_) => 0, onOpen: (_) {}, onAdd: () {})));
    expectGradientBudget();
    expectNoGradientInsideCards();
  });

  testWidgets('设置行:标题 16·400、右侧说明 13 ink3', (tester) async {
    await pumpStage3(tester, const Scaffold(body: _RowProbe()));
    final title = tester.widget<Text>(find.text('口令与恢复码'));
    expect(title.style!.fontSize, 16);
    expect(title.style!.fontWeight, anyOf(FontWeight.w400, isNull));
  });

  testWidgets('两个尺寸 × 两档字号不溢出', (tester) async {
    await expectNoOverflowAtBothSizes(tester, Scaffold(body: MembersCard(
      members: const [], countOf: (_) => 0, onOpen: (_) {}, onAdd: () {})));
  });
}
```

> `_RowProbe` 在这个文件里自己写,直接 pump 一个 `_SettingsRow`(私有 → 用 `SettingsScreen` 里对外可见的那条路径,或把探针改成断言 `MembersCard` 的行;**不要为了测试把私有类改成公开**)。
> 假 `Profile` 的构造照抄 `test/members_card_test.dart` 现成的写法。

- [ ] **Step 2: 跑测试确认它红**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/settings_visual_test.dart
```

- [ ] **Step 3: `MembersCard`(`settings_screen.dart:412`)**

- `Card(…)` → `MedCard(…)`;`Divider(color: MedMe.line)` → `Divider(height: 1, color: MedColors.of(context).line2)`。
- 成员那两行的 `CircleAvatar(backgroundColor: MedMe.tealSoft, child: Text(…))` → `GlossIconTile.letter(letter: m.name.isNotEmpty ? m.name.characters.first : '?')`(默认就是品牌渐变)。
- 「添加成员」那行的 `CircleAvatar` → `GlossIconTile(icon: Icons.add, category: GlossCategory.note)`(mockup `s5` 那一行用的是 note 绿);标题色 `MedColors.of(context).sealInk`。
- 份数 + `chevron_right` 的样式:`MedType.secondary.copyWith(color: c.ink3)` + `Icon(Icons.chevron_right, size: 18, color: c.ink3)`。
- **`'添加成员'` / `'— '` / `'N 份'` 三处字符串一个字不动。**

- [ ] **Step 4: 「我」首屏其余部分**

- `_SectionLabel`(249):15 号 `ink2`,padding `0 4`(与 `MonthHeader` 一档)。
- `_SettingsGroup`(270):外壳换 `MedCard`。
- `_SettingsRow`(291)/ `_InfoRow`(388):`leading` 图标换 `GlossIconTile`,类别按 mockup `s5`:口令与恢复码=`med`、我的设备=`note`、关于/隐私政策=`neutral`、云端相关=`lab`。标题 `MedType.body`(16·400),trailing `MedType.secondary.copyWith(color: c.ink3)`。
- `BackupStatusLine`(`backup_status_line.dart:171`):整条换成 `MedBanner(icon: Icons.cloud_outlined, iconCategory: GlossCategory.lab, title: <现有标题字符串>, subtitle: <现有副标字符串>, onTap: <现有回调>)`。**两个字符串来自现有状态机,原样透传,不许改写。** 三态(加载中 / 成功 / 失败)**都要验**(见 memory `test-all-three-states`):失败态用琥珀(`amber: true`),其余用蓝。

- [ ] **Step 5: 成员页(`s10`)与切换器**

- `member_detail_screen.dart`:三组卡换 `MedCard`;行图标换 `GlossIconTile`(云端备份=`lab`、云端整理=`clinic`、成员头像=`GlossIconTile.letter`、加一个人=`note`、改名字=`note`、把这份病历交给别人=`clinic`、删除这个成员=`alert`);「删除这个成员」标题色 `c.critical`。
- `member_switcher.dart:82` 的 `CircleAvatar` → `GlossIconTile.letter(...)`;sheet 的圆角已由主题给(`bottomSheetTheme`),改成 mockup 的 `26`:在 `theme.dart` 的 `bottomSheetTheme.shape` 里把 `MedShape.radiusCard` 换成 `26`(mockup `.sheet{border-radius:26px 26px 0 0}`)。

- [ ] **Step 6: 跑测试确认绿**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/settings_visual_test.dart test/members_card_test.dart \
  test/member_detail_screen_test.dart test/backup_status_line_test.dart \
  test/member_switcher_locked_test.dart test/member_switcher_shared_state_test.dart \
  test/member_switcher_viewer_expiry_test.dart test/member_no_role_words_test.dart \
  test/settings_icloud_section_visibility_test.dart test/glossary_guard_test.dart
/Users/ziyuanguan/flutter/bin/flutter analyze
```

- [ ] **Step 7: Commit**

```bash
git add lib/screens/settings_screen.dart lib/screens/member_detail_screen.dart \
        lib/widgets/member_switcher.dart lib/widgets/backup_status_line.dart lib/theme.dart \
        test/settings_visual_test.dart
git commit -m "$(cat <<'MSG'
feat(ui): 「我」与「成员页」落 mockup s5/s10

成员头像从 CircleAvatar 换成品牌渐变的光泽方块(brief §色:成员头像 = 品牌渐变;
mockup 里是圆角方块不是圆)。设置行的 leading 全部换成按类别上色的光泽图标块,
卡片跟着 MedCard 去边框。

备份状态行整条换成 MedBanner:成功/加载中用蓝、失败用琥珀,三态都验(改 UI 状态
只验一条会连环出 bug,这是记过账的)。底部 sheet 圆角对齐 mockup 的 26。

字符串全部原样透传,一个字没改。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
MSG
)"
```

---

### Task 12: 屏 —— 「病程档案」(`s3`):页头 logo、提醒横幅、活动度卡、病程时间轴

**Files:**
- Modify: `lib/screens/disease_profile_screen.dart`(`_Body`:268、`_Sources`:331、`_Failed`:239)
- Modify: `lib/widgets/profile_sections.dart`(`ProfileIconTile`:242、`_SectionCard`:196、`_ItemRow`:280、`_StatusCardBody`:353、`_GcBlock`:390、`_HcqBlock`:463、`_ScoreCardBody`:615、`_RemindersBody`:904、`_ReminderRow`:919、`_TimelineBody`:979、`_TimelineEventRow`:1024、`_ChecklistItemRow`:1136)
- Test: `test/disease_profile_visual_test.dart`(新建);`test/profile_sections_test.dart`、`test/profile_cloud_fields_test.dart`、`test/skill_packages_test.dart`(既有,必须仍绿)

**mockup 模板:** `s3`。**渐变预算:** 全 0(页头那枚 logo 是图片,不是渐变面)。

- [ ] **Step 1: 写失败的测试**

新建 `test/disease_profile_visual_test.dart`:

```dart
// 「病程档案」(s3)。页头带真 logo(brief §品牌 四处摆位之一),提醒是琥珀横幅,
// 活动度与用药走化验行(4px 左色条),病程是时间轴。零个品牌渐变面。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/widgets/brand_logo.dart';
import 'package:mobile_flutter/widgets/gloss_tile.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'package:mobile_flutter/widgets/profile_sections.dart';
import 'stage3_visual_helpers.dart';

void main() {
  testWidgets('页头带 30px 真 logo', (tester) async {
    await pumpStage3(tester, Scaffold(appBar: AppBar(
      title: const Row(children: [
        BrandLogo(size: BrandLogo.topBar), SizedBox(width: 10), Text('病程档案 · 狼疮'),
      ]))));
    expect(find.byType(BrandLogo), findsOneWidget);
    expect(tester.getSize(find.byType(BrandLogo)), const Size(30, 30));
  });

  testWidgets('ProfileIconTile 就是光泽图标块 —— 不再是 sealWash 方块', (tester) async {
    await pumpStage3(tester, const Scaffold(body: ProfileIconTile(icon: Icons.timeline_outlined)));
    expect(find.byType(GlossIconTile), findsOneWidget);
    expect(tester.getSize(find.byType(GlossIconTile)), const Size(44, 44));
  });

  testWidgets('时间轴:竖线 #DCE3EA、圆点 seal、异常点 #CF3A5A', (tester) async {
    await pumpStage3(tester, const Scaffold(body: _TimelineProbe()));
    final dots = tester.widgetList<Container>(find.byType(Container))
        .map((w) => w.decoration).whereType<BoxDecoration>()
        .where((d) => d.shape == BoxShape.circle).map((d) => d.color).toList();
    expect(dots, contains(MedColors.light.seal));
    final lines = tester.widgetList<Container>(find.byType(Container))
        .map((w) => (w.decoration as BoxDecoration?)?.color).toList();
    expect(lines, contains(MedBrand.timelineLine));
  });

  testWidgets('零个品牌渐变面,卡里没有渐变', (tester) async {
    await pumpStage3(tester, const Scaffold(body: MedCard(child: ProfileIconTile(icon: Icons.science_outlined))));
    expectGradientBudget();
    expectNoGradientInsideCards();
  });

  testWidgets('两个尺寸 × 两档字号不溢出', (tester) async {
    await expectNoOverflowAtBothSizes(tester,
        const Scaffold(body: SingleChildScrollView(child: _TimelineProbe())));
  });
}
```

> `_TimelineProbe` 在这个文件里写,pump `profile_sections.dart` 里公开可达的时间轴那一节(`ProfileSectionView` 传一个含 timeline 的 section;数据构造照抄 `test/profile_sections_test.dart` 现成的)。

- [ ] **Step 2: 跑测试确认它红**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/disease_profile_visual_test.dart
```

- [ ] **Step 3: `ProfileIconTile` 换成光泽图标块**

`lib/widgets/profile_sections.dart:242`,整个类换成一层薄壳(**类名与构造参数不动**,它被十几处引用):

```dart
/// 病程档案里那一档图标底。Stage 3 起它就是 `GlossIconTile` —— 36×36 的 sealWash
/// 方块被 brief §形 的「3D 图标语言」取代,全 app 只留一种图标底。
///
/// 保留这个类名不直接改调用方:它有十几处引用,而且 [category] 的默认值让老的
/// 调用点不用一个个补参数。
class ProfileIconTile extends StatelessWidget {
  const ProfileIconTile({super.key, required this.icon, this.category = GlossCategory.brand});

  final IconData icon;
  final GlossCategory category;

  @override
  Widget build(BuildContext context) => GlossIconTile(icon: icon, category: category);
}
```

调用点按 mockup `s3` 补类别:用药相关=`med`、化验/活动度=`lab`、提醒=`med`、指南更新=`clinic`、病程事件=`note`、异常/警示=`alert`。

- [ ] **Step 4: 页头、横幅、行**

- `disease_profile_screen.dart` 的 `AppBar` / `_Body`(268)标题行前面加 `BrandLogo(size: BrandLogo.topBar)` + 10px 间距。**标题字符串不动。**
- 「血常规逾期 8 个月」「眼底检查还没查过」这类提醒(`_RemindersBody`:904 / `_ReminderRow`:919)换 `MedBanner(amber: true, iconCategory: GlossCategory.med, …)`,标题与副标**原样透传**。
- 「指南更新」那块(`_GcBlock`:390 / `_HcqBlock`:463 里那段引用文字)换蓝横幅 `MedReadBanner`(Task 10 提到 `med_card.dart` 的那个)。
- 「现在在用」「活动度」两张卡里的行(`_StatusCardBody`:353 / `_ScoreCardBody`:615 / `_OtherDrugRow`:545)改用 `LabLine` 同款排版:4px 左色条 + pill + 彩色数值 + 单位小字。**若这些行现在不是 `LabLine`,不要强行替换组件**,只把它们的色/字/色条对齐(读代码挑代价小的那条)。
- `_TimelineBody`(979)/ `_YearGroup`(1002)/ `_TimelineEventRow`(1024):竖线 `Container(width: 2, color: MedBrand.timelineLine)`;圆点 `10×10` 圆形 `c.seal`、2px 白边、外面再一圈 1px `MedBrand.timelineLine`;异常事件的点换 `MedBrand.barCritical`;日期小标题 `MedType.secondary.copyWith(color: c.ink3)`。
- `_SectionCard`(196)跟着 `MedCard` 自动去边框,无需改。

- [ ] **Step 5: 跑测试确认绿**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/disease_profile_visual_test.dart \
  test/profile_sections_test.dart test/profile_cloud_fields_test.dart \
  test/profile_locked_actions_test.dart test/skill_packages_test.dart \
  test/disease_profile_card_test.dart test/glossary_guard_test.dart
/Users/ziyuanguan/flutter/bin/flutter analyze
```

- [ ] **Step 6: Commit**

```bash
git add lib/screens/disease_profile_screen.dart lib/widgets/profile_sections.dart \
        test/disease_profile_visual_test.dart
git commit -m "$(cat <<'MSG'
feat(ui): 「病程档案」落 mockup s3 —— 页头 logo、琥珀提醒、时间轴

ProfileIconTile 变成 GlossIconTile 的薄壳:36×36 的 sealWash 方块被 brief §形 的
3D 图标语言取代,全 app 只留一种图标底。类名保留是因为它有十几处引用,而 category
有默认值,老调用点不用一个个补参数。

页头加 30px 真 logo(brief §品牌 四处摆位之一),提醒换琥珀横幅、指南更新换蓝
横幅,病程时间轴的竖线/圆点/异常点按 mockup 上色。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
MSG
)"
```

---

### Task 13: 屏 —— 口令/恢复码(`s12`)、换新手机(`s15`)、出码(`s13`)、代拍(`s14`)

**Files:**
- Modify: `lib/screens/account_screen.dart`(`s12` 在 `account_screen.dart:649`–`725`;`s15` 在 `account_screen.dart:787`–`845`)
- Modify: `lib/screens/qr_share_screen.dart`(`_QrShareScreenState`:116)
- Modify: `lib/screens/qr_notice_sheet.dart`(`QrNoticeBody`:49)
- Modify: `lib/screens/doctor/doctor_home_screen.dart`(`_DoctorHomeScreenState`:84、`PatientGrantedSection`:347、`_PatientRow`:397)
- Test: `test/account_visual_test.dart`(新建);`test/account_screen_test.dart`、`test/qr_share_screen_test.dart`、`test/qr_notice_test.dart`、`test/doctor_home_granted_profiles_test.dart`(既有,必须仍绿)

**mockup 模板:** `s12`、`s15`、`s13`、`s14`。**渐变预算:** `s12` = `button:1`;`s15` = `hero:1`;`s13` = `button:1`(在首次那张 sheet 上);`s14` = `hero:1`。

- [ ] **Step 1: 写失败的测试**

新建 `test/account_visual_test.dart`:

```dart
// 口令/换机/出码/代拍四屏。三屏各有一处品牌渐变(s12 的主按钮、s15 与 s14 的
// 居中主卡),s13 的渐变在首次那张 sheet 的「好,出码」上。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/screens/qr_notice_sheet.dart';
import 'package:mobile_flutter/widgets/brand_gradient.dart';
import 'stage3_visual_helpers.dart';

void main() {
  testWidgets('恢复码框:等宽 20 号、字距 .1em、#F1F4F8 底、#0E6285 字、圆角 14', (tester) async {
    await pumpStage3(tester, const Scaffold(body: Center(child: RecoveryCodeBox(
      code: '7K3M-QW9P-XR2D-HB8N-4TVL'))));
    final t = tester.widget<Text>(find.text('7K3M-QW9P-XR2D-HB8N-4TVL'));
    expect(t.style!.fontSize, 20);
    expect(t.style!.letterSpacing, closeTo(2.0, 0.01));   // .1em × 20px
    expect(t.style!.color, MedColors.light.sealInk);
    final d = tester.widget<Container>(find.ancestor(
      of: find.text('7K3M-QW9P-XR2D-HB8N-4TVL'), matching: find.byType(Container)).first)
      .decoration! as BoxDecoration;
    expect(d.color, MedColors.light.paper);
    expect(d.borderRadius, BorderRadius.circular(MedShape.radiusBlock));  // 14
  });

  testWidgets('输入框面板:白底、圆角 16、卡阴影', (tester) async {
    await pumpStage3(tester, const Scaffold(body: Center(child: MedFieldPanel(child: Text('口令,至少 6 位')))));
    final d = tester.widget<Container>(find.descendant(
      of: find.byType(MedFieldPanel), matching: find.byType(Container)).first)
      .decoration! as BoxDecoration;
    expect(d.color, Colors.white);
    expect(d.borderRadius, BorderRadius.circular(MedShape.radiusBanner));  // 16
    expect(d.boxShadow, MedBrand.cardShadow);
  });

  testWidgets('二维码框:白底 160×160 + 10 padding + 圆角 16 + qrShadow', (tester) async {
    await pumpStage3(tester, const Scaffold(body: Center(child: MedQrFrame(child: SizedBox(width: 160, height: 160)))));
    final d = tester.widget<Container>(find.descendant(
      of: find.byType(MedQrFrame), matching: find.byType(Container)).first)
      .decoration! as BoxDecoration;
    expect(d.color, Colors.white);
    expect(d.boxShadow, MedBrand.qrShadow);
  });

  testWidgets('出码首次 sheet:一颗主按钮 + 一颗次按钮,零主卡', (tester) async {
    await pumpStage3(tester, const Scaffold(body: QrNoticeBody()));
    expectGradientBudget(button: 1);
    expect(find.byType(MedSecondaryButton), findsOneWidget);
  });

  testWidgets('四屏各自的尺寸/字号不溢出', (tester) async {
    await expectNoOverflowAtBothSizes(tester, const Scaffold(body: SingleChildScrollView(
      child: Column(children: [
        MedFieldPanel(child: Text('口令,至少 6 位')),
        RecoveryCodeBox(code: '7K3M-QW9P-XR2D-HB8N-4TVL'),
      ]))));
  });
}
```

> `QrNoticeBody` 的构造参数读 `qr_notice_sheet.dart:49`;若它需要回调,测试里传空函数。

- [ ] **Step 2: 跑测试确认它红**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/account_visual_test.dart
```

- [ ] **Step 3: 三个小共用件进 `med_card.dart`**

这三块在四个屏里重复出现,写一次:

```dart
/// 输入框/信息面板(mockup `.field`):白底、圆角 16、卡阴影、17 号字。
class MedFieldPanel extends StatelessWidget {
  const MedFieldPanel({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(color: Colors.white,
      borderRadius: BorderRadius.circular(MedShape.radiusBanner),
      boxShadow: MedBrand.cardShadow),
    padding: const EdgeInsets.all(15),
    child: DefaultTextStyle.merge(
      style: MedType.body.copyWith(fontSize: 17, color: MedColors.of(context).ink3),
      child: child),
  );
}

/// 恢复码框(mockup `.code`):等宽 20 号、字距 .1em、paper 底、sealInk 字、圆角 14。
///
/// **字距单位是逻辑像素不是 em**(Flutter 的老坑):.1em × 20px = 2.0。
class RecoveryCodeBox extends StatelessWidget {
  const RecoveryCodeBox({super.key, required this.code});
  final String code;
  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(color: c.paper,
        borderRadius: BorderRadius.circular(MedShape.radiusBlock)),
      padding: const EdgeInsets.all(13),
      child: Text(code, textAlign: TextAlign.center,
        style: TextStyle(fontFamily: 'monospace', fontSize: 20,
            letterSpacing: 2.0, color: c.sealInk)),
    );
  }
}

/// 二维码白框(mockup `.qr`):白底 + 10 内边距 + 圆角 16 + 专用阴影。
class MedQrFrame extends StatelessWidget {
  const MedQrFrame({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(color: Colors.white,
      borderRadius: BorderRadius.circular(MedShape.radiusBanner),
      boxShadow: MedBrand.qrShadow),
    padding: const EdgeInsets.all(10),
    child: child,
  );
}
```

- [ ] **Step 4: `s12` / `s15`(`account_screen.dart`)**

- `account_screen.dart:649` 的 `const Text('设一个口令', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700))` → `Text('设一个口令', style: MedType.title)`(26·600)。`account_screen.dart:676` 的「恢复码,口令忘了用它」同样 → `MedType.title`?**不 —— 它是分区标题不是页面标题**,按 mockup `s12` 的 `.sec` 走:15 号 `ink2`。读上下文定,**字符串不动**。
- `account_screen.dart:693` 的恢复码显示 → `RecoveryCodeBox(code: _recoveryCode!)`。
- `account_screen.dart:658` / `:810` / `:815` 的输入框外壳 → `MedFieldPanel`。
- 「我抄好了」→ `MedPrimaryButton`;「发给自己」→ `MedSecondaryButton`。
- `s15`(`account_screen.dart:787`–):顶上那块「用旧手机扫码批准,最简单」+ 二维码 → `HeroCard`(居中,`MedQrFrame` 放在里面);下面「输口令」/「用恢复码」两块 → 与 `HomeTiles` 的 `_Tile` 同款白块 + 光泽图标块(`med` 钥匙 / `clinic` 文档)。**把 `_Tile` 从 `archive_screen.dart` 提到 `med_card.dart` 改名 `MedEntryTile` 共用,不复制。**
- `account_screen.dart:834` / `:844` 的两个 `TextButton` 保持 ghost 样式(`c.seal` 字、400)。

- [ ] **Step 5: `s13`(出码)与 `s14`(代拍)**

- `qr_share_screen.dart`:二维码那块 → `MedCard` 居中 + `MedQrFrame`;下面「医生要长期看(15 天)」→ `MedBanner(iconCategory: GlossCategory.clinic)`。**「15 天内有效;只有扫这个码的人能看」这句 note 一个字不动。**
- `qr_notice_sheet.dart`:两颗按钮 → `MedSecondaryButton('先不出')` + `MedPrimaryButton('好,出码')`;正文 15·1.6;标题 `MedType.subtitle`(19·600)。
- `doctor_home_screen.dart`:顶上的步骤条(mockup `.steps`)13 号 `ink3`,当前步 `c.seal`·500;二维码 + 取件码那块 → `HeroCard`(居中,取件码 20 号字距 2.0 白字);下面两行 → `MedCard` + 光泽图标块(`lab` 相机 / `med` 文件);`doctor_home_screen.dart:269` 那颗 `FilledButton.icon(backgroundColor: c.proxy)` 的**代拍主色 `proxy` 保留不动** —— 它是安全设计(个人模式 vs 代拍一眼可辨),brief 没动它。
  > **注意:** `s14` 的渐变预算是 `hero:1`,而代拍主按钮是紫色的 `FilledButton`,不是 `MedPrimaryButton` —— 这没有冲突,紫不是品牌渐变。测试里 `expectGradientBudget(hero: 1)` 即可。

- [ ] **Step 6: 跑测试确认绿**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/account_visual_test.dart test/account_screen_test.dart \
  test/account_session_test.dart test/qr_share_screen_test.dart test/qr_notice_test.dart \
  test/doctor_home_granted_profiles_test.dart test/doctor_summary_card_visual_test.dart \
  test/glossary_guard_test.dart
/Users/ziyuanguan/flutter/bin/flutter analyze
```

- [ ] **Step 7: Commit**

```bash
git add lib/screens/account_screen.dart lib/screens/qr_share_screen.dart \
        lib/screens/qr_notice_sheet.dart lib/screens/doctor/doctor_home_screen.dart \
        lib/screens/archive_screen.dart lib/widgets/med_card.dart test/account_visual_test.dart
git commit -m "$(cat <<'MSG'
feat(ui): 口令/换机/出码/代拍四屏落 mockup s12/s15/s13/s14

抽三个小共用件进 med_card.dart:MedFieldPanel(白底圆角 16 面板)、RecoveryCodeBox
(等宽 20 号 + 字距 2.0 —— Flutter 的 letterSpacing 单位是逻辑像素不是 em)、
MedQrFrame(二维码白框)。四个屏都要,写一次。

s15 与 s14 顶上那块换成居中的 HeroCard,各占那一屏唯一的品牌渐变名额。代拍主按钮
的紫色(MedColors.proxy)原样保留 —— 那是「这不是你自己的档案」的安全设计,
brief 没动它,紫也不是品牌渐变,不占名额。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
MSG
)"
```

---

### Task 14: 屏 —— 三张 sheet 与首启(`s6` 添加 / `s17` 云端整理 / `s16` 首次启动)

**Files:**
- Modify: `lib/screens/archive_screen.dart`(添加 sheet;`s6` 的 `.opt` 三行)
- Modify: `lib/screens/cloud_extract_ask_sheet.dart`(`CloudExtractAskBody`:63)
- Modify: `lib/screens/first_run_consent.dart`(`_FirstRunConsentScreenState.build`:64–270、`_Point`:385、`_Link`:422)
- Test: `test/sheets_visual_test.dart`(新建);`test/cloud_extract_ask_test.dart`、`test/first_run_consent_test.dart`、`test/photo_merge_offer_test.dart`(既有,必须仍绿)

**mockup 模板:** `s6`、`s17`、`s16`。**渐变预算:** `s6` = 全 0;`s17` = `button:1`;`s16` = `button:1`。

- [ ] **Step 1: 写失败的测试**

新建 `test/sheets_visual_test.dart`:

```dart
// 三张 sheet 与首启屏。s6 的选项行是 #F1F4F8 底的圆角块(第一条是 #DDEDF8),
// s17 / s16 各有一颗渐变主按钮,s16 的场景中央是 104px 的真 logo。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/screens/cloud_extract_ask_sheet.dart';
import 'package:mobile_flutter/widgets/brand_gradient.dart';
import 'package:mobile_flutter/widgets/brand_logo.dart';
import 'package:mobile_flutter/widgets/gloss_tile.dart';
import 'package:mobile_flutter/widgets/med_card.dart';
import 'stage3_visual_helpers.dart';

void main() {
  testWidgets('s6 选项行:paper 底圆角 16,第一条是蓝底', (tester) async {
    await pumpStage3(tester, const Scaffold(body: Column(children: [
      MedSheetOption(icon: Icons.photo_camera_outlined, category: GlossCategory.brand,
          label: '拍照', note: '可以连拍几张', highlighted: true),
      MedSheetOption(icon: Icons.image_outlined, category: GlossCategory.lab, label: '从相册选'),
    ])));
    final decos = tester.widgetList<Container>(find.descendant(
      of: find.byType(MedSheetOption), matching: find.byType(Container)))
      .map((w) => w.decoration).whereType<BoxDecoration>()
      .where((d) => d.borderRadius == BorderRadius.circular(MedShape.radiusBanner)).toList();
    expect(decos.map((d) => d.color), [MedBrand.bannerBlue, MedColors.light.paper]);
    expect(find.byType(GlossIconTile), findsNWidgets(2));
  });

  testWidgets('s17:一颗渐变主按钮 + 一颗次按钮,标题 19·600', (tester) async {
    await pumpStage3(tester, const Scaffold(body: CloudExtractAskBody()));
    expectGradientBudget(button: 1);
    expect(find.byType(MedSecondaryButton), findsOneWidget);
  });

  testWidgets('s16:场景中央 104px 真 logo,微微左旋', (tester) async {
    await pumpStage3(tester, const Scaffold(body: Center(child: FirstRunScene())));
    expect(tester.getSize(find.byType(BrandLogo)), const Size(104, 104));
    expect(find.byType(Transform), findsWidgets);          // rotate(-6deg)
    expect(find.byType(GlossIconTile), findsNWidgets(3));  // 三个飘着的小块
  });

  testWidgets('三张 sheet 在两个尺寸 × 两档字号下不溢出', (tester) async {
    await expectNoOverflowAtBothSizes(tester,
        const Scaffold(body: SingleChildScrollView(child: CloudExtractAskBody())));
  });
}
```

> `CloudExtractAskBody` 的构造参数读 `cloud_extract_ask_sheet.dart:63`(可能要两个回调,测试传空函数)。

- [ ] **Step 2: 跑测试确认它红**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/sheets_visual_test.dart
```

- [ ] **Step 3: 两个新共用件**

进 `lib/widgets/med_card.dart`:

```dart
/// 底部 sheet 里的一条选项(mockup `.opt`):paper 底圆角块 + 光泽图标块 + 17 号字
/// + 右侧一句灰色小注。[highlighted] 的那条换成蓝底 —— `s6` 用它标出推荐的那条。
class MedSheetOption extends StatelessWidget {
  const MedSheetOption({super.key, required this.icon, required this.category,
      required this.label, this.note, this.highlighted = false, this.onTap});
  final IconData icon; final GlossCategory category;
  final String label; final String? note;
  final bool highlighted; final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(type: MaterialType.transparency, child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(MedShape.radiusBanner),
        child: Container(
          decoration: BoxDecoration(
            color: highlighted ? MedBrand.bannerBlue : c.paper,
            borderRadius: BorderRadius.circular(MedShape.radiusBanner)),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(children: [
            GlossIconTile(icon: icon, category: category),
            const SizedBox(width: MedShape.s2),
            Expanded(child: Text(label, style: MedType.body.copyWith(fontSize: 17))),
            if (note != null) Text(note!, style: MedType.secondary.copyWith(color: c.ink3)),
          ]),
        ),
      )),
    );
  }
}
```

进 `lib/widgets/brand_logo.dart`:

```dart
/// 首启那一屏中央的场景(mockup `s16` 的 `.scene`):104px 的真 logo 微微左旋,
/// 三个光泽图标块飘在周围 —— brief §插画 说的「用光泽图标块语言拼场景」。
///
/// 这是**占位级**的场景:brief 里那套统一风格的 3D 图标还在外包/生成中。用现有
/// 语言先拼一个,到货后整体换掉,这一屏的其余部分不用动。
class FirstRunScene extends StatelessWidget {
  const FirstRunScene({super.key});

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 160,
    child: Stack(alignment: Alignment.center, children: [
      Positioned(left: 40, top: 14, child: Transform.rotate(angle: 10 * 3.14159 / 180,
        child: const GlossIconTile(icon: Icons.water_drop_outlined,
            category: GlossCategory.lab, size: 52))),
      Positioned(right: 70, top: 6, child: Transform.rotate(angle: 6 * 3.14159 / 180,
        child: const GlossIconTile(icon: Icons.medication_outlined,
            category: GlossCategory.med, size: 40))),
      Positioned(right: 40, bottom: 8, child: Transform.rotate(angle: -12 * 3.14159 / 180,
        child: const GlossIconTile(icon: Icons.show_chart, 
            category: GlossCategory.imaging, size: 56))),
      Transform.rotate(angle: -6 * 3.14159 / 180,
        child: const BrandLogo(size: BrandLogo.splash)),
    ]),
  );
}
```

- [ ] **Step 4: 接进三个屏**

- 添加 sheet(`archive_screen.dart` 里那个 `showModalBottomSheet`):三条选项换 `MedSheetOption`(拍照=`brand` + `highlighted: true`、从相册选=`lab`、选文件(PDF)=`neutral`),标题 `MedType.subtitle`,底下那句小注 `MedType.secondary.copyWith(color: c.ink3)`。**四句文案一个字不动。**
- `cloud_extract_ask_sheet.dart`:标题 `MedType.subtitle`;正文 `MedType.body.copyWith(fontSize: 15, height: 1.6)`;两颗按钮并排 → `Row` + `Expanded`,左 `MedPrimaryButton('开,帮我整理')`、右 `MedSecondaryButton('不开')`。
  > **注意顺序:** mockup `s17` 是「开,帮我整理」在左、「不开」在右。**照现有代码的顺序**,不要为了对齐 mockup 调换 —— 调换按钮位置是结构改动,越了 Stage 3 的界。若两者不一致,记下来报给用户。
- `first_run_consent.dart`:
  - `first_run_consent.dart:181` 的 `ClipRRect(borderRadius: 16) + Image.asset('assets/icon/app_icon.png', 64)` 换成 `const FirstRunScene()`。
  - `first_run_consent.dart:192` 的标题 `TextStyle(fontSize: 24, fontWeight: w700, color: MedMe.tealDark)` → `MedType.title.copyWith(fontSize: 30, height: 1.25, color: MedColors.of(context).ink)`(mockup `s16` 的 `h3`)。**「开始之前,有X件事」这句话与它的动态计数一个字不动。**
  - `first_run_consent.dart:252` 那段「下面还有」渐隐遮罩:`MedMe.bg` 已在 Task 1 对齐成 `#F1F4F8`,**这段代码不用改**;`MedMe.tealDark` 已对齐成 `sealInk`,箭头颜色自动跟上。**这不是品牌渐变**(它是底色到透明的遮罩),不占渐变预算 —— 在测试里用 `expectGradientBudget(button: 1)` 而不是数 `BrandGradientBox`,就不会误伤。
  - 底部「开始使用」→ `MedPrimaryButton`。
  - `_Point`(385)的图标换 `GlossIconTile`。

- [ ] **Step 5: 跑测试确认绿**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/sheets_visual_test.dart test/cloud_extract_ask_test.dart \
  test/first_run_consent_test.dart test/photo_merge_offer_test.dart test/import_helpers_test.dart \
  test/glossary_guard_test.dart
/Users/ziyuanguan/flutter/bin/flutter analyze
```

- [ ] **Step 6: Commit**

```bash
git add lib/screens/archive_screen.dart lib/screens/cloud_extract_ask_sheet.dart \
        lib/screens/first_run_consent.dart lib/widgets/med_card.dart lib/widgets/brand_logo.dart \
        test/sheets_visual_test.dart
git commit -m "$(cat <<'MSG'
feat(ui): 三张 sheet 与首启屏落 mockup s6/s17/s16

sheet 选项换 MedSheetOption(paper 底圆角块 + 光泽图标块,推荐那条用蓝底)。
首启屏中央换 FirstRunScene:104px 真 logo 微微左旋 + 三个光泽图标块飘在周围 ——
brief §插画 说的「用光泽图标块语言拼场景」。那套统一风格的 3D 图标还在外包,
这是占位级实现,到货后整体换掉,这一屏其余部分不用动。

首启那段「下面还有」的渐隐遮罩没改:它是底色到透明,不是品牌渐变,不占预算。
按钮顺序照现有代码,没为了对齐 mockup 调换 —— 那是结构改动。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
MSG
)"
```

---

### Task 15: 动效 —— 折线只描画一次、尊重 reduced-motion、卡片零淡入

**Files:**
- Modify: `lib/widgets/trend_chart.dart`(`TrendChart`:98、`_TrendPainter`:130)
- Test: `test/motion_test.dart`(新建)

**Interfaces:**
- Consumes: `MediaQuery.disableAnimationsOf(context)`(系统「减弱动态效果」开关)。
- Produces: `TrendChart` 新增 `bool animate`(默认 `true`);类名与其余参数不动。

- [ ] **Step 1: 写失败的测试**

新建 `test/motion_test.dart`:

```dart
// 动效闸。brief §品牌:「只有折线描画一次(reduced-motion 关闭);无逐卡淡入」。
//
// 「无逐卡淡入」是这条里最容易被违反的一半 —— 列表进场加淡入是每个人的肌肉记忆,
// 而 MedMe 的列表一屏能有十几张卡,逐卡淡入会让整屏抖一下。所以用扫源码的方式挡,
// 跟 glossary_guard 同一手法:只有扫源码拦得住「有人又写了一个」。
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/widgets/trend_chart.dart';

void main() {
  test('屏与 widget 里没有任何进场淡入', () {
    final offenders = <String>[];
    for (final dir in ['lib/screens', 'lib/widgets']) {
      for (final f in Directory(dir).listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].trimLeft().startsWith('//')) continue;
          for (final banned in ['AnimatedOpacity', 'FadeTransition', 'FadeInImage',
                                'AnimatedSlide', 'SlideTransition']) {
            if (lines[i].contains(banned)) offenders.add('${f.path}:${i + 1}  $banned');
          }
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'brief §品牌:无逐卡淡入。若确有必要,先改 brief:\n${offenders.join('\n')}');
  });

  testWidgets('折线默认描画一次,不循环', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(
      body: SizedBox(width: 300, height: 82, child: TrendChart(points: [1, 2, 3, 4])))));
    await tester.pump(const Duration(milliseconds: 100));
    // 动画跑完后 pumpAndSettle 必须能停下来 —— 停不下来就是循环动画。
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('系统开了「减弱动态效果」时,折线直接画完不描', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: MediaQuery(
      data: MediaQueryData(disableAnimations: true),
      child: Scaffold(body: SizedBox(width: 300, height: 82,
          child: TrendChart(points: [1, 2, 3, 4]))))));
    // 第一帧就是终态:没有排队的动画帧。
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
```

> `TrendChart` 的构造参数读 `lib/widgets/trend_chart.dart:98`,测试里按真实签名填。

- [ ] **Step 2: 跑测试确认它红**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/motion_test.dart
```
预期:reduced-motion 那条红(现在没有这个分支)。若淡入那条也红,先看是哪几处 —— **那几处才是这个 Task 真正要删的东西**。

- [ ] **Step 3: 改 `trend_chart.dart`**

`TrendChart` 改成 `StatefulWidget`(若它现在是 `StatelessWidget`),用一个 `AnimationController` 单次 `forward()` 驱动 `_TrendPainter` 的 `progress`:

```dart
  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // brief §品牌:reduced-motion 下不描画。系统开关一变就跟着变,不是只在首帧读一次。
    // 这是无障碍基线,不是装饰 —— 前庭功能敏感的人会因为动画头晕。
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.value = 1;            // 直接终态
    } else if (!_played) {
      _played = true;          // **只描一次**:重建(切面板、换成员)不重播。
      _c.forward();
    }
  }
```

`_TrendPainter` 加 `final double progress`,画线时用 `PathMetric.extractPath(0, metric.length * progress)`,`shouldRepaint` 比较 `progress`。

- [ ] **Step 4: 删掉找到的淡入**

Step 2 报出来的每一处 `AnimatedOpacity` / `FadeTransition`:**删掉动画,保留终态**。若某一处是**状态切换**的淡入(不是进场),它仍然违反 brief 的「无逐卡淡入」吗?——**不违反**,但把它挪出 `lib/screens` / `lib/widgets` 不现实。遇到这种:在那一行上面加一句 `// 不是进场淡入:…` 的注释,并把测试的 `banned` 检查改成跳过带这句注释的行。**不要**为了让测试绿而删掉一个真正需要的状态过渡。

- [ ] **Step 5: 跑测试确认绿**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/motion_test.dart test/trends_screen_test.dart \
  test/trends_visual_test.dart
/Users/ziyuanguan/flutter/bin/flutter analyze
```

- [ ] **Step 6: Commit**

```bash
git add lib/widgets/trend_chart.dart test/motion_test.dart
git commit -m "$(cat <<'MSG'
feat(ui): 折线只描一次、reduced-motion 下不描,加「无逐卡淡入」闸

brief §品牌 只允许一种动效:折线描画一次。TrendChart 改成单次 forward 的
AnimationController,重建(切面板、换成员)不重播;系统开了「减弱动态效果」就直接
给终态 —— 这是无障碍基线不是装饰,前庭敏感的人会因为动画头晕。

「无逐卡淡入」用扫源码的闸挡,和 glossary_guard 同一手法:这种事只有扫源码拦得住
「有人又写了一个」。列表进场加淡入是所有人的肌肉记忆,而这个 app 一屏十几张卡。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
MSG
)"
```

---

### Task 16: 验收 —— 文案零变更闸、全量测试、九屏模拟器截图对照

**Files:**
- Create: `test/copy_unchanged_test.dart`
- Create: `docs/superpowers/plans/2026-09-18-ux-stage3-screenshots.md`(截图对照清单,**唯一允许新建的文档**)
- Test: 全量 `flutter test` + `flutter analyze`

**Interfaces:**
- Consumes: 基线 commit `2a629a2`(Stage 3 开工前的 HEAD)。

- [ ] **Step 1: 写文案零变更闸**

新建 `test/copy_unchanged_test.dart`:

```dart
// **Stage 3 不许改一个用户可见的字符串。** 这个测试把工作区里每个含汉字的字符串
// 字面量,和基线 commit 里的同一批,做集合对比 —— 多一个、少一个、改一个字都红。
//
// 为什么不存一份基线文件:那份文件自己会腐坏(有人顺手 regenerate 一下就静音了)。
// 直接问 git 要基线,没有可以被顺手更新的中间物。
//
// 为什么只看含汉字的:变量名、asset 路径、RegExp、FontVariation 的 'wght' 这些
// Stage 3 本来就会动。屏上的字在这个 app 里 100% 含汉字。
//
// **闸红了怎么办:** 不是改这个测试,是把那处文案改回去。Stage 3 只改颜色形状字体。
// 唯一合法的例外是删掉整个 widget 时带走它的字符串 —— 而 Stage 3 不删 widget。
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// Stage 3 开工前的 HEAD。
const kBaseline = '2a629a2';

const _dirs = ['lib/screens', 'lib/widgets'];

final _cjk = RegExp(r'[一-鿿]');
/// 单引号或双引号的 Dart 字面量,允许 \ 转义,不跨行。
final _literal = RegExp(r'''(['"])((?:(?!\1)[^\\\n]|\\.)*)\1''');

/// 去掉行注释和块注释 —— 注释里有大量带引号的中文(设计说明、踩坑记录),
/// Stage 3 会改它们,那不算文案变更。
String _stripComments(String src) => src
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
    .split('\n').map((l) {
      final i = l.indexOf('//');
      return i < 0 ? l : l.substring(0, i);
    }).join('\n');

Set<String> _literalsIn(String src) => _literal
    .allMatches(_stripComments(src))
    .map((m) => m.group(2)!)
    .where(_cjk.hasMatch)
    .toSet();

void main() {
  test('用户可见文案与基线 $kBaseline 逐字相同', () {
    final now = <String>{}, before = <String>{};
    for (final dir in _dirs) {
      for (final f in Directory(dir).listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        now.addAll(_literalsIn(f.readAsStringSync()));
      }
    }
    // 基线侧同样只看这两个目录,路径用 git 的相对写法(仓库根在上两级)。
    final ls = Process.runSync('git', ['ls-tree', '-r', '--name-only', kBaseline,
        '--', 'apps/mobile_flutter/lib/screens', 'apps/mobile_flutter/lib/widgets'],
        workingDirectory: '../..');
    for (final path in (ls.stdout as String).trim().split('\n')) {
      if (!path.endsWith('.dart')) continue;
      final show = Process.runSync('git', ['show', '$kBaseline:$path'], workingDirectory: '../..');
      before.addAll(_literalsIn(show.stdout as String));
    }

    expect(now.difference(before), isEmpty, reason: '多出来的文案(Stage 3 不许加字)');
    expect(before.difference(now), isEmpty, reason: '丢掉的文案(Stage 3 不许删字)');
  });
}
```

- [ ] **Step 2: 跑它,确认现在是绿的**

```bash
/Users/ziyuanguan/flutter/bin/flutter test test/copy_unchanged_test.dart
```
**预期:绿。** 如果红了,说明前面某个 Task 动了文案 —— **停下来,把那处改回去,不要改这个测试**。红的信息会直接告诉你多/少了哪一句。

- [ ] **Step 3: 全量测试 + analyze**

```bash
/Users/ziyuanguan/flutter/bin/flutter analyze
/Users/ziyuanguan/flutter/bin/flutter test
```
两条都必须干净。**词表闸 `test/glossary_guard_test.dart` 必须原样绿,且这个 Task 一行都不许改它。**

- [ ] **Step 4: 九屏截图,与 mockup 并排比**

模拟器已经有一台在跑(`iPhone 17`,`xcrun simctl list devices booted` 可确认)。按 `apps/mobile_flutter/CLAUDE.md` 的纪律:**debug 构建、只对当前选中的这一台**,不跑 release、不跑全 ABI。

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a/apps/mobile_flutter
/Users/ziyuanguan/flutter/bin/flutter run -d "iPhone 17"
```
> 这条命令首次冷启会编 Rust,**可能超过 5 分钟** —— 按纪律先把命令报给用户,由用户决定是否现在跑。

app 起来后,逐屏导航并截图(每张截完立刻看一眼,不要攒到最后):

```bash
S=/private/tmp/claude-501/-Volumes-extraSupply-Projects-Medme/6fb778b0-c9b5-404d-ae65-0c0319ec1c97/scratchpad/stage3-shots
mkdir -p "$S"
xcrun simctl io booted screenshot "$S/s1-病历.png"
```

九屏(与 mockup 模板一一对应):

| # | 屏 | 怎么到 | mockup 模板 | 要比的点 |
|---|---|---|---|---|
| 1 | 病历(主页) | 底栏第 1 个 | `s1` | 主卡渐变 + 光晕;「添加」渐变块 vs「给医生看」白块;琥珀横幅;文档行的类别色图标块 |
| 2 | 趋势 | 底栏第 2 个 | `s2` | 病历本条的书脊与右列大数;趋势行三列 + 4px 左色条;蓝色「看懂」横幅 |
| 3 | 病程档案 | 趋势 → 病历本条 | `s3` | 页头 30px logo;琥珀提醒;时间轴圆点 |
| 4 | 给医生看 | 主页「给医生看」 | `s4` | 长清单一项一行;**主按钮固定在底部**(往下滚,按钮不动) |
| 5 | 我 | 底栏第 3 个 | `s5` | 云端蓝横幅;成员头像是渐变圆角方块不是圆 |
| 6 | 一份病历 | 病历 → 点一行 | `s8` | 三段 chip;化验行色条贴卡边;蓝色「报告上的提示」 |
| 7 | 成员页 | 我 → 点某个人 | `s10` | 三组白卡;「删除这个成员」红字 + 警示图标块 |
| 8 | 出码 | 给医生看 → 出码 | `s13` | 二维码白框阴影;蓝横幅 |
| 9 | 首次启动 | 删 app 重装 / 清数据 | `s16` | 104px logo 微左旋 + 三个飘着的光泽块;渐变主按钮 |

把 mockup 在浏览器里并排打开对照:
```bash
open '/private/tmp/claude-501/-Volumes-extraSupply-Projects-Medme/6fb778b0-c9b5-404d-ae65-0c0319ec1c97/scratchpad/mockups/medme-ui-directions.html'
```

- [ ] **Step 5: 写对照清单**

新建 `docs/superpowers/plans/2026-09-18-ux-stage3-screenshots.md`,九屏各一节,每节三行:**截图路径 / mockup 模板 id / 对不上的地方**。对得上就写「一致」。**对不上的不要自己拍板改** —— 列出来交给用户,他认可过的是 mockup v24,不是我的理解。

- [ ] **Step 6: 自查三件事**

1. `git diff 2a629a2 --stat -- apps/mobile_flutter/lib` 里**没有**任何 `main.dart` 之外的行为改动 —— 逐个文件扫一遍 diff,凡是改了条件、回调、导航目标的,退回去。
2. `git diff 2a629a2 -- apps/mobile_flutter/lib | grep -E '^\+.*Text\(' | grep -v '^\+.*style'` —— 新增的 `Text(` 只该是换了 style 的同一句话,不该有新句子。
3. 上面那张「每屏品牌渐变预算」表的每一行,都有一个测试在断言它。没有的补上。

- [ ] **Step 7: Commit**

```bash
git add test/copy_unchanged_test.dart docs/superpowers/plans/2026-09-18-ux-stage3-screenshots.md
git commit -m "$(cat <<'MSG'
test(ui): 文案零变更闸 + 九屏截图对照清单

copy_unchanged_test.dart 把工作区里每个含汉字的字符串字面量,和基线 2a629a2 的
同一批做集合对比:多一个、少一个、改一个字都红。基线直接问 git 要,不存中间文件 ——
存下来的基线自己会腐坏(有人顺手 regenerate 一下就静音了)。注释里的中文先剥掉:
Stage 3 会大改注释,那不算文案变更。

九屏在模拟器上逐屏截图与 mockup v24 并排比,对不上的列进清单交给用户拍板 ——
他认可过的是 mockup,不是我对 mockup 的理解。

flutter analyze 干净,flutter test 全绿,glossary_guard_test 原样未动。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
MSG
)"
```

---

## 自查(写完计划后对着 brief 逐条核)

**1. brief 覆盖率**

| brief 段落 | 落在哪个 Task |
|---|---|
| §色 底/surface/ink 三档/分隔线 | 1 |
| §色 品牌渐变 + 光晕 + seal/sealInk | 1、4 |
| §色 九档类别色 | 1、3 |
| §色 四档状态 + 示例标 | 1、6 |
| §色 蓝/琥珀横幅 | 1、6 |
| §形 六档圆角 | 1 |
| §形 卡无边框 + 两档阴影 | 1、6 |
| §形 光泽图标块 | 3 |
| §形 病历本条 | 5、9 |
| §形 趋势行 | 5、9 |
| §形 化验行 4px 色条 | 6 |
| §形 长文本行 | 5、10 |
| §字 中文系统字体、不打包 Noto | 2 |
| §字 Manrope 500/600 + tabular | 1、2 |
| §字 字重与字号 | 1 |
| §品牌 logo 四处摆位 | 7、8、9、12、14 |
| §品牌 一屏一处渐变 | 4(机制)+ 8–14(逐屏断言) |
| §品牌 动效两条 | 15 |
| §品牌 出码按钮固定底部 | 10 |
| §插画(待外包) | 14(占位级 `FirstRunScene`,brief 自己标了「待外包/生成」) |

**2. 占位扫描**:全篇没有「TBD」「稍后」「类似 Task N」「加上适当的错误处理」。每个要写代码的 Step 都带真代码块。

**3. 类型一致性**:`GlossCategory`(Task 1 定义)在 3/5/6/8–14 被引用,拼写一致;`MedBrand.tile()` 返回 `(Color, Color, Color)` 三元组,Task 1 定义、Task 3 解构使用;`BrandGradientBox` / `HeroCard` / `PrimaryEntryTile` / `MedPrimaryButton` / `MedSecondaryButton` 在 Task 4 定义,8–14 引用;`RecordBookStrip` / `LongTextRow` Task 5 定义,9/10/12 引用;`MedBanner` / `MedDemoPill` / `MedFieldPanel` / `RecoveryCodeBox` / `MedQrFrame` / `MedSheetOption` / `MedEntryTile` / `MedChip` / `MedReadBanner` 在 6/10/13/14 逐步进 `med_card.dart`;`BrandLogo` / `FirstRunScene` 在 7/14 定义。`pumpStage3` / `expectGradientBudget` / `expectNoGradientInsideCards` / `expectNoOverflowAtBothSizes` 在 Task 4 定义,8–14 引用。

**4. 两处需要用户拍板的**(执行到那一步时停下来问,不要自己决定):
- Task 4 Step 4:白字压品牌渐变最亮那一段只有 2.4:1,不过 AA。mockup 就是这么画的 —— 这是 mockup 与项目既有无障碍红线的冲突。
- 计划「已知分歧 5」:「正常」pill 的底色。
