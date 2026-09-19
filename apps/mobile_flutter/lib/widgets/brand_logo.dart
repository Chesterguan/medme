import 'package:flutter/material.dart';

/// 真 logo(毛笔「医」)。**brief §品牌 只允许它出现在四处**:
///
///  · 主页顶栏 [topBar] 30 —— `archive_screen.dart` 的标题行;
///  · 病历本条书脊旁 [bookSpine] 40 —— `record_book_strip.dart`;
///  · 病程档案页头 [topBar] 30 —— `disease_profile_screen.dart`;
///  · 首启场景中央 [splash] 104 —— `first_run_consent.dart`。
///
/// 别处想放品牌,用品牌渐变(`BrandGradientBox`),不要再摆一个 logo —— 到处都是
/// 的标志等于没有标志。
///
/// **不是 app 图标**:`assets/icon/app_icon.png` 是启动/桌面图标,那一张继续用在
/// `main.dart` 的启动画面上,两者不互换。
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.size = topBar});

  static const String assetPath = 'assets/brand/logo112.png';

  static const double topBar = 30;
  static const double bookSpine = 40;
  static const double splash = 104;

  final double size;

  @override
  Widget build(BuildContext context) => ClipRRect(
    // brief §品牌:圆角 22%(相对边长),不是固定 px —— 104 那档要跟着大。
    borderRadius: BorderRadius.circular(size * 0.22),
    child: Image.asset(assetPath, width: size, height: size, fit: BoxFit.cover),
  );
}
