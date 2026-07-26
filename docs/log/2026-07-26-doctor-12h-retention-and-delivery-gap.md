# 2026-07-26 · 医生代拍:阅后即焚 → 12 小时本地保留(已实现并真机验过)+ 发现交付通道断点

> 执行的是 [2026-07-25 交接文档](2026-07-25-NEXT-doctor-mode-12h-retention.md) 里的规范。
> 分支 `feat/doc-geometry`(仍未合 main)。真机:华为 Mate 9 / MHA-L29 / Android 8.0(API 26),release 包。

## 做了什么

代拍从「用完即焚」改成「本机最多留 12 小时,到点自动删」+「今日病历表(按病人名)」+「清空」。

架构按交接文档拍板的走:**每个代拍病人 = 一个独立保险箱**,走与患者模式完全相同的 `openVault` + 普通导入链路,
不再用 `vault_ephemeral`(那个模块留着未删,`main.dart` 的 `EphemeralSession.sweep()` 保留 —— 它现在的作用
是清理旧版本残留在临时目录里的即焚会话,是升级路径的一部分)。

| 文件 | 内容 |
|---|---|
| `apps/mobile_flutter/lib/proxy_patient_manager.dart`(新) | 病人表 + 12h TTL + 同意/已确认/姓名不匹配落盘;命名空间 `<support>/proxy_patients.json`,与患者模式 `profiles.json` 互不可见 |
| `lib/vault_boot.dart` | `openProxyPatientVault` / `ensureProxyVaultOpen` / 开箱 FIFO 队列 |
| `lib/screens/doctor/doctor_home_screen.dart` | 今日病历表(姓名 · 份数 · 还剩几小时)+ 单删 + 清空 |
| `lib/screens/doctor/proxy_intake_flow.dart` | 切到普通 `vault.*`;交付后不再 wipe;支持 `patientId` 续拍 |
| `rust/src/api/vault.rs` | 新增 `create_proxy_share` / `proxy_summary` / `current_vault_root` |
| `packages/parser/src/lib.rs` | 姓名/性别/年龄的冒号改为可选(见下) |

### 与交接文档的三处偏离(都是读代码后发现原设定不成立)

1. **「交付走现有 `build_encrypted_share`」不成立。** 普通 vault 的 `create_share` 不收 consent 也不收
   confirmed_ids(`rust/src/api/vault.rs:642`),带同意的版本**只存在于 ephemeral 那条路**
   (`vault_ephemeral.rs:724` → `build_encrypted_share_with_consent_and_confirmed`)。
   故新增 `create_proxy_share`(纯新增,复用同一个底层函数,患者模式那条路一个字没动)。
   摘要卡同理新增 `proxy_summary(confirmed_ids)`。
2. **确认状态不能放 Rust 内存。** ephemeral 的 `confirmed` 是进程内 `Mutex<HashMap>`(`vault_ephemeral.rs:102`),
   活不过 12 小时窗口里的 app 重启。改为 Dart 侧按病人落盘,交付时作为 `confirmedIds` 传进去 ——
   Rust 侧不落确认状态 = **不动保险箱格式,不新增事件类型**。
3. **姓名不匹配没走 `ReviewState`。** 那套状态以 `ProfileManager.current` 为键,属患者模式命名空间,
   代拍往里写会污染。改为在代拍流程内直接比对 + 橙条提醒,落在 `proxy_patients.json`,零耦合。

### 「进程级 vault 被顶掉」怎么解决的(重点,别退回成注释约定)

Rust 的 vault 是**进程级单例**,开代拍病人的箱子会顶掉医生自己的档案。第一版只在注释里写「调用方记得换回来」——
不够,因为各调用点 `await` 的先后不保证 FFI 到达顺序:「退出代拍时换回」与「紧接着开下一个病人」一旦反序,
采集就会写进医生自己的档案。改成三层,任何一层都不依赖顺序约定:

1. **FIFO 开箱队列**(`vault_boot.dart` 的 `_serializedOpen`):所有开箱排一条队,先发出先生效。
2. **`current_vault_root()`**(新 Rust 函数):能问「此刻开着的是哪个箱子」。
3. **`ensureProxyVaultOpen(patientId)`**:每次落库/交付前比对,不对就重开,重开还不对就**中止写入**并报错。

顺带修掉自己引入的一个 bug:放弃空病人时 `_patientId` 被清成 null 会让 `dispose` 跳过 vault 还原,
进程会攥着一个刚被删掉的目录 —— 改用独立的 `_openedProxyVault` 标记。

### parser 姓名正则放宽(改了共享代码,记一笔)

真机第一次跑完,今日病历表全是「未命名病人」。根因:`packages/parser/src/lib.rs` 的姓名正则**强制要求冒号**
(`(?:姓名|名字)[:：]`),而纸质报告的「姓名/性别/年龄」是靠**表格对齐**排的,拍照 OCR 出来是
`姓名孟丁 性别男`,冒号在版面里根本不存在。这让「按病人名列」这个主诉求半残。

改法:保留带冒号的规则优先,新增一条无冒号兜底,**只认「2-4 汉字 + 紧跟空白或行尾」**——
粘连的 `姓名孟丁性别男` 宁可提不出,也不会把「孟丁性别」当成名字(有负例测试守着)。性别/年龄同样放宽冒号。
影响面:患者模式导入拍照报告也会因此更容易自动命名,是改进而非破坏。全 workspace Rust 测试无回归。

## 真机验证结果(release 包,MHA-L29)

先在个人模式载入示例数据(张建国 22 份)作为「医生自己的档案」基线,再切医生模式代拍。

| 验证项 | 结果 |
|---|---|
| 交付后不再即焚 | ✅ 病人留在今日病历表「1 份 · 还剩 11 小时自动删」 |
| 跨 app 重启存活 | ✅ 强杀重启后:病人在、文档在、**已确认 1 份**在、摘要卡重建 |
| 不污染医生自己的档案 | ✅ 代拍前后个人模式都是张建国 **22 份**,病人的化验单没混进去 |
| `create_proxy_share` | ✅ 加密文件 + 口令生成成功(带同意 + 已确认) |
| `proxy_summary` | ✅ 0 份确认时无摘要卡,确认 1 份后出现 |
| 姓名自动命名 | ✅ parser 修复后显示真实姓名(如「陈秀玲」),不再是「未命名病人」 |
| 清空 | ✅ 一次清干净,回空状态 |
| 12 小时口径一致 | ✅ 主页 / 顶部横幅 / 同意屏 / 交付对话框四处一致 |

真机测出并已修的两个 bug:
- **交付对话框仍写「这台设备不会留底」** —— 现在留 12 小时,这是对病人的假承诺(红线)。已改。
- **今日病历表全是「未命名病人」** —— 即上面的 parser 冒号问题。

## 发现:诊室里没有一条能用的交付通道(微服务器的立项依据)

实测「分享文件」的系统面板,这台华为上是:快速分享、电子邮件、Google Drive、蓝牙、Gmail、Huawei Beam(NFC)、Wi-Fi 直连。
**注意边界:这台测试机没装微信/QQ**(已确认),真实医生手机上微信一定在,不能由此推断「微信不会出现」。

但去掉微信后剩下的,把断点照出来了 —— 在诊室把文件交给一个**陌生**病人:
蓝牙/Beam/Wi-Fi 直连都要和病人手机配对(慢,且 Beam/直连基本华为↔华为);邮件要先问到邮箱(老人多半没有);
Google Drive 病人打不开。**唯一现实可用的是微信,而微信要求医生和病人互加好友** —— 这恰是医生最不愿意的一步,
而且加完就是长期联系人,不是一次性交付。

所以微服务器要解决的**不是「存不下」,是「诊室里没有一条不需要加好友、不需要病人装 app、不需要配对的交付通道」**。
这印证了 memory `doctor-scan-cloud-claim-design` 的形态(瞬时云 + 扫码/短链 + 一链一令一按钮):病人只需用自带相机扫一下。

**本次不做微服务器**(用户确认)。12 小时保留本身降低了它的紧迫性 —— 以前一次没发成东西就没了,现在 12 小时内能回来重发。

## 已知遗留

- **本地 debug 装机在 ort-sys 落地后一直是坏的**(与本次改动无关):cargokit 给 debug 变体**硬编码**追加
  `android-x86`/`x64`(`rust_builder/cargokit/gradle/plugin.gradle:142-145`),而 ort 没有 `i686-linux-android`
  的预编译库。所以 `flutter run`(debug)必失败,本地只能走 release 路径;CI 用的是
  `flutter build apk --release --target-platform android-arm64`(`.github/workflows/mobile.yml:89`)。
  想修就在 cargokit 那里加个跳过 x86 的补丁,尚未做。
- 跑过 `flutter test` 之后再出 release 包会失败:`GeneratedPluginRegistrant.java` 会带上 dev 依赖
  (integration_test / patrol),release 变体编不过。删掉该生成文件重跑即可。
- 安卓 8 的相册/文件多选要**长按**才进多选模式(系统 DocumentsUI 行为,非本项目代码问题;
  `import_flow.dart` 一直是 `pickMultiImage()` + `allowMultiple: true`)。Android 13+ 无此问题,不加提示文案。
- 异步上传微服务器:连 TODO hook 都没留(没有调用方的 hook 是死代码,要做时再加)。
- `feat/doc-geometry` 仍未合 main。
