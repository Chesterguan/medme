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
import 'package:mobile_flutter/screens/emergency_card_screen.dart';
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
  late Future<VisitSummaryDto> _future = _load();

  Future<VisitSummaryDto> _load() => widget.load?.call() ?? viewVisitSummary();

  void _openDoc(int id) {
    // 与病历屏同一条埋点:只报「打开了一份」,不带 id、不带任何内容。
    Analytics.track(AnalyticsEvent.docOpened);
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => DocumentDetailScreen(docId: id)));
  }

  /// 「加一条」。**只有真的存下了才重新拉一次** —— 用户划掉弹层什么也没写时
  /// 白拉一次是浪费,而存了却不拉,他会看着自己刚写的东西没出现(BUG-4)。
  ///
  /// `setState` 必须是**语句块不是箭头**:箭头体会把赋值结果(一个 `Future`)
  /// 当成返回值交出去,`State.setState` 的断言据此在 `markNeedsBuild()` **之前**
  /// 抛 —— `_future` 换了新的却没有任何一次重建被调度。这条由
  /// `test/known_defect_setstate_future_test.dart` 扫源码守着。
  Future<void> _addNote() async {
    final add = widget.onRequestAddNote;
    final saved = add != null
        ? await add(context)
        // 预选中「笔记」,跳过六选一 —— 点这颗按钮时意图已经是「记笔记」
        // (与它取代的浮层同一条理由)。
        : await showManualEntrySheet(context, initialKind: ManualEntryKind.note);
    if (saved != true || !mounted) return;
    final next = _load();
    setState(() {
      _future = next;
    });
    await next;
  }

  /// 固定在底部的主动作 —— **只有这一颗**(`s4`:「真机上这颗按钮固定在底部」)。
  /// 一屏只允许一颗主按钮(规范 §六),诊室里那一下就是把码递过去。
  ///
  /// 跳转在 Task 9 接上(与页内另外三条一起),这一版先把位置和文案摆对。
  Widget _qrBar(MedColors c) => Container(
    padding: const EdgeInsets.fromLTRB(
      MedShape.s4,
      MedShape.s2,
      MedShape.s4,
      MedShape.s2,
    ),
    decoration: BoxDecoration(
      color: c.surface,
      border: Border(top: BorderSide(color: c.line)),
    ),
    child: SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        // Task 9 接上跳转之前这颗是禁用态(灰的)。这一页本身也还没有入口
        // (「病历」首页那颗方块是 Task 5),所以没有用户会先看到它。
        onPressed: null,
        icon: const Icon(Icons.qr_code_2, size: 20),
        label: const Text('出码给医生看'),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('给医生看'),
        // `s4` 标题下面还有一行「张建国,男,61 岁;截至 <今天>」。前半截今天由
        // `VisitSummaryBody` 在正文顶部渲染(`VisitSummaryDto.patient`),
        // 「截至 <今天>」还不存在 —— 两截合并到标题下面是 Task 9/10 的事,
        // 这一版不自己再造一份。
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
          // 推进来直接就是内容,**没有「今天带给医生的」这类抬头**(`s4`)。
          //
          // ⚠️ **正文分块顺序还不是 `s4` 的顺序。** 这里渲染的是今天
          // `VisitSummaryBody` 的既有顺序(我想问医生的 → 我最近的变化 →
          // 医生可能要问的:过敏 + 用药)。`s4` 要的是
          // 过敏 → 在治 → 在吃 → 关键化验 → 检查与手术,过敏在**第一**行,
          // 而且多一整块「检查与手术」—— 那次重排连同各行的迷你折线一起,
          // 归 Task 9/10(Stage 2 内容)。**别照这段注释以为顺序已经对了。**
          //
          // 页脚与底部的分工照 `s4`:「出码给医生看」是主动作,真机上固定在
          // 底部;「打印 / 导出」「急救卡」「代拍」跟着内容滚(否则固定区在
          // 大字号下会把正文挤没 —— ×3.0 时整块直接溢出)。
          //
          // `VisitSummaryBody` 自己就是一个 `ListView`,**不能**再塞进外层
          // `ListView` 的 children(纵向 viewport 拿到无穷高约束,当场炸),
          // 所以那三条是经 `footer` 接进它自己的滚动流里的。
          return Column(
            children: [
              Expanded(
                child: VisitSummaryBody(
                  summary: snap.data!,
                  onOpenDoc: _openDoc,
                  onAddNote: _addNote,
                  // AppBar 上已经写着「给医生看」,正文不再画一次旧名字。
                  showHeading: false,
                  // 「急救卡」这一条现在就接上 —— 概览整屏解散之后它**一个入口
                  // 都不剩**了,而 `s4` 给它的归宿就是这一页。另外两条(打印 /
                  // 导出、代拍)留给 Task 9,那两处各自还要接别的东西。
                  footer: ForDoctorActions(
                    onEmergency: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const EmergencyCardScreen(),
                      ),
                    ),
                  ),
                ),
              ),
              SafeArea(top: false, child: _qrBar(c)),
            ],
          );
        },
      ),
    );
  }
}

/// 接在正文最后、**跟着一起滚**的三条入口(`s4`:固定在底部的只有「出码」那一颗)。
/// **纯 widget,不碰 FFI** —— 这样 `flutter test` 测得到(与 `QuickActions` /
/// `VisitSummaryBody` 同一手法)。
class ForDoctorActions extends StatelessWidget {
  const ForDoctorActions({
    super.key,
    this.onExport,
    this.onEmergency,
    this.onProxy,
  });

  final VoidCallback? onExport;
  final VoidCallback? onEmergency;
  final VoidCallback? onProxy;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 逐字照 `s4`:急救那颗是「急救卡」。
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
