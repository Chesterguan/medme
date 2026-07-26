# 2026-07-26 · 代拍 12 小时保留落地 + 发现诊室里没有能用的交付通道

> 决策见 [ADR 0008](../ADR/0008-doctor-proxy-patient-vaults-12h-retention.md)。真机:华为 Mate 9 / Android 8,release 包。

代拍从「用完即焚」改成「本机留 12 小时」+ 今日病历表 + 清空。每病人一个独立保险箱,
走患者模式同一条 `openVault` + 普通导入链路;不再用 `vault_ephemeral`。

实现时发现原规范三处不成立,都记在 ADR 0008 里:普通 vault 的 `create_share` 不带
consent/confirmed_ids(故新增 `create_proxy_share`);确认状态不能放 Rust 内存(活不过重启);
姓名不匹配不能走 `ReviewState`(那是患者模式命名空间)。

真机全流程验通:交付后不删、强杀重启后病人和确认状态都在、代拍前后个人模式都是 22 份
(没被污染)、清空干净。

**parser 姓名正则原本强制要求冒号**,而纸质报告靠表格对齐排版,拍照 OCR 出来是
`姓名孟丁 性别男` 没有冒号 —— 今日病历表因此全是「未命名病人」。已放宽(带负例测试:
粘连时宁可提不出也不误判)。这条影响患者模式导入,不只代拍。

## 交付通道:微服务器的立项依据

实测系统分享面板(这台机**没装微信**,真机上会有,不能由此推断微信不出现)。
去掉微信后剩下的都不可用:蓝牙/Beam/Wi-Fi 直连要和病人手机配对;邮件要问到邮箱;
Google Drive 病人打不开。**唯一现实可用的是微信,而它要求医生和病人互加好友** ——
医生最不愿意的一步,且加完就是长期联系人,不是一次性交付。

所以微服务器要解决的不是「存不下」,是**「诊室里没有一条不需要加好友、不需要病人装 app、
不需要配对的交付通道」**。印证了 memory `doctor-scan-cloud-claim-design` 的形态(扫码 + 口令认领)。
本次不做 —— 12 小时保留已经把「一次没发成就没了」这个最痛的点解掉了。

## 遗留

- **本地 debug 装机自 PP-OCR 落地起就是坏的**(与本次无关):cargokit 给 debug 硬编码追加
  `android-x86`(`rust_builder/cargokit/gradle/plugin.gradle:142-145`),而 ort 没有 i686 预编译库。
  本地只能走 release;CI 用 `--release --target-platform android-arm64`。修法是给 cargokit 打个跳过 x86 的补丁。
- 跑过 `flutter test` 后再出 release 包会失败(`GeneratedPluginRegistrant.java` 带上了 dev 依赖),删掉重跑即可。
- 安卓 8 相册多选要长按(系统 DocumentsUI 行为,非本项目问题),Android 13+ 无此问题。
- 微服务器:没留 TODO hook(没有调用方的 hook 是死代码)。
