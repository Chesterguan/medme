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
// widget 时带走它的字符串,Stage 3 不删 widget)。红的信息会打印每个差异段、
// 次数差,以及 HEAD/基线两侧各自含有它的文件——"哪个文件"只是调试线索,
// 判定依据是次数本身。
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// Stage 3 开工前的 HEAD。
const kBaseline = '2a629a2';

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
String _stripComments(String src) => src
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
    .split('\n')
    .map((l) {
      final i = l.indexOf('//');
      return i < 0 ? l : l.substring(0, i);
    })
    .join('\n');

List<String> _runsIn(String src) => _cjkRun
    .allMatches(_stripComments(src))
    .map((m) => m[0]!)
    .where(_cjk.hasMatch)
    .toList();

/// 段文本 → 出现次数(多重集)。
Map<String, int> _multiset(Iterable<String> runs) {
  final m = <String, int>{};
  for (final r in runs) {
    m[r] = (m[r] ?? 0) + 1;
  }
  return m;
}

void main() {
  test('用户可见 CJK 文本段的多重集与基线 $kBaseline 相同(允许挪动/拆分,不许增删)', () {
    // HEAD:当前工作区 lib/** 下所有 .dart 文件——不限 screens/widgets。
    final headFiles = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart') && !_isTokenFile(f.path));
    final headRuns = <String>[];
    final headFilesByRun = <String, Set<String>>{};
    for (final f in headFiles) {
      // `.toSet()`:同一段文字在同一个文件里出现几次只算 1,见文件头注释。
      final runs = _runsIn(f.readAsStringSync()).toSet();
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
      // `.toSet()`:同一段文字在同一个文件里出现几次只算 1,见文件头注释。
      final runs = _runsIn(show.stdout as String).toSet();
      baselineRuns.addAll(runs);
      for (final r in runs) {
        (baselineFilesByRun[r] ??= <String>{}).add(path);
      }
    }

    final now = _multiset(headRuns);
    final before = _multiset(baselineRuns);

    final added = <String>[];
    final removed = <String>[];
    for (final r in {...now.keys, ...before.keys}) {
      final n = now[r] ?? 0, b = before[r] ?? 0;
      if (n > b) {
        added.add('「$r」多了 ${n - b} 次 —— 现存于:${(headFilesByRun[r] ?? const {}).join(', ')}');
      }
      if (b > n) {
        removed.add('「$r」少了 ${b - n} 次 —— 基线里在:${(baselineFilesByRun[r] ?? const {}).join(', ')}');
      }
    }

    expect(added, isEmpty, reason: '多出来的文案段(Stage 3 不许加字):\n${added.join('\n')}');
    expect(removed, isEmpty, reason: '丢掉的文案段(Stage 3 不许删字):\n${removed.join('\n')}');
  });
}
