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
  // 「档案」本身**不进闸**:「病程档案」是要留的产品名,而 `档案` 作为子串会把它
  // 一起拦下。进闸的是那两个**只可能指容器**的复合词(终审 I6)。
  '档案': '病历', '健康档案': '病历箱', '医疗档案': '病历箱',
  '保险箱': '病历', '今日病历表': '今天代拍的',
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
  // 「认领」这一支整簇收成「取件」。只进**弱闸**(见 [kWeakEnforced] 那段注释):
  // 硬闸扫整行,会把 `ClaimLink` / `medme://claim` / 认领页 这套机制自己的名字
  // (四十来行注释)一起拦下,而那是 global-constraints 明确排除在闸外的那类。
  '认领': '取件码 / 取件链接',
  // 11 确认一份 → 核对
  // 词按 mockup `s1`/`s7` 定:横幅与 pill 都是「还没核对」,行上那对按钮是
  // 「看原件」/「没问题」。
  '待确认': '还没核对', '点开核对并确认': '', '确认无误,归入档案': '没问题', '确认这一份': '没问题',
  // 不属于任何簇,同批改
  // 「数据出口」的落点 Task 17 又挪了一次:「我」首屏不再放导出行(「给医生看」
  // 那颗按钮是唯一的门),导出功能搬进「给医生看」页里,叫「导出文件」。
  '数据出口': '给医生看 → 导出文件', '数据管理': '删掉全部',
  // Task 2 fix round 1(F6):设置版本行旧文案的两个断言短语,已经整块删掉,
  // 没有替代词——留着是防它换个屏幕重新冒出来(这条本身就是那次教训)。
  '本地优先': '', '只保存在你自己的设备上': '',
  // 「应急卡」(屏顶栏)与「急救卡」(入口按钮、mockup `s4`)两个词长期并存——
  // Task 17 统一成入口一直在用的那个:急救卡。
  '应急卡': '急救卡',
};

/// 已经启用的禁词。**每个 Task 只加自己那一屏清干净的词。**
/// 终点是 ux-audit §4 Done 判据②里那条 grep 的全集(见 Task 17)。
const List<String> kEnforced = [
  '数据出口', '数据管理', '本地优先', '只保存在你自己的设备上',
  '待确认', '点开核对并确认', '确认无误,归入档案',
  '识别文本', '文档内容', '识别质量',
  // Task 9:概览整屏解散,这个词最后的落脚处(那个文件里的几行注释)跟着没了。
  // 「最近就诊」现在住在「趋势」里(`trends_screen.dart` 的 `RecentVisitsCard`)。
  '最近归档',
  // Task 12:云的说法收敛成「云端备份 / 云端整理」两件事。「云同步」命中面最宽
  // (StateError 文案 + 一堆注释),一起清干净 —— 留一处,下一个人就会照着它再写一个。
  '云同步', '云端识别', '云备份',
  // Task 13:「保险箱」是内部容器说法(用户可见处一律改「病历箱」或「病历」,
  // 注释与 StateError 文案改「病历箱」);「家属」在授权语境里会和「成员」打架,
  // 统一成「成员」(挑人的名单/切换器)或「家人」(泛指亲属关系的大白话句子)。
  '保险箱', '家属',
  // Task 14:「密钥材料」这一簇收成「口令 + 恢复码」两个物件——不用「密码」,
  // 老人会默认「密码能找回」,而我们不保管这把钥匙,这是最贵的误解。三个词一起
  // 下(「账号密钥」「档案密钥」这类复合词天然被「密钥」这个子串挡住,不必单列)。
  '密码', '密钥', '生成密钥',
  // Task 15:医生那一整套入口说法收成一句。「医生模式」「为病人代建档」是旧的屏
  // 标题/横幅,「今日病历表」是旧的列表标题,「认领码」是旧的交付话术——四个一起下。
  '医生模式', '为病人代建档', '今日病历表', '认领码',
  // 代拍入口的说法今天有三种:doctor_home 的主按钮「为病人代拍」、词表里的
  // 「代拍」、以及 Task 3 新写的那条入口。**全 App 收成一句**:
  //   「我是医生,替病人代拍」
  // 「替病人拍」也关进来 —— 少一个「代」字就又是一种说法。
  '为病人代拍', '替病人拍',
  // Task 17:合拢 —— ia-proposal §6 Done 判据②那条 grep 的其余部分。
  '存档', '归档', '采集',
  // 词表里剩下的对外用词。
  '看病带这个', '就诊单', '转让',
  // 屏顶栏「应急卡」统一成入口一直在用的「急救卡」(ledger 项,详见 kGlossary)。
  '应急卡',
  // 全分支终审:词表没合拢的那几处(闸没坏,是这些词没进来)。
  // I4 一份病历详情屏的屏名(`s8`);I5 代拍那三屏与患者侧同一件事的两个名字;
  // I6 容器词 —— 只关那两个**只可能指容器**的复合词,「病程档案」不受影响。
  '文档详情', '逐份核对', '确认这一份', '健康档案', '医疗档案',
];

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

// ── 弱闸(task-20b Part B)───────────────────────────────────────────────
//
// 「分享」「授权」「导入」**不进 [kEnforced]**:那三个词同时也是 Dart 标识符/
// 关键字里的常见子串(`import '...';` 语句、`Grants` 类名一大堆),整行子串扫
// 会把满仓的普通代码都拦下来,协调人已裁定这三个词排除在硬闸之外(见
// `global-constraints.md`)。但 task-17 复核发现用户可见字符串里仍有一批残留
// (task-17-report.md「Task 20 hand-off」),task-20b Part B 逐条清过一遍之后,
// 补一条**弱闸**防止以后又手滑写回去——只扫「看起来会渲染给用户看」的位置:
// 被引号包住、且不在整行注释或 `debugPrint(...)` 里的字面量。
//
// **这是弱闸,不是精确解析器**:不处理多行拼接字符串里词落在后半段的情况、
// 不处理引号内嵌套转义。宁可偶尔漏报,也不要因为一个粗糙的正则把
// `import 'package:...';` 这类满仓都是的语句也拦下来,变成没人敢改的哑闸。
///
/// 终审 I5 又添一个:「认领」。它和上面三个同病 —— `ClaimLink`、`medme://claim`、
/// 「认领页」是这套机制自己的名字,硬闸扫整行会把四十来行注释一起拦下(而
/// `global-constraints.md` 把「注释里绕不开的普通词」明确排除在硬闸外)。用户可见的
/// 那一面只有「取件码 / 取件链接」,弱闸正好只看引号里的字。旧词 `认领码` 仍留在
/// [kEnforced] 里(它在注释里也没有合法用法)。
const List<String> kWeakEnforced = ['分享', '授权', '导入', '认领'];

/// 已核实的假阳性,弱闸不报:`link_qr_dialog.dart` 的 `shareLabel` 默认参数
/// 从未实际渲染——三个调用方(`account_screen.dart`/`member_detail_screen.dart`/
/// `doctor_claim_link_dialog.dart`)全部覆盖了这个默认值(task-17-report.md 已核实)。
/// 行号 33→35:task-13b(R27)在这个默认参数之前加了两行 import,行号跟着挪。
const Set<String> _weakFalsePositives = {'lib/widgets/link_qr_dialog.dart:35'};

/// 一行「引号里含有目标词」,且不是整行注释、也不是只进开发者日志的 `debugPrint`。
bool _looksUserFacing(String line, String word) {
  final trimmed = line.trimLeft();
  if (trimmed.startsWith('//')) return false; // 整行注释(含 ///)
  if (trimmed.startsWith('debugPrint(')) return false; // 只进系统日志,不进 UI
  return RegExp("['\"][^'\"]*$word[^'\"]*['\"]").hasMatch(line);
}

List<String> scanLibWeak(String word) {
  final hits = <String>[];
  final root = Directory('lib');
  for (final f in root.listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.dart')) continue;
    if (f.path.contains('lib/src/rust/')) continue;
    final lines = f.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final loc = '${f.path}:${i + 1}';
      if (_weakFalsePositives.contains(loc)) continue;
      if (_looksUserFacing(lines[i], word)) hits.add(loc);
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

  for (final word in kWeakEnforced) {
    test('弱闸:lib 里没有把「$word」写进字符串字面量(应改成「${kGlossary[word]}」;标识符/注释不算)', () {
      final hits = scanLibWeak(word);
      expect(hits, isEmpty, reason: '还剩 ${hits.length} 处:\n${hits.join('\n')}');
    });
  }
}
