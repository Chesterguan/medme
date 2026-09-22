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
import 'package:mobile_flutter/app_mode.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/screens/document_detail.dart';
import 'package:mobile_flutter/screens/emergency_card_screen.dart';
import 'package:mobile_flutter/screens/export_screen.dart';
import 'package:mobile_flutter/screens/manual_entry_sheet.dart';
import 'package:mobile_flutter/screens/qr_share_screen.dart';
import 'package:mobile_flutter/screens/visit_summary_sheet.dart';
import 'package:mobile_flutter/src/rust/api/vault_projections.dart';
import 'package:mobile_flutter/widgets/brand_surfaces.dart';
import 'package:mobile_flutter/widgets/gloss_tile.dart';
import 'package:mobile_flutter/widgets/med_card.dart';

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

  /// 进代拍。**今天点下去就直接切过去了,不确认**(那道一次性的身份确认在
  /// Task 15 补进代拍首页);这里只负责切模式 —— `AppRoot` 监听同一个 notifier,
  /// 自动换根界面。
  ///
  /// 换根之后还要把导航栈弹回第一层:本屏是 `push` 进来的,而 `AppRoot` 在
  /// `Navigator` **下面**,不弹的话代拍首页被这一页整个盖住 —— 用户按下去
  /// 什么都没变。与 `settings_screen.dart` 的「切换模式」同一条处理。
  Future<void> _enterProxy() async {
    // `where: for_doctor` —— 从「给医生看」那一页的最后一行进来的。它和
    // `settings` 的比,说明代拍的人是本来就在找它,还是逛设置逛到的。
    Analytics.track(AnalyticsEvent.modeSelected, {
      'mode': AppModeKind.doctor.name,
      'where': 'for_doctor',
    });
    Analytics.setContext({'mode': AppModeKind.doctor.name});
    await AppMode.instance.setMode(AppModeKind.doctor);
    if (!mounted) return;
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('给医生看'),
        // `s4` 标题下面还有一行「张建国,男,61 岁;截至 <今天>」。前半截今天由
        // `VisitSummaryBody` 在正文顶部渲染(`VisitSummaryDto.patient`),
        // 「截至 <今天>」**还不存在**,两截也还没合并到标题下面 —— Stage 1 的
        // 接线不做这一条,谁来做谁在这里加,别在正文里再造第二份身份行。
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: c.line),
        ),
      ),
      // 固定在底部的主动作 —— **只有这一颗**(brief §品牌 最后一条:「出码给
      // 医生看」固定底部;渐变预算表 `s4` = 1 颗 `MedPrimaryButton`)。一屏只
      // 允许一颗主按钮(规范 §六),诊室里那一下就是把码递过去。挪进
      // `Scaffold.bottomNavigationBar` 而不是留在正文末尾 —— `s4` 的正文是全
      // app 最长的一屏(12 种药 + 6 个诊断),滚到底才看见主动作等于没有主动作。
      // 出码这条动作不读 `_future`(它是另一条 FFI),放在这一层不必等
      // `VisitSummaryDto` 加载完才出现。
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(
          MedShape.s3,
          0,
          MedShape.s3,
          MedShape.s2,
        ),
        child: MedPrimaryButton(
          label: '出码给医生看',
          icon: Icons.qr_code_2_outlined,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const QrShareScreen()),
          ),
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
          // 归 Stage 2。**别照这段注释以为顺序已经对了。**
          //
          // 页脚与底部的分工照 `s4`:「出码给医生看」是主动作,挪进了
          // `Scaffold.bottomNavigationBar`(见上),真机上固定在底部,内容
          // 再长也在;「导出文件」「急救卡」「代拍」跟着内容滚。
          //
          // `VisitSummaryBody` 自己就是一个 `ListView`,**不能**再塞进外层
          // `ListView` 的 children(纵向 viewport 拿到无穷高约束,当场炸),
          // 所以那三条是经 `footer` 接进它自己的滚动流里的。
          return VisitSummaryBody(
            summary: snap.data!,
            onOpenDoc: _openDoc,
            onAddNote: _addNote,
            // AppBar 上已经写着「给医生看」,正文不再画一次旧名字。
            showHeading: false,
            // 「急救卡」在概览解散之后**一个入口都不剩**了,`s4` 给它的
            // 归宿就是这一页(ia-proposal §7 决定 3)。
            footer: ForDoctorActions(
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
          );
        },
      ),
    );
  }
}

/// 接在正文最后、**跟着一起滚**的三条入口(`s4`:固定在底部的只有「出码」那一颗)。
/// **纯 widget,不碰 FFI** —— 这样 `flutter test` 测得到(与 `HomeTiles` /
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
        // 逐字照 `s4`:急救那颗是「急救卡」。leading 换成光泽图标块(brief
        // §形):导出=中性、急救=警示。
        //
        // 「导出文件」是这一页唯一的次要行,排在固定于底部的「出码」之后——出码
        // 才是诊室里那个主动作(本地、离线、30 秒),这一行是低频、要联网的
        // 交付动作(端到端加密、完整病历含原件),Task 17 从「我」首屏搬过来
        // (那边不再单独放一个导出入口,「给医生看」这颗方块是唯一的门)。
        // 文案刻意不用「分享」二字——见 `test/glossary_guard_test.dart` 顶部
        // 关于这个词的收窄说明。
        ListTile(
          leading: const GlossIconTile(
            icon: Icons.print_outlined,
            category: GlossCategory.neutral,
          ),
          title: const Text('导出文件'),
          subtitle: const Text('报销、留档用的可打印文件'),
          onTap: onExport,
        ),
        ListTile(
          leading: const GlossIconTile(
            icon: Icons.favorite_outline,
            category: GlossCategory.alert,
          ),
          title: const Text('急救卡'),
          onTap: onEmergency,
        ),
        const SizedBox(height: MedShape.s1),
        // 换成 mockup `s4` 的蓝横幅(brief §色:横幅=蓝)——全 App 唯一一句
        // 代拍入口文案:`doctor_home_screen.dart:264` 的主按钮用**同一句**
        // (Task 15)。此前存在的另外几种说法已经被 `test/glossary_guard_test.dart`
        // 的禁词闸关掉,**这条注释里也不许复述它们**,否则闸会扫到自己。
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: MedShape.s3),
          child: MedBanner(
            icon: Icons.photo_camera_outlined,
            title: '我是医生,替病人代拍',
            // `s4` 的副标题,逐字。
            subtitle: '病人不用装 App、不用账号',
            onTap: onProxy,
          ),
        ),
      ],
    );
  }
}
