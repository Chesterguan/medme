// 「参考区间的出处」脚注。原在趋势页底部;2026-10-23 趋势页取消,搬到这里给「现在」页用。
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/widgets/app_snack_bar.dart';

const _hypertensionGuidelineUrl =
    'https://files.sciconf.cn/medcon/2024/08/20240814/2024081410492823875104169.pdf';

class ProvenanceFooter extends StatelessWidget {
  const ProvenanceFooter({super.key});

  Future<void> _openGuideline(BuildContext context) async {
    final ok = await launchUrl(
      Uri.parse(_hypertensionGuidelineUrl),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(appSnackBar(content: const Text('无法打开指南原文,请稍后重试')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = MedColors.of(context);
    final bodyStyle = MedType.secondary.copyWith(color: c.ink3, height: 1.5);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('参考区间的出处', style: MedType.body.copyWith(color: c.ink)),
        const SizedBox(height: 4),
        Text(
          '· 医院化验:来自化验单原件本身 —— 点开卡片下方「查看最新一次的原件」'
          '核对。\n'
          '· 家测(血压、心率等):来自公开发布的临床指南或医学共识,出处写在'
          '各卡片区间下方。\n'
          '· 体温、体重、血糖(家测):目前没有可靠、可引用的家测正常区间,'
          '只显示数值,不做偏高偏低的判断。',
          style: bodyStyle,
        ),
        const SizedBox(height: 4),
        GestureDetector(
          onTap: () => _openGuideline(context),
          child: Text(
            '查看《中国高血压防治指南(2024年修订版)》原文',
            style: bodyStyle.copyWith(
              color: c.sealInk,
              decoration: TextDecoration.underline,
              decorationColor: c.sealInk,
            ),
          ),
        ),
        const SizedBox(height: 2),
        // 期刊卷期 + DOI,和上面那条链接并列。
        //
        // **链接会烂,卷期和 DOI 不会。** [_hypertensionGuidelineUrl] 指的是会议
        // 文件服务上的一个具体路径(入口在联盟官网首页下载中心),路径一旦轮换,
        // 这页就在替一个死链背书;而 `launchUrl` 只在唤不起浏览器时才返回 false,
        // 浏览器打开一个 404 页面在它看来是成功的,所以那条失败提示兜不住这种烂法。
        //
        // 这行字是链接烂掉之后的后备:用户凭卷期或 DOI 照样查得到原文。而且它本身
        // 就是这一段想证明的那件事(「我们引的是正式发表的指南」)最硬的证据 ——
        // 一个 URL 证明不了发表过,一个卷期号能。
        Text(
          '《中华高血压杂志(中英文)》2024年7月第32卷第7期\n'
          'doi:10.16439/j.issn.1673-7245.2024.07.002',
          style: bodyStyle.copyWith(color: c.ink3),
        ),
      ],
    );
  }
}
