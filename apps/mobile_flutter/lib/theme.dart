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

  /// 全 app 主题。**设计系统 v1 的落点**:底色/边框/字阶/圆角一律取自
  /// `MedColors.light` / `MedType` / `MedShape`,不再从上面那些旧常量取。
  ///
  /// 上面的 `MedMe.*` 常量仍被医生模式各屏引用,故保留;个人模式主链路的各屏已改
  /// 走 `MedColors.of(context)`。两套中性色有细微差(旧 ink #1E293B 偏蓝、faint
  /// #94A3B8 偏浅),收敛医生模式是独立一件事。
  ///
  /// **深色主题刻意没挂。** `MedColors.dark` 已备好,但挂上 `darkTheme:` 会立刻
  /// 改动每一屏 —— 包括本次没动、仍在读旧常量的医生模式各屏,那会得到一个半深不
  /// 浅的 app。挂它是独立一件事。
  static ThemeData theme() {
    const c = MedColors.light;
    final scheme = ColorScheme.fromSeed(
      seedColor: c.seal,
      primary: c.seal,
      surface: c.surface,
    );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: 'PingFang SC',
    );
    // 控件圆角统一 10(规范 §四:按钮、输入框这一档)。
    final controlShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(MedShape.radiusControl),
    );
    // 按钮文字统一 body(15·600)—— 比 Material 默认的 14 大一档,目标用户含老年人。
    final buttonLabel = WidgetStatePropertyAll(
      MedType.body.copyWith(fontWeight: FontWeight.w600),
    );
    return base.copyWith(
      extensions: const <ThemeExtension<dynamic>>[MedColors.light],
      scaffoldBackgroundColor: c.paper,
      // 正文墨色统一到 `ink`;不写死字号,系统字号放大照常生效。
      textTheme: base.textTheme.apply(bodyColor: c.ink, displayColor: c.ink),
      appBarTheme: AppBarTheme(
        backgroundColor: c.surface,
        foregroundColor: c.ink,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        titleTextStyle: MedType.title.copyWith(color: c.ink),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: c.surface,
        indicatorColor: c.sealWash,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        // 层次靠边框不靠阴影:底栏与内容之间用一道 `line`,不用投影。
        labelTextStyle: WidgetStatePropertyAll(MedType.caption),
      ),
      dividerTheme: DividerThemeData(
        color: c.line,
        thickness: 1,
        space: 1,
      ),
      cardTheme: CardThemeData(
        color: c.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MedShape.radiusCard),
          side: BorderSide(color: c.line),
        ),
        margin: EdgeInsets.zero,
      ),
      // 弹窗与底部表:外层容器,取卡片这一档圆角。
      dialogTheme: DialogThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MedShape.radiusCard),
        ),
        titleTextStyle: MedType.title.copyWith(color: c.ink),
        contentTextStyle: MedType.body.copyWith(color: c.ink2),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(MedShape.radiusCard),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.ink,
        contentTextStyle: MedType.body.copyWith(color: c.surface),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MedShape.radiusControl),
        ),
      ),
      // 三级按钮(规范 §六):主 = seal 纯色**不用渐变**,一屏只允许一个;
      // 次 = seal-wash 底 + seal-ink 字;三 = 透明底 + line 描边。
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(shape: WidgetStatePropertyAll(controlShape), textStyle: buttonLabel),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(shape: WidgetStatePropertyAll(controlShape), textStyle: buttonLabel),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(shape: WidgetStatePropertyAll(controlShape), textStyle: buttonLabel),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: c.seal),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MedShape.radiusControl),
          borderSide: BorderSide(color: c.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MedShape.radiusControl),
          borderSide: BorderSide(color: c.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MedShape.radiusControl),
          borderSide: BorderSide(color: c.seal, width: 1.5),
        ),
      ),
    );
  }
}
