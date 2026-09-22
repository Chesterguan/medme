import 'dart:async';
import 'dart:io';

import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mobile_flutter/analytics.dart';
import 'package:google_api_availability/google_api_availability.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdfx/pdfx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/cloud_extract.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/import_queue.dart';
import 'package:mobile_flutter/ocr_bridge.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/screens/cloud_extract_ask_sheet.dart';
import 'package:mobile_flutter/screens/import_helpers.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/src/rust/api/vault.dart';
import 'package:mobile_flutter/review_state.dart';
import 'package:mobile_flutter/widgets/app_snack_bar.dart';
import 'package:mobile_flutter/widgets/med_card.dart';

/// 一次导入运行的结果,供调用方判断要不要、往哪儿带用户去核对新东西。
///
/// 「还没核对」是这个产品最重要的一道质量闸门(抽取质量是已知短板,见
/// `review_state.dart`)——但它要用户自己翻到「病历」tab 才看得见。若一次添加
/// 原地刷新、不把用户带过去,这道闸门在那条路径上就对用户不可见:不是 UI
/// 疏漏,是一整套写好的核对机制在这条路上悄悄失效。这个结果类型就是让调用方
/// 接住「这次是不是真的有新东西要核对」,自己决定带不带用户过去、去哪儿。
class ImportRunResult {
  const ImportRunResult(this.newDocumentIds, {this.queuedCount = 0});

  /// 本次真正新入库的文档 id——与 [ReviewState.markPending] 标记的是同一批。
  /// 去重、失败的文档不落库,不在这里面;空列表 = 没有新东西要核对。
  ///
  /// **走后台队列的导入(现在患者模式的全部导入)这里恒为空**:添加一结束就返回,
  /// 那时一份都还没识别完,自然也没有 id。要不要带用户去核对由 [queuedCount] 说了
  /// 算。医生代拍那条路不走队列,仍然按 id 走。
  final List<int> newDocumentIds;

  /// 这次**排进队列**的份数(见 `import_queue.enqueueImport`)。
  final int queuedCount;

  bool get hasNewDocs => newDocumentIds.isNotEmpty;
}

/// 导入结果该不该带用户去复核、去哪复核——纯判断,不碰 `Navigator`/`BuildContext`,
/// 方便直接单测(见 `test/import_review_navigation_test.dart`)。实际跳转该怎么
/// 导航(`push` 什么、会不会动底部 tab 状态)交给调用方自己决定,这里不管 UI。
enum ImportReviewDestination {
  /// 没有新文档——原地不动。跳到一个空的还没核对列表比不跳更糟。
  none,

  /// 恰好一份新文档——直接进它的详情最直接,复核动作就在那儿。
  singleDocument,

  /// 多份新文档——「病历」tab 置顶的「还没核对」节已经把它们聚好了,不用另拼一份列表。
  archive,
}

/// [result] 为 `null` 覆盖「用户在选择表/原生选择器里取消」与「context 在添加
/// 过程中失效」两种情况(`runImport` / `showImportSheet` 在这些分支上返回
/// `null`)——语义上与「有结果但没有新文档」一样:都不该跳。
///
/// ⚠️ **概览整屏解散后(Task 9)暂时没有生产调用方**——「病历」tab 的「添加」
/// 排进后台队列,靠「还没核对」横幅接人,不再当场判断跳去哪。这条纯判断逻辑
/// 保留:哪天需要「添加完直接带去复核」这类跳转,直接量这个结果(见
/// `test/import_review_navigation_test.dart`)。
ImportReviewDestination reviewDestinationFor(ImportRunResult? result) {
  if (result == null) return ImportReviewDestination.none;
  // 排进了后台队列 → 一律去档案:那几行「识别中」和识别完长出来的文档都在那儿,
  // 置顶的「还没核对」节也在那儿。此刻还没有任何一份识别完,谈不上"进哪一份的详情"。
  if (result.queuedCount > 0) return ImportReviewDestination.archive;
  if (!result.hasNewDocs) return ImportReviewDestination.none;
  return result.newDocumentIds.length == 1
      ? ImportReviewDestination.singleDocument
      : ImportReviewDestination.archive;
}

/// 「病历」tab 那颗「添加」触发的添加流程:弹三选一(拍照 / 相册 / 选文件),
/// 选定后**把这一批交给后台队列就返回**(见 `import_queue.dart`)——识别不再把用户
/// 钉在一个模态进度框里等,「病历」tab 顶部那几行「识别中」替代了它,每识别完
/// 一份,那份文档就自己长到时间线上。
///
/// 这一层只管**拉起原生取件器**和**问一句合不合并**;OCR、落库、补页、
/// 云抽取全在队列那边。医疗判断全在 Rust core,这里只搬字节 + 调 FFI。
///
/// 返回值见 [ImportRunResult]:取消/未选文件返回 `null`,否则带上这次排了几份。
Future<ImportRunResult?> showImportSheet(BuildContext context) async {
  final choice = await showModalBottomSheet<ImportChoice>(
    context: context,
    showDragHandle: true,
    builder: (context) => const SafeArea(child: AddSheetBody()),
  );
  if (choice == null || !context.mounted) return null;
  return runImport(context, choice);
}

/// [showImportSheet] 的正文(mockup `s6`)。fix round 1(task-14-review
/// Important):从 `builder:` 里原样搬出来(纯搬家,内容一字未改)——只有
/// 提成一个公开 widget,视觉溢出矩阵才 pump 得到这一屏,而不是只测到
/// `CloudExtractAskBody` 一家。**纯 widget,不碰 `Navigator`**——三个
/// `_SheetTile.onTap` 各自 `Navigator.of(context).pop(choice)`,这个 widget
/// 本身不需要知道选完之后去哪儿。
class AddSheetBody extends StatelessWidget {
  const AddSheetBody({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            MedShape.s4,
            4,
            MedShape.s4,
            MedShape.s1,
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '添加病历',
              style: MedType.subtitle.copyWith(color: MedColors.of(context).ink),
            ),
          ),
        ),
        _SheetTile(
          icon: Icons.photo_camera_outlined,
          title: '拍照',
          subtitle: '对着化验单、处方拍一张,自动识别上面的文字',
          choice: ImportChoice.camera,
          // 首页快捷操作原先专门有一颗「拍照」,直达这三选一里的这一项;
          // 改版后那一排快捷操作整个没了(今天「病历」首页只剩「添加」与
          // 「给医生看」两颗方块),拍照要多经一次这个选择表才能到达。视觉上
          // 做成主选项(蓝底块 + `highlighted`)抵消这多出来的一次点击——它
          // 仍然是最高频的动作,不该因为少了专属入口就变得不显眼。
          primary: true,
        ),
        _SheetTile(
          icon: Icons.photo_library_outlined,
          title: '从相册选',
          subtitle: '选一张或多张已经拍好的病历照片',
          choice: ImportChoice.gallery,
        ),
        _SheetTile(
          icon: Icons.folder_open_outlined,
          title: '选择文件',
          subtitle: 'PDF、图片、TXT',
          choice: ImportChoice.files,
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// 跳过三选一,**直接**走某一种取件来源。
///
/// 从 [showImportSheet] 里原样切出来的后半段(逻辑一字未改)——留着这一刀是为了
/// 让将来任何一颗「直接拍照」式的快捷入口都能跳过三选一,不用重新拼一遍后半段
/// 逻辑。⚠️ 今天**只有** [showImportSheet] 一个调用方(概览页那一排快捷操作已在
/// Task 9 随整屏解散,「病历」首页只剩「添加」与「给医生看」两颗方块,都不是
/// 直接拍照的捷径)——这条切分暂时没有第二个用武之地,但保留成本低,拆开来
/// 反而要在两处各写一遍前置等待与埋点。
///
/// 前面那 350ms 的等待对直接调用**同样必要**:调用方多半也是从一个 bottom sheet
/// 或菜单里点过来的,原生扫描器一样会被正在退场的浮层挡下。
///
/// 返回值见 [ImportRunResult]:取消/未选到任何文件返回 `null`,否则是这次运行
/// 的结果(可能没有新文档——全部失败或全部重复)。
Future<ImportRunResult?> runImport(
  BuildContext context,
  ImportChoice choice,
) async {
  // 等 bottom sheet 的关闭动画播完再拉起原生取件器。文档扫描器
  // (VNDocumentCameraViewController)靠 rootViewController.present 弹出;若 sheet
  // 尚未完全消失,present 会被正在退场的 sheet 挡下、静默失败,method channel 永不
  // 回调 —— 表现就是「点了没反应」。ImagePicker 内部自己处理了这个时序,这个扫描器
  // 插件没有,所以在这里补一帧等待。
  await Future<void>.delayed(const Duration(milliseconds: 350));
  if (!context.mounted) return null;

  // 屏上探针的出口。**在任何 await 之前同步取出**,之后就不再碰 context ——
  // 添加期间用户可能把这一屏推走,而 `ScaffoldMessengerState` 自己知道有没有 mounted。
  final probe = ScaffoldMessenger.of(context);

  final List<PendingImport> items;
  try {
    items = await pickImportItems(choice, probe: probe);
  } catch (e) {
    // 兜底。[pickImportItems] 内部每个分支都已自己 catch,所以这里理论上不可达 ——
    // 但「理论上不可达」正是前五版每次都栽的地方:一个漏网的异常从这里飘走,
    // 上面 `await` 的调用方什么都不做,屏上就是「点了没反应」。
    debugPrint('[import] 添加环节未捕获异常: $e');
    _report(probe, choice, ImportCaptureIssue.unknown, '添加没能开始:$e');
    return null;
  }
  if (items.isEmpty || !context.mounted) return null;

  // 第一次添加病历时问一次「云端整理」(ia-proposal §7 决定 5)。放在这里、
  // 而不是拉起相机之前:问的是「刚刚这张照片要不要送云端」,手上有东西的时候
  // 这句话才成立。一次 `runImport` 调用就是一次「run」——排在 `_runImport` 之前、
  // 每次运行只问这一次,不会跟着 `items` 里的每一份文档重复问。
  if (shouldAskCloudExtract(
    loggedIn: AccountSession.instance.loggedIn.value,
    asked: await loadCloudExtractAsked(),
  )) {
    if (!context.mounted) return null;
    await showCloudExtractAskSheet(context);
  }
  if (!context.mounted) return null;

  return _runImport(context, items, choice);
}

/// 添加来源:拍照(含文档扫描器)/ 从相册选 / 选择文件。`public`——除了本文件的
/// [showImportSheet],「医生代拍」临时会话流程(`screens/doctor/proxy_intake_flow.dart`)
/// 也复用 [pickImportItems] 拿取件入口(自己另起一个只含「拍照/选择文件」的选择
/// 表,不复用 `showImportSheet` 的三选一 UI)。
enum ImportChoice { camera, gallery, files }

/// 按 [choice] 走对应的原生取件器,返回待导入项(用户取消为空列表)。**纯取件,
/// 不碰 OCR/落库**——OCR 识别出来的文字、往哪个病历箱落库,都由调用方在拿到
/// [PendingImport] 列表后自己决定(见 [showImportSheet] 与
/// `proxy_intake_flow.dart` 两个不同的下游处理)。
///
/// **本函数不再向外抛异常。** 每个分支都自己 catch,失败一律「屏上说清 + 分类
/// 埋点 + 返回空」——因为这条链路上的每一种失败,在 UI 上都长得一模一样(什么都没
/// 发生),不主动说就只能靠猜。[probe] 是屏上探针的出口(`ScaffoldMessenger`),
/// 调用方在进入本函数**之前**同步取好;不传就只剩埋点和 `debugPrint`。
Future<List<PendingImport>> pickImportItems(
  ImportChoice choice, {
  ScaffoldMessengerState? probe,
}) async {
  switch (choice) {
    case ImportChoice.camera:
      // 文档扫描器(iOS VisionKit / 安卓 ML Kit Document Scanner)自动画框 + 透视
      // 校正,拿到已拉正的图 —— 斜着拍的表格变回横平竖直,OCR 才拼得回整行。
      //
      // **但安卓的 ML Kit 扫描器依赖 Google Play 服务(GMS)**:模型/UI 是 GMS 按需
      // 下载的模块。没有 GMS 的国产机(华为纯 HMS / 墙了 Google)上它起不来,cunning
      // 会转去自己的 fallback 裁剪器,而那个用设备相机、需要我们没声明的 CAMERA 权限
      // → 相机直接打不开。所以**开拍前先检测 GMS**:有 → 用 ML Kit 扫描器(自动
      // 拉正,体验好);无 → 退普通系统相机(image_picker 走系统相机 app 的 intent,
      // 不需要 CAMERA 权限,任何机器都能开)。歪拍质量由下游 OCR 的整页转正 + 切片
      // 兜底,拍照本身不再被 GMS 卡死。iOS 恒用 VisionKit(不涉及 GMS)。
      //
      // ⚠️ 这个检测此前是**裸 await**:`google_api_availability` 走 method channel,
      // 在 GMS 被裁掉/被停用的机器上它自己就可能抛 PlatformException,而异常从这里
      // 一路飘到调用方的 `await`,屏上什么都不显示 —— 又是一个「点了没反应」。
      // 现在检测失败**当作没有 GMS 处置**(与「检测到没有」同一条路),并在屏上说明。
      var useScanner = !Platform.isAndroid;
      if (Platform.isAndroid) {
        try {
          useScanner =
              (await GoogleApiAvailability.instance
                  .checkGooglePlayServicesAvailability()) ==
              GooglePlayServicesAvailability.success;
        } catch (e) {
          debugPrint('[import] GMS 检测失败,按无 GMS 处理: $e');
          _report(
            probe,
            choice,
            ImportCaptureIssue.gmsCheckThrew,
            '检测 Google Play 服务时出错,已改用普通相机:$e',
          );
          useScanner = false;
        }
      }
      // ⚠️ **GMS 在场 ≠ 文档扫描模块在场。** 上面那个检测只回答「这台机器有没有
      // Google Play 服务」,而 ML Kit 文档扫描器的界面(`mlkit.docscan.ui`)是 GMS
      // 用 Chimera **按需下载**的动态模块 —— 检测通过、模块却拉不到,是国内最常见的
      // 那一种(GMS 装着,连不上 Google 的分发服务器)。
      //
      // 2026-08-04 在 Pixel_7 AVD(Android 17,google_apis 镜像、无 Play 商店、
      // docscan 模块从未缓存)实测复现,logcat 铁证:
      //   W/ChimeraProxyRslvr: No registered Chimera impl for …DocumentScanningActivity
      //   E/DynamicModuleDownloader: Zapp module request failed: null
      // 此时 GMS **自己**弹一页英文的 “Something went wrong / Try again later”,
      // 占据前台 20 秒以上,用户点 Cancel 后我们才拿到结果。
      //
      // 这一段就是为了**不让用户第二次看见那一页**:一旦我们确认过这台机器上的
      // 扫描模块拉不到([_ScannerAvailability]),以后拍照直接走普通系统相机。
      //
      // `Platform.isAndroid` 是**必要的**,不只是省一次读盘:iOS 的 VisionKit 是系统
      // 内置的,没有模块下载这回事,这条路在 iOS 上一步都不该走。
      if (Platform.isAndroid &&
          useScanner &&
          await _ScannerAvailability.isKnownUnavailable()) {
        useScanner = false;
        // 不打扰用户(detail 为 null):这是**静默走通**的一条路,不是故障。
        _report(
          probe,
          choice,
          ImportCaptureIssue.scannerSkippedUnavailable,
          null,
        );
      }
      if (useScanner) {
        // 不要给交互式扫描器加 wall-clock 超时:VisionKit 是多页扫描器,用户拍完一页
        // 后靠右上角「保存」结束,合理耗时远超十几秒(踩过:12s timeout 会在用户还在
        // 扫时提前抛出 → 落回退分支叠一个相机 → 点保存「不往后执行」)。取消由插件
        // 返回空处理。扫描器真抛异常(设备不支持等)也落到下面的普通相机。
        //
        // 这条教训仍然成立,**下面那个看门狗没有违反它**:它守的不是「扫完」,是
        // 「扫描器起没起来」,而且判据不是钟表 —— 见 [_scannerFailedToLaunch]。
        try {
          final scan = CunningDocumentScanner.getPictures(
            scannerSource: ScannerSource.camera,
          );
          if (await _scannerFailedToLaunch(scan)) {
            // 扫描器根本没起来。降级到普通相机 —— 注意这里**没有 return**,直接落到
            // 下面那段,与「检测到无 GMS」走同一条路。
            debugPrint(
              '[import] 文档扫描器 ${_kScannerLaunchWatchdog.inSeconds}s 未启动,回退普通拍照',
            );
            _report(
              probe,
              choice,
              ImportCaptureIssue.scannerStalled,
              '文档扫描器 ${_kScannerLaunchWatchdog.inSeconds} 秒没有打开'
              '(常见原因:Google Play 服务下载不到扫描模块),已改用普通相机',
            );
          } else {
            // 走到这里说明扫描器要么已经返回了,要么已经把自己的界面顶到了前台
            // (用户正在扫)—— 后者**不设任何时限**,老老实实等。
            final paths = await scan;
            if (paths == null || paths.isEmpty) {
              // ⚠️ 「用户取消」与「静默失败」在这里分家。插件的返回语义**两个平台
              // 恰好是反的**(2.6.0 源码实证):
              //   安卓 `RESULT_CANCELED` → `success(emptyList())` → 空列表 = 取消;
              //         ML Kit 回了结果但 `pages` 为 null → null = 一页都没有 = 静默失败。
              //   iOS  `documentCameraViewControllerDidCancel` → `nil` → null = 取消;
              //         扫完 0 页 → `processSelectedImages([])` → 空列表 = 静默失败。
              // 此前两者一律 `return const []`,于是「点拍照没反应」的分子分母糊在
              // 一起,永远算不出真实占比。
              final cancelled = Platform.isAndroid
                  ? paths != null
                  : paths == null;
              // ⚠️⚠️ **安卓上「用户取消」和「模块拉不到」是同一个返回值。**
              //
              // 2026-08-04 实测(见上文 AVD 复现)插件源码路径已经走通对齐:
              //   GMS 的英文报错页 → 用户点 Cancel → `RESULT_CANCELED`
              //   → 插件 `success(emptyList())` → 这里拿到**空列表**。
              // 而用户在真扫描器里按返回,走的是**一模一样**的那三步。
              // 也就是说:事后无法区分。此前这里把两者都算作「取消」→ 不打扰用户
              // → 屏上零提示 → 就是用户报的「回到主界面,什么都没发生」。
              //
              // 区分不了就别装作能区分。给一个**不打扰的补救入口**,让用户的选择
              // 来分流:真取消的人不会去点「用普通相机」,点了的人就是没拍成的人。
              // 这一下点击同时也是我们唯一拿得到的「模块不可用」信号 —— 据此记住
              // 这台机器,下次连那页英文都不再出现。
              final recover =
                  Platform.isAndroid &&
                  cancelled &&
                  await _offerPlainCamera(probe);
              if (!recover) {
                _report(
                  probe,
                  choice,
                  cancelled
                      ? ImportCaptureIssue.userCancelled
                      : ImportCaptureIssue.emptyResult,
                  // 取消是正常操作,**不打扰用户**;静默失败才是要说出来的那一种。
                  cancelled ? null : '扫描器没有返回任何一页(既不是取消,也没有报错)',
                );
                return const [];
              }
              await _ScannerAvailability.markUnavailable();
              _report(
                probe,
                choice,
                ImportCaptureIssue.scannerModuleUnavailable,
                null, // 用户刚点过按钮,知道自己在干什么,不用再弹一条。
              );
              // **这里没有 return** —— 直接落到下面的普通相机,与「检测到无 GMS」
              // 走同一条路。
            } else {
              return [
                for (final p in paths)
                  PendingImport(
                    name: p.split('/').last,
                    path: p,
                    isImage: true,
                  ),
              ];
            }
          }
        } catch (e) {
          debugPrint('[import] 文档扫描器不可用,回退普通拍照: $e');
          _report(
            probe,
            choice,
            ImportCaptureIssue.scannerThrew,
            '文档扫描器不可用,已改用普通相机:$e',
          );
        }
      }
      try {
        final file = await ImagePicker().pickImage(source: ImageSource.camera);
        if (file == null) {
          // image_picker 的语义比扫描器干净:取消恒为 null,失败恒是抛异常。
          _report(probe, choice, ImportCaptureIssue.userCancelled, null);
          return const [];
        }
        return [PendingImport(name: file.name, path: file.path, isImage: true)];
      } catch (e) {
        // 此前也是**裸 await**。相机权限被拒、系统相机 app 被禁用都从这里抛
        // PlatformException —— 而这正是最可能真实发生的那一类,却完全不可见。
        debugPrint('[import] 普通相机打不开: $e');
        _report(probe, choice, ImportCaptureIssue.pickerThrew, '打不开相机:$e');
        return const [];
      }
    case ImportChoice.gallery:
      try {
        final files = await ImagePicker().pickMultiImage();
        if (files.isEmpty) {
          _report(probe, choice, ImportCaptureIssue.userCancelled, null);
          return const [];
        }
        return [
          for (final f in files)
            PendingImport(name: f.name, path: f.path, isImage: true),
        ];
      } catch (e) {
        debugPrint('[import] 相册打不开: $e');
        _report(probe, choice, ImportCaptureIssue.pickerThrew, '打不开相册:$e');
        return const [];
      }
    case ImportChoice.files:
      try {
        final result = await FilePicker.platform.pickFiles(
          allowMultiple: true,
          type: FileType.custom,
          allowedExtensions: [
            'pdf',
            'txt',
            'png',
            'jpg',
            'jpeg',
            'tiff',
            'heic',
          ],
        );
        if (result == null) {
          _report(probe, choice, ImportCaptureIssue.userCancelled, null);
          return const [];
        }
        final picked = [
          for (final f in result.files)
            if (f.path != null)
              PendingImport(
                name: f.name,
                path: f.path!,
                isImage: isImageName(f.name),
              ),
        ];
        // 选了文件却一个 path 都没拿到(云盘上没下载下来的文件就是这样)——
        // 用户明明选了东西,屏上却毫无反应。这是静默失败,不是取消。
        if (picked.isEmpty && result.files.isNotEmpty) {
          _report(
            probe,
            choice,
            ImportCaptureIssue.emptyResult,
            '选中的文件在本机上取不到(可能还没从云端下载完)',
          );
        }
        return picked;
      } catch (e) {
        debugPrint('[import] 文件选择器打不开: $e');
        _report(probe, choice, ImportCaptureIssue.pickerThrew, '打不开文件选择器:$e');
        return const [];
      }
  }
}

/// 「启动到扫描器界面出现」这一段的看门狗时限。**只管启动,不管扫描。**
const Duration _kScannerLaunchWatchdog = Duration(seconds: 5);

/// 扫描器**是不是压根没起来**。`true` = 该降级了。
///
/// ## 为什么这不是 v24 那个 12 秒 wall-clock
///
/// v24 的错在于用「过了多久」推断「出没出事」,于是用户还在多页扫描时被提前打断
/// (→ 落回退分支叠一个相机 → 点保存不往后执行)。这里的判据**不是钟表,是
/// 应用生命周期**:
///
///   安卓的 ML Kit 扫描器是**另一个 Activity**(`startIntentSenderForResult`)。
///   它只要真的起来了,本 Activity 必然离开 `resumed`。所以「5 秒了,结果还没回来,
///   而 App 还稳稳停在前台 resumed」——这只可能意味着**没有任何原生界面被拉起来**,
///   不可能是「用户正在扫」(用户正在扫时,前台根本不是我们)。
///
/// ## ⚠️ 它**盖不住**用户报的那个病因 —— 别再指望它
///
/// 这个看门狗当初是按「`getStartScanIntent` 的 Task 永不回调 → future 永久挂起」
/// 设计的。2026-08-04 在 AVD 上实测,那个前提**是错的**:
///
///   1. `getStartScanIntent` **成功**了,`startIntentSenderForResult` 也真的把
///      `com.google.android.gms/.mlkit.docscan.ui.DocumentScanningActivity` 拉了起来
///      (所以插件自己的 `addOnFailureListener` → 备用裁剪器**从来没有触发过**);
///   2. 失败发生在 GMS **内部**:Chimera 找不到该 Activity 的实现、模块又下载不到;
///   3. 于是 **GMS 的 `ModuleDownloadActivity` 顶在前台**弹英文报错页,20 秒以上;
///   4. 用户点 Cancel → `RESULT_CANCELED` → 空列表。全程**没有任何挂起**。
///
/// 第 3 步正好打死这个判据:那 5 秒里前台是 GMS,**我们不是 `resumed`** → 本函数
/// 返回 `false`(「一切正常,继续等」)→ 一次都不会触发。原推理漏了第三种状态:
/// 起来的不是扫描器,是 GMS 的错误页。
///
/// 真正接住这个病因的是**空结果那一段**(补救入口 + [_ScannerAvailability] 记忆),
/// 不是这里。保留本函数只作最后兜底:万一真有设备卡在「什么原生界面都没起来」,
/// 它还能救一次;而它的判据本身没有误伤风险,留着不亏。
///
/// ## 只在安卓武装
///
/// iOS 的 VisionKit 是**同进程内 present 的 view controller**,前台一直是我们自己,
/// `resumed` 不会变 —— 这个判据在 iOS 上恒为「没起来」,会误伤。而 iOS 也根本没有
/// 模块下载这回事(VisionKit 是系统内置)。所以 iOS 上一秒都不等,行为一字不变。
Future<bool> _scannerFailedToLaunch(Future<List<String>?> scan) {
  if (!Platform.isAndroid) return Future<bool>.value(false);
  return Future.any<bool>([
    // 扫描器先返回(成功/取消/抛错)→ 没卡住。**成功路径不会因此多等一毫秒。**
    scan.then<bool>((_) => false, onError: (_) => false),
    Future<void>.delayed(_kScannerLaunchWatchdog).then((_) {
      // `lifecycleState` 在极早期可能是 null。读不到就**不判它有罪** ——
      // 宁可维持现状(继续等),也不能凭猜测把用户的扫描打断。
      return WidgetsBinding.instance.lifecycleState ==
          AppLifecycleState.resumed;
    }),
  ]);
}

/// 扫描器回了空之后的**补救入口**:屏上问一句,愿不愿意改用普通相机。
/// 返回 `true` = 用户点了那个按钮。
///
/// 为什么是 SnackBar 而不是对话框:安卓上「用户主动取消」也会走到这里(两者返回值
/// 完全相同,见调用点),而**取消是正常操作,不该被一个模态框拦住**。SnackBar 不挡
/// 操作、8 秒自己消失,真取消的人可以完全无视它。
///
/// 用户这一下点击是我们唯一能拿到的「扫描器没打开」信号 —— 插件 API 给不出来。
Future<bool> _offerPlainCamera(ScaffoldMessengerState? probe) async {
  if (probe == null || !probe.mounted) return false;
  // 前面可能还挂着别的探针提示,先收掉,否则这条要排队等它,用户早走了。
  probe.hideCurrentSnackBar();
  final controller = probe.showSnackBar(
    appSnackBar(
      content: const Text('没有拍到照片。如果刚才扫描器没能打开,可以改用普通相机。'),
      duration: const Duration(seconds: 8),
      behavior: SnackBarBehavior.floating,
      // 点击动作本身不做事,分流靠下面的 `closed` 原因判断。
      action: SnackBarAction(label: '用普通相机', onPressed: () {}),
    ),
  );
  return await controller.closed == SnackBarClosedReason.action;
}

/// 「这台机器上的 ML Kit 文档扫描模块拉不拉得到」的**记忆**。
///
/// 存在的唯一理由:让用户**最多只看见一次** GMS 那页英文报错。模块拉不到是设备/
/// 网络环境决定的(国内连不上 Google 的模块分发),不是偶发 —— 确认过一次,以后
/// 每次拍照都该直接走普通系统相机。
///
/// **只写不删**:没有自动复位。写入只发生在用户亲手点了「用普通相机」之后,代价是
/// 万一某天 GMS 恢复了,这台机器也不会自己切回自动裁边的扫描器 —— 换来的是那页
/// 英文再也不会出现。对拿它当病历工具的人来说,这笔买卖划算:自动拉正只是锦上添花
/// (歪拍由下游 OCR 的整页转正 + 切片兜底),拍不成照片才是致命的。
abstract final class _ScannerAvailability {
  static const _key = 'scanner_mlkit_module_unavailable';

  static Future<bool> isKnownUnavailable() async {
    try {
      return (await SharedPreferences.getInstance()).getBool(_key) ?? false;
    } catch (e) {
      // 存储读不到就**当作可用**(维持现状),绝不因为一次读盘失败就把好体验砍掉。
      debugPrint('[import] 读扫描器可用性记忆失败,按可用处理: $e');
      return false;
    }
  }

  static Future<void> markUnavailable() async {
    try {
      await (await SharedPreferences.getInstance()).setBool(_key, true);
    } catch (e) {
      // 记不住只是下次再看一遍那页英文,不影响这一次的拍照,安静放弃。
      debugPrint('[import] 记录扫描器不可用失败: $e');
    }
  }
}

/// 屏上探针 + 分类埋点。**一个失败分支一行调用**,这是本次改动的全部产出形式。
///
/// 「屏上探针」是 2026-07-21 那次(相机权限,五版才修对)唯一奏效的手法:真机读不到
/// 日志(工具都要 USB 有线,用户无线连),于是让 App 把状态弹成 SnackBar,用户点一次
/// 就一击定位。见 `docs/log/2026-07-18-qr-share-security-and-community-prep.md` 的追记。
/// 这里把那一招从「临时诊断构建」固化成常驻能力。
///
/// ## 两条数据走两条路,绝不混
///
/// - [detail] 是**给人看的**,含异常字符串,只进 SnackBar 和 `debugPrint`,**不出设备**。
///   异常文本里常带文件名和绝对路径,那是病历内容。传 `null` 表示这一类不值得打扰用户
///   (例如用户主动取消)。
/// - [issue] 是**给后台看的**,只有枚举名一个词,进埋点。
void _report(
  ScaffoldMessengerState? probe,
  ImportChoice source,
  ImportCaptureIssue issue,
  String? detail,
) {
  Analytics.track(issue.event, {
    // 注意:这里的 `source` 是**取件方式**(camera/gallery/files),与 `doc_import_*`
    // 的 `source`(那里代拍会报 `proxy`)口径不同 —— 坏掉的是哪种取件方式才是这条
    // 事件要回答的。个人模式 vs 代拍由会话上下文的 `mode` 切开,不占这个字段。
    'source': source.name,
    'reason': issue.name,
  });
  if (detail == null) return;
  // 分析失败绝不影响功能,屏上探针同理:messenger 已经不在树上就安静放弃。
  if (probe == null || !probe.mounted) return;
  probe.showSnackBar(
    appSnackBar(
      content: Text(detail),
      duration: const Duration(seconds: 8),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

Future<ImportRunResult> _runImport(
  BuildContext context,
  List<PendingImport> items,
  ImportChoice source,
) async {
  // 「合并成一份」**问在识别之前**。改造前它问在整批识别完之后 —— 那时用户还被
  // 一个模态进度框钉在原地,所以问得到。识别搬去后台之后人早就走了,只剩两条路:
  // 要么让队列跑到一半再弹一个框(要多一套「识别中 N/M」的等待态,而且会在用户
  // 正在别的屏上操作时突然打断他),要么在他还站在这儿的时候问掉。选后者:
  // **状态最少**(没有等待态、没有中途打断),代价是万一这几张里有重复/失败,
  // 实际能合并的份数会少于问的时候说的那个数 —— 队列在收尾时按真正入库的照片
  // 份数再判一次(`imageDocIds.length >= 2`),少于两份就不合并。
  final imageCount = items.where((i) => i.isImage).length;
  var mergePhotos = false;
  if (shouldOfferPhotoMerge(imageCount) && context.mounted) {
    mergePhotos = await askPhotoMerge(context, imageCount);
  }

  // 落库那一刻的成员与箱子,就地捕获交给队列 —— 整批都认它们(见
  // `import_queue._Batch`)。根路径拿不到就只能放弃这一批:没有它,后台跑到一半
  // 用户切了成员/医生切去代拍,这几张就会写进**别人的**箱子。
  final String root;
  try {
    root = await currentVaultRoot();
  } catch (e) {
    debugPrint('[import] 读不到当前病历箱根目录,这一批没有排队: $e');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        appSnackBar(content: const Text('病历还没打开,这次没能添加')),
      );
    }
    return const ImportRunResult([]);
  }

  final queued = enqueueImport(
    items: items,
    profile: ProfileManager.instance.current,
    vaultRoot: root,
    source: source,
    mergePhotos: mergePhotos,
  );
  return ImportRunResult(const [], queuedCount: queued);
}

/// 「要合并成一份吗?」这一问 —— **只问,不合并**:真正调 `mergePhotosIntoDocument`
/// 的是后台队列(`import_queue._mergeBatchPhotos`),因为那时候这几张才刚识别完、
/// 有了文档 id,而用户早就走了。
///
/// **为什么每次都问,不自动合并**:一批拍进来的照片不保证真的是同一份文件的
/// 连续页——顺手把上次剩的一张也扫进来、或者一次选了两份不同的化验单,都是
/// 会发生的真实场景。合并是不可逆操作(拆开必须重新导入单张照片,见
/// `pipeline::merge_documents_into_pdf` 文档注释),错误合并两份不相干的病历
/// 且用户没注意到,后果比多问一次、多点一下「分开保存」严重得多——所以交给
/// 用户自己确认,不替 TA 猜。
///
/// 返回合并出的新文档 id;用户选「分开保存」或合并失败都返回 `null`——两种
/// 情况下原来的文档都原样保留(合并失败时的这条保证来自 Rust 侧
/// `merge_documents_into_pdf` 的顺序保证:任何校验/解码失败都发生在删除任何
/// 原文档之前)。
///
/// **合并成功时也不许丢东西**:每张照片已经识别出来的文字由
/// `merge_documents_into_pdf` 逐页带到合并出的这份上(否则原文档一墓碑,
/// `ocr_result` 就跟着没了——2026-09-15 冒烟里 2135 字一次点击归零);云抽取
/// 由调用方改排到新文档上(见 [pendingForMergedDocument])。
Future<bool> askPhotoMerge(BuildContext context, int photoCount) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) {
      final c = MedColors.of(context);
      return AlertDialog(
        title: const Text('要合并成一份吗?'),
        content: Text(
          '刚才这 $photoCount 张,如果是同一份病历的连续页,可以合并'
          '成一份多页文档,时间线上只显示一条。原始照片仍然保留,已经识别出的'
          '文字也会一并带进合并后的这一份,云端整理重新跑一次。\n\n'
          '合并不可撤销:要拆开得重新添加这几张照片。',
          style: MedType.body.copyWith(color: c.ink2),
        ),
        // ⚠️ 顺序是**故意**这样的:主按钮(右下角)必须是「分开保存」。这一问
        // 紧跟在导入结果弹窗后面,那一个的「知道了」也是右下角的 FilledButton
        // —— 两次点在同一个位置,第二次就被合并弹窗接住了(2026-09-15 冒烟里
        // 真的这么误触了一次)。误触落在「分开保存」上什么都不会发生;落在
        // 「合并成一份」上则是一次不可撤销的操作。
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('合并成一份'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(false),
            style: FilledButton.styleFrom(
              backgroundColor: c.sealInk,
              foregroundColor: c.surface,
            ),
            child: const Text('分开保存'),
          ),
        ],
      );
    },
  );
  return confirmed == true;
}

/// 该不该在导入完成后主动问「是否合并成一份」——纯判断,方便单测。至少 2 张
/// 这次一起入库的照片才问;1 张没有「合并」这回事,0 张（全失败/全部非图片）
/// 更谈不上。
bool shouldOfferPhotoMerge(int imageDocCount) => imageDocCount >= 2;

/// 按页渲染 + OCR 的注入点(测试替身用)。生产实现是 [_ocrScannedPdfPages]。
typedef PdfPageOcr =
    Future<Map<int, OcrResult>> Function(String path, List<int> pageNumbers);

/// 逐页回填文本的注入点(测试替身用)。生产实现是 `vault.dart` 的
/// [backfillPdfText]。
///
/// `documentId` 写 `int` 而不是 FRB 生成签名里的 `PlatformInt64`:后者只在
/// `flutter_rust_bridge_for_generated.dart`(标了 internal 的生成侧入口)里,
/// 应用代码不该 import 它;而这支 app 只发 iOS/安卓,在那儿
/// `PlatformInt64 == int`(web 上才是 BigInt,本项目不发 web)。
typedef PdfTextBackfill =
    Future<void> Function({
      required int documentId,
      required int pageNo,
      required String text,
      required double confidence,
    });

Future<void> _defaultBackfill({
  required int documentId,
  required int pageNo,
  required String text,
  required double confidence,
}) => backfillPdfText(
  documentId: documentId,
  pageNo: pageNo,
  text: text,
  confidence: confidence,
);

/// 把 `outcome.pagesWithoutText` 点名的那些页在端上补 OCR 回填,返回**补完之后
/// 依然没有文本**的页数(即调用方要交给 [rowForOutcome] 的 `stillMissingPages`)。
///
/// `pagesWithoutText` 点名了哪些 PDF 页缺文本层(pipeline 落库时没能替这些页拿到
/// 文字)——可能是全篇扫描,也可能是混合页(如出院小结第 1 页打印、后面几页附
/// 检验报告扫描件,只有那几页需要补)。按页码精确补,补不完的(超出单次上限 /
/// 渲染或 OCR 失败)如实计回返回值,**绝不悄悄吞掉**。
///
/// 这段逻辑原先只长在患者模式的导入循环里(`_runImport`),医生代拍那条路
/// (`screens/doctor/proxy_intake_flow.dart`)拿到 `outcome` 后整个丢弃
/// `pagesWithoutText` —— 既不补也不说,医生当场拍完以为收全了。抽成公共函数就是
/// 为了让两条路共用同一份行为:**同一件事不许长成两个实现**。
///
/// 这条路为什么还需要存在(注释此前是反着写的,别再改回去):Rust 侧在 iOS 与
/// arm64 安卓上**是**链接了 PP-OCRv5 的(`apps/mobile_flutter/rust/Cargo.toml`
/// 对 `ocr` 声明了 `features = ["engine"]`),只是它只能 OCR PDF 里内嵌的
/// DCTDecode(JPEG)图,且模型要等 `recognizeImageText` 跑过一次才落盘。所以这条
/// Dart 侧的回填既兜「非 JPEG 编码的扫描页」,也兜「本次会话第一份就是 PDF」。
///
/// [onStage] 供调用方同步埋点用的 `stage`(失败发生在哪一步):进入渲染/OCR 前
/// 报 `'ocr'`,开始回填时报 `'save'` —— 与抽取前患者模式内联写法逐字一致。没有
/// 任何页要补时**一次都不回调**,`stage` 保持调用方原样(落库后就是 `'save'`)。
///
/// **只有 PDF 补得回来。** `pagesWithoutText` 现在还会点名多页图片(多页 TIFF)
/// 里第 2 页起那些页 —— 原生识别器(`recognizeImageText`)拿到的是整个文件、
/// 只认第一帧,那些页根本没被读过(见 `pipeline::ingest_image` 与
/// `api::vault::ingest_image_with_text` 的文档注释)。它们**端上无从补救**:
/// 不是 PDF,`_ocrScannedPdfPages` 拿去 `PdfDocument.openFile` 只会白跑一趟
/// (那里 catch 住返回空表,不崩,但也毫无意义)。所以对图片直接把点名的页数
/// 原样计回返回值 —— 补不了就照实说「N 页未能识别文字」,绝不因为「补救函数
/// 返回了空表」就把它混成一次失败的补救。判据用的是 [isImageName],与调用方
/// 当初把这份文件判成图片(`PendingImport.isImage`)时是同一个谓词、同一个文件。
///
/// ⚠️ [profile] / [vaultRoot] 是**落库那一刻的成员和箱子**,必填。回填不是只读的
/// 补救,它是一条**写事件**:`backfill_pdf_text` → `add_ocr` →
/// `append_event(OcrAdded)`,写下去就进历史、会同步。而 Rust 侧的 vault 是进程级
/// 单例、每个箱子的 rowid 都从 1 开始 —— 拿甲库的 `documentId` 写进乙库,大概率
/// 正好命中乙的另一份文档,甲的扫描页文字就追加进了**别人的病历**。
///
/// 这段渲染 + OCR 最长跑 20 页([_kMaxPdfOcrPagesPerImport]),分钟级。导入还钉在
/// 模态进度框里时这个窗口打不开;搬到后台队列之后,用户点完就回到档案屏,成员
/// tab 条就在眼前。所以每页写之前都过一遍 [ifVaultUnchanged](与落库、云抽取
/// 同一道闸、同一条 vault 队列);换掉了就**一页都不写**,剩下的如实计回返回值
/// —— 补不上就说补不上,绝不悄悄算成补上了。
///
/// [ocrPages] / [backfill] 只为测试注入替身:真实实现要碰 `pdfx` 渲染和 Rust
/// FFI,在 `flutter test` 的纯 dart 进程里都跑不起来。生产调用一律用默认值。
Future<int> backfillPagesWithoutText(
  ImportOutcomeDto outcome,
  String path, {
  required Profile profile,
  required String vaultRoot,
  void Function(String stage)? onStage,
  PdfPageOcr ocrPages = _ocrScannedPdfPages,
  PdfTextBackfill backfill = _defaultBackfill,
}) async {
  if (outcome.pagesWithoutText.isEmpty || outcome.documentId == null) return 0;
  // 多页图片:没得补,如实全部计入「仍未识别」,不动 `stage`(没进渲染/回填)。
  if (isImageName(path)) return outcome.pagesWithoutText.length;
  onStage?.call('ocr');
  final targetPages = outcome.pagesWithoutText.toList();
  final scan = await ocrPages(path, targetPages);
  onStage?.call('save');
  var written = 0;
  for (final entry in scan.entries) {
    // 渲染/OCR 留在 vault 队列**外**(它慢),只有这一行写入进队列 + 核身份。
    final ok = await ifVaultUnchanged(
      profile,
      vaultRoot,
      '补第 ${entry.key} 页',
      () async {
        await backfill(
          documentId: outcome.documentId!,
          pageNo: entry.key,
          text: entry.value.text,
          confidence: entry.value.confidence,
        );
        return true;
      },
    );
    // 换箱子了:后面几页同样不许写,直接收手(闸只会越来越不成立)。
    if (ok == null) break;
    written++;
  }
  return targetPages.length - written;
}

/// 一次导入单份文件时,`_ocrScannedPdfPages` 实际会渲染 + OCR 的页数上限
/// (而不是"这份 PDF 最多支持多少页")——超出的页数如实计入调用方的
/// `stillMissingPages`,不再像旧版 `_kMaxPdfOcrPages` 那样悄悄停在 20 页、
/// UI 一声不吭(那是本次修复一并解决的"移动端扫描 PDF 硬截断,零提示"缺陷)。
const int _kMaxPdfOcrPagesPerImport = 20;

/// 渲染放大倍数的候选,从清晰到保守**逐级降档**。
///
/// 分辨率越高 OCR 越准(笔画密的字在低解析度下会糊成一团),但设备内存有限:
/// 放大到一定程度 `render()` 会直接失败返回 null。此前写死单一倍数,一旦这台
/// 设备渲不出来就整篇零文本 —— 真机上就是这么炸的。所以不再赌一个常量,
/// 而是从高往低试,第一个渲得出来的就用。
///
/// 注意 pdfx 的 `page.width/height` 文档写明是 **像素**(不是 point),所以这里
/// 是相对原始尺寸的倍数,不能按 DPI 直接换算。
const List<double> _kRenderScales = [3.0, 2.0, 1.5];

/// 对 `pageNumbers`(1-based,由 `pipeline::ingest_pdf` 通过
/// `ImportOutcomeDto.pagesWithoutText` 点名——落库时既没有文本层、Rust 侧也没能
/// OCR 出文字的那些页)逐页渲染成 PNG、走 [recognizeImageText](PP-OCRv5,
/// iOS/安卓同引擎),返回 page_no → 识别结果,而不是像旧版那样不管页数
/// 一律从第 1 页盲扫、合并成一整块文本再整份回填。这样才能:(1)只处理真正
/// 缺文本层的页,混合页 PDF 不用把已有文本层的页也重跑一遍;(2)每页独立回填
/// (`page_no` 对应真实页码),某页失败不连累其它页。
///
/// 返回值里没出现的页码 == 没拿到文本(渲染/OCR 失败、识别为空,或超出
/// [_kMaxPdfOcrPagesPerImport] 单次上限没跑到)——调用方用
/// `pageNumbers.length - result.length` 算出「还有几页没识别」,原因不细分,
/// 但**数量本身绝不能不报**,这正是本次修复解决的"移动端扫描 PDF 静默截断"
/// 一类缺陷。
Future<Map<int, OcrResult>> _ocrScannedPdfPages(
  String path,
  List<int> pageNumbers,
) async {
  final byPage = <int, OcrResult>{};
  final toAttempt = pageNumbers.take(_kMaxPdfOcrPagesPerImport);
  PdfDocument? doc;
  Directory? tmp;
  try {
    doc = await PdfDocument.openFile(path);
    tmp = await Directory.systemTemp.createTemp('medme_pdf_ocr');
    for (final i in toAttempt) {
      // 防御性检查:页码来自 Rust 端,正常情况下必然落在 [1, pagesCount] 内;
      // 万一不一致(不同库对同一份 PDF 的页数判定有分歧),跳过而非崩溃或越界。
      if (i < 1 || i > doc.pagesCount) {
        debugPrint('[import] 页码 $i 超出 pdfx 报告的页数 ${doc.pagesCount},跳过');
        continue;
      }
      final page = await doc.getPage(i);
      try {
        // 逐级降档:清晰优先,渲不出来就退一档,别让整页变成零文本。
        PdfPageImage? img;
        for (final scale in _kRenderScales) {
          try {
            img = await page.render(
              width: page.width * scale,
              height: page.height * scale,
              format: PdfPageImageFormat.png,
              // 必须给白底。PNG 默认透明背景,黑字压在透明底上被 OCR 加载时
              // 可能合成成黑底,变成黑字黑底、一个字都认不出。
              backgroundColor: '#FFFFFF',
            );
          } catch (e) {
            debugPrint('[import] 第 $i 页 $scale× 渲染异常: $e');
          }
          if (img != null) {
            debugPrint('[import] 第 $i 页以 $scale× 渲染成功');
            break;
          }
          debugPrint('[import] 第 $i 页 $scale× 渲染失败,降档重试');
        }
        if (img == null) {
          debugPrint('[import] 第 $i 页所有倍数均渲染失败,跳过');
          continue;
        }
        final f = File('${tmp.path}/p$i.png');
        await f.writeAsBytes(img.bytes);
        final ocr = await recognizeImageText(f.path);
        if (ocr.text.trim().isNotEmpty) {
          byPage[i] = OcrResult(ocr.text.trim(), ocr.confidence);
        }
      } finally {
        await page.close();
      }
    }
  } catch (e) {
    debugPrint('[import] 扫描 PDF 渲染/OCR 失败: $e');
  } finally {
    await doc?.close();
    if (tmp != null) {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }
  return byPage;
}

/// 添加病历三选一的一条选项(mockup `s6` 的 `.opt`)。图标 + 标题这一行是
/// [MedSheetOption](paper 底圆角块 + [MedIcon],`primary` 那条换蓝底);
/// [subtitle] 是这条选项原有的说明句,`MedSheetOption.note` 是给短短一句
/// 「右侧小注」用的(见其类文档),放不下这句完整说明,所以单独起一行摆在
/// 选项块下方,缩进对齐到标题(不在文案上做任何删改)。
class _SheetTile extends StatelessWidget {
  const _SheetTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.choice,
    this.primary = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final ImportChoice choice;

  /// 视觉主选项:paper 换成蓝底(`MedSheetOption.highlighted`)。**不改变点击
  /// 行为**,只是这一屏三个选项里最推荐的那个多一点视觉重量。
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(MedShape.s4, 0, MedShape.s4, MedShape.s1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MedSheetOption(
            icon: icon,
            label: title,
            highlighted: primary,
            onTap: () => Navigator.of(context).pop(choice),
          ),
          Padding(
            // fix round 1(task-14-review Minor):缩进要从 MedSheetOption 自己
            // 的水平内边距算起(hPad),不是从 0 算起——标题实际起点是
            // hPad(12) + 图标块(44) + 间距(12) = 68,少算 hPad 会跟标题错位。
            // 点击区域是上面那一整行图标+标题(MedSheetOption 自带的
            // InkWell);这句说明文字不参与点击。
            padding: const EdgeInsets.fromLTRB(
              MedSheetOption.hPad + MedBrand.iconSlot + MedShape.s2, 0, MedShape.s2, 0),
            child: Text(subtitle, style: MedType.secondary.copyWith(color: c.ink3)),
          ),
        ],
      ),
    );
  }
}
