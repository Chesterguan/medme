import 'package:flutter/material.dart';

import 'design_tokens.dart';

/// MedMe 医我 设计令牌 —— 与桌面 / 现有移动端(App.css)一致:teal 品牌色、
/// 柔和背景、圆角卡片。P3 各屏统一从这里取样式,别散落硬编码。
///
/// 设计系统 v1 的规范化令牌在 `design_tokens.dart`(`MedColors` / `MedType` /
/// `MedShape`),已作为 `ThemeExtension` 挂进下面的主题。本类的常量仍被各屏引用,
/// 保留不动;新代码用 `MedColors.of(context)`。
class MedMe {
  MedMe._();

  // 品牌
  static const Color teal = Color(0xFF1789C1);
  static const Color tealDark = Color(0xFF1560A8);
  static const Color tealSoft = Color(0xFFE6F6FA);

  // 中性
  static const Color bg = Color(0xFFF6F8FB);
  static const Color panel = Colors.white;
  static const Color line = Color(0xFFE2E8F0);
  static const Color ink = Color(0xFF1E293B);
  static const Color faint = Color(0xFF94A3B8);
  static const Color danger = Color(0xFFBE123C);

  // 医生模式(代拍病人纸质材料)专属强调色:橙色,与主品牌 teal 明显区分——
  // 任何一屏出现这个颜色就是提醒「这不是你自己的档案」。
  static const Color proxyOrange = Color(0xFFC2570C);
  static const Color proxyOrangeSoft = Color(0xFFFCEEE0);

  static ThemeData theme() {
    final scheme = ColorScheme.fromSeed(
      seedColor: teal,
      primary: teal,
      surface: panel,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // 设计系统 v1 令牌。挂上去只是让各屏取得到,本身不改任何现有配色。
      extensions: const <ThemeExtension<dynamic>>[MedColors.light],
      scaffoldBackgroundColor: bg,
      fontFamily: 'PingFang SC',
      appBarTheme: const AppBarTheme(
        backgroundColor: panel,
        foregroundColor: ink,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: panel,
        indicatorColor: tealSoft,
        elevation: 3,
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      cardTheme: CardThemeData(
        color: panel,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: line),
        ),
        margin: EdgeInsets.zero,
      ),
    );
  }
}
