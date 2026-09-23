// **Stage 3 不许改一个用户可见的字 —— 但允许把一句话拆成几段分别设色。**
// R18(hero 卡「最近就诊」标签与值分开上色)把一条插值字符串
// `'最近就诊 · ${cond ? '暂无' : x}'` 拆成两条独立字面量 `'最近就诊 · '` +
// `'暂无'`,渲染出来的字符跟拆之前逐字节相同。原来「整条字符串字面量集合」
// 的判法(逐字面量取边界)不理解 Dart 的 `${}` 插值嵌套,会把插值字符串的
// 边界切错,对着这种「拆一条为两条、字符不变」的改动打假红(2026-09-19
// Step 1 踩过)。R32 裁定换成「CJK 文本段的多重集」。
//
// **段的多重集不关心字面量的语法边界**,只关心"这些字在非注释代码里连续
// 出现多少次"——天然不需要理解 Dart 词法/插值语法。段 = `一-鿿`(CJK 统一
// 表意文字,含拓展 A 区,简繁都在内)加中文标点 `,。、;:「」()《》·…!?—`
// 的最大连续片段。**故意选这个字符类,不是"所有非 ASCII"**:空格、拉丁
// 字母数字、英文标点(含插值语法的 `$` `{` `}` `?` `:`)都不在类里,天然是
// 段与段之间的切分点——R18 的案例能被正确放行,正是因为「最近就诊 · 」在
// 空格处早就被切成「最近就诊」+「·」两段,跟拆成两条字面量之后的段完全
// 一样;真正的文案变更(加字/删字/改字)会改变某个段出现的次数,骗不过
// 多重集。
//
// **范围是整个 `lib/**`,不止 `lib/screens`+`lib/widgets`**:2026-09-19 用
// 同一手法单独核过 `design_tokens.dart`/`theme.dart`/`doc_labels.dart`/
// `import_flow.dart`/`main.dart` 这五个直属 `lib/` 的文件,零差异——但闸本身
// 应该管住整棵树,不该依赖"这次恰好没有"。多重集是全树聚合:一个段挪到
// 哪个文件、哪个 widget 都不影响计数,只要总次数不变。
//
// **每一段必须至少含一个 `一-鿿` 表意字才计数**——这条是跑出来的,不是拍脑袋
// 定的。给出的字符类里 `,;:()!?` 是半角标点,本身也是 Dart 语法的一部分
// (函数实参的逗号、语句结尾的分号、调用的括号……);不加这条过滤,纯代码
// 结构里裸露的逗号/括号会被当成"文本段"计数,而 Stage 3 到处在挪动/重排
// 代码(提纯 widget、换 token 组件),这类结构性标点的裸计数天然会变,
// 完全是噪音(实测:仅 `,` 一项在两侧就差 455 次,来自 `net.dart`/生成的
// FRB 绑定等与中文文案毫无关系的文件)。加了这条之后,半角标点仍然算进
// 「紧贴中文字」的那一段(比如「已开通」后面紧跟的半角括号),只是不再单独
// 成段——不违背"允许挪动/拆分"的初衷,R18 案例的验证方式不变(空格两侧仍
// 各自成段,「最近就诊」「·」在这条过滤下「·」会被丢弃——两侧同样丢弃,
// 不影响判等)。
//
// **次数在"文件"这一级去重**——同一段文字在同一个文件里重复几次只算 1,
// 挪到 N 个不同文件才算 N。这条也是跑出来的:`link_qr_dialog.dart` 的
// 「复制链接」在 R27(mockup s14 的 hero/非 hero 两条路)之前只有一颗按钮、
// 一处字面量;R27 给同一个按钮加了 hero 分支(`cond ? MedSecondaryButton(...)
// : OutlinedButton.icon(...)`),两个分支互斥渲染同一个标签,字面量在源码里
// 从 1 处变 2 处,但任一次渲染用户看到的还是同一个「复制链接」——跟 R18 是
// 同一类"结构分支导致源码计数变化,渲染不变"。按文件去重之后,`n(此文件含
// 这段)` 而不是 `n(源码里出现几次)`,这类同文件内的分支重复不再算差异;
// 真正会被漏掉的是"同一个文件里意外重复粘贴了一整段话"这种低概率笔误,
// 换来的是不必为每一处 hero/非 hero、状态 A/状态 B 分支都手工核对。跨文件
// 的重复(把一段话意外抄到另一个屏)依然按文件数计数,不受影响。
//
// **`design_tokens.dart`/`theme.dart` 按路径整个排除(R34)**——这两个文件是
// 令牌层,不渲染任何用户可见文本。它们唯一出现过的字面量是 R2(Task 6)
// 删掉的一个死设计笔记常量(`normalIsUncolored`,全仓零引用,不是任何屏上
// 会显示的字),这次扩到 `lib/**` 之后把它的删除也当成了"丢文案"——但它
// 从来没被任何 widget 显示过,不是这个闸该管的东西。这两个文件另有专门的闸
// 盯着裸色值/令牌形状(`no_raw_colors_test.dart`/`design_tokens_test.dart`),
// 不需要也不该叠加这个"用户可见文案"的闸。按路径整个排除,不做逐条引用
// 分析、不做单条字符串的特例。
//
// **闸红了怎么办:** 不是改这个测试,是把文案改回去(唯一合法例外是删掉整个
// widget 时带走它的字符串,Stage 3 不删 widget)。Stage 3.5 起另有
// `kRemovedByDecision`:用户点名删的字。红的信息会打印每个差异段、
// 次数差,以及 HEAD/基线两侧各自含有它的文件——"哪个文件"只是调试线索,
// 判定依据是次数本身。
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// Stage 3 开工前的 HEAD。
const kBaseline = '2a629a2';

/// Stage 3.5(减法,2026-09-22)用户裁定删掉的字,或删掉整个 widget 时带走的字面量
/// (文件头注释写的合法例外)。**值是这个段允许消失的次数上限——一份预算,不是
/// 开关。** HEAD 比基线少的次数(`b - n`)在预算内才放行,超出预算照旧红
/// (`(b - n) > (kRemovedByDecision[r] ?? 0)`)。
///
/// 原来是个 `Set`,判法是「在集合里就放行任意次数」——这条闸本身对同一个段以后
/// **再** 消失多少次完全没有上限。`'我'` 这种全 app 到处用的常见词一旦放进这个
/// 集合,以后不管哪个 widget 不小心删漏了一处「我」,这条闸都会悄悄放行,不会
/// 再红。换成按次数记预算之后,每加一条都要想清楚「这次刚好消失几次」,消失
/// 第二次(没人点名要删、也没有第二个 widget 被整个删掉)就该重新审、重新红。
///
/// 新增条目的数量:用户点名要删的字数「就是它这次实际消失的次数」(通常 1);
/// 删掉整个 widget 带走的字面量,数量是那个 widget **出现过的文件数**(通常
/// 也是 1)——不是这段文字在那个文件里写了几遍(文件内去重见文件头注释)。
const Map<String, int> kRemovedByDecision = {
  '找一找': 1, // 主页月份标题右侧的搜索占位,点了只弹一句「找一找还在做」
  '找一找还在做': 1,
  '看懂': 1, // 趋势页「看懂」横幅:只有壳,内容线从没接上
  '把报告上那段「提示」原文摘出来放这里': 1,
  '还在做。': 1,
  // Task 5(2026-09-22):`IdentityHeroCard` 连同它的头像块(`_Avatar`)整个删掉,
  // 换成一行文字的 `MemberHeader`(没有头像)。`_Avatar` 里唯一的字面量是姓名
  // 取不到首字时的兜底显示 `name.isNotEmpty ? name[0] : '我'`——删掉整个 widget
  // 带走它的字符串,是这份闸自己文件头注释写的合法例外(**不是**用户点名删
  // 「我」这个词本身)。预算记 1——只有 `identity_hero_card.dart` 这一个文件
  // 消失了;「我」作为词本身在 main.dart(底栏「我」tab)/settings_screen.dart/
  // profile_manager.dart 三处原样还在。这个词往后再消失第二次,预算用完,
  // 闸重新红——那时候得说清楚是哪个 widget、为什么。
  '我': 1,

  // Task 6(2026-09-23,趋势重整):`KeyLabsSnapshot`(关键化验各行,并进了
  // `TrendRow` 列表)、`RecentVisitsCard`/`_VisitCard`/`visitCardShowsDate`/
  // `visitCardDesc`(最近就诊,没有下家)、`_AbnormalOnlyRow`(整行 `Switch`,
  // 换成 `PanelChipsRow` 末尾一颗 `MedChip`)三个 widget 整块删掉,带走它们的
  // 字面量——闸自己文件头注释写的合法例外(不是用户点名删这几个词本身)。
  // 以下逐条对应闸实际报告的段,数量按「删掉整个 widget 时字面量出现过的文件
  // 数」记(全部是 1,`trends_screen.dart` 单独一个文件)。
  //
  // `RecentVisitsCard`(`_SectionHeader(title: '最近就诊', actionLabel: '全部
  // $total 份')`+空态「还没有添加过病历。」)与 `_VisitCard`
  // (`visitCardDesc` 的 `'$docCount 份记录'`):
  '最近就诊': 1,
  '份': 1,
  '份记录': 1,
  '还没有添加过病历。': 1,
  // `KeyLabsSnapshot` 的空态:
  '已添加的病历里还没有读到可显示的化验数值。拍一张化验单试试。': 1,
  // `_AbnormalOnlyRow` 的四句(基础开关文案、隐藏计数后缀、搜索/选中大类时
  // 让位说明各一句)——`」下不过滤` 前半的引号来自
  // `'「${_panelChipLabel(selectedPanel)}」下不过滤 …'`,插值把整句切开,
  // 剩下这一段是闸实际认到的字面量,不是漏字:
  '只看非正常项': 1,
  '条正常或判断不了': 1,
  '搜索时不过滤': 1,
  '正常项也一起找。': 1,
  '」下不过滤': 1,
  '这类检查查过的都在这。': 1,
};

/// 与 [kRemovedByDecision] 对称:这一阶段**允许多出来**的段,值 = 允许多出的文件数。
/// 只登记本阶段计划里列出的新字(见 docs/superpowers/plans/2026-09-23-home-todo-and-trends-rework.md
/// Global Constraints);登记之外的新字照旧红。每个 Task 只登记自己引入的段。
///
/// Task 3(2026-09-23):`doc_labels.dart` 新增 `fmtDay`/`fmtDayRange`/
/// `selfAnalyteLabel`,以下两条是跑这个闸实际报告的多出的段,逐条核对与这一
/// 处改动对应(评审再核一遍):
const Map<String, int> kAddedByDecision = {
  // `fmtDay` 的 `'${d.month} 月 ${d.day} 日'`——`月`/`日` 这两个字本已在
  // account_screen.dart/backup_status_line.dart 等多处「M月D日」写法里出现过,
  // `doc_labels.dart` 只是新增了一个也含它们的文件。
  '月': 1,
  '日': 1,
  // Fix round 1(评审 Critical 1):`selfAnalyteLabel` 的心率/体重/体温/血糖
  // 四个标签**不**登记在这里——`manual_entry_sheet.dart` 的 `_analyteErrorLabel`
  // 已改成委托 `selfAnalyteLabel`,不再各自持有一份字面量,两侧净变化为 0,
  // 闸本就不报,登记进来反而是把不该放行的重复默许掉。

  // Task 4(2026-09-23):`widgets/self_week.dart` 新增 `selfWeekTitle`
  // (`'自测 · ${fmtDayRange(...)}'`)与 `selfWeekDesc`(`'... $count 次 ...'`)——
  // 逐条对应计划里登记的新字「自测 · M 月 D 日 – M 月 D 日」「N 次」。
  '自测': 1,
  '次': 1,
  // `archive_screen.dart` 新增的「最近 30 天有 $abnormal30d 项偏高或偏低」
  // (`'最近'`/`'天有'`/`'项偏高或偏低'` 三段,数字被拆在中间不成段;R35a 的
  // 表意字|数字配对闸另加一条 `'最近|30'`)——逐条对应计划里登记的新字
  // 「最近 30 天有 N 项偏高或偏低」。「给医生看」这一段在本文件里已有(`HomeTiles`
  // 的按钮文案),待办卡的「给医生看」note 是同一份字符串,净变化为 0,不登记。
  // 超期 N 天/没查到(状态标签)/血压等指标名全部经既有函数复用(见
  // `reminderOverdueNote`/`reminderStateLabel`/`selfAnalyteLabel`),没有产生
  // 第二份字面量,闸本就不报,不登记。
  '最近': 1,
  '天有': 1,
  '项偏高或偏低': 1,
  '最近|30': 1,

  // Task 6(2026-09-23,趋势重整):`trends_screen.dart` 的 `PanelChipsRow`
  // 新增末尾的「只看异常」开关 chip(`MedChip(label: '只看异常', ...)`,替换
  // 删掉的 `_AbnormalOnlyRow` 那颗 `Switch`),`_SinglesFold` 新增页尾折叠标题
  // 「只测过一次的 N 项」——逐条对应计划里登记的新字「只看异常」「只测过一次的
  // N 项」。数字把「只测过一次的」和「项」隔成两段(R35a 同款,不成一个整段)。
  // 「项」本已出现在 `disease_profile_card.dart`(病种包条目数「N 项」,基线里
  // 就有、未改动)——净变化只来自 `trends_screen.dart` 新增的这一处,预算 1。
  '只看异常': 1,
  '只测过一次的': 1,
  '项': 1,
};

/// 基线 commit 在浅克隆里不存在(CI 若用 fetch-depth: 1 就会这样)——那样的失败
/// 不是文案变了,是 checkout 没带历史;把原因直接写进断言消息。
void _requireBaseline() {
  final r = Process.runSync('git', ['cat-file', '-e', '$kBaseline^{commit}'], workingDirectory: '../..');
  expect(r.exitCode, 0,
      reason: '基线 $kBaseline 不在本地仓库里(浅克隆?mobile.yml 的 checkout 需要 fetch-depth: 0)');
}

/// R34:令牌层,不渲染任何用户可见文本,按路径整个排除——见文件头注释。
bool _isTokenFile(String path) =>
    path.endsWith('lib/design_tokens.dart') || path.endsWith('lib/theme.dart');

/// CJK 统一表意文字 + 中文标点。故意不含空格/拉丁字母数字——它们是段与段
/// 之间天然的切分点,见文件头注释。
final _cjkRun = RegExp(r'[一-鿿,。、;:「」()《》·…!?—]+');

/// 至少含一个表意字——半角标点(`,;:()!?`)本身也是 Dart 语法的一部分,
/// 纯标点、不挨着任何中文字的"段"是代码结构噪音,不是文案,见文件头注释。
final _cjk = RegExp(r'[一-鿿]');

/// 去掉行注释(`//…`/`///…`,行内截断到行尾)和块注释(`/* … */`,可跨行)——
/// 注释里的中文(设计说明、踩坑记录)Stage 3 会大改,那不算文案变更。
///
/// R35b:原来对整行找**第一个** `//` 就截断,连字符串字面量里的 `//`(URL)也当
/// 成注释起点——字面量本身连同它后面真正的注释一起被吞掉,`settings_screen.dart:
/// 556/754/762` 的 `_openWeb('https://…', '主页')` 这类调用因此整行消失(HEAD/
/// 基线两侧一样瞎,闸不红,但漏了覆盖)。改成:整行(trim 后)以 `//` 开头才
/// 整行丢;否则只有当 `//` 前面是空白、且不在单引号字符串里面(数「前面有几个
/// 没被转义的 `'`」,奇数 = 在字符串里)才截断——反斜杠转义按「紧邻前一个字符
/// 是不是 `\`」这一层判断,不处理连续反斜杠这种更深的转义链(这份代码里的
/// 字面量不出现裸反斜杠,见 R35 报告)。
String _stripComments(String src) => src
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
    .split('\n')
    .map((l) {
      if (l.trimLeft().startsWith('//')) return '';
      var quotes = 0;
      for (var i = 0; i < l.length; i++) {
        if (l[i] == "'" && (i == 0 || l[i - 1] != '\\')) {
          quotes++;
        } else if (l[i] == '/' &&
            i + 1 < l.length &&
            l[i + 1] == '/' &&
            i > 0 &&
            l[i - 1].trim().isEmpty &&
            quotes.isEven) {
          return l.substring(0, i);
        }
      }
      return l;
    })
    .join('\n');

List<String> _runsIn(String src) => _cjkRun
    .allMatches(_stripComments(src))
    .map((m) => m[0]!)
    .where(_cjk.hasMatch)
    .toList();

/// R35a:数字/拉丁数字本身不在 `_cjkRun` 的字符类里(见上),所以纯 CJK 段的
/// 多重集看不见「暂存到云端 15 天」改成「30 天」这种改动。只挑**紧跟在表意字
/// 段后面**的数字串配对成一个单元一起计数(如 `…云端|15`,中间只许隔空白,
/// 空隙也可以是零宽——「拍了3张」的「拍了|3」)——数字一改,这个单元的次数
/// 就变。
///
/// **「紧跟」按字面意思、不是「同一行里随便一个更早的表意字段」**:这条是跑
/// 出来的——先按「同一行最近的前一个表意字段」实现过一版,`account_screen.dart`
/// / `member_detail_screen.dart` 里 `Text('恢复码,口令忘了用它', style:
/// TextStyle(fontSize: 15, …))` 这类同一物理行内、但隔着一串 Dart 代码
/// (`style: TextStyle(fontSize: `)的 `15`,以及颜色令牌命名 `.ink3`、
/// `FontWeight.w400` 里的后缀数字,全被当成跟前面的中文段"配对",而这些数字
/// 全是 Stage 3 改样式(字号/字重/取色令牌名)带来的代码噪音,跟中文文案
/// 半点关系没有——两侧一比就假红。改成「中间只许空白」之后,digit 与它要配对
/// 的表意字段之间不能隔着任何非空白代码字符,这类噪音天然配不上(数字前面
/// 不是空白衔接的表意字,直接跳过、不计入),闸回到绿。
final _digitRun = RegExp(r'[0-9]+(?:[.~/-][0-9]+)*');

List<String> _digitPairsIn(String src) {
  final pairs = <String>[];
  for (final line in _stripComments(src).split('\n')) {
    if (!_cjk.hasMatch(line)) continue;
    final cjkRuns = _cjkRun.allMatches(line).where((m) => _cjk.hasMatch(m[0]!)).toList();
    for (final d in _digitRun.allMatches(line)) {
      RegExpMatch? nearest;
      for (final c in cjkRuns) {
        if (c.end <= d.start &&
            line.substring(c.end, d.start).trim().isEmpty &&
            (nearest == null || c.end > nearest.end)) {
          nearest = c;
        }
      }
      if (nearest != null) pairs.add('${nearest[0]}|${d[0]}');
    }
  }
  return pairs;
}

/// 段文本 → 出现次数(多重集)。
Map<String, int> _multiset(Iterable<String> runs) {
  final m = <String, int>{};
  for (final r in runs) {
    m[r] = (m[r] ?? 0) + 1;
  }
  return m;
}

/// `kRemovedByDecision` 预算判法的核心:纯函数、不碰文件系统/git,从
/// [_diffAgainstBaseline] 里单独挑出来方便单测。`before`/`now` 是「段 → 次数」
/// 的多重集,`budget` 就是 [kRemovedByDecision](或测试自己搭的小样本)。
/// 少的次数(`b - n`)超过预算才算违规——返回违规的段集合,判定依据只有
/// 次数本身,不看是哪个文件(文件名只在调用方拼失败信息时用来调试)。
Set<String> _overBudgetRemovals(
  Map<String, int> before,
  Map<String, int> now,
  Map<String, int> budget,
) {
  final over = <String>{};
  for (final r in {...now.keys, ...before.keys}) {
    final n = now[r] ?? 0, b = before[r] ?? 0;
    if (b > n && (b - n) > (budget[r] ?? 0)) over.add(r);
  }
  return over;
}

/// `_overBudgetRemovals` 的镜像:多的次数(`n - b`)超过预算才算违规,`budget`
/// 就是 [kAddedByDecision](或测试自己搭的小样本)。
Set<String> _overBudgetAdditions(
  Map<String, int> before,
  Map<String, int> now,
  Map<String, int> budget,
) {
  final over = <String>{};
  for (final r in {...now.keys, ...before.keys}) {
    final n = now[r] ?? 0, b = before[r] ?? 0;
    if (n > b && (n - b) > (budget[r] ?? 0)) over.add(r);
  }
  return over;
}

/// HEAD 的 `lib/**`(排除令牌层)与基线 [kBaseline] 的同一份文件集,各自喂给
/// [extract]、按文件去重(`.toSet()`——同一段文字在同一个文件里出现几次只算
/// 1,见文件头注释)后聚成多重集,回 added/removed 差异描述(带文件名,供失败
/// 信息用)。CJK 段闸与 R35a 数字配对闸共用这一套「怎么比」,只有「抽什么」
/// ([extract])不同。
({List<String> added, List<String> removed}) _diffAgainstBaseline(
  List<String> Function(String) extract,
) {
  // HEAD:当前工作区 lib/** 下所有 .dart 文件——不限 screens/widgets。
  final headFiles = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart') && !_isTokenFile(f.path));
  final headRuns = <String>[];
  final headFilesByRun = <String, Set<String>>{};
  for (final f in headFiles) {
    final runs = extract(f.readAsStringSync()).toSet();
    headRuns.addAll(runs);
    for (final r in runs) {
      (headFilesByRun[r] ??= <String>{}).add(f.path);
    }
  }

  // 基线:`git ls-tree` 拿文件名单(HEAD 之后新增/删掉的文件天然只在一侧
  // 名单里出现,不要求两侧文件集合相同),逐个 `git show` 取内容——一个
  // 文件一次子进程调用,workingDirectory 在上两级(仓库根),路径按 git
  // 的相对写法。
  final ls = Process.runSync('git', [
    'ls-tree',
    '-r',
    '--name-only',
    kBaseline,
    '--',
    'apps/mobile_flutter/lib',
  ], workingDirectory: '../..');
  final baselinePaths = (ls.stdout as String)
      .trim()
      .split('\n')
      .where((p) => p.endsWith('.dart') && !_isTokenFile(p));
  final baselineRuns = <String>[];
  final baselineFilesByRun = <String, Set<String>>{};
  for (final path in baselinePaths) {
    final show = Process.runSync('git', ['show', '$kBaseline:$path'], workingDirectory: '../..');
    final runs = extract(show.stdout as String).toSet();
    baselineRuns.addAll(runs);
    for (final r in runs) {
      (baselineFilesByRun[r] ??= <String>{}).add(path);
    }
  }

  final now = _multiset(headRuns);
  final before = _multiset(baselineRuns);
  final overBudget = _overBudgetRemovals(before, now, kRemovedByDecision);
  final overAdded = _overBudgetAdditions(before, now, kAddedByDecision);

  final added = <String>[];
  final removed = <String>[];
  for (final r in {...now.keys, ...before.keys}) {
    final n = now[r] ?? 0, b = before[r] ?? 0;
    if (overAdded.contains(r)) {
      added.add('「$r」多了 ${n - b} 次 —— 现存于:${(headFilesByRun[r] ?? const {}).join(', ')}');
    }
    if (overBudget.contains(r)) {
      removed.add('「$r」少了 ${b - n} 次 —— 基线里在:${(baselineFilesByRun[r] ?? const {}).join(', ')}');
    }
  }
  return (added: added, removed: removed);
}

void main() {
  test('用户可见 CJK 文本段的多重集与基线 $kBaseline 相同(允许挪动/拆分,不许增删)', () {
    _requireBaseline();
    final diff = _diffAgainstBaseline(_runsIn);
    expect(diff.added, isEmpty, reason: '多出来的文案段(Stage 3 不许加字):\n${diff.added.join('\n')}');
    expect(diff.removed, isEmpty, reason: '丢掉的文案段(Stage 3 不许删字):\n${diff.removed.join('\n')}');
  });

  test('R35a:表意字|数字配对的多重集与基线 $kBaseline 相同(数字改了要测得出来)', () {
    _requireBaseline();
    final diff = _diffAgainstBaseline(_digitPairsIn);
    expect(diff.added, isEmpty, reason: '多出来的「表意字|数字」配对:\n${diff.added.join('\n')}');
    expect(diff.removed, isEmpty, reason: '丢掉的「表意字|数字」配对:\n${diff.removed.join('\n')}');
  });

  test('kRemovedByDecision 预算自测(纯函数,不碰 git):预算 1 放一次、拦第二次', () {
    const budget = {'我': 1};
    // 基线 2 次、HEAD 1 次 —— 少了 1 次,预算 1,放行。
    expect(_overBudgetRemovals({'我': 2}, {'我': 1}, budget), isEmpty);
    // 基线 2 次、HEAD 0 次 —— 少了 2 次,超过预算 1,照旧红。
    expect(_overBudgetRemovals({'我': 2}, {'我': 0}, budget), {'我'});
  });

  test('kAddedByDecision 预算自测(纯函数,不碰 git):预算 1 放一次、拦第二次', () {
    const budget = {'日': 1};
    // 基线 0 次、HEAD 1 次 —— 多了 1 次,预算 1,放行。
    expect(_overBudgetAdditions({'日': 0}, {'日': 1}, budget), isEmpty);
    // 基线 0 次、HEAD 2 次 —— 多了 2 次,超过预算 1,照旧红。
    expect(_overBudgetAdditions({'日': 0}, {'日': 2}, budget), {'日'});
  });

  test('_digitPairsIn 自测(纯函数,不碰 git):15 天改成 30 天,多重集必须不同', () {
    // 原句取自 `lib/screens/qr_notice_sheet.dart` 的 kQrNoticeText。
    const before = '会把加密后的病历暂存到云端 15 天,只有扫这个码的人能看;我们打不开。';
    const after = '会把加密后的病历暂存到云端 30 天,只有扫这个码的人能看;我们打不开。';
    expect(_multiset(_digitPairsIn(before)), isNot(equals(_multiset(_digitPairsIn(after)))));
  });

  test('_stripComments 自测(纯函数):字符串字面量里的 // 不是注释起点', () {
    const line = "  Text('https://medme.example/主页'), // 主页链接";
    // 保留字面量里的「主页」、丢掉注释里的「主页」——不是「两个都保留」。
    expect(_runsIn(line), ['主页']);
  });
}
