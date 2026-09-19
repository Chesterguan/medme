import 'package:flutter/material.dart';

import '../design_tokens.dart';
import 'gloss_tile.dart';

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

/// 首启那一屏中央的场景(mockup `s16` 的 `.scene`):104px 的真 logo 微微左旋,
/// 三个光泽图标块飘在周围 —— brief §插画 说的「用光泽图标块语言拼场景」。
///
/// 这是**占位级**的场景:brief 里那套统一风格的 3D 图标还在外包/生成中。用现有
/// 语言先拼一个,到货后整体换掉,这一屏的其余部分不用动。
class FirstRunScene extends StatelessWidget {
  const FirstRunScene({super.key});

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 160,
    child: Stack(alignment: Alignment.center, children: [
      Positioned(left: 40, top: 14, child: Transform.rotate(angle: 10 * 3.14159 / 180,
        child: const GlossIconTile(icon: Icons.water_drop_outlined,
            category: GlossCategory.lab, size: 52))),
      Positioned(right: 70, top: 6, child: Transform.rotate(angle: 6 * 3.14159 / 180,
        child: const GlossIconTile(icon: Icons.medication_outlined,
            category: GlossCategory.med, size: 40))),
      Positioned(right: 40, bottom: 8, child: Transform.rotate(angle: -12 * 3.14159 / 180,
        child: const GlossIconTile(icon: Icons.show_chart,
            category: GlossCategory.imaging, size: 56))),
      Transform.rotate(angle: -6 * 3.14159 / 180,
        child: const BrandLogo(size: BrandLogo.splash)),
    ]),
  );
}
