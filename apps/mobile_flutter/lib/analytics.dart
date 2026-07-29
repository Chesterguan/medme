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

  /// 默认开。用户可在设置里关掉,偏好持久保存。
  ///
  /// 之所以敢默认开:**不做持久 ID、不采任何内容**,上报的是「有人导入了一份、用了
  /// 8 秒」这种没法回指到具体人的计数。若日后加了持久 ID,这个默认值必须重新讨论 ——
  /// 那时它就是在处理个人信息了。
  static const _defaultEnabled = true;

  static bool _enabled = _defaultEnabled;
  static bool _started = false;

  static bool get isConfigured => _apiKey.isNotEmpty;
  static bool get isEnabled => _enabled;

  /// 启动时调用。**绝不 await 到阻塞启动**,调用方应 `unawaited(...)`。
  static Future<void> init() async {
    if (!isConfigured) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_prefKey) ?? _defaultEnabled;

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
      if (!_enabled) await Posthog().disable();
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
          ...props,
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
enum AnalyticsEvent {
  /// 打开 App。DAU 基线。注意:**不靠 SDK 的生命周期自动采集**(那个 beforeSend
  /// 拦不住,已关掉),而是我们自己在启动时发一条。
  appOpen('app_open'),

  /// 导入开始。属性:`source`(camera / album / file)。
  docImportStarted('doc_import_started'),

  /// 导入完成。属性:`source`、`page_count_bucket`、`duration_bucket`。
  /// **最核心的一条** —— OCR 耗时分布直接决定要不要优化引擎。
  docImportCompleted('doc_import_completed'),

  /// 导入失败。属性:`source`、`stage`(capture/ocr/parse/save)、`reason_code`。
  /// ⚠️ `reason_code` **必须是预定义枚举** —— 异常消息常带文件名和路径,绝不能上报。
  docImportFailed('doc_import_failed'),

  /// 出示了二维码(密文已上传、码已显示)。属性:`record_count_bucket`、`size_bucket`。
  shareQrShown('share_qr_shown'),

  /// 上传失败后用户的选择:`choice`(retry / fallback)。
  /// 这条能回答「断连到底有多常见、用户愿不愿意等」。
  shareUploadRetry('share_upload_retry'),

  /// 降级成简版码(不含原件)。说明云那条路没走通。
  shareQrDegraded('share_qr_degraded'),

  /// 导出可打印文件。属性:`ranged`(是否用了日期筛选)。
  exportCompleted('export_completed'),

  /// 用户关掉了分析。**最后一条上报**,发完即停。
  analyticsOptOut('analytics_opt_out');

  const AnalyticsEvent(this.name);
  final String name;
}

/// 数值一律分桶再上报 —— 精确值(几份病历、多少字节、多少毫秒)组合起来可能指认到人。
class Bucket {
  Bucket._();

  static String count(int n) {
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

  static String bytes(int n) {
    final mb = n / 1024 / 1024;
    if (mb < 1) return '<1MB';
    if (mb < 5) return '1-5MB';
    if (mb < 20) return '5-20MB';
    if (mb < 100) return '20-100MB';
    return '>100MB';
  }
}
