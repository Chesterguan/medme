# UX Stage 3.5 · 减法 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Stage 3 的视觉噪音减掉——一个品牌色、颜色只说状态、白底细边无阴影、图标退到线性或不用——文案一字不动(用户点名删的四段除外),三道闸继续绿。

**Architecture:** 纯删法。令牌层先改值(底色/细边/圆角)、加化验行刻度条的三个尺寸;共享壳(`HeroCard`/`MedPrimaryButton`/`MedCard`/`MedChip`/`MedBanner`)拍平;`GlossIconTile` 换成 `MedIcon`;化验行换新解剖;再逐屏(病历 / 趋势 / 给医生看)按稿子重排;最后一次令牌收尾把孤儿令牌全删,并加一道「无渐变无阴影」静态闸。每个 Task 删掉它让读者归零的令牌,令牌测试随任务同步。

**Tech Stack:** Flutter(`apps/mobile_flutter`),Dart 3.8 语法(`?x` null-aware 元素已在用),`flutter_test`。不加依赖。

**Spec:** `docs/superpowers/specs/2026-09-22-ux-stage3-5-subtraction-design.md`(稿子 https://claude.ai/artifact/5vC4xPqUoL5eJimz3cmzvV,源 `docs/superpowers/specs/2026-09-22-subtraction-mockup.html`)

**Worktree / 分支:** `/Volumes/extraSupply/Projects/Medme-adv-a`,`feat/ux-stage3-5-subtraction`(自 main 37fa107)。所有路径相对 `apps/mobile_flutter/`,除非写明。

## Global Constraints

每个 Task 的要求都隐含包含这一节。

- **文案一字不改、不加。** 唯一例外是用户 2026-09-22 点名删的四段:「找一找」「找一找还在做」「看懂」「把报告上那段「提示」原文摘出来放这里 —— 还在做。」(Task 1 把它们登记进 `test/copy_unchanged_test.dart` 的 `kRemovedByDecision`)。挪动/拆分字面量允许(闸按 CJK 段多重集比)。**不许显示「正常」二字**(`design_tokens_test.dart:297-305`、`mobile_ia_test.dart:118` 钉着)。
- **不动信息结构**,除计划明写的三处:主页整月的行进一张卡;给医生看每节各一张卡、顺序改为 变化 → 过敏/用药 → 我想问医生的;还没核对的卡片区位置不动。
- **裸色值只许在 `lib/design_tokens.dart` / `lib/theme.dart`**(`no_raw_colors_test.dart`)。`token.withValues(alpha: …)` 允许。`Colors.*` 只许 `white`/`black`/`transparent`。
- **全 lib/ 不许出现渐变和阴影**(Task 8 加静态闸 `test/no_gradient_no_shadow_test.dart`)。折线图若有数据可视化用的渐变填充,用 `// 允许:图表` 前一行标注放行(与 `motion_test.dart` 的 `// 不是进场淡入:` 同一手法)。
- **颜色只说状态**:`high`/`low`/`critical` 与琥珀横幅是仅有的非中性色;正常值 `ink`;类别不上色。
- **一屏至多一颗 `MedPrimaryButton`、至多一张 `HeroCard`**(`test/stage3_visual_helpers.dart` 的 `expectSurfaceBudget` 按屏数)。
- **字号一个不缩**(老人);数值 tabular;Manrope 只 500/600(`fonts_test.dart`)。
- **色值逐字**:底 `#F6F8FA`,一级分隔线 `#E9EEF2`,其余沿用 `MedColors.light`。新尺寸:卡圆角 `16`;化验刻度条 `74×3`、圆点 `9`;图标槽 `44`、图标 `22`。
- **不加依赖;不用 `unwrap`/裸 `!` 之外的非空断言技巧改语义;不动 Rust。**
- **每个 Task 收尾**:`/Users/ziyuanguan/flutter/bin/flutter analyze` 干净 + 该 Task 的测试绿 + 一次 commit,message 末尾**必须**带:

```
Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
```

- **构建纪律**(`apps/mobile_flutter/CLAUDE.md`):日常只跑 `flutter analyze` / `flutter test`;不跑 release、不跑全 ABI;预计超过 5 分钟的命令先停下来报。
- **删,不是改名留壳**:一个令牌/widget/参数读者归零就删掉它本体和它的测试,不留 `@Deprecated`。

---

### Task 1: 令牌层改值 + 文案闸登记用户删的四段

**Files:**
- Modify: `lib/design_tokens.dart`(`MedColors.light.paper/line`、`MedShape.radiusCard`、`MedBrand` 新增刻度条尺寸、`tileSize`→`iconSlot`、`tileIconSize`→`iconSize`)
- Modify: `lib/widgets/gloss_tile.dart`、`lib/import_flow.dart:1006`、`test/gloss_tile_test.dart`(两个改名的读者)
- Modify: `test/design_tokens_test.dart`(`specLight` 两个值、圆角、新令牌)
- Modify: `test/copy_unchanged_test.dart`(`kRemovedByDecision`)

**Interfaces:**
- Produces: `MedBrand.rangeBarWidth = 74`、`rangeBarHeight = 3`、`rangeMarkerSize = 9`、`rangeBandAlpha = 0.3`、`iconSlot = 44`、`iconSize = 22`;`MedShape.radiusCard = 16`;`kRemovedByDecision`。

- [ ] **Step 1: 改令牌值**

`lib/design_tokens.dart`:

```dart
    paper: Color(0xFFF6F8FA),
    ...
    line: Color(0xFFE9EEF2),
```

```dart
  /// 16 —— 外层卡片(减法稿 `.card{border-radius:16px}`)。
  static const double radiusCard = 16;
```

`MedBrand` 里把 `tileSize`/`tileIconSize` 改名并加刻度条尺寸(`tileIconStroke` 留到 Task 3 删):

```dart
  /// 行首图标槽 44、图标 22(减法稿:单色线性图标,没有底块)。
  static const double iconSlot = 44;
  static const double iconSize = 22;

  // ── 化验行的细刻度条(减法稿 `.bar`)────────────────────────
  /// 74×3 的浅条,参考区间那一段用 `ink3` 压 30% 不透明度,一枚 9px 圆点标出这次的值。
  static const double rangeBarWidth = 74;
  static const double rangeBarHeight = 3;
  static const double rangeMarkerSize = 9;
  static const double rangeBandAlpha = 0.3;
```

三个读者跟着改名:`lib/widgets/gloss_tile.dart`(`MedBrand.tileSize`→`iconSlot`、`tileIconSize`→`iconSize`)、`lib/import_flow.dart:1006`(`MedBrand.tileSize`→`MedBrand.iconSlot`)、`test/gloss_tile_test.dart`(同样两个名字)。`grep -rn "tileSize\|tileIconSize" lib test` 结果必须为空(`tileIconStroke` 除外)。

- [ ] **Step 2: 令牌测试**

`test/design_tokens_test.dart`:`specLight` 的 `'paper': 0xFFF6F8FA`、`'line': 0xFFE9EEF2`;「七档圆角」里 `expect(MedShape.radiusCard, 16)`;在 `group('MedBrand …')` 里加:

```dart
    test('减法稿:图标槽、化验刻度条', () {
      expect(MedBrand.iconSlot, 44);
      expect(MedBrand.iconSize, 22);
      expect(MedBrand.rangeBarWidth, 74);
      expect(MedBrand.rangeBarHeight, 3);
      expect(MedBrand.rangeMarkerSize, 9);
      expect(MedBrand.rangeBandAlpha, 0.3);
    });
```

- [ ] **Step 3: 文案闸登记用户删的四段**

`test/copy_unchanged_test.dart`,`kBaseline` 下面加:

```dart
/// Stage 3.5(减法,2026-09-22)用户裁定删掉的字:「没有用的就删掉,有需要再加」。
/// 这些段在 HEAD 里少掉是**预期**,不算丢文案。只许往这里加用户点名删的字,不许拿
/// 它放行任何改写;它只对「少了」生效,「多了」照旧红。
const Set<String> kRemovedByDecision = {
  '找一找', // 主页月份标题右侧的搜索占位,点了只弹一句「找一找还在做」
  '找一找还在做',
  '看懂', // 趋势页「看懂」横幅:只有壳,内容线从没接上
  '把报告上那段「提示」原文摘出来放这里',
  '还在做。',
};
```

`_diffAgainstBaseline` 里 `if (b > n)` 改成 `if (b > n && !kRemovedByDecision.contains(r))`。文件头注释「唯一合法例外是删掉整个 widget 时带走它的字符串」后面补一句:「Stage 3.5 起另有 `kRemovedByDecision`:用户点名删的字」。

- [ ] **Step 4: 跑、提交**

```bash
cd apps/mobile_flutter
/Users/ziyuanguan/flutter/bin/flutter analyze
/Users/ziyuanguan/flutter/bin/flutter test test/design_tokens_test.dart test/copy_unchanged_test.dart test/gloss_tile_test.dart test/no_raw_colors_test.dart
```

全绿后提交:`feat(ui): 减法 Task 1 —— 底色/细边/圆角改值,刻度条与图标槽令牌,文案闸登记用户删的四段`。

---

### Task 2: 共享壳拍平 —— 实色主卡/主按钮、细边卡、描边 chip、横幅去底块、主页两颗药丸

**Files:**
- Rename: `lib/widgets/brand_gradient.dart` → `lib/widgets/brand_surfaces.dart`(`git mv` + 所有 import 改名)
- Modify: `lib/widgets/med_card.dart`
- Modify: `lib/main.dart:683-698`(底栏)
- Modify: `lib/screens/archive_screen.dart:873-892`(`HomeTiles`)、`:910`(`iconCategory`)
- Modify: `lib/screens/for_doctor_screen.dart:251`、`lib/widgets/backup_status_line.dart:185`(`iconCategory`)
- Modify: `lib/screens/trends_screen.dart:387,1414`(`UnderstandBanner`)、`lib/screens/doctor/doctor_home_screen.dart:245`(`HeroCard(color: c.proxyInk)`)
- Modify: `perforated:` 的六个调用点(`grep -rn "perforated:" lib`)
- Modify: `test/stage3_visual_helpers.dart` + 它的 12 个调用文件
- Rename/rewrite: `test/brand_gradient_test.dart` → `test/brand_surfaces_test.dart`
- Modify: `test/med_card_test.dart`、`test/archive_header_test.dart`、`test/archive_visual_test.dart`、`test/document_detail_visual_test.dart`、`test/trends_visual_test.dart`、`test/trends_screen_test.dart`、`test/settings_visual_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `MedShape.radiusCard = 16`。
- Produces: `HeroCard({child, Color? color, onTap, semanticLabel})`(实色,默认 `sealInk`);`MedPrimaryButton` 实色 sealInk;`MedSecondaryButton` 加禁用态;`MedCard({child, background})`(无 `perforated`);`MedBanner({icon, title, subtitle, amber, onTap})`(无 `iconCategory`);`statusWord(String, Color)`;`expectSurfaceBudget({hero, button})`。删除:`BrandGradientBox`、`PrimaryEntryTile`、`MedPerforation`、`MedDemoPill`、`MedReadBanner`、`expectNoGradientInsideCards`。

- [ ] **Step 1: `brand_surfaces.dart`**

```bash
cd apps/mobile_flutter
git mv lib/widgets/brand_gradient.dart lib/widgets/brand_surfaces.dart
grep -rl "widgets/brand_gradient.dart" lib test | xargs sed -i '' 's#widgets/brand_gradient.dart#widgets/brand_surfaces.dart#g'
```

整个文件重写为(`MedSecondaryButton` 加禁用态,其余逐字):

```dart
import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// 品牌色的三个出口:主卡、主按钮、次按钮。**没有渐变、没有阴影、没有光晕**
/// (减法稿 2026-09-22)。一屏至多一张 [HeroCard]、至多一颗 [MedPrimaryButton]——
/// 那是这一屏唯一的一块颜色面,`test/stage3_visual_helpers.dart` 按屏数。
///
/// 卡面白字压 `sealInk`(#0E6285)6.76:1,过 WCAG AA;不用 `seal`(3.9:1)——
/// 目标用户含老年人,`theme.dart` 早已定了填充面一律 sealInk。
class HeroCard extends StatelessWidget {
  const HeroCard({super.key, required this.child, this.color, this.onTap, this.semanticLabel});

  final Widget child;

  /// 卡面实色,默认 `sealInk`。代拍首页传 `proxyInk`(R31:代拍模式保持紫)。
  final Color? color;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final card = Material(
      color: color ?? c.sealInk,
      borderRadius: BorderRadius.circular(MedShape.radiusCard),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        splashColor: Colors.white.withValues(alpha: 0.08),
        highlightColor: Colors.white.withValues(alpha: 0.04),
        child: Padding(padding: const EdgeInsets.fromLTRB(18, 16, 18, 14), child: child),
      ),
    );
    return semanticLabel == null
        ? card
        : Semantics(button: onTap != null, label: semanticLabel, child: card);
  }
}

/// 主按钮:药丸、实色 `sealInk`、17·w500 白字。
///
/// **禁用态**(`onPressed == null`):`line2` 底 + `ink2` 字(R29/R30,ink2/line2 ≈ 7.9:1),
/// 无水波纹——「还能不能点」由底色说,不靠字变浅。
class MedPrimaryButton extends StatelessWidget {
  const MedPrimaryButton({super.key, required this.label, this.icon, this.onPressed});

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final enabled = onPressed != null;
    final fg = enabled ? Colors.white : c.ink2;
    return Material(
      color: enabled ? c.sealInk : c.line2,
      borderRadius: BorderRadius.circular(MedShape.radiusPill),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(MedShape.radiusPill),
        child: Padding(
          padding: const EdgeInsets.all(13),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (icon != null) ...[Icon(icon, size: 20, color: fg), const SizedBox(width: 8)],
            Flexible(child: Text(label, textAlign: TextAlign.center,
              style: MedType.body.copyWith(fontSize: 17, fontWeight: FontWeight.w500,
                  fontVariations: MedType.w500, color: fg))),
          ]),
        ),
      ),
    );
  }
}

/// 次按钮:白底 + 1.5px `seal` 描边 + `sealInk` 字。禁用态:`line` 描边 + `ink3` 字。
class MedSecondaryButton extends StatelessWidget {
  const MedSecondaryButton({super.key, required this.label, this.icon, this.onPressed});

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final enabled = onPressed != null;
    final fg = enabled ? c.sealInk : c.ink3;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(MedShape.radiusPill),
        // R13:白底用 Ink,水波纹才不会被这层不透明白底盖住。
        child: Ink(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(MedShape.radiusPill),
            border: Border.all(color: enabled ? c.seal : c.line, width: 1.5),
          ),
          padding: const EdgeInsets.all(13),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (icon != null) ...[Icon(icon, size: 20, color: fg), const SizedBox(width: 8)],
            Flexible(child: Text(label, textAlign: TextAlign.center,
              style: MedType.body.copyWith(fontSize: 17, fontWeight: FontWeight.w500,
                  fontVariations: MedType.w500, color: fg))),
          ]),
        ),
      ),
    );
  }
}
```

`lib/screens/doctor/doctor_home_screen.dart:245`:`HeroCard(` → `HeroCard(color: c.proxyInk,`(该 build 里已有 `final c = MedColors.of(context)`;没有就取一个)。

- [ ] **Step 2: `med_card.dart`**

`MedCard` 改成细边无阴影、无骑缝线;**删** `MedPerforation`/`_PerforationPainter`、`MedDemoPill`、`MedReadBanner`;`MedBanner` 去 `iconCategory`;`MedChip` 描边;`MedFieldPanel`/`MedQrFrame`/`MedEntryTile` 的 `boxShadow: MedBrand.cardShadow/qrShadow` 换成 `border: Border.all(color: c.line)`(`MedEntryTile`/`MedSheetOption` 里的 `GlossIconTile` 这一步不动,Task 3 统一换)。`import 'gloss_tile.dart'` 保留(Task 3 换)。

```dart
/// 标准卡片:`surface` 底 + 圆角 16 + 1px `line` 细边,**无阴影**(减法稿 2026-09-22:
/// 层次靠字号和留白,不靠阴影)。骑缝线已删——没人读得出那排点在说「可溯源」。
class MedCard extends StatelessWidget {
  const MedCard({super.key, required this.child, this.background});

  /// 卡片内容。**不带内边距** —— 由调用方决定(有的卡整块要盖 InkWell)。
  final Widget child;

  /// 卡片底色,默认 `surface`。
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: background ?? c.surface,
        borderRadius: BorderRadius.circular(MedShape.radiusCard),
        border: Border.all(color: c.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // R24:child 槽位统一垫一层透明 Material,卡内 ListTile/InkWell 才有 Material 祖先。
          Material(type: MaterialType.transparency, child: child),
        ],
      ),
    );
  }
}
```

```dart
/// 一个上了色的状态词(12·600,无底):化验行的「偏高」「偏低」、还没核对卡片的
/// 「还没核对」。减法稿:状态 = 一个词 + 颜色,不再是 pill。
Widget statusWord(String text, Color color) => Text(
  text,
  style: MedType.caption.copyWith(color: color, fontWeight: FontWeight.w600, fontVariations: MedType.w600),
);
```

`MedBanner`(签名与 `build` 里的 Row 头两项):

```dart
  const MedBanner({super.key, required this.icon, required this.title, this.subtitle, this.amber = false, this.onTap});
  ...
              Icon(icon, size: 20, color: ink),
              const SizedBox(width: MedShape.s2),
```

`MedChip.build` 的 decoration 与文字样式:

```dart
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(MedShape.radiusPill),
          border: Border.all(color: selected ? c.seal : c.line),
        ),
        child: Text(
          '$label $count',
          style: MedType.secondary.copyWith(
            fontSize: 14,
            color: selected ? c.sealInk : c.ink2,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            fontVariations: selected ? MedType.w600 : null,
            fontFeatures: MedType.tabular,
          ),
        ),
```

三个 `iconCategory:` 调用点删掉那一行:`archive_screen.dart:910`、`for_doctor_screen.dart:251`、`backup_status_line.dart:185`。六个 `perforated:` 调用点删掉那一行(`grep -rn "perforated:" lib`)。

`trends_screen.dart`:删 `:387` 的 `const UnderstandBanner(),` 及其上下那两个 `SizedBox(height: MedShape.s5)` 中的一个(保留一个间距),删 `:1414` 的 `typedef UnderstandBanner = MedReadBanner;` 和它上面的注释。`grep -rn "MedReadBanner\|UnderstandBanner" lib` 必须为空(`profile_sections.dart` 若只在注释里提到,把那句注释删掉)。

- [ ] **Step 3: 底栏与顶栏**

`lib/theme.dart:58`:`scrolledUnderElevation: 0.5` → `0`(顶栏下面已有一道 `line`,滚动时不再浮出阴影)。

`lib/main.dart:683-698`:

```dart
      // 底栏:白底 + 顶部一道 `line`(减法稿:层次靠边框,不靠阴影)。
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: MedColors.light.line)),
        ),
        child: NavigationBarTheme(
          data: NavigationBarTheme.of(context).copyWith(
            iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
              size: 22,
              color: states.contains(WidgetState.selected) ? MedColors.light.seal : MedColors.light.ink3,
            )),
          ),
```

- [ ] **Step 4: 主页两颗药丸(`HomeTiles`)**

`lib/screens/archive_screen.dart:873-892`:

```dart
class HomeTiles extends StatelessWidget {
  const HomeTiles({super.key, this.onAdd, this.onForDoctor});

  final VoidCallback? onAdd;
  final VoidCallback? onForDoctor;

  @override
  Widget build(BuildContext context) => Row(children: [
    // 减法稿:「添加」实心药丸(这一屏唯一的主按钮),「给医生看」描边药丸。
    Expanded(child: MedPrimaryButton(label: '添加', onPressed: onAdd)),
    const SizedBox(width: MedShape.s2),
    Expanded(child: MedSecondaryButton(label: '给医生看', onPressed: onForDoctor)),
  ]);
}
```

`import 'package:mobile_flutter/widgets/brand_surfaces.dart';` 已随 Step 1 改名;`GlossCategory` 若因此在本文件没了读者,先不管(Task 3 删)。类文档里「方块」的说法改成「药丸」。

- [ ] **Step 5: 测试工具与各屏测试**

`test/stage3_visual_helpers.dart`:删 `expectNoGradientInsideCards` 与 `brand_surfaces`/`med_card` 之外的无用 import;`expectGradientBudget` 改名:

```dart
/// 「一屏一块颜色面」的可执行形式:主卡与主按钮各至多一张/一颗,默认都是 0。
void expectSurfaceBudget({int hero = 0, int button = 0}) {
  expect(find.byType(HeroCard), findsNWidgets(hero), reason: '主卡数不对');
  expect(find.byType(MedPrimaryButton), findsNWidgets(button), reason: '主按钮数不对');
}
```

```bash
grep -rl "expectGradientBudget\|expectNoGradientInsideCards" test | xargs sed -i '' -e 's/expectGradientBudget(/expectSurfaceBudget(/g' -e '/expectNoGradientInsideCards();/d' -e 's/entry: [0-9], //g' -e 's/, entry: [0-9]//g'
grep -rn "entry:" test/*visual*  # 必须为空
```

`test/archive_visual_test.dart`:`expectSurfaceBudget(hero: 1, button: 1)`(主卡 Task 5 才拆);`'「添加」是渐变入口块…'` 改成断言 `find.widgetWithText(MedPrimaryButton, '添加')` 与 `find.widgetWithText(MedSecondaryButton, '给医生看')`;`'底色是实心 #F1F4F8,没有第二个渐变面'` 改成断言 `Scaffold` 背景 `MedColors.light.paper` == `Color(0xFFF6F8FA)` 且 `find.byType(BrandGradientBox)` 这行删(类型没了)。`test/document_detail_visual_test.dart` 删对 `PrimaryEntryTile` 的引用。`test/archive_header_test.dart` 的 `'两颗方块:等宽、都点得动'`/`'SE + 2× 字号…'` 改成找 `MedPrimaryButton`/`MedSecondaryButton`,断言等宽、`tap` 触发回调、2× 下四个字都在(`find.text('给医生看')` 存在且 `tester.takeException()` 为 null)。

`test/trends_visual_test.dart` / `test/trends_screen_test.dart`:删所有 `UnderstandBanner`/`看懂` 断言;chip 那条改成:未选中 `border.top.color == c.line`、选中 `== c.seal`、选中字色 `c.sealInk`、`boxShadow == null`。`test/settings_visual_test.dart`、`test/med_card_test.dart` 里的 `iconCategory:` 参数删掉。

`test/med_card_test.dart`:`'卡无边框、圆角 20、阴影 0 6px 18px'` 改成 `'卡 1px line 细边、圆角 16、无阴影'`(断言 `d.border == Border.all(color: MedColors.light.line)`、`d.boxShadow == null`、半径 16);删 `MedPerforation`/`perforated`/`MedDemoPill` 的所有测试;`MedBanner` 测试改成断言 `Icon` 颜色 == 横幅文字色、没有 `GlossIconTile`。

`test/brand_surfaces_test.dart`(重写,取代 `brand_gradient_test.dart`):

```dart
// 品牌色的三个出口:实色、无渐变、无阴影;禁用态对比度;水波纹有 Material 祖先。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/brand_surfaces.dart';

Future<void> pump(WidgetTester t, Widget w) => t.pumpWidget(MaterialApp(
  theme: MedMe.theme(), home: Scaffold(body: Center(child: w))));

/// WCAG 相对亮度对比度(sRGB 线性化用 dart:math 的 pow,不手搓)。
double contrast(Color a, Color b) {
  double lin(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  double lum(Color c) => 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
  final l1 = lum(a), l2 = lum(b);
  final hi = math.max(l1, l2), lo = math.min(l1, l2);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  const c = MedColors.light;

  testWidgets('HeroCard:实色 sealInk、圆角 16、没有渐变、没有阴影、可点', (t) async {
    var taps = 0;
    await pump(t, HeroCard(onTap: () => taps++, child: const Text('x')));
    final m = t.widget<Material>(find.ancestor(of: find.text('x'), matching: find.byType(Material)).first);
    expect(m.color, c.sealInk);
    expect(m.borderRadius, BorderRadius.circular(16));
    expect(find.byWidgetPredicate((w) => w is Container && (w.decoration as BoxDecoration?)?.gradient != null), findsNothing);
    expect(find.byWidgetPredicate((w) => w is Ink && (w.decoration as BoxDecoration?)?.gradient != null), findsNothing);
    await t.tap(find.text('x'));
    expect(taps, 1);
  });

  testWidgets('HeroCard:color 可覆盖(代拍首页 proxyInk)', (t) async {
    await pump(t, HeroCard(color: c.proxyInk, child: const Text('x')));
    final m = t.widget<Material>(find.ancestor(of: find.text('x'), matching: find.byType(Material)).first);
    expect(m.color, c.proxyInk);
  });

  testWidgets('MedPrimaryButton 启用:sealInk 底白字,对比度 ≥ 4.5', (t) async {
    await pump(t, MedPrimaryButton(label: '出码给医生看', onPressed: () {}));
    final m = t.widget<Material>(find.ancestor(of: find.text('出码给医生看'), matching: find.byType(Material)).first);
    expect(m.color, c.sealInk);
    expect(t.widget<Text>(find.text('出码给医生看')).style!.color, Colors.white);
    expect(contrast(Colors.white, c.sealInk), greaterThanOrEqualTo(4.5));
  });

  testWidgets('MedPrimaryButton 禁用:line2 底 ink2 字,对比度 ≥ 4.5', (t) async {
    await pump(t, const MedPrimaryButton(label: '出码给医生看'));
    final m = t.widget<Material>(find.ancestor(of: find.text('出码给医生看'), matching: find.byType(Material)).first);
    expect(m.color, c.line2);
    expect(t.widget<Text>(find.text('出码给医生看')).style!.color, c.ink2);
    expect(contrast(c.ink2, c.line2), greaterThanOrEqualTo(4.5));
  });

  testWidgets('MedSecondaryButton:启用 seal 描边 sealInk 字;禁用 line 描边 ink3 字', (t) async {
    await pump(t, MedSecondaryButton(label: '给医生看', onPressed: () {}));
    var ink = t.widget<Ink>(find.byType(Ink));
    expect((ink.decoration as BoxDecoration).border!.top.color, c.seal);
    expect(t.widget<Text>(find.text('给医生看')).style!.color, c.sealInk);
    await pump(t, const MedSecondaryButton(label: '给医生看'));
    ink = t.widget<Ink>(find.byType(Ink));
    expect((ink.decoration as BoxDecoration).border!.top.color, c.line);
    expect(t.widget<Text>(find.text('给医生看')).style!.color, c.ink3);
  });

  testWidgets('2.0 字号 × 360×640:三个都不溢出', (t) async {
    t.view.physicalSize = const Size(360, 640);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: MedMe.theme(), home: MediaQuery(
      data: const MediaQueryData(size: Size(360, 640), textScaler: TextScaler.linear(2.0)),
      child: Scaffold(body: Column(children: [
        HeroCard(child: const Text('用旧手机扫码批准,最简单')),
        MedPrimaryButton(label: '出码给医生看', onPressed: () {}),
        MedSecondaryButton(label: '给医生看', onPressed: () {}),
      ])))));
    expect(t.takeException(), isNull);
  });
}
```

> 旧 `brand_gradient_test.dart` 里若已有同款 `contrast` 辅助函数,直接沿用它,不写第二份。

- [ ] **Step 6: 跑、提交**

```bash
/Users/ziyuanguan/flutter/bin/flutter analyze
/Users/ziyuanguan/flutter/bin/flutter test
```

全量必须绿(这一步动了共享壳,只跑几个文件不够)。提交:`feat(ui): 减法 Task 2 —— 主卡/主按钮实色,卡细边无阴影,chip 描边,横幅去底块,主页两颗药丸;删 BrandGradientBox/PrimaryEntryTile/骑缝线/MedDemoPill/看懂横幅`。

---

### Task 3: `GlossIconTile` → `MedIcon` / `MedAvatar`;类别系统整个删

**Files:**
- Create: `lib/widgets/med_icon.dart`
- Delete: `lib/widgets/gloss_tile.dart`、`test/gloss_tile_test.dart`
- Create: `test/med_icon_test.dart`
- Modify: 35 个构造点(见清单)、`lib/design_tokens.dart`(`GlossCategory`、`MedBrand.tile()`、`glossTop`、`glossBottom`、`tileShadow`、`tileIconStroke`、`MedShape.radiusTile`)、`lib/doc_labels.dart:169-196`、`lib/widgets/brand_logo.dart:36-60`、`lib/widgets/med_card.dart`(`MedEntryTile.category`、`MedSheetOption.category`)、`lib/import_flow.dart`(`_SheetTile.category`)、`lib/screens/settings_screen.dart`、`lib/widgets/profile_sections.dart:103-110,245,1038`、`lib/screens/archive_screen.dart:84-92`、`test/design_tokens_test.dart`(九档类别、`radiusTile`)、各 visual test

**Interfaces:**
- Produces: `MedIcon(IconData icon, {Color? color, double size = MedBrand.iconSize})`、`MedAvatar(String letter, {double size = MedBrand.iconSlot})`。
- 删除:`GlossIconTile`、`GlossCategory`、`MedBrand.tile/glossTop/glossBottom/tileShadow/tileIconStroke`、`MedShape.radiusTile`、`categoryForDocType`、`categoryForVisitKind`、`_categoryOf`、`_categoryForKind`。

- [ ] **Step 1: 新 widget**

`lib/widgets/med_icon.dart`:

```dart
import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// 行首图标:一枚单色线性 `Icon`,放在 44×44 的槽里(`MedBrand.iconSlot`),行与行的
/// 文字起点才对得齐。**没有底块、没有渐变、没有类别色**(减法稿 2026-09-22:类别
/// 上色没有信息)。默认 `ink2`;只有这一行本身在报警时才传 [color](设置里的危险
/// 项、姓名不符的红横幅用 `critical`)。
class MedIcon extends StatelessWidget {
  const MedIcon(this.icon, {super.key, this.color, this.size = MedBrand.iconSize});

  final IconData icon;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: MedBrand.iconSlot,
    height: MedBrand.iconSlot,
    child: Center(child: Icon(icon, size: size, color: color ?? MedColors.of(context).ink2)),
  );
}

/// 成员头像:`line2` 圆底 + `ink2` 首字。**不跟系统字号放大**——固定尺寸的装饰字形,
/// 姓名在旁边照常放大(`MedType` 文档里的唯一例外)。
class MedAvatar extends StatelessWidget {
  const MedAvatar(this.letter, {super.key, this.size = MedBrand.iconSlot});

  final String letter;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.line2, shape: BoxShape.circle),
      child: MediaQuery.withNoTextScaling(
        child: Text(letter, style: MedType.subtitle.copyWith(color: c.ink2, fontSize: size * 0.41)),
      ),
    );
  }
}
```

- [ ] **Step 2: 机械替换 35 个构造点**

规则:`GlossIconTile(icon: X, category: Y)` → `MedIcon(X)`;带 `size: Z` 的保留 `size:`;`GlossIconTile.letter(letter: L)` → `MedAvatar(L)`。`const` 照旧可用。**两处传色**:`lib/screens/settings_screen.dart:326` 的 `category: danger ? GlossCategory.alert : category` → `MedIcon(icon, color: danger ? c.critical : null)`;`lib/screens/archive_screen.dart:849`(`_MismatchBanner` 的 alert)→ `MedIcon(Icons.warning_amber_rounded, color: c.critical)`。其余一律默认色。

清单(file:line,来自 2026-09-22 盘点):`emergency_card_screen.dart` 241/300/361/415/477;`visit_summary_sheet.dart` 384/454;`settings_screen.dart` 326/481 + `.letter` 461;`account_screen.dart` 1216/1250;`for_doctor_screen.dart` 228/237;`member_detail_screen.dart` 213/220/353;`archive_screen.dart` 552/674/746/849;`trends_screen.dart` 1315;`first_run_consent.dart` 384;`doctor_home_screen.dart` 379/428;`document_detail.dart` 298;`med_card.dart` 455/494;`profile_sections.dart` 245/1038;`member_switcher.dart` `.letter` 84;`brand_logo.dart` 50/53/56(见 Step 4)。

参数级的类别一并删:`MedEntryTile.category`、`MedSheetOption.category`、`import_flow.dart` `_SheetTile.category`(:134/147/154 的传参与 :975 的字段)、`settings_screen.dart` 里所有 `category:` 传参与对应字段(:158/186/192/198/308/320/745/752/760/829)、`visit_summary_sheet.dart` `_Section.category`(:121-136/314-331/362-369 的传参与字段)、`profile_sections.dart` 的 `category` 字段与 `_categoryForKind`(:46/103-110)、`archive_screen.dart` 的 `_categoryOf`(:84-92)。`doc_labels.dart` 删 `categoryForDocType`(:169-176)与 `categoryForVisitKind`(:193-196)。

```bash
grep -rn "GlossIconTile\|GlossCategory\|categoryForDocType\|categoryForVisitKind\|_categoryOf\|_categoryForKind\|gloss_tile" lib   # 必须为空
```

- [ ] **Step 3: 令牌层删类别系统**

`lib/design_tokens.dart`:删 `enum GlossCategory`、`MedBrand.tile()`、`glossTop`、`glossBottom`、`tileIconStroke`、`tileShadow()`、`MedShape.radiusTile`。`test/design_tokens_test.dart`:删「九档类别渐变与同色投影」、`radiusTile` 那一行。`MedType` 文档里「唯一例外:`GlossIconTile.letter`」改成 `MedAvatar`。

- [ ] **Step 4: 首启场景只留 logo**

`lib/widgets/brand_logo.dart` 的 `FirstRunScene`:

```dart
/// 首启那一屏中央:104px 的真 logo,微微左旋。减法稿 2026-09-22:原来飘在周围的三个
/// 光泽块删了——它们没有信息。
class FirstRunScene extends StatelessWidget {
  const FirstRunScene({super.key});

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 160,
    child: Center(child: Transform.rotate(angle: -6 * 3.14159 / 180,
      child: const BrandLogo(size: BrandLogo.splash))),
  );
}
```

`test/brand_logo_test.dart` / `test/first_run_consent_test.dart` 里对三个光泽块的断言删掉。

- [ ] **Step 5: 测试**

`test/med_icon_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/med_icon.dart';

Future<void> pump(WidgetTester t, Widget w, {double scale = 1.0}) => t.pumpWidget(MaterialApp(
  theme: MedMe.theme(),
  home: MediaQuery(data: MediaQueryData(textScaler: TextScaler.linear(scale)), child: Scaffold(body: w))));

void main() {
  testWidgets('44 槽、22 图标、默认 ink2', (t) async {
    await pump(t, const MedIcon(Icons.science_outlined));
    final box = t.getSize(find.byType(MedIcon));
    expect(box, const Size(44, 44));
    final icon = t.widget<Icon>(find.byType(Icon));
    expect(icon.size, 22);
    expect(icon.color, MedColors.light.ink2);
  });

  testWidgets('只有这一行在报警时才传色', (t) async {
    await pump(t, MedIcon(Icons.delete_outline, color: MedColors.light.critical));
    expect(t.widget<Icon>(find.byType(Icon)).color, MedColors.light.critical);
  });

  testWidgets('MedAvatar:line2 圆底 + ink2 首字,3× 字号不放大不溢出', (t) async {
    await pump(t, const MedAvatar('李'), scale: 3.0);
    expect(t.getSize(find.byType(MedAvatar)), const Size(44, 44));
    final d = t.widget<Container>(find.byType(Container)).decoration as BoxDecoration;
    expect(d.color, MedColors.light.line2);
    expect(d.shape, BoxShape.circle);
    expect(t.widget<Text>(find.text('李')).style!.color, MedColors.light.ink2);
    expect(t.takeException(), isNull);
  });

  test('没有渐变、没有阴影可传', () {
    // 编译期就没有这些参数;这条只是把意图写进测试名。
    expect(const MedIcon(Icons.add).size, 22);
  });
}
```

各 visual test 里对 `GlossIconTile`/类别的断言:`account_visual_test.dart` 130/158/200/234、`archive_visual_test.dart` 40、`disease_profile_visual_test.dart` 42/90、`document_detail_visual_test.dart` 35、`for_doctor_visual_test.dart` 61/99/256、`settings_visual_test.dart` 38/126、`sheets_visual_test.dart` 27/46 —— 断「有类别」的改成断 `find.byType(MedIcon)` 存在(数量不管),断「类别是 X」的整条删。

- [ ] **Step 6: 跑、提交**

`flutter analyze` + 全量 `flutter test` 绿。提交:`refactor(ui): 减法 Task 3 —— GlossIconTile → MedIcon/MedAvatar,删九档类别系统与 categoryFor*,首启场景只留 logo`。

---

### Task 4: 化验行新解剖 —— 无色条、状态词、刻度条;正常不上色

**Files:**
- Modify: `lib/widgets/lab_status.dart`(`labStatusColor`、`labStatusPill`→`labStatusWord`、删 `labStripeColor`、`LabLine.build` 重写、新增 `LabRangeBar` + `labRangeFractions`)
- Modify: `lib/widgets/report_content.dart:170-225`(`_flagColor`、删 `_stripeColor` 及其 4px 左边框、`_flagPill` 改状态词)
- Modify: `lib/screens/trends_screen.dart:1147-1180`(`KeyLabsSnapshot` 注释)、`lib/widgets/profile_sections.dart:1227`(`barCritical`→`c.critical`)
- Modify: `lib/design_tokens.dart`(删 `barHigh/barLow/barNormal/barCritical/normalInk/pillHighInk`)、`test/design_tokens_test.dart`(273-305、510-518)
- Rewrite: `test/lab_row_visual_test.dart`
- Modify: `test/mobile_ia_test.dart:101-133`、`test/med_card_test.dart:141`(三档 LabFlag)

**Interfaces:**
- Consumes: Task 1 的 `MedBrand.rangeBar*`;Task 2 的 `statusWord`;`trendYDomain`(`lib/widgets/trend_chart.dart:74`,该文件不 import lab_status,无环)。
- Produces: `labStatusWord(BuildContext, String? flag) → Widget?`;`labRangeFractions({value, refLow, refHigh}) → ({double bandFrom, double bandTo, double markerAt})`;`LabRangeBar({value, refLow, refHigh, markerColor})`。`LabLine` 构造签名不变。

- [ ] **Step 1: 先写测试(红)**

`test/lab_row_visual_test.dart` 整个重写:

```dart
// 化验行(减法稿 2026-09-22):无左色条;右列 = 数值 + 状态词 + 细刻度条;正常不上色不加字。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/lab_status.dart';
import 'package:mobile_flutter/widgets/med_card.dart';

Future<void> pump(WidgetTester t, Widget w, {Size size = const Size(400, 800), double scale = 1.0}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: MedMe.theme(), home: MediaQuery(
    data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
    child: Scaffold(body: Material(child: w)))));
}

bool _hasLeftBar(WidgetTester t) => t.widgetList<Container>(find.byType(Container)).any(
  (w) => (w.decoration is BoxDecoration) && (w.decoration as BoxDecoration).border?.left.width == 4);

void main() {
  const c = MedColors.light;

  testWidgets('偏高:数值 high、「偏高」上色无底、无左色条、圆点 high', (t) async {
    await pump(t, const LabLine(name: '尿素', value: 8.2, unit: 'mmol/L', flag: 'H', refLow: 3.1, refHigh: 8));
    expect(t.widget<Text>(find.text('8.2')).style!.color, c.high);
    expect(t.widget<Text>(find.text('偏高')).style!.color, c.high);
    expect(find.byType(MedPill), findsNothing);
    expect(_hasLeftBar(t), isFalse);
    expect(t.widget<LabRangeBar>(find.byType(LabRangeBar)).markerColor, c.high);
  });

  testWidgets('偏低:数值 low、「偏低」low、圆点 low', (t) async {
    await pump(t, const LabLine(name: '估算肾小球滤过率', value: 63, unit: 'ml/min/1.73m2', flag: 'L', refLow: 90));
    expect(t.widget<Text>(find.text('63')).style!.color, c.low);
    expect(t.widget<Text>(find.text('偏低')).style!.color, c.low);
    expect(t.widget<LabRangeBar>(find.byType(LabRangeBar)).markerColor, c.low);
  });

  testWidgets('正常(N / 无标记):数值 ink、没有任何状态词、圆点 ink3', (t) async {
    for (final flag in ['N', null]) {
      await pump(t, LabLine(name: '心率', value: 70, unit: '/min', flag: flag, refLow: 60, refHigh: 100));
      expect(t.widget<Text>(find.text('70')).style!.color, c.ink);
      expect(find.text('正常'), findsNothing);
      expect(find.text('偏高'), findsNothing);
      expect(find.text('偏低'), findsNothing);
      expect(t.widget<LabRangeBar>(find.byType(LabRangeBar)).markerColor, c.ink3);
    }
  });

  testWidgets('没有参考区间:不画刻度条', (t) async {
    await pump(t, const LabLine(name: '血糖', value: 6.3, unit: 'mmol/L'));
    expect(find.byType(LabRangeBar), findsNothing);
  });

  testWidgets('认不出的标记:原样成「看一眼」chip,数值不上色,圆点 ink3', (t) async {
    await pump(t, const LabLine(name: '钾', value: 5.9, flag: 'HH', refLow: 3.5, refHigh: 5.3));
    expect(find.widgetWithText(MedPill, 'HH'), findsOneWidget);
    expect(t.widget<Text>(find.text('5.9')).style!.color, c.ink);
    expect(t.widget<LabRangeBar>(find.byType(LabRangeBar)).markerColor, c.ink3);
  });

  testWidgets('需核对 chip 仍在名字前', (t) async {
    await pump(t, const LabLine(name: '钾', value: 5.9, unverified: true));
    expect(find.widgetWithText(MedPill, '需核对'), findsOneWidget);
  });

  testWidgets('360×640 @2×:长名 + 长单位 + 偏低 + 参考区间,不溢出', (t) async {
    await pump(t, const LabLine(name: '抗核抗体谱定量(ANA)', value: 63, unit: 'ml/min/1.73m2',
        flag: 'L', refLow: 90, meta: '2026-02-14', unverified: true, onTap: null),
      size: const Size(360, 640), scale: 2.0);
    expect(t.takeException(), isNull);
  });

  group('labRangeFractions(纯函数,与折线图同一个值域)', () {
    test('≥ 90 而实测 63:点在带子左外侧', () {
      final f = labRangeFractions(value: 63, refLow: 90);
      expect(f.bandTo, 1.0);
      expect(f.markerAt, lessThan(f.bandFrom));
    });
    test('≤ 1.7 而实测 1.95:点在带子右外侧', () {
      final f = labRangeFractions(value: 1.95, refHigh: 1.7);
      expect(f.bandFrom, 0.0);
      expect(f.markerAt, greaterThan(f.bandTo));
    });
    test('70 落在 60–100 里:点在带子里', () {
      final f = labRangeFractions(value: 70, refLow: 60, refHigh: 100);
      expect(f.markerAt, inExclusiveRange(f.bandFrom, f.bandTo));
    });
    test('全部在 [0,1] 里', () {
      final f = labRangeFractions(value: 1000, refLow: 0, refHigh: 1);
      for (final v in [f.bandFrom, f.bandTo, f.markerAt]) {
        expect(v, inInclusiveRange(0.0, 1.0));
      }
    });
  });
}
```

跑 `flutter test test/lab_row_visual_test.dart`:预期编译失败(`LabRangeBar`/`labRangeFractions` 不存在)。

- [ ] **Step 2: 实现**

`lib/widgets/lab_status.dart`:文件头 `import 'package:mobile_flutter/widgets/trend_chart.dart' show trendYDomain;`。`labStatusColor` / `labStatusPill` / `labStripeColor` 三个函数换成:

```dart
/// 状态 → 前景色。正常(`null`)与认不出的标记都是正文墨色——减法稿 2026-09-22:
/// **颜色只说状态,正常不上色**(预检裁定 R2 的「正常档也上色」作废)。
Color labStatusColor(BuildContext context, LabStatus? s) {
  final c = MedColors.of(context);
  return switch (s) {
    LabStatus.high => c.high,
    LabStatus.low => c.low,
    LabStatus.unknown || null => c.ink,
  };
}

/// 状态 → 右列那个词:「偏高」/「偏低」是上了色的字(无底,`statusWord`);认不出的
/// 标记原样透出成「看一眼」中性 chip(`MedPill.check`);正常**什么都不画、不加字**。
///
/// 色盲用户靠这个词读语义,正常视力靠颜色和刻度上的点——同一行里两种编码都在。
Widget? labStatusWord(BuildContext context, String? flag) {
  final c = MedColors.of(context);
  return switch (labStatusOf(flag)) {
    null => null,
    LabStatus.high => statusWord('偏高', c.high),
    LabStatus.low => statusWord('偏低', c.low),
    LabStatus.unknown => MedPill.check(flag!.trim()),
  };
}

/// 刻度条上三个位置(0–1):参考带起止与这次的值。值域用折线图同一个 [trendYDomain]
/// (上下各 20% 余量、两端界值都装得进去),所以「≥ 90」而实测 63 时,点在带子左外侧,
/// 而不是被夹到边上。**不做判定**:只是把三个数画在一条线上,颜色由 `flag` 决定。
({double bandFrom, double bandTo, double markerAt}) labRangeFractions({
  required double value,
  double? refLow,
  double? refHigh,
}) {
  final (lo, hi) = trendYDomain([value], refLow: refLow, refHigh: refHigh);
  double at(double v) => ((v - lo) / (hi - lo)).clamp(0.0, 1.0);
  return (
    bandFrom: refLow == null ? 0.0 : at(refLow),
    bandTo: refHigh == null ? 1.0 : at(refHigh),
    markerAt: at(value),
  );
}

/// 细刻度条(减法稿 `.bar`):74×3 的浅条(`line`),参考区间那一段 `ink3` 压 30%,
/// 一枚 9px 圆点标出这次的值。没有参考区间时调用方不画它——没有带子,点就无从落位。
class LabRangeBar extends StatelessWidget {
  const LabRangeBar({super.key, required this.value, this.refLow, this.refHigh, required this.markerColor});

  final double value;
  final double? refLow;
  final double? refHigh;
  final Color markerColor;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final f = labRangeFractions(value: value, refLow: refLow, refHigh: refHigh);
    return SizedBox(
      width: MedBrand.rangeBarWidth,
      height: MedBrand.rangeMarkerSize,
      child: CustomPaint(
        painter: _RangeBarPainter(
          track: c.line,
          band: c.ink3.withValues(alpha: MedBrand.rangeBandAlpha),
          marker: markerColor,
          bandFrom: f.bandFrom,
          bandTo: f.bandTo,
          markerAt: f.markerAt,
        ),
      ),
    );
  }
}

class _RangeBarPainter extends CustomPainter {
  const _RangeBarPainter({
    required this.track, required this.band, required this.marker,
    required this.bandFrom, required this.bandTo, required this.markerAt,
  });

  final Color track;
  final Color band;
  final Color marker;
  final double bandFrom;
  final double bandTo;
  final double markerAt;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    const h = MedBrand.rangeBarHeight;
    const r = Radius.circular(h / 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(0, cy - h / 2, size.width, h), r),
      Paint()..color = track,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(bandFrom * size.width, cy - h / 2, (bandTo - bandFrom) * size.width, h), r),
      Paint()..color = band,
    );
    canvas.drawCircle(Offset(markerAt * size.width, cy), MedBrand.rangeMarkerSize / 2, Paint()..color = marker);
  }

  @override
  bool shouldRepaint(covariant _RangeBarPainter o) =>
      o.track != track || o.band != band || o.marker != marker ||
      o.bandFrom != bandFrom || o.bandTo != bandTo || o.markerAt != markerAt;
}
```

`LabLine.build` 整个换成(类文档改成「无色条:名称 + 说明 | 数值 + 状态词 + 刻度条」;`LayoutBuilder`/`probe` 那套实测折行逻辑**整个删**——右列有了硬上限,名字用 `Expanded` 自己折):

```dart
  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final status = labStatusOf(flag);
    final word = labStatusWord(context, flag);
    final reviewPill = unverified ? MedPill.check('需核对') : null;
    final ref = refRangeText(refLow, refHigh);
    final sub = [
      if (meta case final m? when m.isNotEmpty) m,
      if (ref != null) '参考 $ref',
    ].join(' · ');
    // 认不出的标记不给圆点上色:我们不知道它是高是低。
    final markerColor = switch (status) {
      LabStatus.high => c.high,
      LabStatus.low => c.low,
      LabStatus.unknown || null => c.ink3,
    };
    final unitText = (unit == null || unit!.isEmpty)
        ? null
        : Text(unit!, style: MedType.caption.copyWith(fontSize: 12, color: c.ink3, fontWeight: FontWeight.w400));

    final right = ConstrainedBox(
      // R19 同款上限:长单位(`ml/min/1.73m2`)在 2× 字号下折到数值下一行,不把名字挤没。
      constraints: const BoxConstraints(maxWidth: MedBrand.trendValueMaxWidth),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: 4,
            children: [
              Text(fmtLabNumber(value), style: MedType.value.copyWith(color: labStatusColor(context, status))),
              ?unitText,
            ],
          ),
          if (word != null) ...[const SizedBox(height: 2), word],
          if (refLow != null || refHigh != null) ...[
            const SizedBox(height: 4),
            LabRangeBar(value: value, refLow: refLow, refHigh: refHigh, markerColor: markerColor),
          ],
        ],
      ),
    );

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: MedShape.s3, vertical: MedShape.s2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    if (reviewPill != null) ...[reviewPill, const SizedBox(width: MedShape.s1)],
                    Flexible(child: Text(name, style: MedType.body.copyWith(
                        color: c.ink, fontWeight: FontWeight.w500, fontVariations: MedType.w500))),
                  ]),
                  if (sub.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(sub, style: MedType.secondary.copyWith(color: c.ink3, fontFeatures: MedType.tabular)),
                  ],
                ],
              ),
            ),
            const SizedBox(width: MedShape.s2),
            right,
            if (onTap != null) Icon(Icons.chevron_right, size: 20, color: c.ink3),
          ],
        ),
      ),
    );
  }
```

文件头与 `labStatusOf` 文档里所有「左侧色条」「`barNormal`」「`normalInk`」的说法改成上面这套(不留过时注释)。

`lib/widgets/report_content.dart`:`_flagColor` 的 `LabFlag.normal => MedBrand.normalInk` → `c.ink`;**删** `_stripeColor` 与它唯一的消费者(那行 `Border(left: BorderSide(color: _stripeColor(...), width: 4))` 所在的 decoration 一并删,留内边距);`_flagPill` 改成返回 `statusWord('偏高', c.high)` / `statusWord('偏低', c.low)`(名字改 `_flagWord`),文档同步。

`lib/widgets/profile_sections.dart:1227`:`MedBrand.barCritical` → `c.critical`(该处已有 `c`)。`lib/screens/trends_screen.dart:1147-1180`:`KeyLabsSnapshot` 里「4px 色条要贴着卡边」那段注释删,`padding: EdgeInsets.zero` 那层 `Padding` 直接去掉(`LabLine` 自带内边距)。

`lib/design_tokens.dart`:删 `barHigh/barLow/barNormal/barCritical/normalInk/pillHighInk` 六个;`test/design_tokens_test.dart`:273-305 那条 R22 测试改成断言 `labStatusColor(ctx, null) == c.ink`、`find.text('正常')` 仍为空;510-518 里这六行删。

- [ ] **Step 3: 其他受影响的测试**

`test/mobile_ia_test.dart:101-133`(flag = N 行):断言改成「没有 `MedPill`、没有『偏高/偏低/正常』、数值色 `c.ink`、没有 4px 左边框」。`:196` 那条(值远超区间但 flag 空 → 颜色非 high/low)保留。`test/med_card_test.dart:141` 「三档 LabFlag 各有色条」改成「三档 LabFlag:偏高/偏低是上色的词,正常不上色不加字」(找 `find.text('偏高')`/`'偏低'` 的颜色、`find.text('正常')` 为空、无 4px 左边框)。

- [ ] **Step 4: 跑、提交**

```bash
/Users/ziyuanguan/flutter/bin/flutter analyze
/Users/ziyuanguan/flutter/bin/flutter test test/lab_row_visual_test.dart test/mobile_ia_test.dart test/med_card_test.dart test/design_tokens_test.dart test/for_doctor_visual_test.dart test/trends_visual_test.dart test/document_detail_visual_test.dart test/no_raw_colors_test.dart test/copy_unchanged_test.dart
```

提交:`feat(ui): 减法 Task 4 —— 化验行去色条,状态词 + 刻度条,正常不上色;化验单表格同规则`。

---

### Task 5: 病历主页 —— 成员一行、删「找一找」、整月一张卡、行无图标

**Files:**
- Create: `lib/widgets/member_header.dart`;Delete: `lib/widgets/identity_hero_card.dart`
- Modify: `lib/screens/archive_screen.dart`(`:262-266` `_search`、`:367-380`、`:413-452` 列表、`:510-632` `_TimelineItem`、`:634-705` `_SubDocList`、`:716-811` `_PendingCard`、`:927-961` `MonthHeader`)
- Create: `test/member_header_test.dart`;Delete: `test/identity_hero_card_test.dart`
- Modify: `test/member_no_role_words_test.dart`、`integration_test/journey_members_test.dart:184,187`、`test/archive_header_test.dart`、`test/archive_visual_test.dart`

**Interfaces:**
- Consumes: Task 2 的 `MedCard`/`statusWord`、Task 3 的 `MedIcon`(本页行上的图标这一步**删掉**,不是换)。
- Produces: `MemberHeader({name, gender, age, recordCount, recentVisitDate, onSwitchMember})`;`MonthHeader({label})`(无 `onSearch`);`_byMonth(List<TimelineGroupDto>)`。

- [ ] **Step 1: 测试先行**

`test/member_header_test.dart`(从 `identity_hero_card_test.dart` 搬:保留「null → 暂无」、「点整行 → onSwitchMember」、「3× 字号姓名不截断」、「成员只用名字」这几组,把类型换成 `MemberHeader`;删渐变/白字/头像/`MergeSemantics` 组),并加:

```dart
  testWidgets('一行元数据:性别 · 年龄 · N 份记录 · 最近就诊 · 日期,ink3、tabular', (t) async {
    await pump(t, MemberHeader(name: '张建国', gender: '男', age: '59', recordCount: 52,
        recentVisitDate: '2026-09-18', onSwitchMember: () {}));
    final meta = t.widget<Text>(find.text('男 · 59 · 52 份记录 · 最近就诊 · 2026-09-18'));
    expect(meta.style!.color, MedColors.light.ink3);
    expect(meta.style!.fontFeatures, MedType.tabular);
    expect(find.byType(HeroCard), findsNothing);
  });
```

`test/member_no_role_words_test.dart`、`integration_test/journey_members_test.dart`:`IdentityHeroCard` → `MemberHeader`。`test/archive_header_test.dart`:删 `'月份标题 + 「找一找」占位'`(85-94);`MonthHeader(label: …)` 不再传 `onSearch`。`test/archive_visual_test.dart`:`expectSurfaceBudget(button: 1)`;`'月份标题 15 号 ink2,「找一找」14·500 seal'` 改成 `'月份标题 13 号 ink3'`;加一条「整月的行在一张 `MedCard` 里,行间是 `line2` 分隔线,行上没有 `MedIcon`」——`_homeBlock()` 现在不含时间线行,这条要单独 pump `MonthHeader + MedCard(Column[...])` 的同款结构做不到;**改为断言 `ArchiveScreen` 源码**:`grep -c "MedIcon(" lib/screens/archive_screen.dart` 只在 `_MismatchBanner` 一处——写成 `test('主页时间线的行上没有图标(源码级)')` 读文件数 `MedIcon(` 出现次数 == 1。

- [ ] **Step 2: `MemberHeader`**

`lib/widgets/member_header.dart`:

```dart
import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/doc_labels.dart';

/// 主页顶部那一行:**你是谁,现在看的是谁**。名字一行,下面一行元数据(性别 · 年龄 ·
/// N 份记录 · 最近就诊 · 日期),右边一对 `⌃⌄` —— 整行可点,弹出成员切换器。
///
/// 减法稿 2026-09-22:原来是一张品牌渐变主卡 + 头像块(`IdentityHeroCard`)。切成员的
/// 隐私含义靠**名字本身**说清楚,不靠一块深色面;主页第一眼该落在「有没有要我做的」
/// 那一行上。
class MemberHeader extends StatelessWidget {
  const MemberHeader({
    super.key,
    required this.name,
    required this.gender,
    required this.age,
    required this.recordCount,
    required this.recentVisitDate,
    required this.onSwitchMember,
  });

  /// 显示名。取的是当前成员标签(调用方已经在 `ProfileManager.displayName` 与
  /// 报告识别名之间做过选择),这里只管显示。
  final String name;
  final String? gender;
  final String? age;
  final int recordCount;

  /// 最近一次就诊/添加的日期,`"YYYY-MM-DD"`。没有任何记录、或那条记录没识别到
  /// 日期时为 null —— 显示「暂无」,**不许**当 0 或今天填。
  final String? recentVisitDate;
  final VoidCallback onSwitchMember;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    // 性别/年龄缺失就不写这一段,不编「未登记」——沿用既有行为。
    final subParts = [
      ...[gender, age].whereType<String>().where((x) => x.isNotEmpty),
      '$recordCount 份记录',
    ];
    final recentVisitText = fmtDate(recentVisitDate);
    final meta = '${subParts.join(' · ')} · 最近就诊 · ${recentVisitText.isEmpty ? '暂无' : recentVisitText}';
    return Semantics(
      button: true,
      label: '当前查看:$name。点击切换成员',
      child: InkWell(
        onTap: onSwitchMember,
        borderRadius: BorderRadius.circular(MedShape.radiusControl),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, MedShape.s1, 4, MedShape.s1),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // **不设 maxLines/ellipsis** —— 大字号下姓名换行,不许被截断。
                    Text(name, style: MedType.body.copyWith(
                        color: c.ink, fontWeight: FontWeight.w600, fontVariations: MedType.w600)),
                    const SizedBox(height: 2),
                    Text(meta, style: MedType.secondary.copyWith(color: c.ink3, fontFeatures: MedType.tabular)),
                  ],
                ),
              ),
              const SizedBox(width: MedShape.s1),
              // 切成员的可视提示,与档案屏 `_PatientHeader` 同一图标语汇。
              Icon(Icons.unfold_more, size: 20, color: c.ink3),
            ],
          ),
        ),
      ),
    );
  }
}
```

`git rm lib/widgets/identity_hero_card.dart test/identity_hero_card_test.dart`。`archive_screen.dart:367` 的 `IdentityHeroCard(` → `MemberHeader(`,import 换成 `widgets/member_header.dart`;`main.dart`/`design_tokens.dart` 里提到 `identity_hero_card`/`IdentityHeroCard` 的注释改掉(`grep -rn "IdentityHeroCard\|identity_hero_card" lib test integration_test` 必须为空)。

- [ ] **Step 3: 删「找一找」、月份标题、整月一张卡**

`archive_screen.dart`:删 `_search()`(:260-266 连同文档);`MonthHeader` 改成:

```dart
/// 月份分组标题(`s1`):13 号 `ink3` 小标题,下面接整月的一张卡。
/// 「找一找」搜索占位已删(用户 2026-09-22:没有用的就删掉,Stage 2 搜索做出来再放回)。
class MonthHeader extends StatelessWidget {
  const MonthHeader({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, MedShape.s4, 4, 6),
    child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: MedType.secondary.copyWith(color: MedColors.of(context).ink3)),
  );
}
```

顶层加分段函数(放在 `monthLabel` 旁边):

```dart
/// 时间线按月切段。列表本来就按日期倒序,所以「这一条和上一条不同月」就是新一段。
List<List<TimelineGroupDto>> _byMonth(List<TimelineGroupDto> groups) {
  final out = <List<TimelineGroupDto>>[];
  for (final g in groups) {
    if (out.isEmpty || monthLabel(_groupDate(out.last.first)) != monthLabel(_groupDate(g))) {
      out.add([g]);
    } else {
      out.last.add(g);
    }
  }
  return out;
}
```

列表尾段(:413-452)换成:

```dart
                if (pending.isEmpty && confirmed.isEmpty)
                  const _EmptyState()
                else
                  for (final section in _byMonth(confirmed)) ...[
                    MonthHeader(label: monthLabel(_groupDate(section.first))),
                    // 整月的行在一张卡里,行间细分隔线(减法稿:白卡浅底,层级靠留白)。
                    MedCard(
                      child: Column(
                        children: [
                          for (var i = 0; i < section.length; i++) ...[
                            if (i > 0) Divider(height: 1, thickness: 1, color: c.line2),
                            _TimelineItem(
                              group: section[i],
                              // 按就诊组 id 记展开态(不用列表下标)——删除/导入后下标会错位到别的组。
                              expanded: switch (section[i]) {
                                TimelineGroupDto_Encounter(:final encounter) => _expanded.contains(encounter.id),
                                _ => false,
                              },
                              onTap: () {
                                switch (section[i]) {
                                  case TimelineGroupDto_Document(:final doc):
                                    _openDoc(doc.id);
                                  case TimelineGroupDto_Encounter(:final encounter):
                                    setState(() {
                                      if (!_expanded.add(encounter.id)) _expanded.remove(encounter.id);
                                    });
                                }
                              },
                              onOpenSubDoc: _openDoc,
                              onDelete: _confirmAndDelete,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
```

`_TimelineItem.build`:`final Widget card = MedCard(perforated…, child: Column([...]))` 改成 `final Widget row = Column(children: [InkWell(...), if (expanded) ...])`——**去掉 `MedCard` 外壳、去掉 `MedIcon(icon…)` 和它后面的 `SizedBox(width: s2)`**,`icon` 变量随之删;`Padding` 改成 `EdgeInsets.symmetric(horizontal: MedShape.s3, vertical: MedShape.s2)`;`Dismissible` 分支照旧包 `row`。类文档里关于骑缝线的那段删。`_SubDocList`:删 `MedIcon(...)` 与其后的 `SizedBox`,内边距改 `horizontal: MedShape.s3 + MedShape.s2`(子行比父行再缩进一档)。

`_PendingCard`:删 `MedIcon(...)` 及其后的 `SizedBox`;`MedPill(text: '还没核对', foreground: c.high, background: c.highWash)` → `statusWord('还没核对', c.high)`;`MedCard(perforated: true, …)` 已在 Task 2 去掉参数,外壳保留(还没核对区结构不动)。

- [ ] **Step 4: 跑、提交**

```bash
/Users/ziyuanguan/flutter/bin/flutter analyze
/Users/ziyuanguan/flutter/bin/flutter test test/member_header_test.dart test/member_no_role_words_test.dart test/archive_header_test.dart test/archive_visual_test.dart test/copy_unchanged_test.dart test/glossary_guard_test.dart
```

提交:`feat(ui): 减法 Task 5 —— 主页成员一行取代主卡,删「找一找」,整月一张卡,行无图标`。

---

### Task 6: 趋势 —— 病历本条变白行、「开启」次按钮、最近就诊行无图标

**Files:**
- Modify: `lib/widgets/record_book_strip.dart`(重写)、`lib/widgets/brand_logo.dart:24`(删 `bookSpine`)、`lib/widgets/disease_profile_card.dart:163-166`、`lib/screens/trends_screen.dart:1315-1320`(`_VisitCard`)、`:1365-1382`(`_SectionHeader` 标题样式)
- Modify: `lib/design_tokens.dart`(删 `spineColors/spineStripe/spineStripeOn/spineStripePeriod/spineWidth`)、`test/design_tokens_test.dart`
- Rewrite: `test/record_book_strip_test.dart`;Modify: `test/trends_visual_test.dart`、`test/brand_logo_test.dart`、`test/disease_profile_card_test.dart`

**Interfaces:**
- Consumes: Task 2 的 `MedCard`、`MedSecondaryButton`(禁用态)。
- Produces: `RecordBookStrip` 签名不变(`logo` 默认 `BrandLogo(size: BrandLogo.topBar)`),删 `bigNumberEndPadding`。

- [ ] **Step 1: `RecordBookStrip` 重写**

```dart
import 'package:flutter/material.dart';

import '../design_tokens.dart';
import 'brand_logo.dart';
import 'med_card.dart';

/// 病程档案入口(减法稿):白卡一行 —— 30px 真 logo + 标题 + 一句说明 + 「活动度(化验
/// 可算部分) 0 / 18」这样的一行数字 + `›`。渐变书脊、右列大数都删了:入口要说的是
/// 「这是一本什么档案、现在什么状态」,不是一块颜色。
class RecordBookStrip extends StatelessWidget {
  const RecordBookStrip({
    super.key,
    required this.title,
    required this.subtitle,
    this.bigNumber,
    this.bigNumberSuffix,
    this.bigNumberCaption,
    this.titleTrailing,
    this.logo = const BrandLogo(size: BrandLogo.topBar),
    this.onTap,
  });

  final String title;
  final String subtitle;

  /// 那个数(「0 / 18」「2 项」)。没有就不画这一行 —— 不摆一个「—」占位。
  final String? bigNumber;
  final String? bigNumberSuffix;
  final String? bigNumberCaption;

  /// 标题后面那枚 pill(「示例」)。
  final Widget? titleTrailing;

  /// 真 logo,30px(与顶栏同一档)。传 `null` 则不画。
  final Widget? logo;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return MedCard(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(MedShape.s3, MedShape.s2, MedShape.s3, MedShape.s2),
          child: Row(
            children: [
              if (logo != null) ...[logo!, const SizedBox(width: MedShape.s2)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      // R21:标题可到两行 —— 病名是这条的主体,截成「系统性…」等于没说。
                      Flexible(child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: MedType.body.copyWith(color: c.ink, fontWeight: FontWeight.w500,
                              fontVariations: MedType.w500, height: 1.3))),
                      if (titleTrailing != null) ...[const SizedBox(width: 6), titleTrailing!],
                    ]),
                    const SizedBox(height: 2),
                    Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: MedType.secondary.copyWith(color: c.ink3)),
                    if (bigNumber != null) ...[
                      const SizedBox(height: 2),
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.end,
                        spacing: 4,
                        children: [
                          if (bigNumberCaption != null)
                            Text(bigNumberCaption!, style: MedType.secondary.copyWith(color: c.ink3)),
                          Text(bigNumber!, style: MedType.value.copyWith(color: c.ink)),
                          if (bigNumberSuffix != null)
                            Text(bigNumberSuffix!, style: MedType.secondary.copyWith(color: c.ink3)),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: MedShape.s1),
                Icon(Icons.chevron_right, size: 20, color: c.ink3),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
```

`_Spine`/`_StripePainter` 删;`brand_logo.dart` 删 `bookSpine`(类文档「四处」改成「三处」:主页顶栏、病程档案页头、首启);`design_tokens.dart` 删五个 `spine*`;`design_tokens_test.dart` 里对应行删。`disease_profile_card.dart:229` 那段「不上渐变面」注释删;`:163-166`:

```dart
            action: MedSecondaryButton(
              label: '开启',
              onPressed: _busy ? null : () => _enable(packageId),
            ),
```

(加 import `brand_surfaces.dart`。)`_ProfileEntry` 里「不画 chevron —— mockup `.book` 没有这个格子(R21)」那句注释删:减法稿这行**有** `›`。

- [ ] **Step 2: 趋势页其余**

`trends_screen.dart:1315-1320`:删 `_VisitCard` 里的 `MedIcon(...)` 与其后的 `SizedBox`(连同那段光泽块注释)。`_SectionHeader`(:1365-1382):标题样式改 `MedType.secondary.copyWith(color: c.ink3)`,类文档「与 MonthHeader 同一档:15 号 ink2…」改成「13 号 ink3」;右侧动作(`actionLabel`)保持 14·500 `seal`。

- [ ] **Step 3: 测试**

`test/record_book_strip_test.dart` 重写为 5 条:① 是一张 `MedCard`(`find.byType(MedCard)` 1),整树没有 `gradient != null` 的 `BoxDecoration`;② 默认 logo 30(`find.byType(BrandLogo)` 的 `size == BrandLogo.topBar`),`logo: null` 时没有;③ 标题/说明/数字行三段文字都在(`bigNumberCaption: '活动度(化验可算部分)'`、`bigNumber: '0 / 18'`),数字 `MedType.value` `ink`;④ `onTap` 传了才有 `›`,tap 触发;⑤ 360×640 @2× 长标题不溢出。`test/trends_visual_test.dart:13-20`:「零个渐变面;病程档案入口是病历本条」→ `expectSurfaceBudget()` + `find.byType(RecordBookStrip)` 存在;`:48` 同步。`test/brand_logo_test.dart` 删 `bookSpine` 断言。`test/disease_profile_card_test.dart`:「开启」仍用 `find.text('开启')`,`_busy` 时按钮禁用的断言(若有)改成 `MedSecondaryButton.onPressed == null`。

- [ ] **Step 4: 跑、提交**

```bash
/Users/ziyuanguan/flutter/bin/flutter analyze
/Users/ziyuanguan/flutter/bin/flutter test test/record_book_strip_test.dart test/trends_visual_test.dart test/trends_screen_test.dart test/disease_profile_card_test.dart test/brand_logo_test.dart test/design_tokens_test.dart test/copy_unchanged_test.dart
```

提交:`feat(ui): 减法 Task 6 —— 病程档案入口变白行,「开启」次按钮,最近就诊行无图标,删书脊令牌`。

---

### Task 7: 给医生看 —— 每节一张卡、无图标、顺序 变化 → 过敏/用药 → 我想问医生的

**Files:**
- Modify: `lib/screens/visit_summary_sheet.dart`(`:86-154` body、`:173-230` `_NotesSection`、`:283-342` `_DoctorMayAskSection`、`:344-410` `_MedsSubsection`、`:436-478` `_Section`、`_LineRow`/`_NoteRow` 内边距)
- Modify: `lib/screens/for_doctor_screen.dart:158-163`(顺序注释)
- Modify: `test/for_doctor_visual_test.dart`、`test/for_doctor_screen_test.dart`、`test/for_doctor_refresh_test.dart`(只在断言顺序/图标处)

**Interfaces:**
- Consumes: Task 2 `MedCard`、Task 4 `LabLine`。
- Produces: `_Section({title, emptyText, isEmpty, children})`(无 `icon`/`category`),渲染「小标题 + 一张卡」。

- [ ] **Step 1: 测试先行**

`test/for_doctor_visual_test.dart`:删 `:236-263` 与 `:59-72` 里对图标类别的断言;加:

```dart
  testWidgets('顺序:我最近的变化 → 过敏史 → 记录中出现的药物 → 我想问医生的;每节一张卡;节内无图标', (t) async {
    await pumpStage3(t, _screenWithData());
    await t.pumpAndSettle();
    double y(String s) => t.getTopLeft(find.text(s).first).dy;
    expect(y('我最近的变化'), lessThan(y('过敏史')));
    expect(y('过敏史'), lessThan(y('记录中出现的药物')));
    expect(y('记录中出现的药物'), lessThan(y('我想问医生的')));
    expect(find.descendant(of: find.byType(VisitSummaryBody), matching: find.byType(MedIcon)), findsNothing);
    expect(find.descendant(of: find.byType(VisitSummaryBody), matching: find.byType(MedCard)), findsNWidgets(4));
    expectSurfaceBudget(button: 1);
  });
```

(`_screenWithData()` = 该文件已有的带过敏/用药/化验/笔记夹具的 pump 方式;没有就照 `for_doctor_refresh_test.dart` 的 `summaryWithNote` 拼一个,四节都非空。)

- [ ] **Step 2: 实现**

`_Section`:

```dart
/// 一节 = 小标题(13·ink3)+ 一张卡。空态那句话就在卡里。减法稿:标题前不再有图标。
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.emptyText, required this.isEmpty, required this.children});

  final String title;
  final String emptyText;
  final bool isEmpty;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: MedShape.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
            child: Text(title, style: MedType.secondary.copyWith(color: c.ink3)),
          ),
          MedCard(
            child: isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(MedShape.s3),
                    child: Text(emptyText, style: MedType.body.copyWith(color: c.ink2, height: 1.5)),
                  )
                : Column(children: [
                    for (var i = 0; i < children.length; i++) ...[
                      if (i > 0) Divider(height: 1, thickness: 1, color: c.line2),
                      children[i],
                    ],
                  ]),
          ),
        ],
      ),
    );
  }
}
```

body(:86-154):删外层那张 `MedCard` 与它的 `Padding(s4)`,children 顺序改为 `_Section('我最近的变化')` → `_DoctorMayAskSection` → `_NotesSection` → `footer`;`SizedBox(height: s4)` 改 `s3`。三个 `_Section(` 调用删 `icon:`/`category:`。`for_doctor_screen.dart:158-163` 那段「顺序还没对」的注释改成现在的顺序。

`_DoctorMayAskSection`:`Text('医生可能要问的')` + 那句「逐字来自…」外面包 `Padding(fromLTRB(4,0,4,s2))`,其余照旧。

`_MedsSubsection` 非空分支:标题行删 `MedIcon(...)` 与其后的 `SizedBox`,标题行外包 `Padding(horizontal: 4)`;`if (expanded)` 里的 `RecordedMedsCaveat` + 行列表包进一张 `MedCard(child: Column([Padding(all: s3, child: RecordedMedsCaveat()), for rows: Divider + row]))`。

`_NotesSection`:标题行(`我想问医生的` + 「加一条」)外包 `Padding(horizontal: 4)`;空态句与 `_NoteRow` 列表包进 `MedCard`(空态 `Padding(all: s3)`;行之间 `Divider(line2)`)。

`_LineRow`、`_NoteRow`:各自最外层 `Padding` 改成 `EdgeInsets.symmetric(horizontal: MedShape.s3, vertical: MedShape.s2)`(原来是卡内 `s4` 统一垫的,现在行自己垫)。`_LabRow` 不动(`LabLine` 自带)。

- [ ] **Step 3: 跑、提交**

```bash
/Users/ziyuanguan/flutter/bin/flutter analyze
/Users/ziyuanguan/flutter/bin/flutter test test/for_doctor_visual_test.dart test/for_doctor_screen_test.dart test/for_doctor_refresh_test.dart test/known_defect_setstate_future_test.dart test/copy_unchanged_test.dart
```

提交:`feat(ui): 减法 Task 7 —— 给医生看每节一张卡、节头无图标,顺序 变化 → 过敏/用药 → 我想问医生的`。

---

### Task 8: 令牌收尾 + 「无渐变无阴影」静态闸 + 全量

**Files:**
- Modify: `lib/design_tokens.dart`(删 `gradientColors/gradientStops/gradientBegin/gradientEnd/heroGlow/heroTileSize/heroTileLetterSize/heroTileInset/heroTileShadow/cardShadow/heroShadow/entryShadow/buttonShadow/navShadow/chipShadow/qrShadow`、`MedShape.radiusHero/radiusEntry`、`MedColors.onDarkMeta` 若无读者;文件头与 `MedBrand` 类文档改写)
- Modify: `test/design_tokens_test.dart`(删对应组:品牌渐变、五档阴影、头像块;圆角组改成六档)
- Create: `test/no_gradient_no_shadow_test.dart`
- Modify: `test/stage3_visual_helpers.dart`(加 `expectNoGradientAnywhere`)+ 它的 12 个调用文件(每处 `expectSurfaceBudget(...)` 后面加一行 `expectNoGradientAnywhere();`)
- Create: `docs/log/2026-09-22-ux-stage3-5-subtraction.md`(仓库根)

**Interfaces:**
- Produces: `expectNoGradientAnywhere()`;静态闸。

- [ ] **Step 1: 令牌孤儿全删**

```bash
cd apps/mobile_flutter
for t in gradientColors gradientStops gradientBegin gradientEnd heroGlow heroTileSize heroTileLetterSize heroTileInset heroTileShadow cardShadow heroShadow entryShadow buttonShadow navShadow chipShadow qrShadow radiusHero radiusEntry onDarkMeta heroValue expandedChartBg timelineLine; do printf '%-20s %s\n' "$t" "$(grep -rl "\b$t\b" lib test | grep -v design_tokens | tr '\n' ' ')"; done
```

读者为空的一律从 `lib/design_tokens.dart` 删掉(`heroValue` 若 `account_screen.dart` 还在用就留;`expandedChartBg`/`timelineLine` 有读者就留)。**同时删 `MedColors.shadowColor` 字段与 `shadow` getter**(零读者,且 getter 里的 `BoxShadow(` 会被 Step 2 的静态闸命中):构造器、`copyWith`、`lerp`、`==`、`hashCode`、`light`/`dark` 两套值、`test/design_tokens_test.dart` 的 `specLight`/`specDark` 表与「lerp 不丢字段」测试一并去掉这一项。`MedShape.radiiDescending` 保持 `[radiusCard, radiusBlock, radiusControl]`(16/14/10,仍递减)。文件头「Stage 3 视觉令牌 brief 取代了…」「MedBrand:渐变、阴影、类别色、状态条、横幅」整段改写成「Stage 3.5 减法(2026-09-22):无渐变、无阴影、无类别色;`MedBrand` 只剩横幅/示例/看一眼配色、时间轴与展开区底、图标槽、刻度条尺寸」。`test/design_tokens_test.dart` 同步删组。

- [ ] **Step 2: 静态闸**

`test/no_gradient_no_shadow_test.dart`:

```dart
// 减法稿 2026-09-22:全 lib/ 不许有渐变和阴影。层级靠字号、留白、1px 细边。
// 与 no_raw_colors_test.dart 同一手法:扫源码,不扫渲染。折线图若要一块数据可视化
// 用的渐变填充,前一行写 `// 允许:图表` 放行(与 motion_test.dart 的标注法一致)。
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

final _banned = RegExp(r'\b(LinearGradient|RadialGradient|SweepGradient|BoxShadow)\s*\(|\bboxShadow\s*:');

void main() {
  test('lib/ 里没有渐变、没有阴影', () {
    final hits = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i];
        if (l.trimLeft().startsWith('//')) continue;
        if (!_banned.hasMatch(l)) continue;
        if (i > 0 && lines[i - 1].contains('// 允许:图表')) continue;
        hits.add('${f.path}:${i + 1}: ${l.trim()}');
      }
    }
    expect(hits, isEmpty, reason: '减法稿:不许渐变、不许阴影\n${hits.join('\n')}');
  });
}
```

先跑它,把命中的地方逐个处理:是残留装饰就删;是折线图的参考带/面积填充才加 `// 允许:图表`。

`test/stage3_visual_helpers.dart` 加:

```dart
/// 减法稿的另一半:整棵树里一个渐变都没有(静态闸管源码,这条管渲染出来的树)。
void expectNoGradientAnywhere() {
  bool hasGradient(Decoration? d) => d is BoxDecoration && d.gradient != null;
  expect(
    find.byWidgetPredicate((w) =>
        (w is Container && hasGradient(w.decoration)) ||
        (w is DecoratedBox && hasGradient(w.decoration)) ||
        (w is Ink && hasGradient(w.decoration))),
    findsNothing,
    reason: '树里还有渐变面',
  );
}
```

12 个调用 `expectSurfaceBudget(` 的测试文件,每处后面加一行 `expectNoGradientAnywhere();`。

- [ ] **Step 3: 全量 + 溢出**

```bash
/Users/ziyuanguan/flutter/bin/flutter analyze
/Users/ziyuanguan/flutter/bin/flutter test
```

全绿。`grep -rn "Stage 3\b\|brief §\|mockup \`" lib --include='*.dart' | wc -l`——把明显过时的注释(引用已删令牌/光泽块/渐变预算的)顺手清掉,**不改文案**。

- [ ] **Step 4: log**

`docs/log/2026-09-22-ux-stage3-5-subtraction.md`(仓库根,精炼,≤ 40 行):为什么(用户原话两句)、六条原则、删了什么(令牌/widget 清单一行一个)、三道闸的变化(文案闸 `kRemovedByDecision`;预算闸改 `expectSurfaceBudget` + `expectNoGradientAnywhere`;新静态闸)、与稿子的三处有意偏差、后面可做(器官小图标)。

- [ ] **Step 5: 提交**

`chore(ui): 减法 Task 8 —— 删孤儿令牌,加无渐变无阴影静态闸,log`。

---

## 执行后(控制者,不派子代理)

- Task 9(我做):模拟器上跑 demo 数据截 病历 / 趋势 / 给医生看 三屏(`scratchpad/stage3-shots` 同款流程),发给用户对照稿子;更新 memory `ui-direction-medical-blue`;开 PR `feat/ux-stage3-5-subtraction → main`,**不合并**,等用户的话。
- 隐私政策:本次不动数据流向,`privacy.html` 不需要改(CLAUDE.md 硬规矩 4 核过:只改样式)。

## 已知分歧(计划作者自查,执行时按此)

1. `MedPill` **保留**(带浅底的标签仍用于病程档案页的类型/分数/已换算等标签);只有化验状态与「还没核对」改成无底的 `statusWord`。
2. `HeroCard` 在换新手机 s15 / 代拍交付 s14 / 代拍首页 三处**保留为实色卡**(那三屏唯一的一块颜色面),卡内白字不动;`account_visual_test:333`、`proxy_handoff_visual_test:57` 的 `hero: 1` 照旧。
3. `MedColors.shadowColor` / `shadow` getter 零读者,Task 8 连同 `ThemeExtension` 四处样板一起删(静态闸不给令牌层开口子)。
4. `proxy_intake_visual_test` 头注释说代拍流程刻意不用 `MedPrimaryButton`——不动。
