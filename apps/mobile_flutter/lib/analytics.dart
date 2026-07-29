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

  /// 补充会话上下文。可多次调用,后到的覆盖同名键。
  static void setContext(Map<String, Object> kv) => _context.addAll(kv);

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
  appOpen('app_open'),

  /// 导入开始。属性:`source`(camera/gallery/files)、`count_bucket`。
  docImportStarted('doc_import_started'),

  /// 导入完成(至少一份成功)。属性:`source`、`count_bucket`、`failed_bucket`、
  /// `duration_bucket`、`per_doc_duration_bucket`、`is_first`。
  ///
  /// **最核心的一条。** 注意是两个耗时:总时长被份数主导,只能回答「用户要等多久」;
  /// 单份时长才是引擎质量,是「换不换 OCR」的依据。当初只报总时长,等于这个问题
  /// 根本答不出来。
  docImportCompleted('doc_import_completed'),

  /// 导入失败(整批全败)。属性:`source`、`count_bucket`、`stage`、`reason_code`。
  /// ⚠️ `reason_code` **必须是预定义枚举**([ImportFailReason])—— 异常消息常带
  /// 文件名和路径,绝不能上报。
  docImportFailed('doc_import_failed'),

  /// 打开了一份病历。**没有任何内容属性,只有「发生了」。**
  /// 回答的决定:档案是被**看**的还是被**堆**的 —— 如果导入了从不打开,
  /// 这就是个垃圾桶,不是助手。
  docOpened('doc_opened'),

  /// 出示了二维码(密文已上传、码已显示)。属性:`record_count_bucket`、`size_bucket`。
  shareQrShown('share_qr_shown'),

  /// 上传失败后用户的选择:`choice`(retry / fallback)。
  /// 这条能回答「断连到底有多常见、用户愿不愿意等」。
  shareUploadRetry('share_upload_retry'),

  /// 降级成简版码(不含原件)。说明云那条路没走通。
  shareQrDegraded('share_qr_degraded'),

  /// 导出可打印文件。属性:`ranged`(是否用了日期筛选)。
  exportCompleted('export_completed'),

  // ── 医生代拍 ──────────────────────────────────────────────────────────────
  // 这是最新、最不确定、赌注最大的功能,却曾经**一个事件都没有**。没有这四条,
  // 「代拍到底成不成立」是盲飞。

  /// 选了身份。属性:`mode`(personal/doctor)、`where`(first=首屏首次选 /
  /// settings=事后在设置里切)。`where` 值钱在于:事后切换说明第一次选错了。
  modeSelected('mode_selected'),

  /// 医生开始了一次代拍(进入代拍流程屏)。属性:`resumed`(是否是回到已建档的病人)。
  proxySessionStarted('proxy_session_started'),

  /// 病人签了知情同意。**同意书是这条流程里最可能的流失点**,不单独埋就只知道
  /// 「掉了」不知道「掉在哪」。started 与它之间的差 = 同意环节流失。
  proxyConsentSigned('proxy_consent_signed'),

  /// 代拍交付成功(加密包已生成)。属性:`count_bucket`、`duration_bucket`。
  /// 耗时决定医生愿不愿意再来 —— 一次代拍要五分钟,就没有第二次。
  proxyShareShown('proxy_share_shown'),

  // ── 认领 ─────────────────────────────────────────────────────────────────
  // ⚠️ 与出码是**两台手机**,没有持久 ID 就无法逐条关联。只看总量比
  // (claim_imported / proxy_share_shown),不做 per-link 关联。

  /// 认领页打开。属性:`entry`(cold=App 被链接拉起 / warm=App 已在运行)。
  /// cold 基本意味着「刚装完就来认领」,是最关键的一条转化路径。
  claimOpened('claim_opened'),

  /// 认领成功。属性:`count_bucket`、`deduped`、`text_only`。
  claimImported('claim_imported'),

  /// 认领失败。属性:`reason`(gone/network/unknown)。
  /// `gone` 尤其值钱:有人扫了已过期的码,说明 12 小时太短或流程太慢 ——
  /// 每一条都代表一次白做的代拍。
  claimFailed('claim_failed'),

  /// 用户关掉了分析。**最后一条上报**,发完即停。
  analyticsOptOut('analytics_opt_out');

  const AnalyticsEvent(this.name);
  final String name;
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
