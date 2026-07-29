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

  test('没配 Key 时整个关闭 —— track 是空操作,绝不抛错', () {
    // 测试环境不会注入 POSTHOG_KEY,所以这里就是「没配」的情形。
    expect(Analytics.isConfigured, isFalse);
    // 关键:即使没初始化,调用 track 也必须安全 —— 它散布在导入/出码等主流程里,
    // 抛错就等于分析拖垮了功能,那是明令禁止的。
    expect(
      () => Analytics.track(AnalyticsEvent.appOpen, {'count_bucket': '1'}),
      returnsNormally,
    );
    expect(() => Analytics.track(AnalyticsEvent.docImportFailed), returnsNormally);
  });
}
