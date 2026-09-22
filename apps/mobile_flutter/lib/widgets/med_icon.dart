import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// 行首图标:一枚单色线性 `Icon`,放在 44×44 的槽里(`MedBrand.iconSlot`),行与行的
/// 文字起点才对得齐。**没有底块、没有渐变、没有类别色**(减法稿 2026-09-22:类别
/// 上色没有信息)。默认 `ink2`;只有这一行本身在报警时才传 [color](设置里的危险
/// 项、姓名不符的红横幅用 `critical`)。
class MedIcon extends StatelessWidget {
  const MedIcon(this.icon, {super.key, this.color, this.size = MedBrand.iconSize});

  final IconData icon;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: MedBrand.iconSlot,
    height: MedBrand.iconSlot,
    child: Center(child: Icon(icon, size: size, color: color ?? MedColors.of(context).ink2)),
  );
}

/// 成员头像:`line2` 圆底 + `ink2` 首字。**不跟系统字号放大**——固定尺寸的装饰字形,
/// 姓名在旁边照常放大(`MedType` 文档里的唯一例外)。
class MedAvatar extends StatelessWidget {
  const MedAvatar(this.letter, {super.key, this.size = MedBrand.iconSlot});

  final String letter;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    // 误报:width/height/decoration 都在用,触发只因 child 是
    // `MediaQuery.withNoTextScaling`(探过:child 换成裸 Text 就不报)。
    // ignore: avoid_unnecessary_containers
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.line2, shape: BoxShape.circle),
      child: MediaQuery.withNoTextScaling(
        child: Text(letter, style: MedType.subtitle.copyWith(color: c.ink2, fontSize: size * 0.41)),
      ),
    );
  }
}
