# UI/UX Stage 1:词表统一 + 三 tab 信息架构 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把手机端底栏从 5 tab 改成 `病历 | 趋势 | 我`(「给医生看」是从「病历」首页推进去的一整页),并按 ia-proposal §3 的 11 组词表把全部用户可见字符串替换成唯一用词,同时清掉所有「不上传 / 只在这台手机上 / 没有账号」的过时对外声明。

**Architecture:** 三条线并行推进,互相之间用 `test/glossary_guard_test.dart` 这一个源码禁词闸串起来。① **词表**:禁词闸是一个读 `lib/**/*.dart` 源码的普通 `flutter test`,它持有 11 组「旧 → 新」映射表和一份 `kEnforced` 已启用禁词列表;每个 Task 往 `kEnforced` 里加自己那几个词 → 测试变红 → 替换字符串 → 变绿。② **结构**:`HomeTab`(`lib/vault_events.dart`)+ `HomeShell.tabScreens`/`tabDestinations`(`lib/main.dart`)+ `AnalyticsTab`(`lib/analytics.dart`)这三处下标必须同时改,`test/mobile_ia_test.dart` 已有的「tab 数 == 页面数 == 底栏项数」断言就是防止漏改一处的看门测试。③ **流程**:「云端整理」首次导入问一次、未登录不给出码,各自是一处判断 + 一处 UI。

**Tech Stack:** Flutter 3.x / Dart SDK ^3.12.2、`flutter_test`(widget test,**无 Rust 原生库**)、`shared_preferences`。

**Spec:**
- `.superpowers/sdd/ux-overhaul/ia-proposal.md`(推荐 IA A 已拍板;§3 = 11 组词表;§6 = 分期与 Done 判据)
- `.superpowers/sdd/ux-overhaul/ux-audit-2026-09-16.md`(44 屏逐屏表;§3 同义词簇;§4 过时文案逐字 + file:line)
- `.superpowers/sdd/ux-overhaul/stage1-plan-brief.md`(本阶段范围与硬约束)

## Global Constraints

- **分支**:所有工作在临时 worktree 分支 `feat/ux-stage1`,从 `feat/advanced-a` 当前 HEAD(`ba808bd`)建。**不 push。**
- **可碰的路径**:`apps/mobile_flutter/lib`、`apps/mobile_flutter/test`、`apps/mobile_flutter/ios/Runner/Info.plist`、`apps/mobile_flutter/android` 的文案资源、`gh-pages` worktree(`/Volumes/extraSupply/Projects/Medme-ghpages`)的 `privacy.html`。
- **绝对不碰**:`packages/`、`services/`、`rust/`、以及 FRB 生成物 `apps/mobile_flutter/lib/src/rust/**`(另一条线在并行改 Rust)。
- **不做**:视觉层、颜色、字号、动效;病程档案的内容;医生代拍流程的重做(只换入口与词)。
- **测试前台跑**:`cd apps/mobile_flutter && flutter test <path>`,不用 `run_in_background`。
- **`flutter test` 不加载 Rust 原生库。** 任何在字段初始化处调 FFI 的整屏 widget(`OverviewScreen`、`TrendsScreen`、`VisitSummarySheet`、`EmergencyCardScreen`、`ForDoctorScreen`)**不能** `pumpWidget` 整屏 —— 只 pump 已拆出来的纯 widget(`QuickActions`、`VisitSummaryBody`、`EmergencyBigCardScreen`、`ForDoctorActions`)或断言 `static const` 列表。这是本项目反复踩过的坑,见 `test/overview_quick_actions_test.dart` 顶部注释。
- **禁词闸的适用范围(协调人已裁定)**:**用户可见字符串必须清干净,一处不留**;Dart 标识符与代码注释里绕不开的普通词(`导入` / `分享` / `授权`)**排除在闸外**,`保险箱` 这类内部容器说法统一改写成「**病历箱**」即可,不必强行套用户词表。Task 17 会把这条差异写进提交信息交评审。
- **词表按 ia-proposal §3 逐字执行**,11 组的选定词:`添加` / `云端`(下分 `云端备份`、`云端整理`)/ `成员` / `病历`(容器与一份同词)/ `给医生看` / `文字` / `代拍` / `口令`+`恢复码` / `给` / `核对`。另加两条:`数据出口`→`给医生看 · 导出`,`数据管理`→`删掉全部`。
- **偏好键沿用 `cloud_extract_enabled`**(常量 `cloudExtractEnabledKey`,定义在 `lib/account.dart:29`)。**不新建键**,新增的「问过没有」用另一个键 `cloud_extract_asked`。
- **默认值不预设**:首次导入那个一次性 sheet 上,「开 / 不开」两颗按钮视觉权重相同,没有预选。
- **云备份**仍然登录即默认开 —— 本阶段只改「云端整理」的征询时机。
- **核心流程导航深度 ≤3**:添加、趋势、给医生看三条路,从底栏点到终点不超过 3 层。
- **已批准的 mockup = 结构与文案的事实来源**:
  `<scratchpad>/mockups/medme-ui-directions.html`(**v24**),模板 `s1`–`s17`。
  **实现前先读对应那一屏的 template**,`ia-proposal` 与本计划里的任何描述与它冲突时,
  **以 mockup 为准**。对照表:

  | template | 屏 | 对应 Task |
  |---|---|---|
  | `s1` | 病历 tab | 5、6 |
  | `s2` | 趋势 tab | 8 |
  | `s3` | 病程档案(Stage 2 内容,Stage 1 只留入口) | 8 |
  | `s4` | 给医生看(整页) | 3、9、10 |
  | `s5` | 我 tab | 12、13 |
  | `s6` | 添加 sheet | 5 |
  | `s7` | 还没核对 | 6 |
  | `s8` | 一份病历详情 | 7 |
  | `s9` | 记录一下 | 8 |
  | `s10` | 某个成员自己的页面 | 12、13 |
  | `s11` `s12` `s15` | 登录 / 设口令 / 拿回病历 | 14 |
  | `s13` | 出码 + 第一次告知 | 11 |
  | `s14` | 替病人代拍 | 15 |
  | `s16` | 首启 | 2 |
  | `s17` | 云端整理问一次 | 16 |

- **mockup 决定(创始人,晚于 ia-proposal,冲突时以此为准)**:
  - **底栏三个 tab:`病历 | 趋势 | 我`**。**「给医生看」不是 tab** —— 它是从「病历」tab 首页那颗主按钮**推进去的一整页**。
  - **「趋势」保留原名**(不叫「看懂」),「病程档案」的入口位落在这个 tab 里。
  - **成员相关的界面上不出现任何亲属/角色词**(家人、家属、主人、可编辑、只读、editor/viewer/owner):「我」里那份名单、身份卡**只显示名字 + 份数**;角色(`能改` / `只能看 · 剩 N 天`)**只在某一个成员自己的页面里**说(`s10`)。
  - **「我」tab 的云端行是一行两段**(`s5`):标题 `云端`、副标题 `已备份,刚刚`、末尾 `›`,整行可点;**「云端整理」在成员自己的页面里**(`s10`),不在「我」的首屏平铺。
  - **不要「今天带给医生的」这类分区标题** —— 「给医生看」那一页推进来就是内容(`s4`)。
  - **「病历」tab 顶部保留现有的 `IdentityHeroCard`**(头像 + 名字 + `⌃⌄` 切换 + `男 · 61 岁 · 5 家医院 · 31 份` + 最近就诊一行)。**没有 MemberChip,顶栏不加任何成员 chip**(`s1`)。
  - **hero 下面是两颗等宽的 `QuickActions` 样式方块**:`添加`(主色填充)与 `给医生看`(白底)。**不是一条通栏大按钮**(`s1`)。
  - ⚠️ **与 ia-proposal §2 的分歧,留档**:那份提案推荐候选 A(4 tab,「给医生看」进底栏),并写明拒绝候选 B 的理由是「老人在底栏找不到『给医生看』」。mockup 选了接近 B 的形态。**执行按 mockup**,这条只作记录,不作阻拦;风险在 Task 19 冒烟里验(老人能不能找到那颗按钮)。
- **老人是主要用户**:所有新文案是大白话,不出现 HTTP 状态码、异常类名、英文缩写。

---

## File Structure

**新建**

| 文件 | 职责 |
|---|---|
| `apps/mobile_flutter/test/glossary_guard_test.dart` | 11 组「旧 → 新」映射表(`kGlossary`)+ 已启用禁词列表(`kEnforced`)+ 扫 `lib/**/*.dart` 的源码闸。全阶段唯一的词表事实来源。 |
| `apps/mobile_flutter/lib/screens/for_doctor_screen.dart` | 「给医生看」**整页**(从「病历」tab 的主按钮推进去,不是 tab)。`ForDoctorScreen`(取数,碰 FFI)+ `ForDoctorActions`(纯 widget,四条入口:出码 / 打印导出 / 急救 / 我是医生,替病人代拍)。 |
| `apps/mobile_flutter/lib/screens/cloud_extract_ask_sheet.dart` | 第一次导入时问一次「云端整理」的一次性 sheet + `shouldAskCloudExtract` 纯判断。 |
| `apps/mobile_flutter/test/for_doctor_screen_test.dart` | `ForDoctorActions` 四条入口的回调与文案。 |
| `apps/mobile_flutter/test/cloud_extract_ask_test.dart` | 「问一次」的判断与 sheet 两颗按钮。 |
| `apps/mobile_flutter/lib/screens/qr_notice_sheet.dart` | 第一次出码时的一次性告知 sheet + `shouldShowQrNotice` 纯判断(Task 11)。 |
| `apps/mobile_flutter/test/qr_notice_test.dart` | 第一次 / 之后两种情况。 |
| `apps/mobile_flutter/test/info_plist_copy_test.dart` | 读 `ios/Runner/Info.plist`,钉住两条用途说明里没有「不会上传」。 |

**不改名**

mockup 把「趋势」留在底栏、也留着原名,所以 `lib/screens/trends_screen.dart` 与
`TrendsScreen` **一个字都不动** —— 它只是多长出「病程档案」入口、化验快照、最近就诊
和一颗成员 chip(Task 8)。

**改**

| 文件 | 改什么 |
|---|---|
| `lib/vault_events.dart:14-51` | `HomeTab` 五个常量 → 三个(`records/trends/me`);`goToArchive`、`goToEmergencyCard` 降级成过渡 shim(Task 9 删),`goToTrends` 保留为真函数,新增 `goToRecords`/`goToMe`。 |
| `lib/main.dart:611-663` | `HomeShell.tabScreens` / `tabDestinations` 各 5 → **3**;`_modeRoot()`(`:568-580`)去掉 `ModePickerScreen` 分支。 |
| `lib/analytics.dart:738-749` | `AnalyticsTab` 枚举五值 → **三值**(`records/trends/me`)。 |
| `lib/screens/doctor/doctor_claim_link_dialog.dart` | 删掉全仓无人调用的 `cloudProfile` 转移分支与 `resolveDoctorClaimUrl`(Task 15)。 |
| `lib/screens/archive_screen.dart` | 顶栏标题 `档案`→`病历`(`:253`)、去掉「看病带这个」剪贴板第二入口(`:262-270`)、`导入`→`添加`(`:295`);body 顶部按 `s1` 摆 hero + 两颗方块(`HomeTiles`)+ `PendingReviewBanner` + 按月分组(`MonthHeader` + 找一找占位);`待确认`→`还没核对`(`:967`)、删掉每行的「点开核对并确认」(`:985-991`)。**顶栏不加成员 chip**。 |
| `lib/screens/settings_screen.dart` | 成为「我」tab:标题 `设置`→`我`(`:352`)、删「模式」分区(`:356-370`)、`保险箱`→`成员`(`:397`)、`数据出口`→`给医生看 · 导出`(`:412`)、`数据管理`→`删掉全部`(`:461`)、云端状态行、版本行(`:527`)。 |
| `lib/screens/document_detail.dart` | `识别文本 / 文档内容`→`文字`(`:339`,`s8` 的三个切换是 表格/文字/原件)、删识别质量徽标(`:434-483`)、`确认无误,归入档案`→`没问题`(`:163`,`s7`)。 |
| `lib/screens/doctor/proxy_document_detail.dart:389` | 同上的 `文字`。 |
| `lib/screens/overview_screen.dart` | 整屏解散:`QuickActions`/`VisitSheetBanner` 删除,化验快照与最近就诊搬进「趋势」(Task 8),`IdentityHeroCard` 移进「我」。 |
| `lib/screens/qr_share_screen.dart` | **第一次**出码时先弹一次告知 sheet(`qr_notice_seen`);登录与否都照常出码。 |
| `lib/screens/first_run_consent.dart:318-345` | 四条声明重写。 |
| `lib/screens/emergency_card_screen.dart` | 从 tab 降级为「给医生看」push 进来的一屏;`EmergencyBigCardScreen` 一字不动。 |
| `lib/screens/mode_picker_screen.dart` | 删除整个文件。 |
| `lib/screens/account_screen.dart` | 云端三词收敛、家属→成员、密钥→口令。 |
| `lib/import_flow.dart` | 三选一标题 `添加病历`→`添加`;首次导入接上「问一次」sheet。 |
| `lib/screens/export_screen.dart` | 标题与两条卡的用词。 |
| `ios/Runner/Info.plist:70,72` | 两条用途说明。 |
| `test/mobile_ia_test.dart:771-808` | 「五 tab」group 改成「三 tab」。 |
| `test/overview_quick_actions_test.dart` | 随 `QuickActions` 删除而删除。 |
| `test/doctor_claim_link_dialog_test.dart` | 四条全是 `resolveDoctorClaimUrl` 的测试,随那个函数一起删(Task 15)。 |
| `test/analytics_catalog_test.dart` | 随 `AnalyticsTab` 改三值而更新。 |
| `/Volumes/extraSupply/Projects/Medme-ghpages/privacy.html` | §三.7「登录后自动进行」→「第一次导入时询问」;词表涉及的对外用词。 |

---

### Task 0: 建 worktree 分支

**Files:**
- 无(只建分支)

**Interfaces:**
- Consumes: 无
- Produces: worktree `/Volumes/extraSupply/Projects/Medme-ux-stage1`,分支 `feat/ux-stage1`

- [ ] **Step 1: 从 feat/advanced-a 当前 HEAD 建 worktree**

```bash
cd /Volumes/extraSupply/Projects/Medme-adv-a
git rev-parse HEAD   # 应为 ba808bd...,记下来写进第一条 commit message
git worktree add -b feat/ux-stage1 /Volumes/extraSupply/Projects/Medme-ux-stage1 HEAD
```

- [ ] **Step 2: 确认基线绿**

Run: `cd /Volumes/extraSupply/Projects/Medme-ux-stage1/apps/mobile_flutter && flutter pub get && flutter test`
Expected: PASS(全部 66 个测试文件)。**若基线本来就红,先停下来报告,不要在红的基线上开工。**

> 以下所有 Task 的路径,`<repo>` 均指 `/Volumes/extraSupply/Projects/Medme-ux-stage1`,`<app>` 指 `<repo>/apps/mobile_flutter`。

---

### Task 1: 词表映射表 + 源码禁词闸(拿「数据出口 / 数据管理」验闸)

**Files:**
- Create: `<app>/test/glossary_guard_test.dart`
- Modify: `<app>/lib/screens/settings_screen.dart:412`、`<app>/lib/screens/settings_screen.dart:461`

**Interfaces:**
- Consumes: 无
- Produces:
  - `const Map<String, String> kGlossary`(旧词 → 新词,ia-proposal §3 全量;供后续每个 Task 查表,**不在运行时被任何代码 import**)
  - `const List<String> kEnforced`(当前已启用的禁词;后续每个 Task 往这里加自己那几个)
  - `List<String> scanLib(String word)` → 返回 `'相对路径:行号'` 列表,已排除 `lib/src/rust/`

- [ ] **Step 1: 写这个失败的测试**

```dart
// 词表闸:ia-proposal §3 的 11 组「一簇一个词」,由一个扫源码的测试来兑现。
//
// 为什么是测试而不是运行时的常量表:界面上的字就该是字面量,谁读代码谁一眼看到
// 屏上会显示什么。把它们塞进一张运行时的 map 只会多一层间接,而真正会腐坏的不是
// 「查不到表」,是「有人又写了一个旧词」—— 那件事只有扫源码拦得住。
//
// 用法:每完成一屏的替换,就把那几个旧词加进 [kEnforced]。列表长到与
// ux-audit §4 的那条 grep 一致时,Stage 1 的词表部分就做完了。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 11 组同义词簇的「旧 → 新」全量映射(ia-proposal §3)。**这是本阶段的词表事实
/// 来源**,每个 Task 改文案前先查这张表,不要自己另想一个词。
const Map<String, String> kGlossary = {
  // 1 把纸变成记录 → 添加
  '存档': '添加', '导入': '添加',
  // 「添加病历」**不进闸**:mockup `s6` 把添加 sheet 的标题就留成这四个字,
  // 而「第一次添加病历时问你一次」这类句子也是正常白话。簇 1 要统一的是
  // 「存档 / 归档 / 采集」那几个动词,不是这个名词短语。
  '归档': '添加', '最近归档': '最近添加', '采集': '添加', '继续采集': '添加',
  // 2 云 → 云端(备份 / 整理)
  '云同步': '云端备份', '云备份': '云端备份', '云端备份': '云端备份', '同步': '云端备份',
  '云端识别': '云端整理', '云端整理': '云端整理',
  // 3 人 → 成员
  '家属': '成员', '家人': '成员', '主人': '本人', '可编辑': '家人(能改)', '只读': '医生(只能看)',
  // 4 + 5 文档容器 / 一份东西 → 病历(故意同词)
  '档案': '病历', '保险箱': '病历', '今日病历表': '今天代拍的',
  '文档': '一份病历', '文档详情': '一份病历', '单据': '病历照片', '单据图': '病历照片',
  // 6 诊室那一页 → 给医生看
  '看病带这个': '给医生看', '就诊单': '给医生看',
  // 7 正文段落标题 → 文字
  '识别文本': '文字', '文档内容': '文字', '识别质量': '',  // 徽标整个删,没有替代词
  // 8 医生那套 → 代拍
  '医生模式': '代拍', '为病人代建档': '代拍', '逐份核对': '核对',
  // 代拍**入口**全 App 只有一句话(Task 15);「代拍」作名词时照旧。
  '为病人代拍': '我是医生,替病人代拍', '替病人拍': '我是医生,替病人代拍',
  // 9 密钥材料 → 口令 + 恢复码
  '密码': '口令', '密钥': '口令', '账号密钥': '口令', '生成密钥': '设好了',
  // 10 给别人看 → 给
  '分享': '给医生看 / 给家人看', '授权': '给过谁看', '转让': '把病历交给他',
  '认领码': '取件码', '认领链接': '取病历的链接',
  // 11 确认一份 → 核对
  // 词按 mockup `s1`/`s7` 定:横幅与 pill 都是「还没核对」,行上那对按钮是
  // 「看原件」/「没问题」。
  '待确认': '还没核对', '点开核对并确认': '', '确认无误,归入档案': '没问题', '确认这一份': '没问题',
  // 不属于任何簇,同批改
  '数据出口': '给医生看 · 导出', '数据管理': '删掉全部',
};

/// 已经启用的禁词。**每个 Task 只加自己那一屏清干净的词。**
/// 终点是 ux-audit §4 Done 判据②里那条 grep 的全集(见 Task 17)。
const List<String> kEnforced = ['数据出口', '数据管理'];

/// 扫 `lib/**/*.dart` 找这个词。排除 FRB 生成物(`lib/src/rust/`)—— 那是机器
/// 产出,本阶段硬约束里明确不碰。
///
/// 匹配的是**子串**,所以词要选得准:像「添加病历」这种既是 mockup 留用的标题、又是正常
/// 白话的,就**不要进这个列表**(mockup `s6` 把添加 sheet 的标题就留成那四个字)。
/// 真要钉某一个字符串字面量时,把引号一起写进词里(`"'某某'"`),那样只命中
/// 那一处,不会把注释和别处的文案一起拦下。
List<String> scanLib(String word) {
  final hits = <String>[];
  final root = Directory('lib');
  for (final f in root.listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.dart')) continue;
    if (f.path.contains('lib/src/rust/')) continue;
    final lines = f.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].contains(word)) hits.add('${f.path}:${i + 1}');
    }
  }
  return hits;
}

void main() {
  test('kEnforced 里的每个词都在 kGlossary 里有去处', () {
    // 值可以是空串 —— 那表示「整块删掉,没有替代词」(如「识别质量」徽标、
    // 「点开核对并确认」那一行)。但**键必须在表里**:一个没写明去处的禁词,
    // 下一个人只会原地绕过它。
    for (final w in kEnforced) {
      expect(kGlossary.containsKey(w), isTrue, reason: '「$w」没写明换成什么');
    }
  });

  for (final word in kEnforced) {
    test('lib 里没有「$word」(应改成「${kGlossary[word]}」)', () {
      final hits = scanLib(word);
      expect(hits, isEmpty, reason: '还剩 ${hits.length} 处:\n${hits.join('\n')}');
    });
  }
}
```

- [ ] **Step 2: 跑,确认它红**

Run: `cd <app> && flutter test test/glossary_guard_test.dart`
Expected: FAIL —— 「数据出口」命中 `lib/screens/settings_screen.dart:412`,「数据管理」命中 `lib/screens/settings_screen.dart:461`。

- [ ] **Step 3: 改设置屏那两行**

`lib/screens/settings_screen.dart:412`:

```dart
          _SectionLabel('给医生看 · 导出'),
```

`lib/screens/settings_screen.dart:461`:

```dart
          _SectionLabel('删掉全部'),
```

- [ ] **Step 4: 跑,确认它绿**

Run: `cd <app> && flutter test test/glossary_guard_test.dart`
Expected: PASS(3 个 test)

- [ ] **Step 5: 提交**

```bash
cd <repo>
git add apps/mobile_flutter/test/glossary_guard_test.dart apps/mobile_flutter/lib/screens/settings_screen.dart
git commit -m "test(mobile): 加词表闸,先拿「数据出口/数据管理」验一遍

ia-proposal §3 的 11 组词表落成一个扫 lib 源码的 flutter test。
kEnforced 逐 Task 增长,终点是 ux-audit §4 Done 判据②那条 grep。"
```

---

### Task 2: 首启同意页四条声明 + Info.plist 两条 + 设置版本行

**Files:**
- Modify: `<app>/lib/screens/first_run_consent.dart:318-345`
- Modify: `<app>/ios/Runner/Info.plist:70`、`<app>/ios/Runner/Info.plist:72`
- Modify: `<app>/lib/screens/settings_screen.dart:527`
- Create: `<app>/test/info_plist_copy_test.dart`
- Test: `<app>/test/first_run_consent_test.dart`(追加一个 group)

**Interfaces:**
- Consumes: 无
- Produces: `const _points`(四条声明,长度仍为 4,标题「有四件事」由长度派生,不要改长度)

> 这一条是 ux-audit Top-10 的 P5:**对外不实陈述**,不只是文案问题。四条声明 + 两条 Info.plist + 设置版本行是同一句谎的三处出口,一起改。
>
> **`s16` 给的是三句话,不是四条声明**:标题「你的病历,自己拿着」,三条
> `拍一下单子变成表和趋势` / `看病时一页给医生` / `加密存在手机登录后云端备份,我们打不开`,
> 底下一行 `用了就是同意《隐私政策》和《用户协议》。`,按钮 `开始使用`。
>
> ⚠️ **有一处本 Task 没有照 mockup 做,需要创始人点头**:`s16` 把今天那道
> **显式同意门**(必须滚到底才能点「我知道了」,`test/first_run_consent_test.dart`
> 钉着它)换成了「用了就是同意」。**换掉的是一个合规机制,不是一句文案** ——
> 所以本 Task **采用 `s16` 的三句内容**(它们对当前数据流是准确的),但
> **保留那道滚动到底 + 明确点击的同意门**。要不要真的改成「用了就是同意」,
> 请创始人单独拍一句;拍了之后删掉 `first_run_consent_test.dart` 的滚动门断言
> 是一个独立的小改动。

- [ ] **Step 1: 写这两个失败的测试**

`<app>/test/first_run_consent_test.dart` 末尾追加(文件已有 `pumpScreen` / `useTallPhone` 两个 helper,直接复用):

```dart
  // ── Stage 1:四条声明不许再说「不上传 / 只在这台手机上 / 没有账号」 ──────────
  //
  // 本版默认开云备份,并在第一次导入时征询「云端整理」(脱敏后的病历画面会送
  // 境内云端模型)。ux-audit §4 第 1-5 条:这几句话已经是对外不实陈述,而且
  // 印在 App Store 可见的位置上。
  group('首启声明与当前数据流一致', () {
    const banned = [
      '只存在这台手机上',
      '没有账号,不需要注册',
      '我们那里本来就没有',
      '不会上传',
      '只在这台手机上',
      '只保存在你自己的设备上',
    ];

    testWidgets('整屏找不到任何一句过时声明', (tester) async {
      useTallPhone(tester);
      await pumpScreen(tester);
      for (final s in banned) {
        expect(find.textContaining(s), findsNothing, reason: '「$s」已不成立');
      }
    });

    testWidgets('云端整理这件事必须在同意之前说出来', (tester) async {
      useTallPhone(tester);
      await pumpScreen(tester);
      expect(find.textContaining('云端'), findsWidgets);
    });

    testWidgets('三条就是 s16 那三句', (tester) async {
      useTallPhone(tester);
      await pumpScreen(tester);
      for (final t in [
        '拍一下单子变成表和趋势',
        '看病时一页给医生',
        '加密存在手机,登录后云端备份,我们打不开',
      ]) {
        expect(find.text(t), findsOneWidget);
      }
      expect(find.text('开始使用'), findsOneWidget);
    });
  });
```

`<app>/test/info_plist_copy_test.dart`(新文件):

```dart
// 系统权限弹窗逐字给用户看,而它的文案在 Info.plist 里,没有任何 Dart 测试
// 能碰到它 —— 于是它成了全项目最容易过期的两句话(ux-audit §4 第 7、8 条)。
// 这个测试直接读那个文件。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('相机/相册用途说明不再承诺「不会上传」', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    for (final s in ['不会上传', '只存在本机', '只在本机处理']) {
      expect(plist.contains(s), isFalse, reason: 'Info.plist 里还有「$s」');
    }
    // 两条用途说明本身必须还在 —— 删掉会直接被 App Store 拒。
    expect(plist.contains('NSCameraUsageDescription'), isTrue);
    expect(plist.contains('NSPhotoLibraryUsageDescription'), isTrue);
  });
}
```

- [ ] **Step 2: 跑,确认两个都红**

Run: `cd <app> && flutter test test/first_run_consent_test.dart test/info_plist_copy_test.dart`
Expected: FAIL —— consent 屏命中「只存在这台手机上」「没有账号,不需要注册」「我们那里本来就没有」;plist 命中「不会上传」两次。

- [ ] **Step 3: 改三处文案**

`lib/screens/first_run_consent.dart:318-345`,整段 `_points` 换成 `s16` 的三条
(**长度从 4 变 3;标题「有几件事」由这份列表的长度派生,会自动跟着变成「三件事」**):

```dart
const _points = [
  // 三条逐字照 mockup `s16`。标题「你的病历,自己拿着」写在这份列表上方。
  _PointData(
    icon: Icons.document_scanner_outlined,
    title: '拍一下单子变成表和趋势',
    body: '化验单、处方、出院记录拍进来,自动认字、排好队、能看变化。'
        '文字识别可能出错 —— 以原件和医师判断为准,MedMe 不是医生。',
  ),
  _PointData(
    icon: Icons.assignment_outlined,
    title: '看病时一页给医生',
    body: '过敏、在治、在吃、最近的数,收在一页里。诊室里点开就能递过去。',
  ),
  _PointData(
    icon: Icons.lock_outline,
    title: '加密存在手机,登录后云端备份,我们打不开',
    body: '不登录也能用,只是换手机找不回来。要不要让云端帮你整理单子,'
        '第一次添加病历时会问你一次。',
  ),
];
```

> 三条把原来第 2 条(不是医生)并进了第 1 条、第 4 条(使用计数)整条删掉 ——
> 那条承诺的「设置里随时可关」在没配 Key 的构建里根本不渲染
> (`settings_screen.dart:441` 的 `if (Analytics.isConfigured)`,ux-audit §4 第 4 条),
> 而 `s16` 也没有它。**埋点本身不变**,只是不在首启页做一个找不到的承诺。
>
> 屏底那行按 `s16` 写 `用了就是同意《隐私政策》和《用户协议》。`,
> 按钮写 `开始使用`(替掉今天的「我知道了,开始使用」)。**滚动门保留**,见上面那条 ⚠️。

`ios/Runner/Info.plist:70`:

```xml
	<string>MedMe 需要使用相机拍摄你的化验单、处方等病历(识别文字后保存到你自己的病历里),以及在新手机上用旧手机扫码完成登录。开了「云端整理」时,病历画面会先在本机把姓名等身份信息涂掉再送云端认字。</string>
```

`ios/Runner/Info.plist:72`:

```xml
	<string>MedMe 需要访问相册,添加你已经拍好的病历照片。开了「云端整理」时,照片会先在本机把姓名等身份信息涂掉再送云端认字。</string>
```

`lib/screens/settings_screen.dart:527`:

```dart
                subtitle:
                    'v$_appVersionName ($_appBuildNumber) · 端到端加密:云端只有密文,我们打不开',
```

- [ ] **Step 4: 跑,确认绿**

Run: `cd <app> && flutter test test/first_run_consent_test.dart test/info_plist_copy_test.dart`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
cd <repo>
git add apps/mobile_flutter/lib/screens/first_run_consent.dart \
        apps/mobile_flutter/ios/Runner/Info.plist \
        apps/mobile_flutter/lib/screens/settings_screen.dart \
        apps/mobile_flutter/test/first_run_consent_test.dart \
        apps/mobile_flutter/test/info_plist_copy_test.dart
git commit -m "fix(mobile): 首启声明/权限说明/版本行不再说「不上传、没有账号」

ux-audit §4 第 1-5、7、8 条:本版默认开云备份、第一次导入征询云端整理,
这三处的话已经是对外不实陈述。Info.plist 那两条加了个读文件的测试盯住。"
```

---

### Task 3: 底栏 5 → 3 tab 骨架(病历 | 趋势 | 我)

**Files:**
- Modify: `<app>/lib/vault_events.dart:14-51`
- Modify: `<app>/lib/main.dart:583-663`
- Modify: `<app>/lib/analytics.dart:738-749`
- Modify: `<app>/lib/screens/trends_screen.dart:966-973`
- Modify: `<app>/lib/screens/settings_screen.dart:232`
- Create: `<app>/lib/screens/for_doctor_screen.dart`
- Test: `<app>/test/mobile_ia_test.dart:771-808`

**Interfaces:**
- Consumes: `kGlossary` / `kEnforced`(Task 1,只作查表参考)
- Produces:
  - `HomeTab.records = 0` / `HomeTab.trends = 1` / `HomeTab.me = 2` / `HomeTab.count = 3`
  - `void goToRecords()` / `void goToTrends()`(**保留原名,不是 shim**)/ `void goToMe()`
  - **过渡期 shim(Task 9 删)**:`@Deprecated` 的 `goToArchive()` 与 `goToEmergencyCard()`
  - `TrendsScreen` **不改名、不改签名**(Task 8 给它补两个可选注入点)
  - `class ForDoctorScreen extends StatefulWidget`(`const ForDoctorScreen({super.key, Future<VisitSummaryDto> Function()? load, Future<bool?> Function(BuildContext)? onRequestAddNote})`)—— 两个注入点与被它取代的 `VisitSummarySheet` **签名完全一致**,这样 `test/visit_summary_sheet_test.dart` 的「存完笔记要当场刷新」那组能原样搬过来(Task 17)
  - `class ForDoctorActions extends StatelessWidget`(`const ForDoctorActions({super.key, VoidCallback? onShowQr, VoidCallback? onExport, VoidCallback? onEmergency, VoidCallback? onProxy})`)
  - `HomeShell.tabScreens` / `HomeShell.tabDestinations`,各 **3** 项

- [ ] **Step 1: 写这个失败的测试**

`<app>/test/mobile_ia_test.dart`,把 `group('五 tab 信息架构', ...)`(`:771-808`)整段替换成:

```dart
  // ───────────────────────────────────────────────────────────────────────────
  group('三 tab 信息架构', () {
    test('tab 数 == 页面数 == 底栏项数', () {
      // 这三个数字散在两处 const 列表和一组常量里。加一个 tab 时最容易漏掉其中
      // 一处,而漏掉的表现是运行时越界或**点 A 进了 B**,不是编译错误。
      expect(HomeTab.count, 3);
      expect(HomeShell.tabScreens.length, HomeTab.count);
      expect(HomeShell.tabDestinations.length, HomeTab.count);
    });

    test('下标连续、互不重复', () {
      const order = [HomeTab.records, HomeTab.trends, HomeTab.me];
      expect(order, [0, 1, 2]);
      expect(order.toSet().length, HomeTab.count);
    });

    test('底栏文案就是 mockup 那三个词', () {
      expect(
        HomeShell.tabDestinations.map((d) => d.label).toList(),
        ['病历', '趋势', '我'],
      );
    });

    test('「给医生看」**不在**底栏 —— 它是从「病历」推进去的一整页', () {
      // mockup。这条断言存在的理由:ia-proposal §2 推荐的是把它放进底栏,
      // 谁照着那份提案改回去,红的应该是这里,而不是到了真机上才发现两处打架。
      expect(
        HomeShell.tabDestinations.map((d) => d.label),
        isNot(contains('给医生看')),
      );
      expect(
        HomeShell.tabDestinations.map((d) => d.label),
        isNot(contains('应急卡')),
      );
    });

    test('程序化跳转落在正确的 tab 上', () {
      goToTrends();
      expect(selectedTab.value, HomeTab.trends);
      goToMe();
      expect(selectedTab.value, HomeTab.me);
      goToRecords();
      expect(selectedTab.value, HomeTab.records);
    });

    test('埋点枚举与 tab 一一对应 —— 少一个就会把 A 的人气记成 B', () {
      expect(AnalyticsTab.values.length, HomeTab.count);
      expect(AnalyticsTab.of(HomeTab.records), AnalyticsTab.records);
      expect(AnalyticsTab.of(HomeTab.me), AnalyticsTab.me);
      expect(AnalyticsTab.of(3), isNull);
    });
  });
```

同文件顶部的 import 加一行 `import 'package:mobile_flutter/analytics.dart';`(`screens/trends_screen.dart` 那行不动 —— 这个文件不改名)。

- [ ] **Step 2: 跑,确认它红**

Run: `cd <app> && flutter test test/mobile_ia_test.dart`
Expected: FAIL,编译错误 `Undefined name 'HomeTab.records'` / `goToMe` / `AnalyticsTab.records`。

- [ ] **Step 3: 改四处 + 建一个新屏**

`lib/vault_events.dart`,把 `:14` 起(`HomeTab` 的类文档)到文件末尾(`:51`)整段替换:

```dart
/// 底部一级 tab 的下标。**三个**(mockup,创始人拍板):
///
/// | tab | 用户在干什么 |
/// |---|---|
/// | 病历 | 拍/添加一份,以及回头找某一张 |
/// | 趋势 | 这个病现在怎么样、吃过什么药、该查没查 |
/// | 我 | 云端、成员、口令与恢复码、设置 |
///
/// **「给医生看」不是 tab** —— 它是「病历」首页那颗主按钮推进去的一整页
/// (`screens/for_doctor_screen.dart`)。急救大字模式在那一页里。
/// ⚠️ ia-proposal §2 推荐的是把它放进底栏(候选 A);mockup 改了主意。
/// 两处打架时**以 mockup 为准**,理由见计划的 Global Constraints。
class HomeTab {
  HomeTab._();

  static const int records = 0;
  static const int trends = 1;
  static const int me = 2;

  /// tab 总数。`HomeShell` 的页面列表与底栏项数都对它断言,少一个就崩在测试里,
  /// 而不是运行时 `IndexedStack` 越界。
  static const int count = 3;
}

/// 当前底部一级 tab 下标(取值见 [HomeTab])。`HomeShell` 监听它切换页面。
final ValueNotifier<int> selectedTab = ValueNotifier<int>(HomeTab.records);

/// 跳到「病历」tab。
void goToRecords() => selectedTab.value = HomeTab.records;

/// 跳到「趋势」tab。
void goToTrends() => selectedTab.value = HomeTab.trends;

/// 跳到「我」tab。
void goToMe() => selectedTab.value = HomeTab.me;

// ── 过渡期 shim ─────────────────────────────────────────────────────────────
//
// `overview_screen.dart` 还要活到 Task 9(它的「最近的关键化验」「最近就诊」得先
// 搬进「趋势」才能拆,见 Task 8),在那之前这两个旧名字仍有调用方
// (`overview_screen.dart:569,650` 和 `:248`)。直接删会让**本次提交的
// `flutter analyze` 当场就红** —— 而每个 Task 的「Expected: PASS」指的是那一刻
// 整仓的 analyze + test,不是只有新写的那个测试文件。
//
// `goToTrends` 不在此列:「趋势」仍然是一个 tab,那个函数照旧是真的。
//
// 两个 shim 在 Task 9 随概览一起删。

@Deprecated('Stage 1: 用 goToRecords();概览删掉后本 shim 一并删(Task 9)')
void goToArchive() => goToRecords();

/// 急救已经搬进「给医生看」那一页,底栏没有它的位置了 —— 这个 shim **只是让
/// 注定要删的概览还能编译**,落点是权宜的,不代表产品意图。Task 9 删。
@Deprecated('Stage 1: 急救在「给医生看」页里;概览删掉后本 shim 一并删(Task 9)')
void goToEmergencyCard() => goToRecords();
```

**本 Task 自己顺手改掉两个调用方**(它们不在概览里,不会被 Task 9 带走):

`lib/screens/trends_screen.dart:966-973` —— 空态那段:

```dart
            Text(
              '趋势需要同一个指标在不同日期至少测过一次,并且报告上能定出日期。\n'
              '在「病历」里添加几张化验单,这里就会长出线来。',
              textAlign: TextAlign.center,
              style: MedType.body.copyWith(color: c.ink2, height: 1.6),
            ),
            const SizedBox(height: MedShape.s3),
            OutlinedButton(
              onPressed: goToRecords,
              child: const Text('去「病历」添加化验单'),
            ),
```

`lib/screens/settings_screen.dart:232` —— 载入示例后那条「去看看」:

```dart
              goToRecords();
```

剩下四个调用方只在 `lib/screens/overview_screen.dart`(`:248`、`:486`、`:569`、`:650`),
**本 Task 不动它们**:`:486` 调的是真函数 `goToTrends`,另外三处靠上面两个 shim 撑到 Task 9。

新建 `lib/screens/for_doctor_screen.dart`:

```dart
// 「给医生看」—— 诊室里那 30 秒。**照 `s4` 实现。**
//
// **不是 tab**:从「病历」首页那颗「给医生看」方块推进去的一整页(`s1` → `s4`)。它原来是个
// 盖住底栏的浮层(`visit_summary_sheet.dart`),退出只能下滑,自动化和真人都在
// 那儿退不出去过(ux-audit 走查「试了不止一次」①②)。升格成整页之后有了返回箭头,
// 也不再依赖上传才能给出东西。
//
// **不加分区标题**(mockup:不要「今天带给医生的」这类抬头)—— 推进来就是内容。
//
// 内容主体直接复用 `VisitSummaryBody`(那个 widget 本来就是纯渲染、不碰 FFI),
// 取数留在本屏的 State 里 —— 与浮层同一条分工。
import 'package:flutter/material.dart';

import 'package:mobile_flutter/analytics.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/screens/document_detail.dart';
import 'package:mobile_flutter/screens/manual_entry_sheet.dart';
import 'package:mobile_flutter/screens/visit_summary_sheet.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';

class ForDoctorScreen extends StatefulWidget {
  const ForDoctorScreen({super.key, this.load, this.onRequestAddNote});

  /// 数据源。null → [viewVisitSummary](FFI)。
  final Future<VisitSummaryDto> Function()? load;

  /// 「加一条」按下时走的动作,返回「是否真的存了一条」。null → 开录入弹层(FFI)。
  ///
  /// 这两个注入点与它取代的 `VisitSummarySheet` **签名一字不差** —— 那边
  /// 「存完笔记要当场重新拉一次」的回归(BUG-4)靠的就是这两个钩子,浮层删掉之后
  /// 那组测试原样搬到这里继续跑(Task 17)。不注入时整屏碰 FFI,`flutter test`
  /// 不带原生库,那种情况下只 pump [ForDoctorActions]。
  final Future<bool?> Function(BuildContext context)? onRequestAddNote;

  @override
  State<ForDoctorScreen> createState() => _ForDoctorScreenState();
}

class _ForDoctorScreenState extends State<ForDoctorScreen> {
  late Future<VisitSummaryDto> _future = widget.load?.call() ?? viewVisitSummary();

  void _openDoc(int id) {
    Analytics.track(AnalyticsEvent.docOpened);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DocumentDetailScreen(docId: id)),
    );
  }

  /// 「加一条」。**只有真的存下了才重新拉一次** —— 用户划掉弹层什么也没写时
  /// 白拉一次是浪费,而存了却不拉,他会看着自己刚写的东西没出现(BUG-4)。
  Future<void> _addNote() async {
    final saved = widget.onRequestAddNote != null
        ? await widget.onRequestAddNote!(context)
        : await showManualEntrySheet(context);
    if (saved != true || !mounted) return;
    setState(() => _future = widget.load?.call() ?? viewVisitSummary());
  }

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('给医生看'),
        // `s4`:标题下面一行「张建国,男,61 岁;截至 <今天>」。数据来自
        // `VisitSummaryDto.patient`,日期是**渲染这一页的当天** —— 医生要知道
        // 这份摘要是什么时候的。
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: c.line),
        ),
      ),
      body: FutureBuilder<VisitSummaryDto>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(MedShape.s6),
                child: Text(
                  '这一页暂时打不开。',
                  style: MedType.body.copyWith(color: c.ink2),
                ),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              // 推进来直接就是内容,**没有「今天带给医生的」这类抬头**(`s4`)。
              //
              // `s4` 的顺序是固定的,别自己重排:
              //   过敏一行 → 在治(图标块 + 列表)→ 在吃(图标块 + 列表)
              //   → 关键化验 → 检查与手术 → 出码 → 打印/导出 + 急救卡 → 代拍
              //
              // **Stage 1 只负责顺序,不提前做内容**:`s4` 里关键化验各行画了
              // 迷你折线、还多一块「检查与手术」—— 那两样是 Stage 2,这一版
              // 保持今天 `VisitSummaryBody` 的最后一次取值行,位置先摆对。
              VisitSummaryBody(
                summary: snap.data!,
                onOpenDoc: _openDoc,
                onAddNote: _addNote,
              ),
              const SizedBox(height: MedShape.s4),
              // 四条入口在 Task 9 接上真实跳转,这里先摆位置。
              // `s4` 里「出码给医生看」在真机上固定在底部;**Stage 1 先内联**
              // (mockup 那句「真机上这颗按钮固定在底部」是 Stage 3 视觉层的事)。
              const ForDoctorActions(),
            ],
          );
        },
      ),
    );
  }
}

/// 页面底部四条入口。**纯 widget,不碰 FFI** —— 这样 `flutter test` 测得到
/// (与 `QuickActions` / `VisitSummaryBody` 同一手法)。
class ForDoctorActions extends StatelessWidget {
  const ForDoctorActions({
    super.key,
    this.onShowQr,
    this.onExport,
    this.onEmergency,
    this.onProxy,
  });

  final VoidCallback? onShowQr;
  final VoidCallback? onExport;
  final VoidCallback? onEmergency;
  final VoidCallback? onProxy;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 逐字照 `s4`:出码那颗是「出码给医生看」,急救那颗是「急救卡」。
        ListTile(
          leading: const Icon(Icons.qr_code_2_outlined),
          title: const Text('出码给医生看'),
          onTap: onShowQr,
        ),
        ListTile(
          leading: const Icon(Icons.print_outlined),
          title: const Text('打印 / 导出'),
          onTap: onExport,
        ),
        ListTile(
          leading: const Icon(Icons.emergency_outlined),
          title: const Text('急救卡'),
          onTap: onEmergency,
        ),
        ListTile(
          // 全 App 唯一一句代拍入口文案 —— `doctor_home_screen.dart:264` 的
          // 主按钮用**同一句**(Task 15)。此前存在的另外几种说法已经被
          // `test/glossary_guard_test.dart` 的禁词闸关掉,**这条注释里也不许
          // 复述它们**,否则闸会扫到自己。
          leading: const Icon(Icons.medical_services_outlined),
          title: const Text('我是医生,替病人代拍'),
          // `s4` 的副标题,逐字。
          subtitle: const Text('病人不用装 App、不用账号'),
          onTap: onProxy,
        ),
      ],
    );
  }
}
```

`lib/main.dart:583-663`,把 `HomeShell` 的类文档与两个 const 列表替换成:

```dart
/// 底部导航壳:**三个一级 tab**(mockup,创始人拍板)。
///
/// | tab | 用户在干什么 |
/// |---|---|
/// | 病历 | 拍/添加一份,以及回头找某一张 |
/// | 趋势 | 这个病现在怎么样、吃过什么药、该查没查 |
/// | 我 | 云端、成员、口令与恢复码、设置 |
///
/// ## 四处刻意的缺席
///
/// **「给医生看」不是 tab** —— 它是「病历」首页那颗主按钮推进去的一整页。
/// ⚠️ ia-proposal §2 推荐的恰恰相反(候选 A 把它放进底栏,并写明拒绝候选 B 的
/// 理由是「老人在底栏找不到它」)。mockup 改了主意,**执行按 mockup**;
/// 那条风险在模拟器冒烟里验(Task 19)。
///
/// **「应急卡」不再是 tab**,是「给医生看」那一页里的一条。降的是位置不是质量:
/// `EmergencyBigCardScreen` 大字模式一字未动。
///
/// **「概览」整屏解散**:成员卡进「我」,化验快照与最近就诊进「趋势」,最近添加
/// 与「病历」tab 重复,三颗快捷操作各归各位。
///
/// **「趋势」保留原名**,不叫「看懂」——「病程档案」的入口位落在它里面。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  /// 三个 tab 的页面,顺序必须与 [HomeTab] 的常量逐一对应 —— `IndexedStack` 按
  /// 下标取,错一位就是点「趋势」进了「我」。
  ///
  /// 与 [tabDestinations] 一起公开是为了让 `test/mobile_ia_test.dart` 能钉住
  /// 「页面数 == 底栏项数 == [HomeTab.count]」。
  static const List<Widget> tabScreens = [
    ArchiveScreen(),
    TrendsScreen(),
    SettingsScreen(),
  ];

  /// 底栏三项,顺序同 [tabScreens]。
  static const List<NavigationDestination> tabDestinations = [
    NavigationDestination(
      icon: Icon(Icons.folder_outlined),
      selectedIcon: Icon(Icons.folder),
      label: '病历',
    ),
    NavigationDestination(
      icon: Icon(Icons.show_chart_outlined),
      selectedIcon: Icon(Icons.show_chart),
      label: '趋势',
    ),
    NavigationDestination(
      icon: Icon(Icons.person_outline),
      selectedIcon: Icon(Icons.person),
      label: '我',
    ),
  ];

  @override
  State<HomeShell> createState() => _HomeShellState();
}
```

`lib/main.dart` 的 `_HomeShellState._index` 初值改成 `HomeTab.records`;import 里
`screens/overview_screen.dart`、`screens/emergency_card_screen.dart` 删掉
(`screens/trends_screen.dart` 那行**留着**)。

`lib/analytics.dart:738-749`:

```dart
enum AnalyticsTab {
  records,
  trends,
  me;

  /// 下标 → 名字。越界返回 `null`,调用点据此**不报**(与 `is_first` 同一条
  /// 「不知道就不报,绝不猜」的规矩)。
  static AnalyticsTab? of(int index) =>
      index >= 0 && index < values.length ? values[index] : null;
}
```

同文件 `:345` 那句「1.6.0 把三 tab 拆成五个」的说明改写成「Stage 1 收成三个」,
并把「五个一级席位该给谁」改成「三个一级席位该给谁」。

- [ ] **Step 4: 跑,确认绿**

Run:

```bash
cd <app>
flutter analyze
flutter test
```

Expected: **两条都全绿**,不只是 `mobile_ia_test.dart`。这是每个 Task 的收口标准 ——
「Expected: PASS」指的是那一刻**整仓**的 analyze + test。

两处会红、且都在意料之中:
- `analytics_catalog_test.dart` 因为枚举值名字变了而红 → 把它里面的五个旧名字改成上面三个新名字;
- `flutter analyze` 报 `deprecated_member_use_from_same_package`(两个 shim 被 `overview_screen.dart` 调)→ 在 `lib/screens/overview_screen.dart` 顶部加一行 `// ignore_for_file: deprecated_member_use_from_same_package`,**Task 9 删这个文件时它一起消失**。

- [ ] **Step 5: 提交**

```bash
cd <repo>
git add apps/mobile_flutter/lib apps/mobile_flutter/test
git commit -m "feat(mobile): 底栏 5 tab 改成 病历|趋势|我(mockup)

给医生看从浮层升格成一整页(新 for_doctor_screen.dart),入口是「病历」首页
的主按钮,不占底栏席位;应急卡收进那一页。概览与应急卡这一步先从底栏撤下,
内容在后续 Task 里各归各位。趋势保留原名,不改文件名。

⚠️ ia-proposal §2 推荐的是 4 tab 把「给医生看」放进底栏;mockup 改了主意,
执行按 mockup,那条「老人找不找得到」的风险在 Task 19 冒烟里验。"
```

---

### Task 4: 删「你是?」角色选择屏

**Files:**
- Delete: `<app>/lib/screens/mode_picker_screen.dart`
- Modify: `<app>/lib/main.dart:568-580`
- Modify: `<app>/lib/app_mode.dart:60-70`
- Test: `<app>/test/mode_root_test.dart`(新建)

**Interfaces:**
- Consumes: `AppMode.instance.mode`(`ValueNotifier<AppModeKind?>`)、`HomeShell`、`DoctorHomeScreen`
- Produces: `Widget modeRoot(AppModeKind? mode)` —— 纯函数,`null` 与 `personal` 都给 `HomeShell`,`doctor` 给 `DoctorHomeScreen`

> 「为病人代拍」对普通老人是噪音,却和「自己/家人的病历」同等视觉权重(ux-audit 屏02)。
> 代拍入口在 Task 9 里接到「给医生看」的最后一行,不再是开机第一个问题。

- [ ] **Step 1: 写这个失败的测试**

`<app>/test/mode_root_test.dart`:

```dart
// 「你是?」删掉之后,没选过模式的人必须直接落在个人模式的三 tab 里,
// 而不是一个空屏或一个还问一次的选择页(ux-audit 屏02)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/app_mode.dart';
import 'package:mobile_flutter/main.dart';
import 'package:mobile_flutter/screens/doctor/doctor_home_screen.dart';

void main() {
  test('没选过模式 → 直接进个人模式的壳,不再问一次', () {
    expect(modeRoot(null), isA<HomeShell>());
    expect(modeRoot(AppModeKind.personal), isA<HomeShell>());
    expect(modeRoot(AppModeKind.doctor), isA<DoctorHomeScreen>());
  });
}
```

- [ ] **Step 2: 跑,确认它红**

Run: `cd <app> && flutter test test/mode_root_test.dart`
Expected: FAIL,`Undefined name 'modeRoot'`。

- [ ] **Step 3: 实现**

`lib/main.dart`,把 `_AppRootState._modeRoot()`(`:568-580`)换成一个顶层纯函数 + 一处调用:

```dart
/// 按模式决定根界面。**`null`(从没选过)走个人模式** —— 「你是?」那一屏已经删了
/// (ia-proposal §2 候选 A 的删除清单):代拍不是开机第一个该问的问题,它的入口
/// 在「给医生看」的最后一行。
///
/// 顶层纯函数,不碰 `BuildContext` —— 这样 `flutter test` 能直接断言映射关系。
Widget modeRoot(AppModeKind? mode) => switch (mode) {
  AppModeKind.doctor => const DoctorHomeScreen(),
  _ => const HomeShell(),
};
```

`_AppRootState` 里原来的 `_modeRoot()` 方法体改成:

```dart
  Widget _modeRoot() {
    return ValueListenableBuilder<AppModeKind?>(
      valueListenable: AppMode.instance.mode,
      builder: (context, mode, _) => modeRoot(mode),
    );
  }
```

删文件与残留 import:

```bash
cd <app>
git rm lib/screens/mode_picker_screen.dart
grep -rl "mode_picker_screen" lib test | xargs sed -i '' '/mode_picker_screen/d'
```

`lib/app_mode.dart:60-70`,`chooseMode` 的文档里「首次选择模式(「你是?」选择屏调)」改成「设置为某个模式(现在只有代拍入口与「退出代拍」会调)」;`ensureLoaded` 的行为不变。

- [ ] **Step 4: 跑,确认绿**

Run: `cd <app> && flutter test test/mode_root_test.dart test/mobile_ia_test.dart`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
cd <repo>
git add -u apps/mobile_flutter
git add apps/mobile_flutter/test/mode_root_test.dart
git commit -m "feat(mobile): 删「你是?」角色选择屏,开机直接进个人模式

代拍入口挪到「给医生看」最后一行(Task 9 接线)。modeRoot 抽成顶层纯函数,
映射关系有了测试。"
```

---

### Task 5: 「病历」tab —— 两颗方块(添加 / 给医生看)+ 还没核对横幅 + 月份分组

**Files:**
- Modify: `<app>/lib/screens/archive_screen.dart:253`、`:262-270`、`:295`,以及 body 顶部(hero 下面那两颗方块、还没核对横幅、月份分组)
- Test: `<app>/test/archive_header_test.dart`(新建)
- **不动** `<app>/lib/import_flow.dart:127`(见下)
- Modify: `<app>/test/glossary_guard_test.dart`(`kEnforced` 加 `导入`、`添加病历`)
- Test: `<app>/test/glossary_guard_test.dart`

**Interfaces:**
- Consumes: `IdentityHeroCard`(既有,**原样保留**:头像 + 名字 + `⌃⌄` 切换 + 一行摘要)、`showMemberSwitcherSheet`
- Produces: `class HomeTiles extends StatelessWidget`(`const HomeTiles({super.key, this.onAdd, this.onForDoctor})`)—— hero 下面那两颗等宽方块

> **先读 `s1`。** 这一屏的结构(自上而下):`IdentityHeroCard` → 两颗方块 →
> 「还没核对」横幅 → 按月分组的时间线(每个月份标题右边一条「找一找」)。
>
> ux-audit 屏73:顶栏挤了成员 chip +「+」+ 剪贴板 +「+ 导入」四个操作。剪贴板那颗是
> 「看病带这个」的第二入口 —— 它现在是「给医生看」那一整页,不需要第二入口。
>
> **两处按 mockup 回退了本计划早先的写法,别照旧稿做**:
> 1. **顶栏不加成员 chip。** 换成员仍然点 hero 卡上的 `⌃⌄`(`s1` 就是今天这张卡),
>    `MemberChip` 这个 widget **不要建**。
> 2. **添加 sheet 的标题仍是「添加病历」**(`s6` 逐字)—— 早先计划把它改成「添加」并
>    把 `'添加病历'` 关进禁词闸,mockup 留着这四个字。**`import_flow.dart:127` 不动,
>    禁词闸里也不加这个词**(见 Step 1)。

- [ ] **Step 1: 写这个失败的测试 + 把词加进禁词闸**

`<app>/test/archive_header_test.dart`(整屏 `ArchiveScreen` 碰 FFI,不可 pump;这三个是纯 widget):

```dart
// 「病历」首页 hero 下面那两颗方块、「还没核对」横幅、月份标题(`s1`)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/screens/archive_screen.dart';
import 'package:mobile_flutter/theme.dart';

Widget wrap(Widget child, {double textScale = 1.0}) => MaterialApp(
  theme: MedMe.theme(),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void useNarrowPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(320 * 3, 568 * 3); // iPhone SE
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('两颗方块:等宽、都点得动', (tester) async {
    useNarrowPhone(tester);
    var add = false, doc = false;
    await tester.pumpWidget(
      wrap(HomeTiles(onAdd: () => add = true, onForDoctor: () => doc = true)),
    );
    expect(find.text('添加'), findsOneWidget);
    expect(find.text('给医生看'), findsOneWidget);
    // 等宽 —— 它们是一对并列的动作,不是一主一次。
    expect(
      tester.getSize(find.text('添加').first).width > 0 &&
          tester.getSize(find.byType(HomeTiles)).width > 0,
      isTrue,
    );
    final w1 = tester.getRect(find.ancestor(
      of: find.text('添加'), matching: find.byType(Material)).first).width;
    final w2 = tester.getRect(find.ancestor(
      of: find.text('给医生看'), matching: find.byType(Material)).first).width;
    expect((w1 - w2).abs() < 1.0, isTrue, reason: '两颗必须等宽');
    await tester.tap(find.text('添加'));
    await tester.tap(find.text('给医生看'));
    expect([add, doc], [true, true]);
  });

  testWidgets('SE + 2× 字号:「给医生看」四个字不裁 —— 它是那一页唯一的入口', (tester) async {
    useNarrowPhone(tester);
    await tester.pumpWidget(wrap(const HomeTiles(), textScale: 2.0));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('给医生看'), findsOneWidget);
  });

  testWidgets('还没核对横幅:逐字两句,0 份时整条不画', (tester) async {
    useNarrowPhone(tester);
    await tester.pumpWidget(wrap(const PendingReviewBanner(count: 2)));
    expect(find.text('2 份还没核对'), findsOneWidget);
    expect(find.text('扫描件,识别出的字有几处不确定'), findsOneWidget);
    // 旧写法的痕迹:每行一个「待确认 · 点开核对并确认」,一处都不许留。
    expect(find.textContaining('待确认'), findsNothing);

    await tester.pumpWidget(wrap(const PendingReviewBanner(count: 0)));
    expect(find.textContaining('还没核对'), findsNothing, reason: '没有要核对的就整条不画');
  });

  testWidgets('月份标题 + 「找一找」占位', (tester) async {
    useNarrowPhone(tester);
    var searched = false;
    await tester.pumpWidget(
      wrap(MonthHeader(label: '2026 年 8 月', onSearch: () => searched = true)),
    );
    expect(find.text('2026 年 8 月'), findsOneWidget);
    await tester.tap(find.text('找一找'));
    expect(searched, isTrue);
  });
}
```

**禁词闸这一轮不加词。**「添加病历」按 `s6` 留着(早先计划要禁它,mockup 留了),
其余旧词各自在 Task 6、7、12–15、17 里处理。

`test/glossary_guard_test.dart`:

```dart
const List<String> kEnforced = ['数据出口', '数据管理'];
```

> `导入` 暂不加:`import_flow.dart` 里大量函数名/注释含这两个字(`showImportSheet` 的
> 中文文档、`ImportRunResult`……),整体清理留到 Task 17。这一步只清用户看得见的那几处。

- [ ] **Step 2: 跑,确认它红**

Run: `cd <app> && flutter analyze && flutter test`
Expected: FAIL —— `archive_header_test.dart` 报 `Undefined name 'HomeTiles'` / `'PendingReviewBanner'` / `'MonthHeader'`。

- [ ] **Step 3: 改四处**

`lib/import_flow.dart:127`:

```dart
                '添加',
```

`lib/screens/archive_screen.dart:253` —— 标题换词,`actions` 里只剩「添加」那一颗
(剪贴板删掉,成员切换在 hero 卡上,**不加 chip**):

```dart
        title: const Text('病历'),
```

body 最上方摆 hero + 两颗方块(`s1`):

```dart
                IdentityHeroCard(
                  name: ProfileManager.instance.displayName,
                  gender: profile.gender,
                  age: profile.age,
                  recordCount: profile.recordCount.toInt(),
                  recentVisitDate: /* 时间线最新一条的日期,与 s1 那行「最近就诊」同源 */,
                  onSwitchMember: () => showMemberSwitcherSheet(
                    context,
                    onChanged: _refresh,
                  ),
                ),
                const SizedBox(height: MedShape.s3),
                HomeTiles(
                  onAdd: _startAdd,
                  onForDoctor: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const ForDoctorScreen()),
                  ),
                ),
```

同文件末尾加那两颗方块 —— **等宽、并排、同高**,只有底色不同(`s1`):

```dart
/// 「病历」首页 hero 下面那两颗方块(`s1`)。
///
/// **两颗等宽同高**,区别只在底色:`添加` 填主色(最高频的动作),`给医生看` 白底
/// 带描边。**不做成一条通栏大按钮** —— 它们是一对并列的动作,不是一主一次。
///
/// 「给医生看」没有底栏席位,这颗方块是它**全 App 唯一的入口**;ia-proposal §2
/// 拒绝候选 B 的理由正是「老人在底栏找不到它」,那条风险现在压在这颗方块上。
/// 谁把它改小、改成纯图标、或者塞进某个菜单里,就是在把那条风险放大 ——
/// 它在 iPhone SE + 2× 字号下必须仍然写得全那四个字(见本 Task 的测试)。
class HomeTiles extends StatelessWidget {
  const HomeTiles({super.key, this.onAdd, this.onForDoctor});

  final VoidCallback? onAdd;
  final VoidCallback? onForDoctor;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Row(
      children: [
        Expanded(
          child: _Tile(
            icon: Icons.add_a_photo_outlined,
            label: '添加',
            background: c.seal,
            foreground: Colors.white,
            onTap: onAdd,
          ),
        ),
        const SizedBox(width: MedShape.s2),
        Expanded(
          child: _Tile(
            icon: Icons.assignment_outlined,
            label: '给医生看',
            background: c.surface,
            foreground: c.sealInk,
            border: c.line,
            onTap: onForDoctor,
          ),
        ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.label,
    required this.background,
    required this.foreground,
    this.border,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final Color background;
  final Color foreground;
  final Color? border;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(MedShape.radiusBlock),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(MedShape.radiusBlock),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: MedShape.s3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(MedShape.radiusBlock),
            border: border == null ? null : Border.all(color: border!),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 26, color: foreground),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                style: MedType.body.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
```

「还没核对」那条横幅(`s1` 逐字,**一条,不是每行一个橙框**):

```dart
                // s1:一条横幅说一次,不是每行一个橙框(ux-audit P6)。
                // 「N 份」的 N 是还没核对的份数;点进去是 s7 那一屏。
                PendingReviewBanner(
                  count: pending.length,
                  onTap: _openReviewQueue,
                ),
```

```dart
/// 「还没核对」横幅(`s1`)。逐字:`N 份还没核对` + `扫描件,识别出的字有几处不确定`。
class PendingReviewBanner extends StatelessWidget {
  const PendingReviewBanner({super.key, required this.count, this.onTap});

  final int count;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (count == 0) return const SizedBox.shrink();
    final c = MedColors.of(context);
    return Material(
      color: c.sealWash,
      borderRadius: BorderRadius.circular(MedShape.radiusBlock),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(MedShape.radiusBlock),
        child: Padding(
          padding: const EdgeInsets.all(MedShape.s3),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$count 份还没核对',
                      style: MedType.body.copyWith(
                        color: c.ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '扫描件,识别出的字有几处不确定',
                      style: MedType.secondary.copyWith(color: c.ink2),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 20, color: c.ink3),
            ],
          ),
        ),
      ),
    );
  }
}
```

时间线按**月份**分组(`s1`:`2026 年 8 月` / `2026 年 7 月` …),每个月份标题右边一条
「找一找」。**Stage 1 只做到入口** —— 真正的搜索是 Stage 2(ia-proposal §6):

```dart
/// 月份分组标题(`s1`)。右边那条「找一找」是**搜索的入口位**:Stage 1 点了只说
/// 一句「还在做」,搜索本身(医院 / 日期 / 类型 / 指标 / 药名)是 Stage 2。
///
/// 为什么现在就摆出来:ux-audit P10「找不回东西」是这个定位的核心动作,而一个
/// 空白的月份标题不会让任何人想起「原来可以搜」。占位不等于假装能用 —— 点了
/// 明说还在做。
class MonthHeader extends StatelessWidget {
  const MonthHeader({super.key, required this.label, this.onSearch});

  final String label;
  final VoidCallback? onSearch;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, MedShape.s4, 0, MedShape.s1),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: MedType.caption.copyWith(color: c.ink3)),
          if (onSearch != null)
            GestureDetector(
              onTap: onSearch,
              child: Text('找一找', style: MedType.caption.copyWith(color: c.sealInk)),
            ),
        ],
      ),
    );
  }
}
```

`label` 由那一组的日期格式化成 `2026 年 8 月`;`onSearch` 接
`appSnackBar(content: const Text('找一找还在做'))`。

`lib/screens/archive_screen.dart:262-270`,整个 `IconButton`(「看病带这个」第二入口)连同上面那段注释删除,换成一行说明:

```dart
          // 那个剪贴板图标(「给医生看」的第二入口)已删 —— 它现在是底栏的
          // 「给医生看」tab,有固定位置,不需要在这里再开一个口子
          // (ia-proposal §2:每个功能只有一条路到达)。
```

`lib/screens/archive_screen.dart:295`:

```dart
              label: const Text('添加'),
```

同文件 `:284-293` 的 catch 分支里 `'导入没能开始:$e'` 改成 `'没能开始添加:$e'`。

- [ ] **Step 4: 跑,确认绿**

Run: `cd <app> && flutter analyze && flutter test`
Expected: 整仓全绿

- [ ] **Step 5: 提交**

```bash
cd <repo>
git add -u apps/mobile_flutter
git add apps/mobile_flutter/test/archive_header_test.dart
git commit -m "feat(mobile): 病历 tab 按 s1 摆 —— 两颗方块 + 还没核对横幅 + 月份分组

ux-audit 屏73 四个操作挤一行,剪贴板那个第二入口删掉。
mockup s1:保留现有 IdentityHeroCard(⌃⌄ 换成员,不加顶栏 chip);hero 下面
两颗等宽方块 添加(填色)/ 给医生看(白底),后者是「给医生看」全 App 唯一入口;
「还没核对」收成一条横幅;时间线按月分组,月份标题右边「找一找」占位(搜索是
Stage 2)。

s6:添加 sheet 标题仍是「添加病历」,不改。"
```

---

### Task 6: 「待确认」→「还没核对」,核对队列按 s7 摆

**Files:**
- Modify: `<app>/lib/screens/archive_screen.dart:967`、`:985-991`
- Modify: `<app>/lib/screens/document_detail.dart:163`
- Modify: `<app>/lib/review_state.dart`(仅注释用词)
- Modify: `<app>/test/glossary_guard_test.dart`(`kEnforced` 加 `待确认`、`点开核对并确认`、`确认无误,归入档案`)
- Test: `<app>/test/glossary_guard_test.dart`

**Interfaces:**
- Consumes: `ReviewState.instance.isPending(int docId)`(不变)
- Produces: 无新符号

> ux-audit P6:7 份全是橙色虚线 + 「待确认 · 点开核对并确认」,像 7 条错误提示。
> ia-proposal §3 第 11 簇:动作词只留一个(`核对`),且只出现在一处。

- [ ] **Step 1: 把三个词加进禁词闸(测试先红)**

```dart
const List<String> kEnforced = [
  '数据出口', '数据管理',
  '待确认', '点开核对并确认', '确认无误,归入档案',
];
```

> **词按 `s7` 逐字定**:那一屏的标题是「还没核对」、副标题「N 份扫描件;识别出的字有
> 几处不确定」、行上的按钮是「看原件」与「没问题」。计划早先写的「待核对」「核对好了」
> 是猜的,**以 mockup 为准**。

- [ ] **Step 2: 跑,确认它红**

Run: `cd <app> && flutter test test/glossary_guard_test.dart`
Expected: FAIL —— 命中 `archive_screen.dart:967`、`:988`、`document_detail.dart:163`,外加 `import_flow.dart` / `review_state.dart` / `vault_boot.dart` / `ephemeral_session.dart` 的若干注释。

- [ ] **Step 3: 改**

`lib/screens/archive_screen.dart:967`(pill 文字,`s1`/`s7` 同一个词):

```dart
                                text: '还没核对',
```

`lib/screens/archive_screen.dart:985-991`,那个 `Text` 整块删除 —— 它把 `docRowLabel(doc)`
和「点开核对并确认」用 ` · ` 拼在一起,**只删后半句会留下一个孤零零的 `join`**,
所以整块换成直接渲染类型标签:

```dart
                          // 原来每行都催一句「点开核对」,7 份就是 7 条错误提示
                          // (ux-audit P6)。那句话现在只在列表顶部说一次,行上
                          // 只留类型标签 +「还没核对」那枚 pill。
                          Text(
                            docRowLabel(doc),
                            style: MedType.secondary.copyWith(color: c.ink2),
                          ),
```

`lib/screens/document_detail.dart:163` —— `s7` 的一对按钮是「看原件」与「没问题」:

```dart
                    label: const Text('没问题'),
```

旁边那颗次按钮写「看原件」(`s7`),接已有的原件查看器。

`lib/review_state.dart` 里全部注释的「待确认」改成「还没核对」(`:8`、`:12`、`:18`、`:19`、`:91`、`:94`、`:97`、`:117`、`:136`、`:144`);`lib/import_flow.dart:26,52,58,68`、`lib/vault_boot.dart:278,340`、`lib/ephemeral_session.dart:77,78,82`、`lib/import_queue.dart:117`、`lib/screens/settings_screen.dart:284` 同样把注释里的「待确认」改成「还没核对」。

- [ ] **Step 4: 跑,确认绿**

Run: `cd <app> && flutter test test/glossary_guard_test.dart test/import_review_navigation_test.dart`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
cd <repo>
git add -u apps/mobile_flutter
git commit -m "feat(mobile): 待确认→还没核对,列表行不再每行一句「点开核对并确认」

ux-audit P6 + mockup s1/s7:一条横幅说一次,行上只留「还没核对」那枚 pill;
详情页那一对按钮逐字是「看原件」/「没问题」。"
```

---

### Task 7: 文档详情的段落标题统一成「文字」,删识别质量徽标

**Files:**
- Modify: `<app>/lib/screens/document_detail.dart:339`、`:434-483`
- Modify: `<app>/lib/screens/doctor/proxy_document_detail.dart:389`
- Modify: `<app>/test/glossary_guard_test.dart`(`kEnforced` 加 `识别文本`、`文档内容`、`识别质量`)
- Test: `<app>/test/glossary_guard_test.dart`

**Interfaces:**
- Consumes: 无
- Produces: 无新符号(`confTierFor` 及其调用点一并删除)

> **先读 `s8`。** 一份病历详情顶部是三个切换:`表格` / `文字` / `原件` ——
> 「文字」这个词在 mockup 里已经兑现,本 Task 只是让代码追上。
>
> ux-audit §4 尾注:同一段正文在照片/PDF 下顶两个标题。ia-proposal §3 第 7 簇:
> 「文字」与「原件」成一对,照片和 PDF 用同一个标题;「识别质量:高」删掉
> (它对旁边只有 14 个字的那份也会说「高」,见 `document_detail.dart:434` 的自述)。

- [ ] **Step 1: 把三个词加进禁词闸(测试先红)**

```dart
const List<String> kEnforced = [
  '数据出口', '数据管理',
  '待确认', '点开核对并确认', '确认无误,归入档案',
  '识别文本', '文档内容', '识别质量',
];
```

- [ ] **Step 2: 跑,确认它红**

Run: `cd <app> && flutter test test/glossary_guard_test.dart`
Expected: FAIL —— 命中 `document_detail.dart:69,226,339,434,446,449,464,470,476,482`、`proxy_document_detail.dart:28,389`、`ephemeral_session.dart:59,83`、`ocr_bridge.dart:9`、`import_flow.dart:215`、`cloud_extract.dart:177,440`、`widgets/report_content.dart:228`。

- [ ] **Step 3: 改**

`lib/screens/document_detail.dart:339` 与 `lib/screens/doctor/proxy_document_detail.dart:389`,两处的三目运算直接换成常量:

```dart
              '文字',
```

`lib/screens/document_detail.dart:434-483`,`confTierFor` 与识别质量徽标那个 widget 整段删除;同文件里渲染它的那一处调用一并删掉。

上面 grep 命中的其余位置全部是注释,把「识别文本」改成「识别出来的文字」、「文档内容」改成「文件正文」、「识别质量」改成「识别置信度」—— 都是内部说法,不再撞用户可见词。

- [ ] **Step 4: 跑,确认绿**

Run: `cd <app> && flutter test test/glossary_guard_test.dart test/report_content_test.dart`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
cd <repo>
git add -u apps/mobile_flutter
git commit -m "feat(mobile): 正文段落标题统一成「文字」,删掉识别质量徽标

ia-proposal §3 第 7 簇。徽标那段的代码注释自己就写着它会对 14 个字的那份
说「高」,删。"
```

---

### Task 8: 「趋势」tab 按 s2 摆 —— 病程档案 → 分类 chip → 关键化验 → 看懂 → 最近就诊 → 记录一下

**Files:**
- Modify: `<app>/lib/screens/trends_screen.dart`(AppBar 标题、`_load()` 多取一份 `viewVisitSummary()`、列表顶部四块)
- Modify: `<app>/test/visit_card_dedup_test.dart`(`visitCardShowsDate` 的 import 换文件)
- **不建** `MemberChip`(`s2` 顶栏只有「趋势」两个字,换成员在「病历」的 hero 卡上)
- Test: `<app>/test/trends_screen_test.dart`(新建)

**Interfaces:**
- Consumes: `TrendsScreen`(Task 3 未改名,原样)、`viewVisitSummary()` → `Future<VisitSummaryDto>`、`VisitSummaryDto.recentLabs` / `.recentVisits` / `.patient.recordCount`
- Produces(全部是纯 widget / 纯函数,`flutter test` 可直接 pump):
  - `class KeyLabsSnapshot extends StatelessWidget`(`const KeyLabsSnapshot({super.key, required List<VisitLabDto> labs, required void Function(int docId) onOpenDoc})`)
  - `class RecentVisitsCard extends StatelessWidget`(`const RecentVisitsCard({super.key, required List<VisitRecordDto> visits, required int total, required void Function(int docId) onOpenDoc})`)
  - `bool visitCardShowsDate({required String title, required String date})`(从 `overview_screen.dart` 原样搬来,签名一字不改)
  - `class DiseaseFileEntryCard extends StatelessWidget`(`const DiseaseFileEntryCard({super.key, this.onTap})`)
  - `class RecordEntryCard extends StatelessWidget`(`const RecordEntryCard({super.key, this.onTap})`)
  - `class UnderstandBanner extends StatelessWidget`(`const UnderstandBanner({super.key})`)—— `s2` 那条「看懂」横幅的**占位**(内容由另一条线做)

> **先读 `s2`。** 这一屏自上而下的顺序是固定的,**别自己重排**:
>
> 1. 「病程档案 · <病名>」入口条(Stage 1 **占位**)
> 2. `关键化验` 标题 + 分类 chip(肾功能 / 血糖 / 血脂 / 血常规 / 风湿免疫 —— 就是今天的 `trendPanelChips`)
> 3. 关键化验各行(`s2` 画了迷你折线,**Stage 1 保持今天的最后一次取值行**,折线是 Stage 2)
> 4. 「看懂」内容横幅(Stage 1 **占位**)
> 5. `最近就诊` 列表
> 6. `记录一下` 按钮(`s9`:血压 / 体重 / 今天不舒服 / 血糖 / 写句话)
>
> **顶栏不加成员 chip**(`s2` 顶栏只有「趋势」两个字)。
>
> **⚠️ 这个 Task 必须排在 Task 9 之前跑完。** Task 9 会删掉 `overview_screen.dart`,
> 而「最近的关键化验」(`_LabSnapshot`)与「最近归档」(`_RecentArchive`)现在还住在
> 那个文件里 —— 先搬进「趋势」,再删原屋,中间不能有一版是「两处都没有」。
>
> 「病程档案」的**内容由另一条线做**,本阶段只留入口位:一张卡,写清楚这里以后
> 放什么,点了给一句「还在做」。「记录」(手填血压/体重/笔记)同样从概览搬进来。

- [ ] **Step 1: 写这个失败的测试**

`<app>/test/trends_screen_test.dart`:

```dart
// 「趋势」tab 顶部四块:化验快照 / 最近就诊 / 病程档案入口 / 记录入口。
// 整屏不可 pump —— `TrendsScreen` 在字段初始化那一刻就调 `viewTrends()`
// 与 `viewVisitSummary()`(FFI),`flutter test` 不带原生库会直接崩(与
// `test/overview_quick_actions_test.dart` 同一条限制)。这四块都是纯 widget。
//
// 前两块是从 `overview_screen.dart` 搬过来的(概览在 Task 9 整屏解散)。**搬家
// 必须先于拆房**:这个文件的存在就是证明搬到了。
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show Int64List;
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/screens/trends_screen.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/theme.dart';

Widget wrap(Widget child, {double textScale = 1.0}) => MaterialApp(
  theme: MedMe.theme(),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void useNarrowPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360 * 3, 640 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

void main() {
  // ── 从概览搬过来的两块(Task 9 会删掉原屋) ────────────────────────────────
  group('化验快照 / 最近就诊 已经搬进「趋势」', () {
    final labs = [
      VisitLabDto(
        name: '肌酐',
        date: '2025-11-05',
        value: 96,
        unit: 'umol/L',
        flag: 'H',
        valuesConverted: false,
        documentId: 7,
        selfMeasured: false,
        unverified: false,
      ),
    ];
    final visits = [
      VisitRecordDto(
        title: '化验 · 协和',
        kind: 'lab',
        date: '2025-11-05',
        documentIds: Int64List.fromList([7]),
      ),
    ];

    testWidgets('化验快照:数值与标记照原样显示,点得开那一份', (tester) async {
      useNarrowPhone(tester);
      var opened = 0;
      await tester.pumpWidget(
        wrap(KeyLabsSnapshot(labs: labs, onOpenDoc: (id) => opened = id)),
      );
      expect(find.text('肌酐'), findsOneWidget);
      expect(find.text('偏高'), findsOneWidget, reason: '化验单说的,照搬');
      await tester.tap(find.text('肌酐'));
      expect(opened, 7);
    });

    testWidgets('最近就诊:标题、份数、点进一份', (tester) async {
      useNarrowPhone(tester);
      var opened = 0;
      await tester.pumpWidget(
        wrap(
          RecentVisitsCard(
            visits: visits,
            total: 12,
            onOpenDoc: (id) => opened = id,
          ),
        ),
      );
      expect(find.text('化验 · 协和'), findsOneWidget);
      expect(find.text('全部 12 份'), findsOneWidget);
      await tester.tap(find.text('化验 · 协和'));
      expect(opened, 7);
    });

    test('标题里已有日期就不在右边重复一遍(原样搬来的纯函数)', () {
      expect(
        visitCardShowsDate(title: '化验 · 协和 · 2025-11-05', date: '2025-11-05'),
        isFalse,
      );
      expect(visitCardShowsDate(title: '化验 · 协和', date: '2025-11-05'), isTrue);
      expect(visitCardShowsDate(title: '化验 · 协和', date: ''), isFalse);
    });

    testWidgets('两块空态都不报错、不撒谎', (tester) async {
      useNarrowPhone(tester);
      await tester.pumpWidget(
        wrap(
          Column(
            children: [
              KeyLabsSnapshot(labs: const [], onOpenDoc: (_) {}),
              RecentVisitsCard(visits: const [], total: 0, onOpenDoc: (_) {}),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('一切正常'), findsNothing, reason: '没数据不等于正常');
    });
  });

  testWidgets('看懂横幅:占位,不假装已经有内容', (tester) async {
    useNarrowPhone(tester);
    await tester.pumpWidget(wrap(const UnderstandBanner()));
    expect(find.text('看懂'), findsOneWidget);
    expect(find.textContaining('还在做'), findsOneWidget);
    // s2 里这条横幅引用的是某份报告「提示」一栏的原文 —— 没有真内容时,
    // 一个像结论的字都不许摆出来。
    for (final claim in ['提示:', '建议', '考虑']) {
      expect(find.textContaining(claim), findsNothing);
    }
  });

  testWidgets('病程档案入口:说清楚以后放什么,不假装已经有了', (tester) async {
    useNarrowPhone(tester);
    await tester.pumpWidget(wrap(const DiseaseFileEntryCard()));
    expect(find.text('病程档案'), findsOneWidget);
    // 不许宣称已经能用 —— 内容由另一条线做。
    for (final claim in ['活动度', '该查没查', '查看详情']) {
      expect(find.textContaining(claim), findsNothing);
    }
    expect(find.textContaining('还在做'), findsOneWidget);
  });

  testWidgets('记录一下:点得动', (tester) async {
    useNarrowPhone(tester);
    var tapped = false;
    await tester.pumpWidget(wrap(RecordEntryCard(onTap: () => tapped = true)));
    expect(find.text('记录一下'), findsOneWidget);
    await tester.tap(find.text('记录一下'));
    expect(tapped, isTrue);
  });

  testWidgets('2× 字号不溢出', (tester) async {
    useNarrowPhone(tester);
    await tester.pumpWidget(
      wrap(
        const Column(children: [DiseaseFileEntryCard(), RecordEntryCard()]),
        textScale: 2.0,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
```

- [ ] **Step 2: 跑,确认它红**

Run: `cd <app> && flutter test test/trends_screen_test.dart`
Expected: FAIL,`Undefined name 'KeyLabsSnapshot'` / `'RecentVisitsCard'` / `'visitCardShowsDate'` / `'DiseaseFileEntryCard'`。

- [ ] **Step 3: 实现 —— 先搬家,再加两张新卡**

**3a. 把概览的两块搬进来(改公开名,逻辑一字不改)。**

```bash
cd <app>
# 只搬这四段:_LabSnapshot、_RecentArchive、_VisitCard、_SectionHeader,
# 外加纯函数 visitCardShowsDate 和它旁边的副标题函数。
# 搬完 overview_screen.dart 里这几段删掉(它整屏在 Task 9 删,先留着能编译)。
```

从 `lib/screens/overview_screen.dart` 剪切到 `lib/screens/trends_screen.dart` 末尾,并改这三个名字:

- `class _LabSnapshot` → `class KeyLabsSnapshot`(构造参数名 `labs` / `onOpenDoc` 不变)
- `class _RecentArchive` → `class RecentVisitsCard`(构造参数名 `visits` / `total` / `onOpenDoc` 不变),section 标题 `'最近归档'` → `'最近就诊'`,空态文案 `'还没有归档的记录。'` → `'还没有添加过病历。'`,`onAction: goToArchive` → `onAction: goToRecords`
- `_VisitCard`、`_SectionHeader`、`visitCardShowsDate` 原样搬,名字不变(前两个仍是私有)

`test/visit_card_dedup_test.dart` 的 import 从 `screens/overview_screen.dart` 改成 `screens/trends_screen.dart`。

**3b. `TrendsScreen` 多取一份 visit summary,并开两个注入点。**

注入点与 `ForDoctorScreen`(Task 3)同款,理由也一样:整屏碰 FFI,`flutter test`
不带原生库;而「存完一条记录要当场刷新」这条回归只有整屏能验(Task 17 的 1c)。

```dart
/// 这一屏一次要用到的三样东西:全部趋势序列 + 检验大类 chip 的目录 +
/// 概览搬过来的那份就诊摘要(化验快照 / 最近就诊)。
typedef TrendsData = (List<TrendSeriesDto>, List<String>, VisitSummaryDto);

class TrendsScreen extends StatefulWidget {
  const TrendsScreen({super.key, this.load, this.onRequestAddNote});

  /// 数据源。null → 三个真实投影(FFI)。
  final Future<TrendsData> Function()? load;

  /// 「记录」按下时走的动作,返回「是否真的存了一条」。null → 开录入弹层(FFI)。
  final Future<bool?> Function(BuildContext context)? onRequestAddNote;

  @override
  State<TrendsScreen> createState() => _TrendsScreenState();
}

class _TrendsScreenState extends State<TrendsScreen> {
  late Future<TrendsData> _future = _load();

  Future<TrendsData> _load() async {
    final injected = widget.load;
    if (injected != null) return injected();
    final r = await Future.wait([
      viewTrends(),
      viewTrendPanelCatalog(),
      viewVisitSummary(),
    ]);
    return (
      r[0] as List<TrendSeriesDto>,
      r[1] as List<String>,
      r[2] as VisitSummaryDto,
    );
  }

  /// 「记录」。**只有真的存下了才重新拉一次** —— 与 `ForDoctorScreen._addNote`
  /// 同一条规矩(BUG-4):存了却不拉,用户看着自己刚量的血压没出现。
  Future<void> _addRecord() async {
    final saved = widget.onRequestAddNote != null
        ? await widget.onRequestAddNote!(context)
        : await showManualEntrySheet(context);
    if (saved != true || !mounted) return;
    setState(() => _future = _load());
  }
```

> `HomeShell.tabScreens` 里那个 `const TrendsScreen()` 不受影响 —— 两个参数都可选。

**3c-1. 「趋势」顶栏。** AppBar 标题保持 `'趋势'`,**不加 actions**(`s2`)。

**3c-2. 整屏按 `s2` 的顺序重排。** 列表 children 从上到下:

```dart
                // ① 病程档案入口(Stage 1 占位,内容由另一条线做)
                DiseaseFileEntryCard(
                  onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                    appSnackBar(content: const Text('病程档案还在做')),
                  ),
                ),
                const SizedBox(height: MedShape.s4),
                // ② 「关键化验」标题 + 分类 chip(就是今天的 trendPanelChips)
                Text('关键化验', style: MedType.caption.copyWith(color: c.ink3)),
                const SizedBox(height: MedShape.s1),
                /* 今天那一排 _PanelChip,原样搬到这里 */
                const SizedBox(height: MedShape.s2),
                // ③ 关键化验各行。s2 画了迷你折线 —— **Stage 1 保持今天的取值行**,
                //    折线是 Stage 2(ia-proposal §6):位置先摆对,内容不提前做。
                KeyLabsSnapshot(labs: summary.recentLabs, onOpenDoc: _openDoc),
                const SizedBox(height: MedShape.s5),
                // ④ 「看懂」横幅(Stage 1 占位)
                const UnderstandBanner(),
                const SizedBox(height: MedShape.s5),
                // ⑤ 最近就诊
                RecentVisitsCard(
                  visits: summary.recentVisits,
                  total: summary.patient.recordCount.toInt(),
                  onOpenDoc: _openDoc,
                ),
                const SizedBox(height: MedShape.s4),
                // ⑥ 记录一下(s9:血压 / 体重 / 今天不舒服 / 血糖 / 写句话)
                RecordEntryCard(onTap: _addRecord),
                const SizedBox(height: MedShape.s5),
```

原来那段 `_Preamble`(顶部开发者口吻的免责长文,ux-audit 屏19)**删掉** —— `s2` 里没有它。

补 `_openDoc`(与档案屏同一条埋点,只报「打开了一份」):

```dart
  void _openDoc(int id) {
    Analytics.track(AnalyticsEvent.docOpened);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DocumentDetailScreen(docId: id)),
    );
  }
```

补 import:`analytics.dart`、`screens/document_detail.dart`、`screens/manual_entry_sheet.dart`、`widgets/app_snack_bar.dart`、`widgets/lab_status.dart`、`widgets/med_card.dart`、`doc_labels.dart`。

**3c. 两张新卡,追加在文件末尾:**

```dart
/// 「病程档案」的入口位。**本阶段只有位置,没有内容** —— 内容(活动度 / 用药
/// 时间轴 / 该查没查 / 给医生的一页)由另一条线做,ia-proposal §6 Stage 2。
///
/// 留一张说清楚「这里以后放什么」的卡,而不是留空:老人在一个空 tab 上学不到
/// 这个 tab 是干什么的,而这正是「趋势」这一步最需要先立起来的东西。
class DiseaseFileEntryCard extends StatelessWidget {
  const DiseaseFileEntryCard({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Card(
      child: ListTile(
        leading: Icon(Icons.timeline_outlined, color: c.ink3),
        title: Text('病程档案', style: MedType.body.copyWith(color: c.ink)),
        subtitle: Text(
          '把一个病的用药、检查、变化串成一条线 —— 还在做,先占个位。',
          style: MedType.secondary.copyWith(color: c.ink2),
        ),
        onTap: onTap,
      ),
    );
  }
}

/// 「看懂」横幅的**占位**(`s2` 里它引用某份报告「提示」一栏的原文)。
///
/// **Stage 1 只有壳。** 真内容(哪份报告、原文哪一段)由另一条线做;在那之前
/// 一个字都不许编 —— 这一块摆的是医学结论,编出来的那句会被当成医生说的话。
class UnderstandBanner extends StatelessWidget {
  const UnderstandBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return MedCard(
      child: Padding(
        padding: const EdgeInsets.all(MedShape.s3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('看懂', style: MedType.caption.copyWith(color: c.ink3)),
            const SizedBox(height: 4),
            Text(
              '把报告上那段「提示」原文摘出来放这里 —— 还在做。',
              style: MedType.secondary.copyWith(color: c.ink2),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「记录一下」入口(`s2` 底部那颗;点开是 `s9`:血压 / 体重 / 今天不舒服 /
/// 血糖 / 写句话)。从解散的概览快捷操作搬过来 —— 自己填的数和医院的数看的是
/// 同一件事,归属在「趋势」。
class RecordEntryCard extends StatelessWidget {
  const RecordEntryCard({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Card(
      child: ListTile(
        leading: Icon(Icons.edit_note_outlined, color: c.ink3),
        title: Text('记录一下', style: MedType.body.copyWith(color: c.ink)),
        subtitle: Text(
          '自己量的血压、体重,或者想记一句话',
          style: MedType.secondary.copyWith(color: c.ink2),
        ),
        onTap: onTap,
      ),
    );
  }
}
```

- [ ] **Step 4: 跑,确认绿**

Run: `cd <app> && flutter test test/trends_screen_test.dart test/visit_card_dedup_test.dart test/mobile_ia_test.dart`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
cd <repo>
git add -u apps/mobile_flutter
git add apps/mobile_flutter/test/trends_screen_test.dart
git commit -m "feat(mobile): 趋势 tab 按 s2 摆 —— 病程档案 / 关键化验 / 看懂 / 最近就诊 / 记录一下

化验快照与最近就诊从概览搬过来(概览在下一个 Task 整屏解散)——
先搬家再拆房,中间不能有一版是两处都没有。

mockup s2 的顺序是固定的,别自己重排。病程档案与「看懂」两块内容由另一条线做,
这里只留位置并说清楚还在做;s2 画的迷你折线是 Stage 2,Stage 1 保持今天的取值行。
顶栏不加成员 chip(换成员在「病历」的 hero 卡上)。删掉趋势顶部那段开发者
口吻的免责长文(ux-audit 屏19,s2 里没有它)。"
```

---

### Task 9: 「给医生看」页四条入口接线 + 概览解散

**Files:**
- Modify: `<app>/lib/screens/for_doctor_screen.dart`(四个回调接真实跳转)
- Delete: `<app>/lib/screens/overview_screen.dart`
- Delete: `<app>/test/overview_quick_actions_test.dart`
- Modify: `<app>/lib/vault_events.dart`(删 Task 3 留的三个 `@Deprecated` shim)
- Modify: `<app>/lib/main.dart:687`、`<app>/lib/analytics.dart:350`(注释里提到的 `goToArchive()`)
- Modify: `<app>/lib/screens/settings_screen.dart`(接收概览搬来的成员卡)
- Create: `<app>/test/for_doctor_screen_test.dart`
- Modify: `<app>/lib/screens/visit_summary_sheet.dart:37`、`:224`(删「复制全文给医生」)

**Interfaces:**
- Consumes: `ForDoctorActions`(Task 3)、`HomeTiles`(Task 5,「病历」首页那两颗方块;右边那颗是「给医生看」全 App 唯一入口)、`QrShareScreen`、`ExportScreen`、`EmergencyCardScreen`、`AppMode.instance.setMode`、`KeyLabsSnapshot` / `RecentVisitsCard`(**Task 8 已经搬进 `trends_screen.dart`**)
- Produces: 无新符号

> ux-audit P3 + 屏24:「复制全文给医生」复制到用户自己的剪贴板,对面医生拿不到 ——
> 代码注释(`visit_summary_sheet.dart:37`)自己就写着「两个按钮分不清,得自己推」。
> 这一页升格成整页之后只留一条出口:出码。

- [ ] **Step 1: 先确认 Task 8 已经跑完 —— 概览的内容都搬走了,才能拆房**

> **这是本 Task 的前置闸,不是提醒。** 本 Task 要删 `overview_screen.dart`,而
> 「最近的关键化验」与「最近归档」在 Task 8 之前还只住在那个文件里。**Task 8 必须
> 先跑完**,中间不能有一版是「两处都没有」。

Run:

```bash
cd <app>
grep -n "class KeyLabsSnapshot\|class RecentVisitsCard\|bool visitCardShowsDate" lib/screens/trends_screen.dart
grep -n "class HomeTiles\|class PendingReviewBanner\|class MonthHeader" lib/screens/archive_screen.dart
flutter test test/trends_screen_test.dart test/archive_header_test.dart
```

Expected: 三个符号都在 `trends_screen.dart` 里、`HomeTiles`/`PendingReviewBanner`/`MonthHeader` 在 `archive_screen.dart` 里,两个测试文件全绿。**任何一条不满足就停下来先做 Task 8 / Task 5**,不要继续。

- [ ] **Step 2: 写这个失败的测试**

`<app>/test/for_doctor_screen_test.dart`:

```dart
// 「给医生看」底部四条入口。整屏不可 pump(`ForDoctorScreen` 走 `viewVisitSummary()`
// FFI);`ForDoctorActions` 是拆出来的纯 widget。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/screens/for_doctor_screen.dart';
import 'package:mobile_flutter/theme.dart';

Widget wrap(Widget child, {double textScale = 1.0}) => MaterialApp(
  theme: MedMe.theme(),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  testWidgets('四条入口都在,顺序固定:出码 / 打印导出 / 急救 / 代拍', (tester) async {
    await tester.pumpWidget(wrap(const ForDoctorActions()));
    final labels = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((t) => (t.title! as Text).data)
        .toList();
    expect(labels, ['出码给医生看', '打印 / 导出', '急救卡', '我是医生,替病人代拍']);
  });

  testWidgets('四条各自触发自己的回调', (tester) async {
    var qr = false, exp = false, emg = false, proxy = false;
    await tester.pumpWidget(
      wrap(
        ForDoctorActions(
          onShowQr: () => qr = true,
          onExport: () => exp = true,
          onEmergency: () => emg = true,
          onProxy: () => proxy = true,
        ),
      ),
    );
    await tester.tap(find.text('出码给医生看'));
    await tester.tap(find.text('打印 / 导出'));
    await tester.tap(find.text('急救卡'));
    await tester.tap(find.text('我是医生,替病人代拍'));
    expect([qr, exp, emg, proxy], [true, true, true, true]);
  });

  testWidgets('2× 字号不溢出', (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(const ForDoctorActions(), textScale: 2.0));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
```

- [ ] **Step 3: 跑,确认它红**

Run: `cd <app> && flutter test test/for_doctor_screen_test.dart`
Expected: FAIL —— 第一条断言的顺序对不上(Task 3 摆的占位卡 `onTap` 全是 null,第二条断言会全 false)。

- [ ] **Step 4: 实现**

`lib/screens/for_doctor_screen.dart` 的 `build` 里,把 `const ForDoctorActions()` 换成:

```dart
              ForDoctorActions(
                onShowQr: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const QrShareScreen()),
                ),
                onExport: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const ExportScreen()),
                ),
                onEmergency: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const EmergencyCardScreen(),
                  ),
                ),
                onProxy: _enterProxy,
              ),
```

同文件加 `_enterProxy`:

```dart
  /// 进代拍。**先确认一次身份**(一次性的那道确认在 Task 15 补进代拍首页),
  /// 这里只负责切模式 —— `AppRoot` 监听同一个 notifier,自动换根界面。
  Future<void> _enterProxy() async {
    Analytics.track(AnalyticsEvent.modeSelected, {
      'mode': AppModeKind.doctor.name,
      'where': 'for_doctor',
    });
    Analytics.setContext({'mode': AppModeKind.doctor.name});
    await AppMode.instance.setMode(AppModeKind.doctor);
  }
```

并补上 import:`app_mode.dart`、`screens/qr_share_screen.dart`、`screens/export_screen.dart`、`screens/emergency_card_screen.dart`。

`lib/screens/visit_summary_sheet.dart:218-228`,「复制全文给医生」那颗按钮连同 `_copy` 方法删除(`:98-115`);`:37` 那条「两个按钮分不清,得自己推」的注释一并删除 —— 问题已经没了。`AnalyticsEvent.visitSheetAction` 的 `VisitSheetAction.copy` 枚举值保留(历史事件还在库里),但不再有调用点。

删概览,**连同 Task 3 留的三个过渡 shim** —— 概览是它们最后的调用方:

```bash
cd <app>
git rm lib/screens/overview_screen.dart test/overview_quick_actions_test.dart
grep -rl "overview_screen" lib test | xargs sed -i '' '/overview_screen/d'
# 确认真的没人再调了,再动手删
grep -rn "goToArchive\|goToTrends\|goToEmergencyCard" lib test
```

上面那条 grep 此刻应当只剩:`lib/vault_events.dart` 里**两个** shim 的定义
(`goToArchive` / `goToEmergencyCard`)、真函数 `goToTrends` 的定义与调用点,外加
`lib/main.dart:687` 与 `lib/analytics.dart:350` 两处注释。把 `lib/vault_events.dart`
末尾「过渡期 shim」那一整段(两个 `@Deprecated` 函数连同上面的说明注释)删掉,
两处注释里的 `goToArchive()` 改成 `goToRecords()`。**`goToTrends` 留着** ——
「趋势」仍然是一个 tab。

概览搬走的三件东西:`IdentityHeroCard` + 成员切换 → 「我」tab(`settings_screen.dart` 顶部,Task 12 摆位置);「最近的关键化验」→ 「趋势」(Task 8 已搬,`KeyLabsSnapshot`);「最近归档」→ 与「病历」tab 时间线重复,删。

- [ ] **Step 5: 跑,确认绿**

Run:

```bash
cd <app>
flutter analyze
flutter test
```

Expected: **整仓 analyze + test 全绿。** 三处会红,都在意料之中:
- `visit_summary_sheet_test.dart` 里若有断言「复制全文给医生」存在 → 改成断言它**不**存在;
- 删了两个 shim 之后 `flutter analyze` 不该再有 `deprecated_member_use_from_same_package`;若还有,说明还有调用方没清干净,回上一步 grep;
- `test/visit_card_dedup_test.dart` 的 import 已在 Task 8 改过,这里只是顺带复核。

- [ ] **Step 6: 提交**

```bash
cd <repo>
git add -u apps/mobile_flutter
git add apps/mobile_flutter/test/for_doctor_screen_test.dart
git commit -m "feat(mobile): 给医生看页四条入口接线;概览整屏解散

删「复制全文给医生」—— 复制到用户自己的剪贴板,对面医生拿不到
(ux-audit P3,代码注释里自己记着这条)。"
```

---

### Task 10: 应急卡降为「给医生看」页里一条,大字模式原样保留

**Files:**
- Modify: `<app>/lib/screens/emergency_card_screen.dart:18-31`(类文档)
- Test: `<app>/test/mobile_ia_test.dart`(应急卡 group 追加一条)

**Interfaces:**
- Consumes: `EmergencyCardScreen`、`EmergencyBigCardScreen`(均不改构造签名)
- Produces: 无新符号

> ia-proposal §7 决定 3:**降级,但大字模式原样保留**。它是全 App 做得最好的一屏
> (ux-audit 屏23),降的是位置不是质量。这个 Task 的全部工作就是:确认降级没有
> 顺手弄丢大字模式,并把类文档里「这是一个 tab」的话改对。

- [ ] **Step 1: 写这条失败的测试**

`test/mobile_ia_test.dart` 的 `group('应急卡', ...)` 末尾追加:

```dart
    testWidgets('降级之后大字模式一字未动:深色、高对比、没有输入框', (tester) async {
      // ia-proposal §7 决定 3:降的是位置不是质量。这条测试存在的唯一理由是
      // 「顺手」—— 把一屏从 tab 降成 push 进来的一页时,最容易发生的事是有人
      // 觉得「既然不常用了」就顺便简化它。
      await tester.pumpWidget(
        wrapScreen(
          EmergencyBigCardScreen(card: emptyCard, profile: profile),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(TextFormField), findsNothing);
      expect(find.text('未登记'), findsOneWidget);
      // 它不再是底栏的一项(底栏只有三个:病历 / 趋势 / 我)。
      expect(
        HomeShell.tabDestinations.map((d) => d.label),
        isNot(contains('应急卡')),
      );
      expect(HomeShell.tabDestinations.length, 3);
    });
```

- [ ] **Step 2: 跑,确认它红**

Run: `cd <app> && flutter test test/mobile_ia_test.dart -N 应急卡`
Expected: 若 Task 3 已把底栏改对(三项,没有「应急卡」),这条会 PASS —— 当回归锁住即可,直接进 Step 3。若 FAIL,说明底栏还没改对,回到 Task 3 修。

- [ ] **Step 3: 改类文档**

`lib/screens/emergency_card_screen.dart:18-24`:

```dart
/// 急救信息 —— 从「给医生看」那一页的第三条入口进来(ia-proposal §7 决定 3 +
/// mockup:不再占底栏席位,但**质量一字未动**)。
///
/// 这是全 app 唯一一个**读者不是用户本人**的界面。所有取舍都从这一句推出来:
///
/// * **[EmergencyBigCardScreen] 大字模式**才是这一屏的产品本体,平时这一屏
///   只是它的维护界面。所以主按钮是「大字模式」,不是别的。
```

同文件 `:173` 那句「这个 tab 把它花在这里」改成「这一屏把它花在这里」;`:18-19`
「底部导航一级 tab「应急卡」」的说法一并去掉。

- [ ] **Step 4: 跑,确认绿**

Run:

```bash
cd <app>
flutter analyze
flutter test
# 过渡 shim 应当在 Task 9 已经清空 —— 这里只是最后复核一次
grep -rn "goToArchive\|goToTrends\|goToEmergencyCard" lib test
```

Expected: analyze + test 全绿;最后那条 grep **无输出**。有输出说明 Task 9 漏删了,
回去补。

- [ ] **Step 5: 提交**

```bash
cd <repo>
git add -u apps/mobile_flutter
git commit -m "feat(mobile): 应急卡从 tab 降成「给医生看」页里一条,大字模式原样保留

加了一条回归,专门拦「既然不常用了就顺便简化它」这种顺手。"
```

---

### Task 11: 第一次出码时告知一次(不拦登录)

**Files:**
- Create: `<app>/lib/screens/qr_notice_sheet.dart`
- Create: `<app>/test/qr_notice_test.dart`
- Modify: `<app>/lib/account.dart`(加一个 `qr_notice_seen` 键)
- Modify: `<app>/lib/screens/qr_share_screen.dart`(`_init()` 里先问一次)

**Interfaces:**
- Consumes: `SharedPreferences`
- Produces:
  - `const qrNoticeSeenKey = 'qr_notice_seen'`(`lib/account.dart`)
  - `bool shouldShowQrNotice({required bool seen})`
  - `Future<bool> showQrNoticeSheet(BuildContext context)` —— 返回「要不要继续出码」
  - `class QrNoticeBody extends StatelessWidget`(纯 widget,两颗按钮)

> **创始人已拍板,取代原方案。** 之前这个 Task 是「未登录不给出码」;现在
> **出码不看登录状态,照常可用**,改成**第一次**在这台设备上出码时,用大白话把
> 「东西去哪了」说一遍,让用户自己按下那一下。
>
> 理由很直接:诊室里那 30 秒是这个产品的全部价值,用一道登录墙挡住它,代价比
> 收益大;而「用户不知道发生了什么」这件事,一句话就能解决,不需要一道墙。
>
> **逐字文案照 `s13`(比早先那版多一句「我们打不开」,以 mockup 为准)**:
> 标题「第一次出码,说一句」
> 正文「会把加密后的病历暂存到云端 15 天,只有扫这个码的人能看;我们打不开。」
> 两颗按钮,左「先不出」右「好,出码」。
>
> `s13` 的出码屏本体还有两行说明(「医生用手机扫一下就能看」/「15 天内有效;
> 只有扫这个码的人能看」)和一条「医生要长期看(15 天)· 医生也要装 MedMe」
> 的可选项 —— 那条就是今天 `_canGrant` 那个二选一,**文案照 `s13` 换,逻辑不动**。
>
> 这句话与隐私政策第三节**第 3 项**(二维码中转)说的是同一件事,政策那边**不用改**
> (Task 18 只动第 7 项)。

- [ ] **Step 1: 写这个失败的测试**

`<app>/test/qr_notice_test.dart`:

```dart
// 第一次出码时告知一次(创始人拍板,取代「未登录不给出码」)。
//
// 钉三件事:①「第一次」的判断只看 seen,不看登录;② 那句话逐字出现;
// ③ 两颗按钮各自返回什么。文案是对外承诺(与隐私政策第三节第 3 项同一件事),
// 改了就得回去改政策 —— 所以这里按逐字钉。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/screens/qr_notice_sheet.dart';
import 'package:mobile_flutter/theme.dart';

void main() {
  group('问不问', () {
    test('这台设备没见过 → 问', () {
      expect(shouldShowQrNotice(seen: false), isTrue);
    });
    test('见过就不再问 —— 一次性,不是每次出码都弹', () {
      expect(shouldShowQrNotice(seen: true), isFalse);
    });
  });

  group('sheet 本体', () {
    testWidgets('那句话逐字出现,两颗按钮都在', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: MedMe.theme(),
          home: const Scaffold(body: QrNoticeBody()),
        ),
      );
      expect(
        find.text('会把加密后的病历暂存到云端 15 天,只有扫这个码的人能看;我们打不开。'),
        findsOneWidget,
      );
      expect(find.text('好,出码'), findsOneWidget);
      expect(find.text('先不出'), findsOneWidget);
      // 旧方案的痕迹一处都不许留:不拦登录、不报状态码。
      expect(find.textContaining('先登录'), findsNothing);
      expect(find.textContaining('403'), findsNothing);
    });

    testWidgets('2× 字号不溢出', (tester) async {
      tester.view.physicalSize = const Size(360 * 3, 640 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: MedMe.theme(),
          home: const MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2.0)),
            child: Scaffold(body: SingleChildScrollView(child: QrNoticeBody())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
```

- [ ] **Step 2: 跑,确认它红**

Run: `cd <app> && flutter test test/qr_notice_test.dart`
Expected: FAIL,`Target of URI doesn't exist: 'package:mobile_flutter/screens/qr_notice_sheet.dart'`。

- [ ] **Step 3: 实现**

`lib/account.dart`,在 `cloudExtractAskedKey` 旁边加:

```dart
/// 第一次出码前那条告知,这台设备上说过没有(一次性)。**跟设备走,不按成员、
/// 也不按登录状态** —— 说的是「东西去哪了」,那件事和你是谁无关。
const qrNoticeSeenKey = 'qr_notice_seen';
```

新建 `lib/screens/qr_notice_sheet.dart`:

```dart
// 第一次出码前告知一次(创始人拍板)。
//
// 这条取代了「未登录不给出码」那个方案:诊室里那 30 秒是这个产品的全部价值,
// 用一道登录墙挡住它,代价比收益大。而「用户不知道发生了什么」这件事,一句话
// 就够,不需要一道墙。
//
// ⚠️ 那句话是**对外承诺**,与隐私政策第三节第 3 项(二维码中转)说的是同一件事。
// 改这里的文案 = 改对外说法,必须同步去看 `gh-pages` 的 `privacy.html`
// (CLAUDE.md 硬规矩 4)。`test/qr_notice_test.dart` 按逐字钉住它。
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobile_flutter/account.dart';

/// 逐字文案。**单独拎成常量**,让测试和这一屏引用同一份字符串 —— 两处各写一遍,
/// 改一处忘一处时测试反而是绿的。
const kQrNoticeText = '会把加密后的病历暂存到云端 15 天,只有扫这个码的人能看;我们打不开。';

/// 这次该不该说。纯判断,方便单测。**不看登录状态** —— 登录与否都照常出码。
bool shouldShowQrNotice({required bool seen}) => !seen;

Future<bool> loadQrNoticeSeen() async {
  try {
    return (await SharedPreferences.getInstance()).getBool(qrNoticeSeenKey) ?? false;
  } catch (_) {
    // 读不到就当说过 —— 宁可少说一次,也不要每次出码都弹一张挡在医生面前的纸。
    return true;
  }
}

/// 说一次,并记下「说过了」。返回**要不要继续出码**。
///
/// 「先不出」也记 seen:他已经看过这句话了,再问一遍只是烦人。
Future<bool> showQrNoticeSheet(BuildContext context) async {
  final go = await showModalBottomSheet<bool>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    isScrollControlled: true,
    builder: (_) => const SafeArea(child: QrNoticeBody()),
  );
  try {
    await (await SharedPreferences.getInstance()).setBool(qrNoticeSeenKey, true);
  } catch (_) {}
  return go ?? false;
}

/// sheet 的内容主体。**纯 widget,不碰 prefs** —— 这样 `flutter test` 测得到。
class QrNoticeBody extends StatelessWidget {
  const QrNoticeBody({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            // `s13` 逐字。
            '第一次出码,说一句',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          const Text(kQrNoticeText, style: TextStyle(height: 1.6)),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('先不出'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('好,出码'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
```

同时把出码屏本体的文案换成 `s13` 逐字:标题 `出码`、副标题 `医生用手机扫一下就能看`、
码下面一行 `15 天内有效;只有扫这个码的人能看`;`_canGrant` 那个二选一的第二项写成
`医生要长期看(15 天)` + 小字 `医生也要装 MedMe`。**逻辑一行不动**,只换字。

`lib/screens/qr_share_screen.dart` 的 `_init()`,在读 prefs 之后、`_generate()` 之前插入:

```dart
    // 第一次在这台设备上出码:先把「东西去哪了」说一句,他按了「好,出码」才继续。
    // **不看登录状态** —— 登录与否都照常出码(创始人拍板,取代「未登录不给出码」)。
    if (shouldShowQrNotice(seen: await loadQrNoticeSeen())) {
      if (!mounted) return;
      final go = await showQrNoticeSheet(context);
      if (!mounted) return;
      if (!go) {
        Navigator.of(context).pop(); // 「先不出」= 退出这一屏,什么都没传
        return;
      }
    }
```

补 import:`screens/qr_notice_sheet.dart`。**`_generate()` 一字不改** —— 出码逻辑本身
没有变化,变的只是它前面多了一次告知。

- [ ] **Step 4: 跑,确认绿**

Run: `cd <app> && flutter analyze && flutter test`
Expected: 整仓全绿。`qr_share_screen_test.dart` 里若有测试会走到 `_init()`,给它预置
`SharedPreferences.setMockInitialValues({'qr_notice_seen': true})`,免得每个用例都被
这张 sheet 挡住。

- [ ] **Step 5: 提交**

```bash
cd <repo>
git add apps/mobile_flutter/lib apps/mobile_flutter/test
git commit -m "feat(mobile): 第一次出码时告知一次,不再拿登录挡路

创始人拍板,取代原来的「未登录不给出码」:诊室里那 30 秒是这个产品的全部
价值,用一道登录墙挡住它代价比收益大;而「用户不知道发生了什么」一句话就够。

逐字文案与隐私政策第三节第 3 项(二维码中转)是同一件事,政策不用改。
偏好键 qr_notice_seen,跟设备走。"
```

---

### Task 12: 「我」tab —— 云端状态只剩一处,云的三个词收敛

**Files:**
- Modify: `<app>/lib/screens/settings_screen.dart:352`、`:356-370`、`:371-395`、`:379`
- Modify: `<app>/lib/widgets/backup_status_line.dart:22-46`
- Modify: `<app>/lib/screens/account_screen.dart:146`、`:599`、`:1947`、`:1205-1225`
- Modify: `<app>/lib/sync_engine.dart`、`<app>/lib/vault_boot.dart`、`<app>/lib/main.dart`、`<app>/lib/grants.dart`、`<app>/lib/account_flow.dart`、`<app>/lib/analytics.dart`(注释与 `StateError` 里的「云同步」)
- Modify: `<app>/test/glossary_guard_test.dart`(`kEnforced` 加 `云同步`、`云端识别`、`云备份`)
- Test: `<app>/test/backup_status_line_test.dart`

**Interfaces:**
- Consumes: `backupStatus({required bool loggedIn, required Profile profile, required LastSync? last, bool icloudOn, DateTime? now})` → `({String text, bool canRetry})`(签名不变)
- Produces: 无新符号

> ia-proposal §4:**一个词:云端。底下只有两件事 —— 云端备份 / 云端整理。**
> 状态只在一处(「我」tab 顶部一行)。删掉:概览备份状态行(概览已在 Task 9 删)、
> 账号屏横幅、设置行副标题、云同步分区标题。**四处说法 → 一处。**
>
> **先读 `s5`**(「我」)与 `s10`(某个成员自己的页面)。`s5` 自上而下:
>
> 1. 云端行:标题 `云端`、副标题 `已备份,刚刚`、末尾 `›`(**一行两段,不是一句话**)
> 2. `这台手机上的病历` 卡:每个成员一行 —— 头像 + **名字** + `N 份 ›`,
>    **只有名字和份数,没有任何角色词**;卡的最后一行是 `添加成员`
> 3. `口令与恢复码 ›`
> 4. `我的设备  2 台 ›`
> 5. `关于 / 隐私政策 ›`
>
> **「云端整理」开关不在「我」里**,它在**某个成员自己的页面**(`s10`:`云端备份 开 · 刚刚备份过` / `云端整理 开`)。

- [ ] **Step 1: 把三个词加进禁词闸 + 改状态行的测试(都先红)**

`test/glossary_guard_test.dart`:

```dart
const List<String> kEnforced = [
  '数据出口', '数据管理',
  '待确认', '点开核对并确认', '确认无误,归入档案',
  '识别文本', '文档内容', '识别质量',
  '云同步', '云端识别', '云备份',
];
```

`test/backup_status_line_test.dart` 里,把断言 `'云同步已关闭'` 的那条改成 mockup
的逐字格式,并追加两条:

```dart
    expect(
      backupStatus(loggedIn: true, profile: paused, last: null).text,
      '备份关着',
    );
```

```dart
  test('未登录那句不再替产品说「只在这台手机上」', () {
    final s = backupStatus(loggedIn: false, profile: p, last: null);
    expect(s.text, '没登录,换手机找不回来');
    expect(s.canRetry, isFalse);
  });

  test('成功那句逐字就是 s5 那一行的副标题', () {
    final now = DateTime(2026, 9, 16, 10, 12);
    final s = backupStatus(
      loggedIn: true,
      profile: cloudReady,
      last: LastSync(at: now, ok: true),
      now: now,
    );
    expect(s.text, '已备份,刚刚');
  });

  testWidgets('整行渲染成 s5 的样子:标题「云端」+ 副标题 + 一个 ›', (tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: MedMe.theme(), home: const Scaffold(body: BackupStatusLine())),
    );
    await tester.pumpAndSettle();
    expect(find.text('云端'), findsOneWidget);
    // `›` 是「这一行点得进去」的唯一提示,而「云端整理」就在里面那一层 ——
    // 漏掉它,下一层就没有入口了。
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    // 副标题里不许再出现「云端」两个字 —— 标题已经说过一次了。
    expect(find.textContaining('云端 ·'), findsNothing);
  });
```

- [ ] **Step 2: 跑,确认都红**

Run: `cd <app> && flutter test test/glossary_guard_test.dart test/backup_status_line_test.dart`
Expected: FAIL。「云同步」命中面比另外两个词宽得多,**Step 3 要全部清掉**,逐处记在这里免得漏:

- 用户可见:`backup_status_line.dart:29`、`account_screen.dart:146`、`:599`、`:1947`、`settings_screen.dart:379`
- `StateError` 文案(会经 `friendlyApiError` 冒到屏上,算用户可见):`grants.dart:90`、`:254`、`:270`、`sync_engine.dart:224`、`:262`、`:321`
- 纯注释:`account_flow.dart:565`、`vault_boot.dart:129`、`:131`、`:143`、`main.dart:98`、`:143`、`:225`、`:310`、`:476`、`sync_engine.dart:125`、`:130`、`:174`、`:182`、`:202`、`:909`、`analytics.dart:538`

「云端识别」命中 `settings_screen.dart:379`、`account_screen.dart:599`;「云备份」命中
`ephemeral_session.dart:15`、`proxy_patient_manager.dart:21`、`qr_share_screen.dart:55-58`、
`account_screen.dart:138,144,146`。状态行两条断言的文案也对不上。

- [ ] **Step 3: 改**

`lib/widgets/backup_status_line.dart:22-46`,`backupStatus` 从此**只返回副标题那半句**
(`s5`:标题恒为 `云端`,副标题随状态变,末尾一个 `›`)。签名不变:

```dart
  // `s5`:这一行是**两段** —— 标题恒为「云端」,这里返回的是副标题那半句
  // (`已备份,刚刚`),末尾的 `›` 由行本身画。早先写成一整句
  // 写成一整句(前缀 + 状态 + 箭头)是误读了 mockup,以 `s5` 为准。
  //
  // `›` 不是装饰 —— 它是「这一行点得进去」的唯一提示。
  String body;
  bool retry = false;
  if (!loggedIn) {
    body = '没登录,换手机找不回来';
  } else if (profile.cloudPaused) {
    body = '备份关着';
  } else if (icloudOn) {
    // 复审 I5:开着 iCloud 同步时云端备份压根开不了(见 `CloudEnableBlocked`),
    // 那时说「点这里重试」是一条点不动的提示 —— 说真正的原因。
    body = '这台手机开着 iCloud 备份,两套不能一起开';
  } else if (profile.cloudId == null) {
    body = '还没开始备份'; retry = true;
  } else if (last == null) {
    body = '还没备份过'; retry = true;
  } else if (!last.ok) {
    body = '上次没备份成功'; retry = true;
  } else {
    body = '已备份,${_ago(last.at, now ?? DateTime.now())}';
  }
  return (text: body, canRetry: retry);
```

`BackupStatusLine` 这个 widget 渲染成 `s5` 那一行:标题 `云端`、副标题
`backupStatus(...).text`、trailing `Icon(Icons.chevron_right)`,整行可点(点进
成员自己的页面 `s10`)。`_ago` 的 `'刚刚'` / `'N 分钟前'` / `'N 小时前'` /
`'M月D日'` 四档保持原样。类文档里「概览屏顶部那一行」改成「「我」tab 第一行」。

`lib/screens/settings_screen.dart:352`:

```dart
      appBar: AppBar(title: const Text('我')),
```

`:356-370` 的「模式」整个分区删除(代拍入口已在「给医生看」,Task 9)。

`:371` 的 `_SectionLabel('账号')` 改成 `_SectionLabel('云端')`,并在这个分区最前面插一行状态。
**这一行是可点的,点进去才是云端页**(mockup:「云端整理」在下一层,不在这一屏平铺):

```dart
          _SectionLabel('云端'),
          const _SettingsGroup(children: [BackupStatusLine()]),
```

把「云端整理」那个开关**从「我」的首屏移走**,放进**某个成员自己的页面**
(`s10`:`云端备份 开 · 刚刚备份过` / `云端整理 开` 两行并排;
`account_screen.dart:1205-1225` 那个开关搬过去)。「我」的首屏在云端行之后
按 `s5` 摆:`这台手机上的病历` 卡(每行 头像 + 名字 + `N 份 ›`,最后一行
`添加成员`)→ `口令与恢复码 ›` → `我的设备  N 台 ›` → `关于 / 隐私政策 ›`。
`s5` 里**没有**「示例数据」「使用情况」「iCloud 同步」这几节 —— 它们移到
`关于` 里面那一层,首屏不再平铺。

`:379` 的 subtitle:

```dart
                  subtitle: '换手机能找回、家人能看、云端帮你认字',
```

`lib/screens/account_screen.dart:146` —— **角色不再拼进这一行**(mockup:挑人的
界面上不说角色)。`roleLabel` 函数本身留着,给某个成员自己的页面用:

```dart
  // mockup:成员列表/切换器上只写名字。`roleLabel(p.role)` 从这里撤掉 ——
  // 授权级别在某个成员自己的页面里说,那里有上下文;摆在挑人的列表上,
  // 用户读到的是「家里谁是谁」,而那不是这个字段的意思。
  return '已开通云端备份';
```

`lib/screens/account_screen.dart:1947` —— **Step 2 预告了这一处,别漏**。这一行同时
带着「云同步」和「家属」两个词,本 Task 只负责前者,「家属」留给 Task 13:

```dart
      return const Text('当前成员还没开通云端备份,暂时不能添加家属', style: TextStyle(color: MedMe.faint));
```

同函数 `:1942-1943` 的文档注释里「这个成员必须已经开通云同步」改成「必须已经开通云端备份」。

`:599`:

```dart
      '换手机能找回病历、和家人一起看、云端帮你认字。不登录不影响这台手机上用。',
```

`:1205-1225` 的「云端整理」开关保留原样(词已正确),但它所在分区的标题若写着「云同步」,改成「云端」;账号屏顶部那条「你的病历会自动备份到云端」的一次性横幅删除 —— 状态只在「我」tab 顶部说一次(ia-proposal §4)。

**剩下的全量清扫。** Step 2 列出的 `StateError` 与注释命中逐处换词:`StateError('这个成员还没开通云同步')` → `StateError('这个成员还没开通云端备份')`(`grants.dart` 三处、`sync_engine.dart` 三处),注释里的「云同步」一律写成「云端备份」。**`sync_engine.dart` 的函数名 `enableCloud` / `runBackgroundSync` 一个都不改** —— 标识符不在闸内(见 Global Constraints)。

- [ ] **Step 4: 跑,确认绿**

Run: `cd <app> && flutter test test/glossary_guard_test.dart test/backup_status_line_test.dart test/account_screen_test.dart`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
cd <repo>
git add -u apps/mobile_flutter
git commit -m "feat(mobile): 云的四个词收成「云端备份/云端整理」,状态只剩「我」tab 一处

ia-proposal §4。删账号屏横幅、设置行副标题、云同步分区标题三处重复说法。
mockup s5:那一行是「云端」+「已备份,刚刚」+「›」两段一行,整行可点;
「我」首屏按 s5 收成 云端 / 这台手机上的病历(名字 + 份数 + 添加成员)/
口令与恢复码 / 我的设备 / 关于;「云端整理」挪进成员自己的页面(s10)。"
```

---

### Task 13: 「我」tab —— 保险箱 → 成员,家属/家人 → 成员,成员界面只写名字

**Files:**
- Modify: `<app>/lib/screens/settings_screen.dart:397`、`:466`
- Modify: `<app>/lib/screens/account_screen.dart:1039`、`:1947`、`:1956`、`:1964`、`:1982`、`:1501`、`:1507`
- Modify: `<app>/lib/widgets/member_switcher.dart`(文案 + 去掉角色标)
- Modify: `<app>/lib/widgets/identity_hero_card.dart`(同上)
- Test: `<app>/test/member_no_role_words_test.dart`(新建)
- Modify: `<app>/test/glossary_guard_test.dart`(`kEnforced` 加 `保险箱`、`家属`)
- Test: `<app>/test/glossary_guard_test.dart`、`<app>/test/member_switcher_shared_state_test.dart`

**Interfaces:**
- Consumes: `ProfileManager.instance`、`_VaultCard`(改名 `_MembersCard`)、`roleLabel(String role)`(**保留函数,只收窄调用点**)
- Produces: 无新符号

> ia-proposal §3 第 3、4 簇:「保险箱」里放的是**人**,那是成员;「家属/家人」在
> 授权语境里会和「成员」打架(ux-audit 屏28、屏46/75:三套「加家人」互不相干)。
> **本阶段只统一词,三条路合成一个 sheet 是 Stage 2**(ia-proposal §6)。
>
> **mockup 追加一条,比词表更严**:**挑人的界面上不出现任何亲属/角色词**。
> `s5` 的名单、`s1` 的 hero 卡、切换器**只显示名字(+ 份数)**。
>
> 角色**只在某个成员自己的页面里**说,而且 `s10` 已经给了逐字的样子:
> 分区标题 `谁能看张建国的病历`,行上是 `王淑芬 / 能改 · 撤销`、
> `陈医生 / 只能看 · 剩 9 天 · 撤销`,下面是 `加一个人 / 手机号或扫码`、
> `改名字 ›`、`把这份病历交给别人 ›`、`删除这个成员 ›`。
>
> 理由:在切换入口上说关系,等于把家里谁是谁摆在每一屏最上面 —— 那既不是用户
> 要的信息,也是最容易说错的(一份档案的 role 是服务端给的授权级别,不是亲属
> 关系,两者被并在一起显示过,见 ux-audit §3 第 3 簇)。

- [ ] **Step 1: 写这个失败的测试 + 把两个词加进禁词闸**

`<app>/test/member_no_role_words_test.dart`:

```dart
// mockup:成员相关的界面上**不出现亲属/角色词**,只写名字。
//
// 钉的是产品定的语义,不是某一版措辞:切换器、身份卡这类「挑人」的界面上,
// 任何身份词都不许出现。角色只在某一个成员自己的页面里说 —— 那里有上下文,
// 这里没有。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/widgets/identity_hero_card.dart';

const kRoleWords = [
  '家人', '家属', '本人', '主人', '只读', '能改', '可编辑',
  'owner', 'editor', 'viewer',
];

Widget wrap(Widget child) => MaterialApp(
  theme: MedMe.theme(),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets('身份卡只写名字、性别年龄、份数 —— 没有角色', (tester) async {
    await tester.pumpWidget(
      wrap(const IdentityHeroCard(
        name: '张建国',
        gender: '男',
        age: '68岁',
        recordCount: 12,
      )),
    );
    expect(find.textContaining('张建国'), findsOneWidget);
    for (final w in kRoleWords) {
      expect(find.textContaining(w), findsNothing, reason: '身份卡不说「$w」');
    }
  });
}
```

同时把这两个词加进禁词闸:

```dart
const List<String> kEnforced = [
  '数据出口', '数据管理',
  '待确认', '点开核对并确认', '确认无误,归入档案',
  '识别文本', '文档内容', '识别质量',
  '云同步', '云端识别', '云备份',
  '保险箱', '家属',
];
```

- [ ] **Step 2: 跑,确认它红**

Run: `cd <app> && flutter test test/glossary_guard_test.dart`
Expected: FAIL —— 「保险箱」命中 `vault_events.dart:3,11`、`claim_link.dart:10,60`、`import_flow.dart:215,644,647`、`grants.dart:236`、`vault_boot.dart` 多处、`cloud_extract.dart:216,329`、`claim_storage.dart:16`、`ephemeral_session.dart:9`、`settings_screen.dart:397,466`;「家属」命中 `grant_link.dart:3`、`grants.dart:61,79,150,248,249`、`main.dart:78,720`、`sync_engine.dart:909`、`account_screen.dart` 多处。

- [ ] **Step 3: 改**

用户可见的:

`lib/screens/settings_screen.dart:397`:

```dart
          _SectionLabel('成员'),
```

`:466`:

```dart
                title: '删掉全部',
```

`lib/screens/account_screen.dart:1039`:

```dart
    const Text('成员', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
```

`:1947`:

```dart
      return const Text('这个成员还没开通云端备份,暂时加不了人', style: TextStyle(color: MedMe.faint));
```

`:1956` labelText → `'成员手机号'`;`:1964` 按钮 → `'按手机号加成员'`;`:1982` snackbar → `'已加上'`;`:1501` → `'注销后:账号里的云端病历、成员与医生的授权全部永久删除,他们会立刻'`;`:1507` → `'请到「删掉全部」里单独操作。建议先导出一份留档,再继续注销。'`。

不可见的(注释与内部说法):`保险箱` 一律改成 `病历箱`,`家属` 一律改成 `家人成员`。这两个词只出现在注释与 `StateError` 文案里,不进界面。

**挑人的界面去角色词**(`s1`/`s5`):`lib/widgets/member_switcher.dart` 与
`lib/widgets/identity_hero_card.dart` 里凡是渲染 `roleLabel(...)` 或
「本人 / 家人(能改)/ 医生(只能看)」的地方一律删掉,只留名字(+ 身份卡原有的
性别年龄与份数)。

**`roleLabel` 不删,只换词并挪到成员自己的页面**(`s10`):`editor` → `能改`、
`viewer` → `只能看`、`owner` 那一行不显示角色(那就是你自己)。viewer 带到期的
再接一句 `剩 N 天`,后面跟 `撤销`。分区标题写成 `谁能看<名字>的病历`。

> ⚠️ `lib/import_flow.dart:647` 的 `'保险箱没打开,这次没能导入'` 是**用户可见**的
> snackbar,改成 `'病历还没打开,这次没能添加'`。

- [ ] **Step 4: 跑,确认绿**

Run: `cd <app> && flutter analyze && flutter test`
Expected: 整仓全绿。`member_switcher_*_test.dart` / `identity_hero_card_test.dart` 里若有
断言角色标存在,改成断言它**不**存在。

- [ ] **Step 5: 提交**

```bash
cd <repo>
git add -u apps/mobile_flutter
git commit -m "feat(mobile): 保险箱→成员/病历箱,家属→成员;挑人的界面只写名字

ia-proposal §3 第 3、4 簇。三套「加家人」合成一个 sheet 是 Stage 2,
本阶段只统一词。

mockup s1/s5:hero 卡、切换器、「我」里那份名单上不出现任何亲属/角色词,
只有名字和份数。角色按 s10 只在成员自己的页面里说(能改 / 只能看 · 剩 N 天 ·
撤销)。roleLabel 函数保留,换词 + 调用点收窄。"
```

---

### Task 14: 口令 + 恢复码 —— 密码 / 密钥 / 生成密钥 全部收敛

**Files:**
- Modify: `<app>/lib/screens/account_screen.dart:159`、`:670`、`:787`、`:790`
- Modify: `<app>/lib/vault_boot.dart:129-140`
- Modify: `<app>/test/glossary_guard_test.dart`(`kEnforced` 加 `密码`、`密钥`、`生成密钥`)
- Test: `<app>/test/glossary_guard_test.dart`、`<app>/test/vault_bootstrap_error_text_test.dart`

**Interfaces:**
- Consumes: 无
- Produces: 无新符号

> **先读 `s12`**(设口令)与 `s15`(拿回病历)。`s12` 逐字:标题 `设一个口令`、
> 副标题 `换手机时用它解开云端那份;我们没有这把钥匙`、输入框 `口令,至少 6 位`、
> 恢复码一节 `恢复码,口令忘了用它` + 分组码 + `抄在纸上或存到别处。两个都丢了,
> 云端那份谁也打不开。`、两颗按钮 `发给自己` 与 `我抄好了`。
> `s15`:标题 `拿回你的病历`,三条路 `用旧手机扫码批准,最简单` / `输口令` /
> `用恢复码`,底下一行 `口令和恢复码都丢了?`。
>
> ia-proposal §3 第 9 簇:两个物件(口令 / 恢复码)不能并成一个词,但可以砍掉另外两个。
> **不用「密码」**:老人会默认「密码能找回」,而我们不保管钥匙 —— 这是最贵的误解。
> 同时修 ux-audit §4 第 9、10、11 条(三句假话)。

- [ ] **Step 1: 把三个词加进禁词闸(测试先红)**

```dart
const List<String> kEnforced = [
  '数据出口', '数据管理',
  '待确认', '点开核对并确认', '确认无误,归入档案',
  '识别文本', '文档内容', '识别质量',
  '云同步', '云端识别', '云备份',
  '保险箱', '家属',
  '密码', '密钥', '生成密钥',
];
```

- [ ] **Step 2: 跑,确认它红**

Run: `cd <app> && flutter test test/glossary_guard_test.dart`
Expected: FAIL —— 命中 `account_screen.dart:159,670,790`、`account_flow.dart:35,492,530`、`vault_boot.dart:129-131`、`sync_engine.dart:202,262`、`grants.dart:248` 等。

- [ ] **Step 3: 改**

`lib/screens/account_screen.dart:159`:

```dart
const _kdfWaitHint = '正在设置,老一点的手机可能要等几秒,请不要退出';
```

`:670` —— `s12` 那颗按钮逐字是「我抄好了」(它在恢复码那一步,用户要做的是抄下来):

```dart
      label: '我抄好了',
```

同屏标题按 `s12` 写成 `设一个口令`,副标题 `换手机时用它解开云端那份;我们没有这把钥匙`,
输入框 placeholder `口令,至少 6 位`;恢复码一节标题 `恢复码,口令忘了用它`,
说明 `抄在纸上或存到别处。两个都丢了,云端那份谁也打不开。`,旁边多一颗 `发给自己`。

`:787`(分区标题跟着输入框走,修 ux-audit §4 第 11 条 —— 切到恢复码后标题不变)。
`s15` 把这一屏叫「拿回你的病历」,两条路分别是「输口令」与「用恢复码」:

```dart
      _usingRecoveryCode ? '用恢复码' : '输口令',
```

这一屏的标题按 `s15` 改成 `拿回你的病历`,副标题 `已登录;云端有你的病历,选一种方式解开`;
扫码那条写 `用旧手机扫码批准,最简单` + 小字 `旧手机打开 MedMe → 我 → 我的设备 → 扫码`;
底部那条兜底链接写 `口令和恢复码都丢了?`。

`:790`(修 ux-audit §4 第 9 条,那句在「本机注册 → 退出 → 重新登录」这条最常见的路上是假话):

```dart
        '打开你的病历需要口令。忘了口令就用恢复码。',
```

`lib/vault_boot.dart:138`(修 ux-audit §4 第 10 条 —— 锁住的是本机那一箱,说成「在云端」会让人以为断网就完了):

```dart
  '你的病历是加密的,需要你的口令才能打开。断网也打得开。',
```

其余命中处全部是注释与内部标识(`账号密钥对`、`档案密钥`),改成「账号口令对」「档案钥匙」。**不改任何 Rust 侧 API 名**(`vault_open_keyed` 之类),只改中文注释。

- [ ] **Step 4: 跑,确认绿**

Run: `cd <app> && flutter test test/glossary_guard_test.dart test/vault_bootstrap_error_text_test.dart test/account_screen_test.dart`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
cd <repo>
git add -u apps/mobile_flutter
git commit -m "feat(mobile): 密码/密钥/生成密钥 全收成 口令 + 恢复码

顺带修 ux-audit §4 第 9、10、11 条三句假话:「这台设备之前没解锁过」、
「你的病历在云端是加密的」、切到恢复码后标题不跟着变。"
```

---

### Task 15: 代拍 —— 医生模式 / 为病人代建档 全收成「代拍」,交付话术统一成「取件码」

**Files:**
- Modify: `<app>/lib/screens/doctor/doctor_home_screen.dart:205`、`:264`、`:52-60`、`:336`
- Modify: `<app>/lib/screens/doctor/consent_screen.dart:157`
- Modify: `<app>/lib/screens/doctor/proxy_intake_flow.dart:260`、`:1109`
- Modify: `<app>/lib/screens/doctor/doctor_share_result_dialog.dart`
- Modify: `<app>/lib/screens/doctor/doctor_claim_link_dialog.dart`(删死分支)
- Modify: `<app>/lib/screens/account_screen.dart:1860`(指向那个分支的注释)
- Delete: `<app>/test/doctor_claim_link_dialog_test.dart`
- Modify: `<app>/test/glossary_guard_test.dart`(`kEnforced` 加 `医生模式`、`为病人代建档`、`为病人代拍`、`替病人拍`、`今日病历表`、`认领码`)
- Test: `<app>/test/glossary_guard_test.dart`、`<app>/test/doctor_consent_visual_test.dart`

**Interfaces:**
- Consumes: 无
- Produces: 无新符号

> **先读 `s14`**(替病人代拍)。逐字:标题 `替病人代拍`、副标题
> `病人不用装 App、不用账号`、三步 `1 同意 › 2 拍 › 3 交给病人`、
> `病人扫这个码,病历就进他的手机` + `取件码 4829`、
> `拍了 3 份 / 12 小时后自动清掉`、`没网时 / 发加密文件 + 口令`。
> —— 「取件码」在 mockup 里已经兑现,且**成功与没网两条路都给取件码**,
> 正是 ia-proposal §5 要的那个统一。
>
> ia-proposal §5:交付话术统一成「取件码」。今天同意书说「当场给您一个码,您用手机
> 拍下来带走」,实际交付是**加密文件 + 44 位口令**(ux-audit 屏63 vs 屏69)——
> **病人签的字和发生的事对不上**,和 P5 同级。本阶段只换入口与词,不重做流程。

- [ ] **Step 1: 把四个词加进禁词闸(测试先红)**

```dart
const List<String> kEnforced = [
  '数据出口', '数据管理',
  '待确认', '点开核对并确认', '确认无误,归入档案',
  '识别文本', '文档内容', '识别质量',
  '云同步', '云端识别', '云备份',
  '保险箱', '家属',
  '密码', '密钥', '生成密钥',
  '医生模式', '为病人代建档', '今日病历表', '认领码',
  // 代拍入口的说法今天有三种:doctor_home 的主按钮「为病人代拍」、词表里的
  // 「代拍」、以及 Task 3 新写的那条入口。**全 App 收成一句**:
  //   「我是医生,替病人代拍」
  // 「替病人拍」也关进来 —— 少一个「代」字就又是一种说法。
  '为病人代拍', '替病人拍',
];
```

> ⚠️ `替病人拍` 是 `我是医生,替病人代拍` 的**真子串**吗?不是 —— 那一句里是
> 「替病人**代**拍」。闸扫的是子串,所以这两个词可以同时存在而不自相矛盾;
> 写成「我是医生,替病人拍」就会被自己的闸拦下,这正是要的效果。

- [ ] **Step 2: 跑,确认它红**

Run: `cd <app> && flutter test test/glossary_guard_test.dart`
Expected: FAIL —— 命中 `doctor_home_screen.dart:52,57,205,264,336`、`consent_screen.dart`、`proxy_intake_flow.dart:1109`、`grants.dart:49,53`、`design_tokens.dart:17,81,88,91`、`theme.dart:31,33,41`、`settings_screen.dart`(若 Task 12 已删「模式」分区则无),以及 **Task 3 写的 `for_doctor_screen.dart` 那条入口文案 —— 它此刻是「我是医生,替病人代拍」,不该命中;命中就说明 Task 3 写成了别的说法,回去改**。

- [ ] **Step 3: 改**

`lib/screens/doctor/doctor_home_screen.dart:205` —— `s14` 这一屏的标题逐字是
「替病人代拍」,副标题「病人不用装 App、不用账号」:

```dart
        title: const Text('替病人代拍'),
```

同文件的「为病人代建档」标题与横幅 → `'代拍'`;「今日病历表」→ `'今天代拍的'`。

`lib/screens/doctor/doctor_home_screen.dart:264` —— 一屏唯一的主按钮,**与
`ForDoctorActions` 那条入口用同一句**(Task 3 已经写成这句):

```dart
                      label: const Text('我是医生,替病人代拍'),
```

`lib/screens/doctor/consent_screen.dart:157`(同意书,**这条是签过字的不实陈述**):

```dart
          '拍完当场给您一个取件码。凭它在自己手机上把这份病历取走,'
          '只交给您本人,不会自动发给别人。',
```

`lib/screens/doctor/proxy_intake_flow.dart:1109`:

```dart
                  child: const Text('生成取件码,交给病人'),
```

`:260` 的「拍摄病历材料」→ `'添加'`(与个人模式同一张三选一表的标题一致,ux-audit 屏04/66)。

`lib/screens/doctor/doctor_share_result_dialog.dart` 里,成功路径与 OSS 失败路径的产物
统一叫「取件码」(`s14`):成功 = `病人扫这个码,病历就进他的手机` + `取件码 NNNN`;
没网 = `发加密文件 + 口令`,同样给一个取件码。列表上那行按 `s14` 写
`拍了 N 份` + `12 小时后自动清掉`。

其余命中处是注释与颜色令牌文档,「医生模式」一律改成「代拍」。

- [ ] **Step 4: 删掉那条死的 `cloudProfile` 转移分支**

`lib/screens/doctor/doctor_claim_link_dialog.dart` 的 `resolveDoctorClaimUrl` 是一条
**全仓无人走的路**:唯一调用方 `proxy_intake_flow.dart:620` 从来不传 `cloudProfile`,
那个可选参数恒为 null,于是 `:21` 一进去就 `return fallbackUrl`。它自己的文档也写着
「调用方目前还没有任何一条路径会把已开通云同步的代拍档案传进来」。

先确认它真的是死的,再动手:

```bash
cd <app>
grep -rn "cloudProfile\|resolveDoctorClaimUrl" lib | grep -v 'lib/src/rust/'
```

Expected: 除了 `doctor_claim_link_dialog.dart` 自己和 `account_screen.dart:1860` 那条
注释,**没有别的命中**。有的话停下来报告 —— 那说明它不是死的。

然后把 `resolveDoctorClaimUrl` 整个函数、`showDoctorClaimLinkDialog` 的 `cloudProfile`
与 `grants` 两个参数、以及类文档里讲那条分支的三段说明全部删掉,函数体直接用 `url`:

```dart
/// 代拍交付成功后的结果:**一条取件链接,直接显示成二维码**。
///
/// 为什么是二维码而不是「发文件」:代拍面对的病人常常没有微信、加不上好友、也不会
/// 收文件。屏幕上摆一张码,他自己或家属**用任何相机拍一下**就带走了 —— 不需要建立
/// 任何传输通道。旁边再给一条可复制的链接,方便能用微信/短信的人。
///
/// 与「病人自己出码给医生看」(`qr_share_screen.dart`)方向相反:那是给医生**当场看**,
/// 这是给病人**带走**。所以这里必须给可复制的链接,那边不需要。
///
/// **代拍永远只出取件码这一条路。** 这里曾经有一条 `cloudProfile` 分支,想在医生
/// 已登录、且代拍档案已开通云端备份时改发 `role=owner` 的转移邀请 —— 但「把代拍
/// 病人的临时病历箱注册成云档案」那一步从来没接线,所以没有任何调用方会传那个
/// 参数,分支一次都没跑过。删掉:没跑过的分支不是前向兼容,是一份读者每次都要
/// 重新判断「这条到底走不走」的负担。
Future<void> showDoctorClaimLinkDialog(
  BuildContext context,
  String url,
  int recordCount, {
  required Rect Function() shareOrigin,
}) async {
  if (!context.mounted) return;
  // 展示本身(码 + 复制 + 分享)共用 `showLinkQrDialog` —— 「转为主人」那条路
  // (`account_screen.dart` 的 B5)要的是同一套东西,不该重写一遍。
  await showLinkQrDialog(
    context,
    title: '好了,请病人扫这个码',
    url: url,
    body: '共 $recordCount 份记录。请病人本人(或家属)用手机相机拍下这个码,带走后随时能看。',
    footnote: '只有拿到这个码的人能打开,医生和我们都看不到里面的内容。15 天后自动失效。',
    shareSubject: '你的病历',
    shareLabel: '发给病人',
    copiedMessage: '链接已复制,可以发给病人',
    shareOrigin: shareOrigin,
    accent: MedColors.of(context).proxy,
  );
}
```

`account.dart` / `api_client.dart` / `grants.dart` / `profile_manager.dart` 四个 import
随之不再需要,删掉;`lib/screens/account_screen.dart:1860` 那条指向这条分支的注释一并删。

`test/doctor_claim_link_dialog_test.dart` 的四条用例(`:64`、`:75`、`:86`、`:97`)
全是 `resolveDoctorClaimUrl` 的,随那个函数一起删:

```bash
cd <app>
git rm test/doctor_claim_link_dialog_test.dart
```

- [ ] **Step 5: 跑,确认绿**

Run:

```bash
cd <app>
flutter analyze
flutter test
# 代拍入口全 App 只有一句话
grep -rn "我是医生,替病人代拍" lib
# 那条死分支彻底没了
grep -rn "resolveDoctorClaimUrl\|cloudProfile" lib | grep -v 'lib/src/rust/'
```

Expected: analyze + test 全绿;「我是医生,替病人代拍」那条 grep **恰好两处**
(`for_doctor_screen.dart` 的入口、`doctor_home_screen.dart:264` 的主按钮)一字不差;
最后那条 grep **无输出**。

- [ ] **Step 6: 提交**

```bash
cd <repo>
git add -u apps/mobile_flutter
git commit -m "feat(mobile): 代拍入口全 App 一句话,交付话术统一成「取件码」

「医生模式 / 为病人代建档 / 为病人代拍 / 替病人拍」四种说法收成两处同一句:
「我是医生,替病人代拍」。

ia-proposal §5。同意书那句「拍下来带走」与实际交付(加密文件 + 44 位口令)
对不上,是签过字的不实陈述,与 P5 同级。

顺手删掉 doctor_claim_link_dialog.dart 里那条**全仓无人调用**的 cloudProfile
转移分支(resolveDoctorClaimUrl)与它的四条测试:唯一调用方从不传那个参数,
分支一次都没跑过。代拍从此永远只出取件码这一条路。"
```

---

### Task 16: 「云端整理」第一次导入时问一次

**Files:**
- Create: `<app>/lib/screens/cloud_extract_ask_sheet.dart`
- Create: `<app>/test/cloud_extract_ask_test.dart`
- Modify: `<app>/lib/account.dart:29`(旁边加一个「问过没有」的键)
- Modify: `<app>/lib/import_flow.dart`(`runImport` 里接上)

**Interfaces:**
- Consumes: `cloudExtractEnabledKey`(`'cloud_extract_enabled'`,`lib/account.dart:29`)、`saveCloudExtractEnabled(bool)`
- Produces:
  - `const cloudExtractAskedKey = 'cloud_extract_asked'`(`lib/account.dart`)
  - `bool shouldAskCloudExtract({required bool loggedIn, required bool asked})`
  - `Future<void> showCloudExtractAskSheet(BuildContext context)`

> ia-proposal §7 决定 5,**创始人已拍板:问一次**。默认开省一次点击,但 App Store 描述、
> `Info.plist`、隐私政策三处都要写「照片会送云端」;有一次明确同意,这三处才站得住。
> **默认值不预设** —— 两颗按钮视觉权重相同,没有预选。
>
> **文案逐字照 `s17`**(比早先那版短,说清了涂黑哪几样、不开会怎样、以后在哪改)。

- [ ] **Step 1: 写这个失败的测试**

`<app>/test/cloud_extract_ask_test.dart`:

```dart
// 「云端整理」第一次添加病历时问一次(ia-proposal §7 决定 5)。
//
// 这一屏是隐私政策、Info.plist、App Store 描述三处「照片会送云端」站得住的
// 唯一依据 —— 所以它被钉住的是:只问一次、不预设默认、两条路都记得住。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/screens/cloud_extract_ask_sheet.dart';
import 'package:mobile_flutter/theme.dart';

void main() {
  group('问不问', () {
    test('没登录不问 —— 没有账号就没有云端,问了也没意义', () {
      expect(shouldAskCloudExtract(loggedIn: false, asked: false), isFalse);
    });
    test('登录了、没问过 → 问', () {
      expect(shouldAskCloudExtract(loggedIn: true, asked: false), isTrue);
    });
    test('问过就不再问 —— 一次性,不是每次导入都弹', () {
      expect(shouldAskCloudExtract(loggedIn: true, asked: true), isFalse);
    });
  });

  group('sheet 本体', () {
    testWidgets('两颗按钮权重相同,没有预选;说清楚送出去的是什么', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: MedMe.theme(), home: const Scaffold(body: CloudExtractAskBody())),
      );
      expect(find.text('开,帮我整理'), findsOneWidget);
      expect(find.text('不开'), findsOneWidget);
      // 默认值不预设:两颗都不是 FilledButton 独占主按钮位。
      expect(find.byType(FilledButton), findsNWidgets(2));
      // 必须说出:先在本机涂掉身份信息,再送出去。
      expect(find.textContaining('涂黑'), findsOneWidget);
      expect(find.textContaining('「我 → 云端」随时改'), findsOneWidget);
    });

    testWidgets('2× 字号不溢出', (tester) async {
      tester.view.physicalSize = const Size(360 * 3, 640 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: MedMe.theme(),
          home: const MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2.0)),
            child: Scaffold(body: SingleChildScrollView(child: CloudExtractAskBody())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
```

- [ ] **Step 2: 跑,确认它红**

Run: `cd <app> && flutter test test/cloud_extract_ask_test.dart`
Expected: FAIL,`Target of URI doesn't exist: 'package:mobile_flutter/screens/cloud_extract_ask_sheet.dart'`。

- [ ] **Step 3: 实现**

`lib/account.dart:29` 旁边加:

```dart
/// 「云端整理」问过没有(一次性)。**与 [cloudExtractEnabledKey] 是两件事**:
/// 那个记的是开关值,这个记的是「用户已经做过一次选择」。没有这个键的话,
/// 关掉的人每次导入都会被再问一次。
const cloudExtractAskedKey = 'cloud_extract_asked';
```

新建 `lib/screens/cloud_extract_ask_sheet.dart`:

```dart
// 第一次添加病历时问一次「云端整理」(ia-proposal §7 决定 5,创始人拍板)。
//
// 为什么不是默认开:默认开省一次点击,但 App Store 描述、`Info.plist`、隐私政策
// 三处都要写「照片会送云端」—— 有一次明确同意,这三处才站得住(CLAUDE.md 硬规矩 4)。
//
// 为什么在第一次添加时问、不在登录时问:登录那一刻用户脑子里是「我要备份」,
// 云端整理跟备份不是一件事;而第一次添加病历时,他刚刚交出去的就是那张照片。
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/cloud_extract.dart';

/// 这次该不该问。纯判断,方便单测。
///
/// 没登录不问:没有账号就没有云端,云端整理根本跑不起来(见 `cloud_extract.dart`
/// 的 `runCloudExtraction`,未登录一律静默退回本地正则)。
bool shouldAskCloudExtract({required bool loggedIn, required bool asked}) =>
    loggedIn && !asked;

Future<bool> loadCloudExtractAsked() async {
  try {
    return (await SharedPreferences.getInstance()).getBool(cloudExtractAskedKey) ?? false;
  } catch (_) {
    // 读不到就当问过 —— 宁可少问一次,也不要每次导入都弹。
    return true;
  }
}

/// 问一次,把答案和「问过了」一起写下去。用户下滑关掉 sheet 也算答过
/// (`barrierDismissible` 为 false,只有两颗按钮能退出,不会出现这种情况;
/// 但系统返回手势仍可能触发,那时按「不开」记 —— 没明确同意就不送)。
Future<void> showCloudExtractAskSheet(BuildContext context) async {
  final on = await showModalBottomSheet<bool>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    isScrollControlled: true,
    builder: (_) => const SafeArea(child: CloudExtractAskBody()),
  );
  await saveCloudExtractEnabled(on ?? false);
  try {
    await (await SharedPreferences.getInstance()).setBool(cloudExtractAskedKey, true);
  } catch (_) {}
}

/// sheet 的内容主体。**纯 widget,不碰 prefs** —— 这样 `flutter test` 测得到。
/// 两颗按钮都用 `FilledButton`:**默认值不预设**,不给任何一边额外的视觉权重。
class CloudExtractAskBody extends StatelessWidget {
  const CloudExtractAskBody({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            // 下面这三段逐字照 mockup `s17`,改字 = 改对外说法,要同步隐私政策。
            '要不要让云端帮你整理?',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          const Text(
            '开了以后,每次添加的单子会先在手机上把名字、证件号、医院名涂黑,'
            '再送到云端整理成表格。不开就只用手机自己识别,能认出来的字段少一点。'
            '以后在「我 → 云端」随时改。',
            style: TextStyle(height: 1.6),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('不开'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('开,帮我整理'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
```

`lib/import_flow.dart` 的 `runImport`,在 `items.isEmpty` 那道闸之后、`_runImport` 之前插入:

```dart
  // 第一次添加病历时问一次「云端整理」(ia-proposal §7 决定 5)。放在这里、
  // 而不是拉起相机之前:问的是「刚刚这张照片要不要送云端」,手上有东西的时候
  // 这句话才成立。
  if (shouldAskCloudExtract(
    loggedIn: AccountSession.instance.loggedIn.value,
    asked: await loadCloudExtractAsked(),
  )) {
    if (!context.mounted) return null;
    await showCloudExtractAskSheet(context);
  }
  if (!context.mounted) return null;
```

补 import:`account.dart`、`screens/cloud_extract_ask_sheet.dart`。

- [ ] **Step 4: 跑,确认绿**

Run: `cd <app> && flutter test test/cloud_extract_ask_test.dart test/cloud_extract_test.dart test/import_queue_test.dart`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
cd <repo>
git add apps/mobile_flutter/lib apps/mobile_flutter/test
git commit -m "feat(mobile): 云端整理改成第一次添加病历时问一次

ia-proposal §7 决定 5。偏好键沿用 cloud_extract_enabled,另加
cloud_extract_asked 记「问过了」。两颗按钮权重相同,不预设默认。"
```

---

### Task 17: 禁词闸合拢 —— 把审计那条 grep 的全集加进来

**Files:**
- Modify: `<app>/test/glossary_guard_test.dart`(`kEnforced` 补齐)
- Modify: `<app>/test/visit_summary_sheet_test.dart`(`:325`、`:363`、`:389` 还在 `new VisitSummarySheet(...)`,**删了本体这个文件就编译不过**)
- Modify: `<app>/lib/**`(残留处)

**Interfaces:**
- Consumes: `kEnforced`(前 16 个 Task 逐步累加的结果)
- Produces: `kEnforced` == ux-audit §6 Stage 1 Done 判据②那条 grep 的全集

> ia-proposal §6 Stage 1 Done 判据②的原文 grep:
> `存档\|归档\|采集\|云同步\|云端识别\|保险箱\|家属\|待确认\|识别文本\|文档内容\|医生模式\|生成密钥\|数据出口`
> —— 前面的 Task 已经清掉其中 9 个,这一步补上 `存档`、`归档`、`采集` 三个,
> 外加词表里还没启用的 `看病带这个`、`就诊单`、`分享`、`转让`、`授权`。

- [ ] **Step 1: 把剩下的词加进 kEnforced(测试先红)**

```dart
const List<String> kEnforced = [
  '数据出口', '数据管理',
  '待确认', '点开核对并确认', '确认无误,归入档案',
  '识别文本', '文档内容', '识别质量',
  '云同步', '云端识别', '云备份',
  '保险箱', '家属',
  '密码', '密钥', '生成密钥',
  '医生模式', '为病人代建档', '今日病历表', '认领码',
  // 合拢:ia-proposal §6 Done 判据②那条 grep 的其余部分
  '存档', '归档', '采集',
  // 词表里剩下的对外用词
  '看病带这个', '就诊单', '转让',
];
```

> `导入` / `分享` / `授权` **不进这个列表**:它们同时是 Dart 标识符语义(`ImportChoice`、
> `share_plus`、`Grants`)的中文注释里绕不开的普通词,而且在用户可见字符串里已经清干净。
> 硬把它们列进去会逼出一堆无意义的改写。这是本阶段唯一一处对判据②的收窄,**写进
> 提交信息里**,交给评审判断。

- [ ] **Step 2: 跑,确认它红**

Run: `cd <app> && flutter test test/glossary_guard_test.dart`
Expected: FAIL —— 「存档」命中 `import_flow.dart:170`、`account_screen.dart:1507`;「归档」命中 `archive_screen.dart:1019`、`document_detail.dart:144`、`identity_hero_card.dart:73`;「采集」命中 `import_flow.dart` 十余处 + `vault_boot.dart:19,213` + `ephemeral_session.dart:31,44` + `ocr_bridge.dart:55`;「看病带这个」命中 `vault_events.dart:23`、`main.dart:600,606,609`、`doc_labels.dart:8`、`analytics.dart` 多处、`visit_summary_sheet.dart:15,259,310`、`settings_screen.dart:405`。

- [ ] **Step 3: 清残留**

逐处按 `kGlossary` 换词。三条注意:

1. `lib/screens/visit_summary_sheet.dart:310` 的 `Text('看病带这个', ...)` 是**用户可见标题**,而这个 sheet 已经不再被任何入口唤起(Task 9 把它的内容升格成了 tab)。**把 `VisitSummarySheet` 与 `showVisitSummarySheet` 整个删掉**,只保留 `VisitSummaryBody` 及其下面的私有 widget —— 那才是「给医生看」tab 在用的东西。

   **但 `AnalyticsEvent.visitSheetOpened` 与 `VisitSheetEntry` 的定义留着**(协调人裁定):PostHog 里已有这两个事件的历史数据,枚举删了就对不上账。加 `@Deprecated` 标注、**不再有任何发射点**:

   ```dart
   // lib/analytics.dart —— 枚举成员上
   /// 「给医生看」还是浮层时,记的是它从哪一屏被唤起的。
   @Deprecated('Stage 1: 浮层已删,保留枚举以对上 PostHog 历史')
   visitSheetOpened('visit_sheet_opened', {'where'}),
   ```

   ```dart
   /// 浮层时代的两个入口(概览 / 档案)。两处都已不存在。
   @Deprecated('Stage 1: 浮层已删,保留枚举以对上 PostHog 历史')
   enum VisitSheetEntry { overview, archive }
   ```

   `analytics_catalog_test.dart` 里这两条的断言**保留**(目录仍然认这两个键);若 `flutter analyze` 因为 `@Deprecated` 在本文件内被自身引用而报 info,在 `analytics.dart` 顶部加一行 `// ignore_for_file: deprecated_member_use_from_same_package`。**全仓不许再有新的发射点** —— 用 `grep -rn "visitSheetOpened\|VisitSheetEntry" lib` 确认只剩定义处。

1b. **`test/visit_summary_sheet_test.dart` 必须同批改,否则删了本体它就编译不过**(`:325`、`:363`、`:389` 三处 `VisitSummarySheet(load: ..., onRequestAddNote: ...)`)。

   那组测试钉的是 BUG-4:**存完笔记要当场重新拉一次数据**,用户刚写的东西得立刻出现。这条覆盖不能丢 —— 它现在的归宿是 `ForDoctorScreen`,那两个注入点的签名在 Task 3 就是照着 `VisitSummarySheet` 定的,**构造器名一换即可**:

   ```dart
   // 三处都从
   //   body: VisitSummarySheet(load: ..., onRequestAddNote: ...)
   // 换成
              body: ForDoctorScreen(
                load: () async {
                  loads++;
                  return summary;
                },
                onRequestAddNote: (_) async {
                  summary = summaryWithNote('降压药是不是要减量');
                  return true;
                },
              ),
   ```

   文件顶部 import 从 `screens/visit_summary_sheet.dart` 换成 `screens/for_doctor_screen.dart`(`VisitSummaryBody` 仍在前者,若该文件还用到它就两个都 import),文件也一并改名:

   ```bash
   cd <app>
   git mv test/visit_summary_sheet_test.dart test/for_doctor_refresh_test.dart
   ```

   其余断言(「加一条」按钮在、放弃不白拉一次、刷新路径无未捕获异常)**一字不改** —— `ForDoctorScreen` 渲染的就是同一个 `VisitSummaryBody`。

1c. **「趋势」那一侧同样要刷新。** 它的化验快照来自同一份 `viewVisitSummary()`,用户在「记录」里存一条血压之后不刷新,就会看着自己刚量的数没出现 —— 与 BUG-4 同一个形状。给 `TrendsScreen` 补上与 Task 8 同款的注入点后加一条:

   ```dart
   testWidgets('「趋势」里存完一条记录,化验快照当场重新拉一次', (tester) async {
     var loads = 0;
     await tester.pumpWidget(
       MaterialApp(
         theme: MedMe.theme(),
         home: TrendsScreen(
           load: () async {
             loads++;
             return trendsDataFixture();
           },
           onRequestAddNote: (_) async => true,
         ),
       ),
     );
     await tester.pumpAndSettle();
     expect(loads, 1);
     await tester.tap(find.text('记录一下'));
     await tester.pumpAndSettle();
     expect(loads, 2, reason: '存完必须重新拉一次,否则刚量的血压不出现');
   });
   ```

   放进 `test/trends_screen_test.dart`,`trendsDataFixture()` 就是 Task 8 那个测试里已有的 `labs` / `visits` 夹具拼成的 `_TrendsData`。
2. `lib/analytics.dart` 里那些注释提到「五 tab」「概览 / 趋势 / 档案 / 应急卡」的地方一并改成三 tab(病历 / 趋势 / 我)的说法。
3. `lib/main.dart:600-609` 与 `lib/vault_events.dart:23` 里「「看病带这个」不是 tab」那两段长注释已经过时(它现在就是 tab),直接删。

- [ ] **Step 4: 跑全量,确认绿**

Run:

```bash
cd <app>
flutter analyze
flutter test
```

Expected: analyze + test **全绿**。这是整个词表部分的收口。`test/visit_summary_sheet_test.dart`
此时应当已经改名成 `test/for_doctor_refresh_test.dart` 并全部通过 —— 若它还在旧名字下
红着,说明 1b 没做。

- [ ] **Step 5: 提交**

```bash
cd <repo>
git add -u apps/mobile_flutter
git add apps/mobile_flutter/test/for_doctor_refresh_test.dart
git commit -m "refactor(mobile): 禁词闸合拢,清掉 存档/归档/采集/看病带这个 的残留

删掉 VisitSummarySheet 浮层本体(内容已升格成「给医生看」tab),
只留纯渲染的 VisitSummaryBody。visitSheetOpened / VisitSheetEntry 两个
埋点定义**保留**并标 @Deprecated —— PostHog 里有历史数据,删了对不上账;
全仓已无发射点。

BUG-4「存完笔记要当场重新拉一次」那组回归没丢:随本体搬到 ForDoctorScreen
(test/for_doctor_refresh_test.dart),「趋势」侧补了同形状的一条。

⚠️ 收窄:「导入 / 分享 / 授权」未进 kEnforced —— 它们在代码注释里是绕不开的
普通词,用户可见字符串已清干净。与 ia-proposal §6 Done 判据②的差异,请评审确认。"
```

---

### Task 18: 隐私政策同步(gh-pages worktree,本地提交、不推)

**Files:**
- Modify: `/Volumes/extraSupply/Projects/Medme-ghpages/privacy.html`(`:8`、`:87`、`:142`、`:172`、`:245`、`:268`、`:372`、`:416`、`:431`)

**Interfaces:**
- Consumes: Task 16 的行为(第一次添加病历时问一次)
- Produces: 无代码符号

> **只动第三节第 7 项(云端结构化整理)。第 3 项(二维码中转)一个字都不改** ——
> Task 11 那句「会把加密后的病历暂存到云端 15 天,只有扫这个码的人能看。」与政策
> 第 3 项现在说的是同一件事,政策那边已经写对了。
>
> CLAUDE.md 硬规矩 4:**改了「数据往哪走」,必须同步隐私政策。** 这次改的正是
> *什么时候征询、默认是什么* —— 政策里现在逐字写着「**只要你登录了就会自动发生**」。
> `gh-pages` 是两棵没有共同祖先的独立历史,`main` 里没有它的副本,评审看不见它。
> **本 Task 只在本地提交,不 push**(brief 硬约束)。

- [ ] **Step 0: 先确认第 3 项不需要动**

Run:

```bash
cd /Volumes/extraSupply/Projects/Medme-ghpages
grep -n "二维码" privacy.html | head
```

拿输出里第三节第 3 项那几句,和 Task 11 的逐字文案(`kQrNoticeText`)比一遍:
两边说的必须是同一件事(加密、暂存云端、15 天、只有拿到码的人能看)。**对得上就
不动它**;对不上就停下来报告 —— 那是 app 和政策打架,不是这个 Task 能顺手改的。

- [ ] **Step 1: 先读现状,确认要改哪几处**

```bash
cd /Volumes/extraSupply/Projects/Medme-ghpages
git branch --show-current   # 必须是 gh-pages
git status --short          # 必须干净
grep -n "登录后自动进行\|只要你登录了就会自动发生\|只要你登录了,导入病历时就会自动发生\|设置 → 账号 → 云端整理" privacy.html
```

- [ ] **Step 2: 改「什么时候发生」那四处**

`:245`(§三.7 的小标题):

```html
<h3>7. 云端结构化整理(<strong>第一次添加病历时问你一次</strong>,以后可在我 → 云端里改)</h3>
```

`:87`(开头摘要那句):

```html
<strong>第七种(云端结构化整理)在你第一次添加病历时会问你一次,开了之后每次添加都会发生,可以在「我 → 云端 → 云端整理」里关掉</strong>。
```

`:142`(第三节开头那句):

```html
<strong>第 7 项(云端结构化整理)在你登录后第一次添加病历时会问你一次;你答应了才开,之后每次添加病历都会发生,可以在「我 → 云端 → 云端整理」里关掉</strong>
```

`:268`(「怎么关掉」):

```html
<p><strong>怎么关掉。</strong><strong>「我 → 云端 → 云端整理」里一个开关</strong>,关掉之后新添加的病历只用本机识别,不再送出。不想登录也是一条关法:退出登录(我 → 云端 → 账号管理)同样会停掉这条通道。成员的「云端备份」开关<strong>管不到这一条</strong>——那个开关只管病历密文的上传下载。</p>
```

`:8`、`:290`、`:372`、`:416`、`:431` 里凡出现「登录后自动」「只要你登录了……就会自动」的措辞,一律改成「你答应之后」;凡出现「设置 → 账号 → 云端整理」的路径,一律改成「我 → 云端 → 云端整理」;「云同步」改成「云端备份」。

- [ ] **Step 3: 自查改全了**

Run:

```bash
cd /Volumes/extraSupply/Projects/Medme-ghpages
grep -n "登录后自动进行\|只要你登录了\|设置 → 账号\|云同步" privacy.html
```

Expected: 无输出。有输出就是还有一处没改。

- [ ] **Step 4: 本地提交,不推**

```bash
cd /Volumes/extraSupply/Projects/Medme-ghpages
git add privacy.html
git commit -m "docs(privacy): 云端整理改成第一次添加病历时问一次

对应 app 侧 feat/ux-stage1。原文写着「只要你登录了就会自动发生」,
现在要用户先答应。路径也随三 tab 改版从「设置 → 账号」变成「我 → 云端」。

⚠️ 未 push —— gh-pages 推上去即上线,等 app 侧这一版真发出去再推,
推完自己 curl 一下线上核实(CLAUDE.md 硬规矩 4)。"
git log --oneline -1
git status --short   # 必须干净
```

- [ ] **Step 5: 确认没有误推**

Run: `cd /Volumes/extraSupply/Projects/Medme-ghpages && git log origin/gh-pages..HEAD --oneline`
Expected: 恰好一条本地提交,尚未推送。

---

### Task 19: 模拟器冒烟 —— Stage 1 的「定义完成」

**Files:**
- 无代码改动(只跑、只记)

**Interfaces:**
- Consumes: Task 1-18 的全部产出
- Produces: 冒烟结论(四条判据逐条给出证据),写进 commit message

> 判据逐字来自 ia-proposal §6 Stage 1「Done 的判据」。**每条都要给出可核查的证据**,
> 不是「看起来对」。

- [ ] **Step 1: 全量测试 + 静态检查**

Run:

```bash
cd <app>
flutter analyze
flutter test
```

Expected: `analyze` 无 error(warning 可留);`flutter test` 全绿。**这一步不过就不要进模拟器。**

- [ ] **Step 2: 判据② —— 那条 grep 零命中**

Run:

```bash
cd <repo>
grep -rn "存档\|归档\|采集\|云同步\|云端识别\|保险箱\|家属\|待确认\|识别文本\|文档内容\|医生模式\|生成密钥\|数据出口" \
  apps/mobile_flutter/lib --include='*.dart' | grep -v 'lib/src/rust/'
```

Expected: 无输出。**有输出就回 Task 17 清干净**,不要在这里放行。

- [ ] **Step 3: 判据④ —— 三处过时声明的痕迹**

Run:

```bash
cd <repo>
grep -rn "不上传\|不会上传\|只在这台手机上\|只存在这台手机\|只保存在你自己的设备\|没有账号" \
  apps/mobile_flutter/lib apps/mobile_flutter/ios/Runner/Info.plist
```

Expected: 无输出。

- [ ] **Step 4: 判据① 与 ③ —— 真机/模拟器走一遍**

```bash
cd <app>
xcrun simctl list devices | grep -i "iPhone 17"
flutter run -d <udid> --dart-define=MEDME_API_BASE=http://localhost:9000
```

逐条核,每条截一张图存 `scratchpad/ux-stage1/shots/`:

- **① 冷启动后底栏是 `病历 / 趋势 / 我`,三个名字与词表一致**(mockup)。
- **①b 「给医生看」不在底栏,而在「病历」首页 hero 下面那两颗方块的右边那颗。** 这是 mockup
  与 ia-proposal §2 分歧的落点:**在 iPhone SE 尺寸上专门看一眼那颗按钮够不够显眼、
  四个字有没有被截断**,并在 2× 字号下再看一遍。这条是本阶段最该被真人验的一条 ——
  提案当初拒绝候选 B 的理由就是「老人在底栏找不到它」,现在它确实不在底栏了。
- **①c 逐屏对着 mockup 走一遍**(`s1` 病历 / `s2` 趋势 / `s4` 给医生看 / `s5` 我 /
  `s6` 添加 / `s7` 还没核对 / `s8` 一份病历 / `s13` 出码 / `s17` 云端整理):
  **块的顺序**与**每块的标题文案**必须对得上。Stage 1 允许缺内容(迷你折线、
  检查与手术、病程档案、看懂 —— 都是 Stage 2),**不允许顺序不同或文案不同**。
- **③ 每个功能只有一条路到达。** 逐一点过三个 tab,确认:添加只有「病历」tab 右上角
  一个入口;「给医生看」只有「病历」首页那颗按钮(概览的 banner、档案顶栏的剪贴板
  都没了);出码只有「给医生看 → 出码给医生」一条;应急大字只有「给医生看 → 急救」一条。
- **顺带验导航深度 ≤3**:病历 → 一份病历 → 原件(3 层);病历 → 给医生看 → 出码给医生(3 层)。
- **顺带验成员面**(`s1`/`s5`/`s10`):换成员走「病历」hero 卡上的 `⌃⌄`,**顶栏没有
  chip**;「我」里那份名单只有名字 + `N 份 ›`;`能改` / `只能看 · 剩 N 天` 这类词
  **只在某个成员自己的页面里**出现,别处一个都找不到。
- **顺带验「我」的云端行**(`s5`):标题 `云端`、副标题 `已备份,刚刚`、一个 `›`;
  「云端整理」的开关**不在这一屏**,在成员自己的页面里(`s10`)。
- **顺带验 Task 16**:全新安装 + 登录 + 第一次添加 → 弹一次「要让云端帮你认字吗?」;
  第二次添加**不再弹**。
- **顺带验 Task 11**:全新安装 → 第一次点「出码给医生」→ 弹一次那句告知,按「好,出码」
  才开始上传;**退出登录后再点,照样出码**(不再有登录墙);第二次点**不再弹**。

- [ ] **Step 5: 记结论并提交**

```bash
cd <repo>
git commit --allow-empty -m "chore(mobile): Stage 1 冒烟通过

ia-proposal §6 Stage 1「Done 的判据」逐条:
① 底栏 = 病历/趋势/我;「给医生看」在「病历」首页那两颗方块的右边那颗,
   SE 尺寸 + 2× 字号下不截断、够显眼;九屏逐块对照 mockup v24,顺序与标题一致
② 那条 grep 在 apps/mobile_flutter/lib 零命中
③ 添加/给医生看/出码/急救大字 各只有一条路到达;核心流程深度 ≤3
④ lib 与 Info.plist 里没有「不上传/只在这台手机上/没有账号」

另验:第一次添加弹一次云端整理征询(s17 文案)、第二次不弹;第一次出码弹一次
告知(s13 文案)、按「好,出码」才上传、退出登录后照样能出码、第二次不弹;
挑人的界面上没有角色词,角色只在成员自己的页面(s10);「我」的云端行是
「云端」+「已备份,刚刚」+「›」,云端整理在成员页里。
截图在 scratchpad/ux-stage1/shots/。

未 push(brief 硬约束)。"
```

---

### Task 20: App Store 中文文案(`docs/store/`,纯文本,不进代码)

**Files:**
- Create: `<repo>/docs/store/app-store-copy-zh.md`

**Interfaces:**
- Consumes: Task 2(首启四条声明的新说法)、Task 16(第一次添加时问一次)、Task 18(`privacy.html` 改完之后的逐字措辞)
- Produces: 无代码符号

> **纯文本任务,一行代码都不写。** 这份文案是 App Store Connect 里要粘贴的东西,
> 它和 `privacy.html` 是同一件事的两处对外表述 —— 说法必须逐句对得上(CLAUDE.md
> 硬规矩 4)。**Task 18 必须先做完**:以政策里的措辞为准,不是反过来。

- [ ] **Step 1: 把政策里那几句原文抄出来当对照基准**

Run:

```bash
cd /Volumes/extraSupply/Projects/Medme-ghpages
sed -n '87p;142p;245p;268p' privacy.html
grep -n "无明文病历、无解密密钥\|我们只存那个箱子\|涂黑\|境内" privacy.html | head
```

把输出存到 `/tmp/claude-501/.../scratchpad/store-copy-basis.txt`,写文案时逐句比对。**不许凭印象写** —— 这一条正是上次「代拍改成上云、政策还写着不经过服务器」那次的教训。

- [ ] **Step 2: 写 `<repo>/docs/store/app-store-copy-zh.md`**

按这个结构写(每节都要能指回 `privacy.html` 的某一句):

```markdown
# App Store 中文文案(zh-Hans)

> 最后核对日期:2026-09-16 · 对照基准:`gh-pages` 的 `privacy.html`(Task 18 之后的版本)
> 每一句都在政策里有出处;改政策必须回来改这里,反之亦然。

## 副标题(30 字以内)
跨院看病的病历助手

## 关键词(100 字符以内,逗号分隔,不留空格)
病历,化验单,体检报告,慢病,复诊,就诊记录,加密,病历管理,健康档案,家人

## 「关于你的数据」段落(描述正文里的那一段,逐字)

账号是可选的。不登录也能用,病历就在这台手机里 —— 只是换手机找不回来。

登录之后,云端备份默认打开:整箱病历在你手机上加密之后才上传,我们那边只有密文,
**没有解密密钥**,打不开。这个开关随时可以关。

第一次添加病历时,我们会问你一次要不要开「云端整理」:开了,病历画面会**先在你的
手机上把姓名、证件号、手机号、病历号、医院名涂掉**,再送到**中国境内**的云端模型
去认字,把化验值、诊断、用药整理成表。不开也能用,只靠这台手机认字。这个开关以后
在「我 → 云端」里随时可以改。

文字识别、查看、导出都不需要联网。

MedMe 是个人病历整理工具,不是医疗器械,不提供诊断或治疗建议;一切以原始医疗
文件为准,请遵医嘱。

## 逐句出处对照

| 这里写的 | privacy.html 的出处 |
|---|---|
| 账号是可选的,不登录也能用 | §三 开头「第 1、3、4、5 项要你自己在 App 里触发」+ 登录章 |
| 只有密文、没有解密密钥 | 第三方表格「保险箱的**密文**。**无明文病历、无解密密钥**」 |
| 第一次添加病历时问一次 | §三.7 小标题(Task 18 改后) |
| 先在手机上涂掉再送出 | §三.7「一张**在你手机上脱敏并涂黑之后**的病历画面」 |
| 中国境内 | §跨境「**第三节第 7 项那条通道也在境内**」 |
| 识别/查看/导出不需要联网 | 权限表「**文字识别、查看、导出不需要联网**」 |
```

- [ ] **Step 3: 自查每一句都有出处**

逐条对着上面那张表,把 `privacy.html` 里对应的那句话**原样粘到临时文件里比对**。
出现下面任何一种就是不合格,回 Step 2 改:

- 文案里有一句在政策里找不到出处;
- 两边对同一件事的措辞不一致(例如这边写「自动」、那边写「问你一次」);
- 用了「诊断级」「AI 医生」「零服务器」这类监管词或已被松绑的旧口径(见 memory `landing-messaging-2026-07`)。

- [ ] **Step 4: 确认没有碰到代码**

Run: `cd <repo> && git status --short`
Expected: 只有 `docs/store/app-store-copy-zh.md` 一个新文件,`apps/` 下没有任何改动。

- [ ] **Step 5: 提交**

```bash
cd <repo>
git add docs/store/app-store-copy-zh.md
git commit -m "docs(store): App Store 中文文案对齐新的数据流

账号可选、云端备份默认开可关、云端整理第一次添加时询问、脱敏后送境内模型、
我们无解密密钥。每一句都附了 privacy.html 的出处,改一边必须改另一边。

纯文本,不进代码。"
```

---

## Self-Review

**1. Spec coverage**

| brief 的要求 | 在哪个 Task |
|---|---|
| (1) 词表映射表任务 | Task 1 |
| (1) 按屏替换用户可见字符串 | Task 5-7、12-15、17 |
| (1) Info.plist 用途说明 | Task 2 |
| (1) 首次启动声明 | Task 2 |
| (1) 设置版本行 | Task 2 |
| (1) App Store 描述另出 `docs/store/` | Task 20(纯文本,排在 Task 18 之后 —— 以政策措辞为准) |
| (2) 底栏改 tab(mockup:3 个) | Task 3 |
| (2) 页面并入/删除/新建 | Task 3(建给医生看页)、4(删角色选择)、5(建「给医生看」入口按钮)、8(趋势收编化验快照/最近就诊/病程档案入口)、9(删概览、接线)、10(降应急卡)、15(删死掉的转移分支)、17(删 VisitSummarySheet) |
| (2) 导航深度 ≤3 | Task 19 Step 4 验 |
| (3) 云端整理首次导入问一次 | Task 16 |
| ~~(4) 未登录出码给「先登录」~~ → **创始人改判**:出码不看登录,改成第一次出码时告知一次 | Task 11(已整条替换) |
| mockup `s1`:hero(⌃⌄ 换成员)+ 两颗等宽方块 + 还没核对横幅 + 月份分组 + 找一找占位 | Task 5 |
| mockup `s2`/`s9`:病程档案 → 分类 chip → 关键化验 → 看懂 → 最近就诊 → 记录一下 | Task 8 |
| mockup `s4`:给医生看整页的块序与四条入口文案 | Task 3、9、10 |
| mockup `s5`/`s10`:我 tab 五块;角色只在成员自己的页面 | Task 12、13 |
| mockup `s6`:添加 sheet 标题仍是「添加病历」(撤回早先的禁词) | Task 5 |
| mockup `s7`:还没核对 / 看原件 / 没问题 | Task 6 |
| mockup `s8`:表格 / 文字 / 原件 | Task 7 |
| mockup `s12`/`s15`:设一个口令 / 我抄好了 / 拿回你的病历 | Task 14 |
| mockup `s13`:出码屏 + 第一次告知(含「我们打不开」) | Task 11 |
| mockup `s14`:替病人代拍 + 取件码 | Task 15 |
| mockup `s16`:首启三句 ⚠️ 同意门是否改成「用了就是同意」待创始人拍板 | Task 2 |
| mockup `s17`:云端整理问一次的逐字文案 | Task 16 |
| Stage 2 不提前做:迷你折线、检查与手术、病程档案内容、看懂内容、搜索 | Task 5、8、3 各自标注 |
| (5) 隐私政策同步 | Task 18 |
| (6) 每个 Task 用 widget test 钉住 | 全部 Task 的 Step 1 |
| (6) 最后一个 Task 是模拟器 smoke | Task 19 |
| 11 组词表逐一替换 | `kGlossary`(Task 1)+ Task 5-7、12-15、17 |
| 应急卡大字模式保留 | Task 10 |
| 病程档案只留入口位 | Task 8 |

**2. Placeholder scan**:全部代码步都给了可直接粘贴的代码块;所有 `Run:` 都是可执行命令并写明 Expected。

**3. Type consistency**:`HomeTab.records/trends/me` 在 Task 3 定义,Task 10、19 引用同一组名字;`AnalyticsTab.records/trends/me` 与之一一对应(Task 3 的测试直接断言这层对应);`goToTrends` 是真函数,`goToArchive`/`goToEmergencyCard` 是 Task 3 建、Task 9 删的 `@Deprecated` shim;`ForDoctorScreen({load, onRequestAddNote})` 在 Task 3 定义、Task 5 推入、Task 17 的回归测试注入;`ForDoctorActions` 的四个回调名 `onShowQr/onExport/onEmergency/onProxy` 在 Task 3 定义、Task 9 接线、Task 9 的测试断言;`HomeTiles({onAdd, onForDoctor})` / `PendingReviewBanner({count, onTap})` / `MonthHeader({label, onSearch})` 在 Task 5 定义、Task 9 前置闸复核;`UnderstandBanner()` 在 Task 8 定义;**没有 `MemberChip`** —— 换成员走既有的 `IdentityHeroCard.onSwitchMember`;`TrendsScreen({load, onRequestAddNote})` 与 `TrendsData` 在 Task 8 定义、Task 17 的 1c 使用;`shouldAskCloudExtract({loggedIn, asked})` 在 Task 16 定义并在同 Task 的 `import_flow.dart` 调用;`shouldShowQrNotice({seen})` / `kQrNoticeText` / `showQrNoticeSheet` 在 Task 11 定义并在 `qr_share_screen.dart` 调用;三个偏好键 `cloud_extract_enabled`(既有)、`cloud_extract_asked`(Task 16)、`qr_notice_seen`(Task 11)互不相同,各自文档里写明了区别。
