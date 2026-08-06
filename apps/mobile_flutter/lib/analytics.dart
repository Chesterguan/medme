import 'dart:async';

import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 行为分析。**只采行为骨架,绝不采内容。**
///
/// 这是一个装病历的 App,所以采集的红线比一般产品低得多:病历文字、文件名、OCR 结果、
/// 药名、诊断、检验值、日期、医院名 —— 一个字都不能出去。这里能上报的只有「发生了什么
/// 动作、成没成、花了多久(分桶)」。
///
/// **三条硬约束(用户定的):**
/// 1. 只采行为,不采内容
/// 2. 用户可以关
/// 3. **绝不影响功能** —— 上报失败静默丢弃,永不阻塞 UI、永不让任何操作因分析而失败
///
/// **刻意不做跨会话的持久 ID。** 持久 ID 会让这些事件变成「个人信息」(PIPL 第 73 条:
/// 去标识化仍是个人信息,只有无法识别且不能复原的匿名化才脱离管辖),而这个 App 的
/// 数据属于**敏感个人信息**,一旦出境就没有「10 万人以下豁免」。代价是**看不到留存
/// 曲线**——那是等有几百个用户、且有公司主体之后的下一步,不是现在。
///
/// 所以每次启动都 [Posthog.reset]:distinct_id 只在本次会话内有效,漏斗仍然算得出
/// (导入开始→完成、出码→被扫),跨会话拼接则做不到——这正是我们要的。
class Analytics {
  Analytics._();

  /// PostHog 项目 Key。用 `--dart-define=POSTHOG_KEY=phc_xxx` 注入。
  /// **没配就整个关掉** —— 不是降级,是干脆不初始化,连 SDK 都不启动。
  static const _apiKey = String.fromEnvironment('POSTHOG_KEY');
  static const _host = String.fromEnvironment(
    'POSTHOG_HOST',
    defaultValue: 'https://us.i.posthog.com',
  );

  static const _prefKey = 'analytics_enabled';
  static const _prefAsked = 'analytics_consent_asked';
  static const _prefFirstUse = 'analytics_first_use_ms';
  static const _prefLaunches = 'analytics_launch_count';

  /// **默认关,问过之后才可能开。**
  ///
  /// 早先是默认开的,理由是「不做持久 ID、不采内容,回指不到具体人」。但那样一来
  /// 隐私政策里「数据离开手机的每一种情况都由你主动触发」这句话就是假的 —— 首次
  /// 冷启动在用户看到任何说明之前就已经上报了。按 PIPL 的口径,默认开启 + 事后告知
  /// 也是常见处罚点。
  ///
  /// 所以改成:**没问过 = 不采**。见 [hasAsked] 与 `screens/analytics_consent.dart`。
  static const _defaultEnabled = false;

  static bool _enabled = _defaultEnabled;
  static bool _started = false;
  static bool _asked = false;

  /// 是否已经问过用户。没问过时 App 首屏会弹一次询问,之后永不再问。
  static bool get hasAsked => _asked;

  /// 用户答复了(无论开还是关)。**只记「问过了」**,开关状态由 [setEnabled] 写。
  static Future<void> markAsked() async {
    _asked = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefAsked, true);
    } catch (_) {
      // 写失败就下次再问一遍 —— 多问一次比偷偷采集好。
    }
  }

  static bool get isConfigured => _apiKey.isNotEmpty;
  static bool get isEnabled => _enabled;

  /// 会话上下文:**每条事件都自动带上**。
  ///
  /// 这里放的是「这台设备关于它自己的描述」——用了多久、库里几份、这是第几次打开。
  /// 关键区别:**描述自己 ≠ 标识自己**。原始值(首次使用日期、精确份数)永不上传,
  /// 只上传分桶后的 4-5 个取值;组合起来基数低到拼不出指纹,也无法把两次会话对上。
  ///
  /// 为什么值得要:没有持久 ID 就没有留存曲线,但「今天的会话里有多少来自用了 30 天
  /// 以上的设备」是同一个问题的另一种问法,而它不需要认出任何人。
  static final Map<String, Object> _context = {};

  /// **每条事件都会自动带上的键全集。**
  ///
  /// 为什么要写这一份:[AnalyticsEvent.props] 早就把「某条事件带什么」钉死了,
  /// 上下文这半边却一直是自由的 —— 谁在哪一屏 `setContext` 一把就多一个键,而它
  /// 会跟着**每一条**事件出去。事件属性漂了 CI 会红,上下文漂了没人知道,而上下文
  /// 恰恰是覆盖面最大的那一半。
  ///
  /// `docs/analytics-catalog.md` 第三节与这份清单由
  /// `test/analytics_catalog_test.dart` 双向对钉。
  ///
  /// 注:`hour_bucket` 不经 [setContext],它在 [_send] 里现算(要的是发送时刻的
  /// 本地钟点);但它同样是「每条都带」,所以列在这里 —— 这份清单的定义是
  /// **出口面**,不是某个函数的入参。
  static const contextKeys = {
    'tenure_bucket',
    'session_index_bucket',
    'library_size_bucket',
    'member_count_bucket',
    'mode',
    'hour_bucket',
  };

  /// 补充会话上下文。可多次调用,后到的覆盖同名键。
  static void setContext(Map<String, Object> kv) {
    // 与 [track] 里那道 assert 同一条理由,只是守的是上下文这半边。
    // release 里被剥掉,线上永远不因埋点崩。
    assert(() {
      final extra = kv.keys.toSet().difference(contextKeys);
      if (extra.isNotEmpty) {
        throw StateError(
          '会话上下文出现了未声明的键 $extra —— 上下文会跟着**每一条**事件出去,'
          '加键必须同时加进 Analytics.contextKeys 并同步 '
          'docs/analytics-catalog.md 第三节',
        );
      }
      return true;
    }());
    _context.addAll(kv);
  }

  /// 当前已知的库存份数;`null` = 还没读到(冷启动早期,或医生模式没有个人档案)。
  /// 导入埋点用它判断 `is_first`——**不知道就不报**,绝不猜。
  static int? _librarySize;

  /// 档案屏载入后回填(见 `archive_screen.dart`)。这是唯一的来源:不为了埋点额外
  /// 读一次库,用本来就要读的那次。
  static void setLibrarySize(int n) {
    _librarySize = n;
    setContext({'library_size_bucket': Bucket.count(n)});
  }

  static int? get librarySize => _librarySize;

  /// 启动时调用。**绝不 await 到阻塞启动**,调用方应 `unawaited(...)`。
  ///
  /// 缓存自己的 Future:重复调用拿到同一个,所以「要等上下文就绪」的地方
  /// (如 `app_open`)可以直接 `await Analytics.init()`,不会跑第二遍初始化。
  static Future<void>? _initOnce;
  static Future<void> init() => _initOnce ??= _doInit();

  static Future<void> _doInit() async {
    if (!isConfigured) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_prefKey) ?? _defaultEnabled;
      _asked = prefs.getBool(_prefAsked) ?? false;

      // 设备任期与启动次数。**两个 int 存在本机,永不上传原值** —— 上传的只有分桶。
      // 首次使用日期在这里落下:第一次启动时写入,之后只读。
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final firstMs = prefs.getInt(_prefFirstUse) ?? nowMs;
      if (prefs.getInt(_prefFirstUse) == null) {
        await prefs.setInt(_prefFirstUse, nowMs);
      }
      final launches = (prefs.getInt(_prefLaunches) ?? 0) + 1;
      await prefs.setInt(_prefLaunches, launches);
      setContext({
        'tenure_bucket': Bucket.tenure(
          Duration(milliseconds: nowMs - firstMs),
        ),
        'session_index_bucket': Bucket.count(launches),
      });

      await Posthog().setup(
        PostHogConfig(_apiKey)
          ..host = _host
          // ── 把所有「自动采集」逐个关掉 ────────────────────────────────
          // 关键:`beforeSend` 钩子**拦不住原生发起的事件**(生命周期、feature flag、
          // 问卷),所以「只报我们指定的事件」不能靠白名单兜底,必须在这里逐个关死。
          ..captureApplicationLifecycleEvents = false
          ..sessionReplay = false
          // preloadFeatureFlags 会在 SDK 启动时发一次网络请求 —— 那是唯一一条会落在
          // 冷启动路径上的调用,关掉,把网络依赖从启动路径上彻底摘掉。
          ..preloadFeatureFlags = false
          ..sendFeatureFlagEvents = false
          ..surveys = false
          ..debug = false,
      );

      // **每次启动重置 distinct_id** —— 这就是「不做持久 ID」的执行者。
      await Posthog().reset();
      // ⚠️ **两个方向都要显式设。** `Posthog().disable()` 是**跨启动持久**的:SDK 把
      // 「已退出」记在原生存储里。早先这里只写了 `if (!_enabled) disable()`,于是首启
      // (同意门之前,统计默认关)调过一次 disable 后,**后续每次启动 SDK 都还是关的**
      // —— 用户同意了也没用,除非他手动去设置里拨那个开关。真机上表现为 `app_open`
      // 一条都收不到。
      if (_enabled) {
        await Posthog().enable();
      } else {
        await Posthog().disable();
      }
      _started = true;
    } catch (_) {
      // 分析初始化失败**绝不能影响 App**。静默放弃,后续 track 自动变成空操作。
      _started = false;
    }
  }

  /// 用户在设置里开/关。
  static Future<void> setEnabled(bool on) async {
    _enabled = on;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, on);
      if (!_started) return;
      if (on) {
        await Posthog().enable();
      } else {
        // 关之前先报最后一条,好知道有多少人关掉了 —— 这条之后就不再有任何上报。
        await _send(AnalyticsEvent.analyticsOptOut, const {});
        await Posthog().disable();
      }
    } catch (_) {
      // 偏好写失败不该弹错;下次启动会退回默认值。
    }
  }

  /// 上报一个事件。**fire-and-forget** —— 不 await、不抛错、不阻塞调用方。
  static void track(AnalyticsEvent event, [Map<String, Object>? props]) {
    // 调用点发了 [AnalyticsEvent.props] 里没有的键 = 目录必然漂。只在 debug/测试里
    // 炸(assert 在 release 被剥掉),线上永远不因埋点崩。
    assert(() {
      final extra = (props ?? const {}).keys.toSet().difference(event.props);
      if (extra.isNotEmpty) {
        throw StateError(
          '${event.name} 发了未声明的属性 $extra —— '
          '要么改调用点,要么把它加进 AnalyticsEvent.$event 的 props 并同步 '
          'docs/analytics-catalog.md(会话上下文那几个键由 setContext 统一加,不在这里报)',
        );
      }
      return true;
    }());
    if (!_started || !_enabled) return;
    unawaited(_send(event, props ?? const {}));
  }

  static Future<void> _send(AnalyticsEvent event, Map<String, Object> props) async {
    try {
      await Posthog().capture(
        eventName: event.name,
        properties: {
          // 会话上下文在最前:调用点想覆盖某个键就能覆盖。
          ..._context,
          ...props,
          // 本地时段。关了 GeoIP 之后服务端只剩 UTC,而「代拍是不是发生在门诊时间」
          // 恰恰要看本地钟点 —— 那是「医生真的在诊室用」最直接的证据。4 个桶,
          // 低到不构成定位信息。
          'hour_bucket': Bucket.hour(DateTime.now()),
          // 服务端 GeoIP 富化会按 IP 补上省市 —— 我们不需要,明确禁掉。
          // (IP 采集本身还要在 PostHog 项目设置里关,SDK 侧关不了。)
          r'$geoip_disable': true,
        },
      );
    } catch (_) {
      // 网络/序列化失败一律吞掉。SDK 自己有退避重试与丢弃策略,我们不再叠一层。
    }
  }
}

/// 允许上报的事件全集。**枚举而不是自由字符串** —— 想加事件必须改这里,
/// 于是「采了什么」永远是一份可以逐条审的清单(工信部双清单要用)。
///
/// 每条事件**对应一个决定**;答不出决定的事件不该存在。完整的「事件 → 决定 → 属性」
/// 对照表在 `docs/analytics-catalog.md`,由 `test/analytics_catalog_test.dart`
/// 双向钉住 —— 这里加了那里没写(或反过来)都会红。
enum AnalyticsEvent {
  /// 打开 App。DAU 基线。注意:**不靠 SDK 的生命周期自动采集**(那个 beforeSend
  /// 拦不住,已关掉),而是我们自己在启动时发一条。
  appOpen('app_open', {'vault_ok'}),

  /// 导入开始。属性:`source`(camera/gallery/files)、`count_bucket`。
  docImportStarted('doc_import_started', {'source', 'count_bucket'}),

  /// 导入完成(至少一份成功)。属性:`source`、`count_bucket`、`failed_bucket`、
  /// `duration_bucket`、`per_doc_duration_bucket`、`is_first`。
  ///
  /// **最核心的一条。** 注意是两个耗时:总时长被份数主导,只能回答「用户要等多久」;
  /// 单份时长才是引擎质量,是「换不换 OCR」的依据。当初只报总时长,等于这个问题
  /// 根本答不出来。
  docImportCompleted('doc_import_completed', {
    'source',
    'count_bucket',
    'failed_bucket',
    'duration_bucket',
    'per_doc_duration_bucket',
    'is_first',
  }),

  /// 导入失败(整批全败)。属性:`source`、`count_bucket`、`stage`、`reason_code`。
  /// ⚠️ `reason_code` **必须是预定义枚举**([ImportFailReason])—— 异常消息常带
  /// 文件名和路径,绝不能上报。
  docImportFailed('doc_import_failed', {
    'source',
    'count_bucket',
    'failed_bucket',
    'duration_bucket',
    'per_doc_duration_bucket',
    'is_first',
    'stage',
    'reason_code',
  }),

  /// 采集器**没起来**,已降级到备用路径(普通系统相机)。属性:`source`、`reason`。
  ///
  /// 回答的决定:安卓「点拍照没反应」到底是哪一种病因 —— GMS 检测自己炸了、扫描器
  /// 抛异常、还是 `getStartScanIntent` 的 Task 既不 success 也不 failure(模块下不
  /// 下来)导致 method channel 永不回调。这三种在 UI 上是**字节级相同**的症状,
  /// 五版没修对就是因为在数据里也一样是零 —— [docImportStarted] 要等到拿着文件了
  /// 才发,整个采集环节此前是彻底的盲区。
  ///
  /// ⚠️ `reason` 必须是预定义枚举([ImportCaptureIssue]);异常文本**只上屏,不上报**。
  docCaptureDegraded('doc_capture_degraded', {'source', 'reason'}),

  /// 采集这一轮结束,但**一份都没拿到**。属性:`source`、`reason`。
  ///
  /// 回答的决定:「点了没反应」里有多少是**用户自己取消**(正常,不用修)、多少是
  /// 采集器**静默返回空**(bug,要修)。这两者在屏上完全一样,此前一律
  /// `return const []`,连分子分母都分不开。
  docCaptureAborted('doc_capture_aborted', {'source', 'reason'}),

  /// 打开了一份病历。**没有任何内容属性,只有「发生了」。**
  /// 回答的决定:档案是被**看**的还是被**堆**的 —— 如果导入了从不打开,
  /// 这就是个垃圾桶,不是助手。
  ///
  /// 五 tab 之后概览 / 趋势 / 档案 / 应急卡 /「看病带这个」五处都能打开一份,
  /// 这条**仍然不带来源** —— 「是被看的还是被堆的」不需要知道从哪一屏点的,
  /// 而多一维就多一次泄露面的评估。
  docOpened('doc_opened', {}),

  // ── 五 tab 信息架构 ───────────────────────────────────────────────────────

  /// 用户**手点**了底栏的某个一级 tab。属性:`tab`(枚举 [AnalyticsTab])。
  ///
  /// 回答的决定:**五个一级席位该给谁。** 1.6.0 把三 tab 拆成五个,「趋势」和
  /// 「应急卡」各占掉一格,而 `HomeShell` 的文档里那句「做成 tab 就是给一个一年
  /// 用十次的动作一个常驻席位,而把它挤掉的会是应急卡」到今天为止纯属推理 ——
  /// 席位之争是本版最大的赌注,却一个数都没有。这条把它变成可证伪的。
  ///
  /// **只在手点时发**(`onDestinationSelected`)。程序化跳转(`goToArchive()`、
  /// 载入示例后的「去看看」)不发 —— 那是别的功能的副作用,不是用户想去哪,
  /// 混进来会把一个功能的成功记成另一个 tab 的人气。
  ///
  /// 不泄露内容:`tab` 是五个界面名,与病历、成员、数值全都无关。
  homeTabSelected('home_tab_selected', {'tab'}),

  // ── 手动录入「记录」 ──────────────────────────────────────────────────────

  /// 手动录入存下了一条。属性:`kind_group`(枚举 [RecordKindGroup])、
  /// `edited`(这次是在改一条已有的,不是新增)。
  ///
  /// 回答的决定:**「记录」这条路该往数值走还是往笔记走。** 它是本版新开的
  /// **第二条入库路径**,而两种用法通向完全不同的路线图 —— 数值要喂趋势与概览的
  /// 自测序列(单位换算、参考区间、血压双值),笔记要喂「看病带这个」的「我想问
  /// 医生的」。两边现在都在做,这个比值说该收哪一半。
  ///
  /// `edited` 回答第二个决定:编辑走的是「先删再写」,那条顺序有过一个会**静默
  /// 丢数据**的必现 bug(见 `manual_entry_sheet.dart` 的 `_save`)。几乎没人编辑
  /// 的话,这类风险的优先级就低;编辑很常见的话,它值得一层额外的保护。
  ///
  /// **为什么不并进 `doc_import_*`:** 那三条事件的存在理由是 OCR 引擎质量
  /// (`per_doc_duration_bucket` 直接决定「换不换 OCR」)。手动录入没有 OCR 这一步,
  /// 耗时接近零 —— 加一个 `source=manual` 会把引擎指标稀释成一个没人能解释的数。
  /// 入库总量要看两条之和,目录第六节写明了这条算法。
  ///
  /// ⚠️ **不报是哪一种**(血压/心率/体重/体温/血糖)。「这台设备在测血糖」是对
  /// 机主的健康推断,属于敏感个人信息,与「不采内容」这条红线同级。
  /// `measurement` / `note` 两分不指向任何身体系统,是能安全拿到的最大信息量。
  /// 数值、单位、笔记原文、测量时间一概不出设备。
  recordAdded('record_added', {'kind_group', 'edited'}),

  // ── 「看病带这个」 ────────────────────────────────────────────────────────

  /// 「看病带这个」浮层被打开。属性:`where`(枚举 [VisitSheetEntry])。
  ///
  /// 回答的决定:**「它刻意不占 tab」这个赌注成不成立。** 它只从概览和档案两处
  /// 顶栏唤起,依据是「进诊室前你本来就在其中之一」这个假设。打开次数接近零就说明
  /// 没人找得到它 —— 那这一屏(本版最重的一屏)要么给席位,要么砍。
  /// `where` 说的是两个入口谁在起作用,决定另一个该不该留。
  ///
  /// 不泄露内容:只有「哪一屏唤起的」。屏上显示的药名、过敏史、化验值一个字不带。
  visitSheetOpened('visit_sheet_opened', {'where'}),

  /// 在「看病带这个」里按下了一颗动作键。属性:`action`(枚举 [VisitSheetAction])。
  ///
  /// 回答的决定:**「复制全文」和「出示二维码」哪一条才是诊室里真正走的路。**
  /// 两条路的成本差一个数量级 —— 复制是本地几行代码,出码要联网、要 E2E 加密、
  /// 要托管查看器、要 12 小时过期清理。产品验收已经指出这两颗按钮「分不清,得
  /// 自己推」;若出码几乎没人按,那整条云链路就该退成次要入口而不是并列。
  ///
  /// 与 [visitSheetOpened] 组成漏斗:**打开了却一颗都没按**,说明这一屏只是被
  /// 瞄了一眼,内容没能用起来 —— 那是排版问题,不是入口问题,两者要修的地方不同。
  ///
  /// `addNote` 单独一档:「我想问医生的」是本版新加的、这一屏唯一属于患者自己的
  /// 一节,有没有人真的往里写,决定它排最前是对是错。
  ///
  /// 不泄露内容:只有按了哪颗键。复制走的文本、二维码载荷、笔记原文都不上报。
  visitSheetAction('visit_sheet_action', {'action'}),

  // ── 应急卡 ───────────────────────────────────────────────────────────────

  /// 打开了应急卡的**大字模式**。无属性。
  ///
  /// 回答的决定:**应急卡该不该继续占一个一级席位。** `emergency_card_screen.dart`
  /// 自己写着「大字模式才是这个 tab 的产品本体,平时这一屏只是它的维护界面」。
  /// 若 tab 有人进([homeTabSelected])而大字模式没人开,那句话就是错的:这个 tab
  /// 实际是个资料编辑页,「急救现场」的前提从未被验证过,席位该还给别人。
  ///
  /// 不泄露内容:**没有任何属性。** 姓名、血型、过敏史、联系人一个都不带 ——
  /// 这一屏上的每一样东西都是最敏感的那一类。
  emergencyBigModeOpened('emergency_big_mode_opened', {}),

  // ── 趋势 ─────────────────────────────────────────────────────────────────

  /// 在趋势屏动了一次筛选。属性:`control`(枚举 [TrendsFilterControl])。
  ///
  /// 回答的决定:**「只看非正常项」默认开对不对。** 这是全 App 唯一一处替用户
  /// 排序的默认值,代码里为它写了整整一段辩护。用户把它**关掉**的频次就是这段
  /// 辩护的检验:关得多 = 默认藏错了东西,该改成默认关或改文案。
  ///
  /// 顺带回答第二个:检验大类 chip 是本版新做的(Rust 侧一份 panel 目录 + 词典
  /// 投入),上线理由是「取代搜索成为主路径」。chip 与搜索各自被用了多少,决定
  /// 要不要继续往词典里投,以及那颗放大镜还留不留。
  ///
  /// ⚠️ **绝不报是哪个大类,绝不报搜索词。** 「这台设备在看肝功能」是健康推断,
  /// 搜索词更是直接的内容(用户会打指标名甚至病名)。这里只报「动了哪一类控件」,
  /// 四个取值,与身体系统无关。搜索只在**展开搜索栏**时发一次,不随输入发 ——
  /// 按键发会既是噪音又逼近内容。
  trendsFilterUsed('trends_filter_used', {'control'}),

  /// 出示了二维码(密文已上传、码已显示)。属性:`record_count_bucket`、`size_bucket`。
  shareQrShown('share_qr_shown', {'record_count_bucket', 'size_bucket'}),

  /// 上传中断相关。`choice`:`interrupted`(传到一半断了,自动发)/ `retry`(用户点了重试)。
  /// **降级到简版码记在 [shareQrDegraded] 上,不是这里** —— 目录里一度把两者混成
  /// 一个 `retry/fallback`。另带 `progress_bucket`:断在进度的哪一段。
  /// ⚠️ `progress_bucket` 是把「进度 × 10」喂给 `Bucket.count`,所以桶名读作
  /// `0/1/2-5/6-20`,语义别扭 —— 是「断在一成以内 / 二到五成 / 六成以上」。
  shareUploadRetry('share_upload_retry', {'choice', 'progress_bucket'}),

  /// 降级成简版码(不含原件)。说明云那条路没走通。
  shareQrDegraded('share_qr_degraded', {'choice'}),

  /// 导出可打印文件。属性:`ranged`(是否用了日期筛选)。
  exportCompleted('export_completed', {'ranged'}),

  // ── 医生代拍 ──────────────────────────────────────────────────────────────
  // 这是最新、最不确定、赌注最大的功能,却曾经**一个事件都没有**。没有这四条,
  // 「代拍到底成不成立」是盲飞。

  /// 选了身份。属性:`mode`(personal/doctor)、`where`(first=首屏首次选 /
  /// settings=事后在设置里切)。`where` 值钱在于:事后切换说明第一次选错了。
  modeSelected('mode_selected', {'mode', 'where'}),

  /// 医生开始了一次代拍(进入代拍流程屏)。属性:`resumed`(是否是回到已建档的病人)。
  proxySessionStarted('proxy_session_started', {'resumed'}),

  /// 病人签了知情同意。**同意书是这条流程里最可能的流失点**,不单独埋就只知道
  /// 「掉了」不知道「掉在哪」。started 与它之间的差 = 同意环节流失。
  proxyConsentSigned('proxy_consent_signed', {}),

  /// 代拍交付成功(认领链接已生成)。属性:`count_bucket`(交付几份)、
  /// `confirmed_bucket`(医生确认过几份)、`size_bucket`、`duration_bucket`。
  /// 耗时决定医生愿不愿意再来 —— 一次代拍要五分钟,就没有第二次。
  proxyShareShown('proxy_share_shown', {
    'count_bucket',
    'confirmed_bucket',
    'size_bucket',
    'duration_bucket',
  }),

  // ── 认领 ─────────────────────────────────────────────────────────────────
  // ⚠️ 与出码是**两台手机**,没有持久 ID 就无法逐条关联。只看总量比
  // (claim_imported / proxy_share_shown),不做 per-link 关联。

  /// 认领页打开。属性:`entry`(cold=App 被链接拉起 / warm=App 已在运行)。
  /// cold 基本意味着「刚装完就来认领」,是最关键的一条转化路径。
  claimOpened('claim_opened', {'entry'}),

  /// 认领成功。属性:`count_bucket`、`deduped`、`text_only`。
  claimImported('claim_imported', {'count_bucket', 'deduped', 'text_only'}),

  /// 认领失败。属性:`reason`(gone / network / failed / unknown,见
  /// `claim_screen.dart` 的 `_trackFailure`)。
  /// `gone` 尤其值钱:有人扫了已过期的码,说明 12 小时太短或流程太慢 ——
  /// 每一条都代表一次白做的代拍。
  claimFailed('claim_failed', {'reason'}),

  // ── 数据主权(设置) ──────────────────────────────────────────────────────

  /// 载入了示例数据。属性:`ok`(整条流有没有跑完)。
  ///
  /// 回答的决定:**示例数据该被提到空态里,还是该整个砍掉。** 它现在埋在「设置」
  /// 的第三节,而需要它的人正站在「概览」的空态上。载入的人多,它就该出现在第一屏;
  /// 几乎没人载入,那条 Rust 流式 API + 合成成员 + 一串进度文案就是净负担,可以删。
  ///
  /// `ok=false` 另有用处:`load_demo_data` **恒不返回 `Err`**(失败靠字段带出来),
  /// 这是个天然会安静坏掉的地方 —— 它坏了用户只看到一句提示,我们此前一无所知。
  ///
  /// 不泄露内容:只有一个布尔。失败原因是 Rust 侧的一段文本,**不上报**
  /// (与 `doc_import_failed` 只报 `reason_code` 同一条规矩)。
  demoDataLoaded('demo_data_loaded', {'ok'}),

  /// 用户确认了「清空所有数据 · 重置保险箱」。无属性。
  ///
  /// 回答的决定:**这是我们能看见的最强的负面信号。** 没有持久 ID 就永远看不到
  /// 卸载,而清空是仅次于卸载的一步,并且它在一道二次确认之后 —— 不会误触。
  /// 配合会话上下文的 `tenure_bucket` 就分得开两种人:第一天就清掉(装完试了一下
  /// 不满意,是**首次体验**问题)vs 用了一个月才清(是**出了什么事**)。这两种
  /// 要修的东西完全不同,而在此之前它们都是零。
  ///
  /// 不泄露内容:没有任何属性 —— 而且此刻设备上已经什么都不剩了。
  dataWiped('data_wiped', {}),

  /// 用户关掉了分析。**最后一条上报**,发完即停。
  analyticsOptOut('analytics_opt_out', {});

  const AnalyticsEvent(this.name, this.props);
  final String name;

  /// 这个事件**可能**携带的属性名全集(有些是条件带上的,所以是上界不是等号)。
  ///
  /// 为什么要在代码里写一遍:目录 `docs/analytics-catalog.md` 是双清单和隐私政策的
  /// 底稿,而它此前只被「事件名」钉住 —— 属性漂了 CI 不会红。实际就漂过:
  /// `share_upload_retry` 的取值在目录里写成 `retry/fallback`(真实是
  /// `interrupted`/`retry`,`fallback` 记在 `share_qr_degraded` 上),
  /// `proxy_share_shown` 漏了两个属性。
  ///
  /// 现在两头都钉:[Analytics.track] 里 assert 调用点不许发这里没有的键;
  /// `test/analytics_catalog_test.dart` 校验目录第四节的属性列与这里逐字一致。
  final Set<String> props;
}

/// 数值一律分桶再上报 —— 精确值(几份病历、多少字节、多少毫秒)组合起来可能指认到人。
class Bucket {
  Bucket._();

  static String count(int n) {
    // 0 必须单独成桶:库存 0 份和 1 份是完全不同的状态(空档案 vs 用过一次),
    // 混进同一个桶,「有没有人在累积」就白问了。
    if (n <= 0) return '0';
    if (n <= 1) return '1';
    if (n <= 5) return '2-5';
    if (n <= 20) return '6-20';
    if (n <= 50) return '21-50';
    return '50+';
  }

  static String duration(Duration d) {
    final s = d.inMilliseconds / 1000;
    if (s < 3) return '<3s';
    if (s < 10) return '3-10s';
    if (s < 30) return '10-30s';
    if (s < 120) return '30-120s';
    return '>120s';
  }

  /// **单份**耗时 —— 引擎质量指标。两点用途:
  ///
  /// 1. **不被份数带偏**:5 份各 2 秒,[duration] 报 `3-10s`(像是慢),这里报
  ///    `1-3s`(其实正常)。只看总时长会把批量冒充成引擎问题。
  /// 2. **分辨率更高**:[duration] 一个桶里塞着的 2 倍差异(4s vs 8s),这里分得开。
  ///
  /// ⚠️ 分桶看不见小幅改进(4.0s → 3.5s 在任何合理的桶里都不动)——那是隐私换来的
  /// 代价。要精确耗时只能上真机基准测试,不能指望埋点。
  static String perDoc(Duration d) {
    final s = d.inMilliseconds / 1000;
    if (s < 1) return '<1s';
    if (s < 3) return '1-3s';
    if (s < 6) return '3-6s';
    if (s < 15) return '6-15s';
    return '>15s';
  }

  static String bytes(int n) {
    final mb = n / 1024 / 1024;
    if (mb < 1) return '<1MB';
    if (mb < 5) return '1-5MB';
    if (mb < 20) return '5-20MB';
    if (mb < 100) return '20-100MB';
    return '>100MB';
  }

  /// 设备任期(距首次使用多久)。**留存曲线的替代品**:看不出是不是同一个人,
  /// 但「今天的会话里有多少来自 30 天以上的设备」是同一个问题的另一种问法。
  static String tenure(Duration since) {
    final d = since.inDays;
    if (d < 1) return '0d';
    if (d <= 7) return '1-7d';
    if (d <= 30) return '8-30d';
    return '30d+';
  }

  /// 本地时段,4 桶。门诊在上午/下午两段 —— 代拍如果密集落在这两桶里,
  /// 就是「医生真的在诊室用」的证据。粗到不构成行踪信息。
  static String hour(DateTime local) {
    final h = local.hour;
    if (h < 6) return '00-06';
    if (h < 12) return '06-12';
    if (h < 18) return '12-18';
    return '18-24';
  }
}

/// 导入失败的原因码。**上报的永远是这个枚举的名字,绝不是异常文本** ——
/// 异常里常带文件名和路径,那是内容。
///
/// ponytail: 靠错误串匹配分类,不是靠 Rust 侧的类型化错误。天花板很明确 ——
/// 如果 `unknown` 在数据里占了大头,就说明该让 core 返回类型化错误码了。
enum ImportFailReason {
  /// 文件格式不支持 / 解析不了。
  unsupported,

  /// 文件读不出来、空文件、损坏。
  corrupt,

  /// OCR 跑完没有任何文字(拍糊了、拍到白纸)。
  ocrEmpty,

  /// 落库失败(磁盘满、保险箱写入错误)。
  storage,

  /// 缺权限(相机/相册被拒)。
  permission,

  /// 没归上类。占比一高就是该上类型化错误的信号。
  unknown;

  /// 从异常粗分类。**只读异常的形状,不把它的内容带出去。**
  static ImportFailReason of(Object error) {
    final s = error.toString().toLowerCase();
    if (s.contains('permission') || s.contains('denied')) return permission;
    if (s.contains('unsupported') || s.contains('格式')) return unsupported;
    if (s.contains('empty') || s.contains('corrupt') || s.contains('空文件')) {
      return corrupt;
    }
    if (s.contains('no text') || s.contains('无文本')) return ocrEmpty;
    if (s.contains('disk') || s.contains('space') || s.contains('write')) {
      return storage;
    }
    return unknown;
  }
}

/// 采集环节(拍照 / 相册 / 选文件,`import_flow.dart` 的 `pickImportItems`)出了
/// 什么事。**与 [ImportFailReason] 分工明确**:那个说的是「拿到文件之后处理失败」,
/// 这个说的是「压根没拿到文件」。
///
/// 存在的理由:抛异常 / 永久挂起 / 返回空列表 —— 三种完全不同的病因,在 UI 上渲染成
/// 字节级相同的症状(什么都没发生)。不把它们分开命名,就只能靠猜。
///
/// ⚠️ 上报的永远是**这个枚举的名字**,绝不是异常文本 —— 异常里常带文件名和路径。
/// 异常文本可以显示在屏上(屏上探针),但不出设备。
enum ImportCaptureIssue {
  // ── 降级类:采集器没起来,已落到备用路径,后面可能还是成功的 ──────────────
  /// GMS 可用性检测本身抛了异常。**此前是裸 await**,炸了整个流程直接消失。
  gmsCheckThrew(AnalyticsEvent.docCaptureDegraded),

  /// 启动看门狗触发:扫描器迟迟没起来,而 App 还停在前台 —— 说明没有任何原生
  /// 界面被拉起来,不是「用户正在扫」。详见 `import_flow.dart` 的判据说明。
  scannerStalled(AnalyticsEvent.docCaptureDegraded),

  /// 扫描器抛异常(设备不支持、权限被拒等),已回退普通相机。
  scannerThrew(AnalyticsEvent.docCaptureDegraded),

  /// 扫描器回了空,用户在补救提示里点了「用普通相机」——**这台机器的 ML Kit 文档
  /// 扫描模块拉不到**(GMS 在场但下载不到 `mlkit.docscan.ui`,国内最常见)。
  /// 这是我们唯一拿得到的「模块不可用」信号:插件把它和「用户取消」返回成同一个
  /// 空列表,只能靠用户这一下点击分流。记住之后,下次直接走普通相机。
  scannerModuleUnavailable(AnalyticsEvent.docCaptureDegraded),

  /// 上一条记住之后,**这次拍照直接跳过了扫描器**,静默走普通相机。
  /// 它是 [scannerModuleUnavailable] 的下游:占比越高,说明「装了 GMS 却用不了
  /// 扫描器」的机器越多 —— 这正是判断要不要换掉整个扫描方案的那个数。
  scannerSkippedUnavailable(AnalyticsEvent.docCaptureDegraded),

  // ── 中止类:这一轮采集一份都没拿到 ────────────────────────────────────────
  /// 用户主动取消。**正常,不是 bug** —— 但必须和下面那条分开,否则
  /// 「点拍照没反应」永远算不出真实占比。
  userCancelled(AnalyticsEvent.docCaptureAborted),

  /// 采集器**返回了结果,但里面什么都没有**。用户没取消,东西却没了 —— 这是 bug。
  /// 具体是哪一种由同事件的 `source` 区分:`camera` = 扫描器回了 0 页;
  /// `files` = 选中的文件在本机取不到(云盘上还没下载完的文件就是这样)。
  emptyResult(AnalyticsEvent.docCaptureAborted),

  /// 系统相册 / 相机 / 文件选择器抛异常。
  pickerThrew(AnalyticsEvent.docCaptureAborted),

  /// 没归上类(采集函数外层的兜底 catch)。占比一高就说明还有没枚举到的分支。
  unknown(AnalyticsEvent.docCaptureAborted);

  const ImportCaptureIssue(this.event);

  /// 这条原因归哪个事件。写在枚举上而不是调用点,是为了让「降级 vs 中止」的归属
  /// 只有一处定义 —— 调用点只管说出原因,不用记得它该发哪条事件。
  final AnalyticsEvent event;
}

/// 底栏一级 tab 的**上报名**([AnalyticsEvent.homeTabSelected] 的 `tab`)。
///
/// 与 `vault_events.dart` 的 `HomeTab` 下标一一对应,但**刻意不共用那组 int**:
/// 上报的必须是稳定的名字,而下标会随 tab 顺序调整而变 —— 顺序一改,后台里所有
/// 历史数据就整体错位,而且看不出来。
enum AnalyticsTab {
  overview,
  trends,
  archive,
  emergency,
  settings;

  /// 下标 → 名字。越界返回 `null`,调用点据此**不报**(与 `is_first` 同一条
  /// 「不知道就不报,绝不猜」的规矩)。
  static AnalyticsTab? of(int index) =>
      index >= 0 && index < values.length ? values[index] : null;
}

/// 手动录入存下的是「数值」还是「笔记」([AnalyticsEvent.recordAdded] 的
/// `kind_group`)。
///
/// ⚠️ **刻意只有两档。** 六选一里具体是血压还是血糖,是对机主的**健康推断**
/// (「这台设备在测血糖」),属于敏感个人信息,与「不采内容」同级 —— 不上报。
/// 而「数值 vs 笔记」不指向任何身体系统,却已经足够分开两条产品路线(喂趋势
/// vs 喂「我想问医生的」)。这是这条事件上能安全拿到的最大信息量。
enum RecordKindGroup { measurement, note }

/// 「看病带这个」是从哪一屏唤起的([AnalyticsEvent.visitSheetOpened] 的 `where`)。
/// 它没有 tab 席位,只有这两个入口 —— 这个枚举就是那两个入口的全集。
enum VisitSheetEntry { overview, archive }

/// 在「看病带这个」里按了哪颗动作键([AnalyticsEvent.visitSheetAction] 的
/// `action`)。三颗按钮的全集,不含任何被复制/被分享/被写下的内容。
enum VisitSheetAction {
  /// 「复制全文给医生」。**只报按了,不报文本。**
  copy,

  /// 「医生要看原件 · 出示二维码」。出码本身仍由 `share_qr_shown` 计数,
  /// 这一档只做**入口归属** —— 出码还能从设置 →「导出 · 分享」进,两条路的
  /// 占比决定哪一条才是主路径。
  qr,

  /// 「我想问医生的」那一节的「加一条」。存下来那条本身由 `record_added` 计数,
  /// 这一档只做入口归属。
  addNote,
}

/// 趋势屏上动了哪一类筛选控件([AnalyticsEvent.trendsFilterUsed] 的 `control`)。
///
/// ⚠️ **取值里没有「哪个大类」,也没有「搜了什么词」** —— 那些是内容:大类指向
/// 身体系统(健康推断),搜索词更是用户直接打进去的字(会是指标名甚至病名)。
enum TrendsFilterControl {
  /// 「只看非正常项」被**关掉**(用户要看全部)。默认开,所以**这一档才是信号** ——
  /// 它是那条默认值唯一的检验。
  abnormalOnlyOff,

  /// 「只看非正常项」被重新打开。是上一档的分母,单独看没有意义。
  abnormalOnlyOn,

  /// 点了某个检验大类 chip。**不报是哪个** —— 只报「chip 这条路被走了」。
  panel,

  /// 展开了搜索栏。**不报搜索词**,而且只在展开时发一次、不随输入发 ——
  /// 按键发既是噪音,又一步步逼近内容本身。
  search,
}
