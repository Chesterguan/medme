// 分析埋点的红线:**绝不上报内容,数值一律分桶**。
//
// 这是一个装病历的 App。一旦有人在事件属性里塞了文件名、异常消息、或者精确的
// 「第几份/多少字节」,泄漏的就是医疗信息。靠人审代码守不住,所以在这里钉死。
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/analytics.dart';

void main() {
  test('事件名去医疗语义 —— 不含任何能推断病情的词', () {
    // 事件名会和时间戳一起进分析后台。`viewed_lab_result` 这种即使不带数值,
    // 也泄漏了「这个人在看化验单」。全集必须是中性的动作词。
    const forbidden = [
      'lab', 'diagnos', 'prescription', 'medicine', 'drug', 'disease',
      'patient', 'hospital', 'doctor_name', 'symptom', 'icd',
    ];
    for (final e in AnalyticsEvent.values) {
      for (final bad in forbidden) {
        expect(
          e.name.toLowerCase().contains(bad),
          isFalse,
          reason: '事件名 ${e.name} 含医疗语义词「$bad」',
        );
      }
      // 只允许小写字母 + 下划线:杜绝有人把动态内容拼进事件名。
      expect(
        RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(e.name),
        isTrue,
        reason: '事件名 ${e.name} 不是静态 snake_case',
      );
    }
  });

  test('计数分桶:相邻的精确值落进同一个桶,反推不出原值', () {
    expect(Bucket.count(1), '1');
    expect(Bucket.count(2), Bucket.count(5), reason: '2 和 5 应同桶');
    expect(Bucket.count(6), Bucket.count(20));
    expect(Bucket.count(21), Bucket.count(50));
    expect(Bucket.count(51), Bucket.count(100000));
    // 桶的个数要少 —— 桶越细越接近原值。
    final buckets = {for (var i = 1; i <= 500; i++) Bucket.count(i)};
    expect(buckets.length, lessThanOrEqualTo(6));
  });

  test('耗时分桶:毫秒级差异不可见', () {
    expect(
      Bucket.duration(const Duration(milliseconds: 1200)),
      Bucket.duration(const Duration(milliseconds: 2900)),
      reason: '1.2s 和 2.9s 都该落在 <3s',
    );
    expect(Bucket.duration(const Duration(seconds: 5)), '3-10s');
    expect(Bucket.duration(const Duration(minutes: 5)), '>120s');
    final buckets = {
      for (var s = 0; s <= 300; s++) Bucket.duration(Duration(seconds: s)),
    };
    expect(buckets.length, lessThanOrEqualTo(6));
  });

  test('体积分桶', () {
    expect(Bucket.bytes(500 * 1024), '<1MB');
    expect(Bucket.bytes(5452595), '5-20MB'); // 真机上那份 5.2MB 的密文
    expect(Bucket.bytes(200 * 1024 * 1024), '>100MB');
  });

  test('perDoc 能分辨 duration 分辨不了的量级变化', () {
    // perDoc 存在的理由是**分辨率**,不是无限精度。分桶天然看不见小幅改进
    // (4.0s → 3.5s 在任何合理的桶里都不动),那是隐私换来的代价,认了。
    // 它必须做到的是:duration 的一个桶里塞着的 2 倍差异,perDoc 要分得开。
    for (final (a, b) in [
      (const Duration(milliseconds: 4000), const Duration(milliseconds: 8000)),
      (const Duration(milliseconds: 500), const Duration(milliseconds: 2000)),
    ]) {
      expect(Bucket.duration(a), Bucket.duration(b), reason: '前提:总时长桶看不出 $a vs $b');
      expect(
        Bucket.perDoc(a),
        isNot(Bucket.perDoc(b)),
        reason: 'perDoc 必须分得开 $a 和 $b —— 否则它没有存在意义',
      );
    }
  });

  test('单份耗时不被批量份数带偏 —— 这才是 perDoc 的主要用途', () {
    // 4 份各 2 秒 = 总 8 秒。总时长报 '3-10s'(看起来慢),单份报 '1-3s'(其实正常)。
    // 只报总时长的话,「OCR 快不快」会被份数冒充成引擎问题。
    const perDoc = Duration(seconds: 2);
    const total = Duration(seconds: 8);
    expect(Bucket.duration(total), '3-10s');
    expect(Bucket.perDoc(perDoc), '1-3s');
  });

  test('库存 0 单独成桶 —— 空档案不能和「用过一次」混在一起', () {
    expect(Bucket.count(0), '0');
    expect(Bucket.count(0), isNot(Bucket.count(1)));
  });

  test('任期分桶:原始日期不可反推,桶数少', () {
    expect(Bucket.tenure(const Duration(hours: 5)), '0d');
    expect(Bucket.tenure(const Duration(days: 3)), Bucket.tenure(const Duration(days: 7)));
    expect(Bucket.tenure(const Duration(days: 400)), '30d+');
    final buckets = {
      for (var d = 0; d <= 400; d++) Bucket.tenure(Duration(days: d)),
    };
    expect(buckets.length, lessThanOrEqualTo(4), reason: '任期桶多了就接近具体日期');
  });

  test('时段分桶:粗到不构成行踪,但分得开上午和下午', () {
    expect(Bucket.hour(DateTime(2026, 7, 29, 9)), '06-12'); // 上午门诊
    expect(Bucket.hour(DateTime(2026, 7, 29, 15)), '12-18'); // 下午门诊
    expect(Bucket.hour(DateTime(2026, 7, 29, 2)), '00-06');
    expect(Bucket.hour(DateTime(2026, 7, 29, 23)), '18-24');
    final buckets = {
      for (var h = 0; h < 24; h++) Bucket.hour(DateTime(2026, 7, 29, h)),
    };
    expect(buckets.length, 4);
  });

  test('失败原因码永远是枚举名,绝不带异常文本', () {
    // 这是最容易出事的一条:异常消息里常有文件名和绝对路径。
    final leaky = Exception('无法读取 /var/mobile/张建国-血常规-2026-03-11.pdf');
    final code = ImportFailReason.of(leaky);
    expect(ImportFailReason.values, contains(code));
    // 上报的是 `.name`——校验它不含原异常里的任何片段。
    for (final r in ImportFailReason.values) {
      expect(RegExp(r'^[a-zA-Z]+$').hasMatch(r.name), isTrue);
      expect(r.name.contains('/'), isFalse);
    }
    expect(code.name, 'unknown', reason: '认不出来就归 unknown,不猜');
    expect(ImportFailReason.of(Exception('Permission denied')), ImportFailReason.permission);
  });

  test('没问过之前不采 —— 首启同意门的全部意义', () {
    // 隐私政策里写着「数据离开手机的每一种情况都由你主动触发」。默认开启会让这句话
    // 变成假的:首次冷启动在用户看到任何说明之前就已经上报了。
    expect(Analytics.hasAsked, isFalse, reason: '全新安装应当是「没问过」');
    expect(Analytics.isEnabled, isFalse, reason: '没问过就必须是关的');
  });

  test('没配 Key 时整个关闭 —— track 是空操作,绝不抛错', () {
    // 测试环境不会注入 POSTHOG_KEY,所以这里就是「没配」的情形。
    expect(Analytics.isConfigured, isFalse);
    // 关键:即使没初始化,调用 track 也必须安全 —— 它散布在导入/出码等主流程里,
    // 抛错就等于分析拖垮了功能,那是明令禁止的。
    expect(
      () => Analytics.track(AnalyticsEvent.appOpen, {'vault_ok': true}),
      returnsNormally,
    );
    expect(() => Analytics.track(AnalyticsEvent.docImportFailed), returnsNormally);
  });

  test('封闭取值枚举里不许出现身体部位 / 检验项 —— 属性值也是上报面', () {
    // 事件**名**的中性由上面第一条守着,但取值同样会进后台。`kind_group=glucose`
    // 泄漏的东西和一个叫 `viewed_lab_result` 的事件名一样多:都是对机主的健康推断。
    //
    // 这条盯的是最容易被「顺手加细一点」破坏的地方 —— 手动录入本来就有六个类型,
    // 把它们原样报上去只要改一个字符,而那一改没有任何别的地方会红。
    // ⚠️ 这份词表与事件名那份**不同**:少了 `lab`。取值名是 camelCase 的英文词组,
    // `lab` 会命中 `scannerModuleUnavai(lab)le`、`label` —— 一个必然的假阳性,
    // 而假阳性会逼下一个人整条删掉。事件名那边是 snake_case 的短名,不吃这个亏。
    // 这里留下的都是**只可能因为报了身体系统 / 检验项才出现**的词。
    const forbidden = [
      'glucose', 'pressure', 'systolic', 'diastolic', 'heart', 'weight',
      'temperature', 'liver', 'kidney', 'thyroid', 'tumor', 'diagnos',
      'analyte', 'loinc',
    ];
    final reportedValues = [
      ...RecordKindGroup.values.map((e) => e.name),
      ...TrendsFilterControl.values.map((e) => e.name),
      ...VisitSheetAction.values.map((e) => e.name),
      ...VisitSheetEntry.values.map((e) => e.name),
      ...AnalyticsTab.values.map((e) => e.name),
      ...ImportFailReason.values.map((e) => e.name),
      ...ImportCaptureIssue.values.map((e) => e.name),
    ];
    for (final v in reportedValues) {
      for (final bad in forbidden) {
        expect(
          v.toLowerCase().contains(bad),
          isFalse,
          reason: '上报取值「$v」含医疗语义词「$bad」—— 属性值和事件名一样会进后台',
        );
      }
    }
    // 手动录入有六个类型,上报面**必须**只有两档。数字写死在这里:有人把它拆细
    // 的那一刻就红,不用等到 code review。
    expect(
      RecordKindGroup.values.length,
      2,
      reason: '「数值 vs 笔记」两分是刻意的上界 —— 六种自测项是健康推断,不上报',
    );
  });

  test('会话上下文未声明的键 → debug 下立刻炸', () {
    // 上下文跟着**每一条**事件出去,覆盖面比任何单条事件都大,而它此前是全自由的。
    // 与下面那条事件属性的 assert 同一条理由,守的是更大的那一半。
    expect(
      () => Analytics.setContext({'patient_name': '张建国'}),
      throwsA(isA<StateError>()),
    );
    // 已声明的键照常放行。
    expect(
      () => Analytics.setContext({'member_count_bucket': '1'}),
      returnsNormally,
    );
  });

  test('发了未声明的属性 → debug 下立刻炸(release 会被剥掉,线上不受影响)', () {
    // 这是 `AnalyticsEvent.props` 那张表的执行者。属性漂了在后台是**看不出来**的:
    // 图照样画,只是画的东西不对;而目录 `docs/analytics-catalog.md` 是隐私政策与
    // 双清单的底稿,漂了就是对外声明与事实不符。所以宁可在开发期吵一次。
    //
    // ⚠️ 这条与上一条不矛盾:上一条保的是「线上绝不因埋点崩」——assert 在 release
    // 构建里整个被剥掉,所以那个保证依然成立。这里炸的只有开发者自己。
    expect(
      () => Analytics.track(AnalyticsEvent.appOpen, {'count_bucket': '1'}),
      throwsA(isA<StateError>()),
    );
  });
}
