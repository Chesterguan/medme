import 'package:flutter/material.dart';

import 'design_tokens.dart';

/// MedMe 医我 主题装配 —— 把 `design_tokens.dart` 的规范化令牌(`MedColors` /
/// `MedType` / `MedShape`)接进 Flutter 的 `ThemeData`。P3 各屏统一从
/// `MedColors.of(context)` 取样式,别散落硬编码。
///
/// 本类曾经还有一套 `MedMe.teal`/`bg`/`faint`/`danger` 等旧颜色常量供各屏直接
/// 引用;2026-09 逐屏迁完、清零后已删除。
class MedMe {
  MedMe._();

  // 代拍专属强调色曾经是橙 `#C2570C` —— **已删**。
  // 它离化验「偏高」的琥珀 `#B45309` 太近(色相差 1°),同一个 app 里一个橙点既
  // 可能是「这不是你的档案」也可能是「这项指标偏高」,语义被稀释。现在代拍的
  // 主色是令牌 `MedColors.proxy`(紫 #7C4096),取在色板里唯一没被语义占用的色相
  // 空档上,见 `design_tokens.dart` 的字段文档。

  /// 全 app 主题。**设计系统 v1 的落点**:底色/边框/字阶/圆角一律取自
  /// `MedColors.light` / `MedType` / `MedShape`。全部屏(含个人模式主链路与代拍)
  /// 都已改走 `MedColors.of(context)`,不再有旧颜色常量这条岔路。
  ///
  /// **深色主题刻意没挂。** `MedColors.dark` 已备好(含代拍的深色主色),但挂上
  /// `darkTheme:` 会立刻改动每一屏视觉。挂它是独立一件事。
  static ThemeData theme() {
    const c = MedColors.light;
    final scheme = ColorScheme.fromSeed(
      seedColor: c.seal,
      // 白字压 seal(#1789C1) 只有 3.90:1,低于 WCAG AA 的 4.5 —— 目标用户含老年人,
      // 填充按钮一律用 sealInk(6.76:1)。seal 保留给图标/描边/大标题(非文本门槛 3:1)。
      primary: c.sealInk,
      surface: c.surface,
    );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: MedType.family,
      fontFamilyFallback: MedType.fallback,
    );
    // 控件圆角统一 10(规范 §四:按钮、输入框这一档)。
    final controlShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(MedShape.radiusControl),
    );
    // 按钮文字统一 body(16·600)—— 比 Material 默认的 14 大一档,目标用户含老年人。
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
        indicatorColor: Colors.transparent,   // mockup 底栏没有药丸指示块,靠颜色区分
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        labelTextStyle: WidgetStatePropertyAll(MedType.caption),
      ),
      dividerTheme: DividerThemeData(color: c.line, thickness: 1, space: 1),
      // brief §形:卡**无边框**,靠阴影分层(旧规范是反过来的:靠边框不靠阴影)。
      cardTheme: CardThemeData(
        color: c.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MedShape.radiusCard),
          side: BorderSide.none,
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
        // R6:mockup `.sheet{border-radius:26px 26px 0 0}`—— 走 MedShape.radiusSheet
        // 令牌(全 app 最大的一档),不写裸数字。
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(MedShape.radiusSheet),
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
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(controlShape),
          textStyle: buttonLabel,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(controlShape),
          textStyle: buttonLabel,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(controlShape),
          textStyle: buttonLabel,
        ),
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
