// 「最近归档」卡片的去重回归测试。
//
// 模拟器实测发现:一张卡把同样的信息说三遍 ——
//
//     门诊 · 2026-06-20        2026-06-20      ← 日期两遍
//     门诊                                      ← 类型两遍
//
// 三处各自都对(标题来自保险箱、右侧独立渲染日期、副标题渲染类型),合起来是坏的。
// 根因是标题常常已经把类型和日期拼进去了,而渲染侧无条件又各来一次。
//
// 这里测的是**裁剪判据本身**,不拉起整个概览屏(那需要 Rust FFI)。
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/screens/overview_screen.dart';

void main() {
  group('最近归档卡片:标题里已有的不重复', () {
    test('标题含日期时,右侧不再单独渲染日期', () {
      expect(
        visitCardShowsDate(title: '门诊 · 2026-06-20', date: '2026-06-20'),
        isFalse,
      );
    });

    test('标题不含日期时,右侧照常渲染', () {
      expect(
        visitCardShowsDate(title: '四川大学华西医院', date: '2026-06-20'),
        isTrue,
      );
    });

    test('标题含类型时,副标题不再重复类型', () {
      expect(
        visitCardDesc(title: '门诊 · 2026-06-20', kindLabel: '门诊', docCount: 1),
        isEmpty,
      );
    });

    test('标题不含类型时,副标题给出类型', () {
      expect(
        visitCardDesc(title: '北京协和医院', kindLabel: '门诊', docCount: 1),
        '门诊',
      );
    });

    test('多份记录时份数照常显示,与类型是否重复无关', () {
      expect(
        visitCardDesc(title: '门诊 · 2026-06-20', kindLabel: '门诊', docCount: 3),
        '3 份记录',
      );
      expect(
        visitCardDesc(title: '北京协和医院', kindLabel: '门诊', docCount: 3),
        '门诊 · 3 份记录',
      );
    });
  });
}
