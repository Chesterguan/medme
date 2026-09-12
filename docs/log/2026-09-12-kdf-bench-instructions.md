# 2026-09-12 KDF 真机基准工具 —— Task 14(a)

Task 14 只做了 (a):工具本身。(b)(c)(挑参数、改 `KDF_DEFAULT`/`AccountFlow.kdf`)要等这份表填回来才做——这里不猜数字。

## 这是什么

账号屏(已登录 → 「账号管理」区块最下面)加了一行 **debug-only**「KDF 基准测试」。只在
`kDebugMode` 下出现,不落盘、不上传,纯本机跑一遍 `syncKdfBenchMs` 拿毫秒数。

代码:`apps/mobile_flutter/lib/screens/account_screen.dart`(`_kdfBenchSection`/`_runKdfBench`)。

## 怎么跑

**别用 release,debug 就够**(`apps/mobile_flutter/CLAUDE.md` 硬规矩):

```bash
# 先看设备
flutter devices

# 华为 Mate 9(或任意安卓真机)
flutter run -d <mate9-device-id>

# iPhone(接好 Xcode 签名的那台)
flutter run -d <iphone-device-id>
```

跑起来后:先登录/解锁账号(没有账号也行,「设备管理」这些区块能不能加载不影响这一行本身;
但账号屏得先走到「已就绪」阶段才看得到「账号管理」)。滚动到「账号管理」→ 底部「KDF 基准测试
(仅 debug)」→ 点「运行 KDF 基准测试」。

- 顺序跑 4 档 m_kib(16384/32768/65536/131072 KiB)× 2 档 t(2/3),p 固定 1,共 8 格。
- 每格测 2 次取更小值,串行(不并发——老机器就是要测的对象,并发只会互相抢资源,数字没意义)。
- 某一格如果低于 argon2 自己的下限会抛错(`m_kib >= 8` 且 `m_kib >= 8·p`,`t >= 1`,
  `1 <= p <= 0xFFFFFF`——这四档都远高于下限,正常不会触发,除非机器上的 argon2 版本行为有异),
  那一格显示 `ERROR: ...`,其它格照常跑完,不中断整轮。
- 跑完点「复制结果」,粘贴到下面的表格里(纯文本,含 `Platform.operatingSystem` +
  `operatingSystemVersion`,不含任何设备 id)。

## 挑参数的验收规则(来自 spec/brief,不是本次发明)

`docs/superpowers/sdd/2026-09-11-account-keys-sync/task-14-brief.md` 与设计 spec 的风险项
（`Argon2 在老安卓机上的耗时 → 参数按 Mate 9 实测定`）给的规则:

> 取「Mate 9 上 ≤ 1.5 s」的最大内存档,作为 `KDF_DEFAULT`(`packages/sync/src/keys.rs`)与
> `AccountFlow.kdf`(`apps/mobile_flutter/lib/account_flow.dart`)的新值,两处改成同一组数。

即:在下表 Mate 9 那一栏里,从 m_kib 大到小找第一个 `min_ms <= 1500` 的行,那一档
(m_kib, t, p=1)就是新参数。iPhone 那栏只是确认新参数在 iOS 上也够快,不参与挑选
（iPhone 性能明显强于 2016 年的 Kirin 960,不会是瓶颈)。

floor(下限)由 `argon2` crate 自己在 `Params::new` 里把关,`syncKdfBenchMs`
(`apps/mobile_flutter/lib/src/rust/api/vault_sync.dart`)不做任何 clamp/静默改写——
越界直接抛错,不会跑出一个看起来很快但根本没跑满的 `~0ms`。

## 结果表(待填 —— 现在都是占位符)

### 华为 Mate 9(2016 Kirin 960)

设备信息(粘贴「复制结果」第一行):`<待填>`

| m_kib | t | p | min_ms |
|---|---|---|---|
| 16384 | 2 | 1 | |
| 16384 | 3 | 1 | |
| 32768 | 2 | 1 | |
| 32768 | 3 | 1 | |
| 65536 | 2 | 1 | |
| 65536 | 3 | 1 | |
| 131072 | 2 | 1 | |
| 131072 | 3 | 1 | |

### iPhone

设备信息:`<待填,如 ios 17.5>`

| m_kib | t | p | min_ms |
|---|---|---|---|
| 16384 | 2 | 1 | |
| 16384 | 3 | 1 | |
| 32768 | 2 | 1 | |
| 32768 | 3 | 1 | |
| 65536 | 2 | 1 | |
| 65536 | 3 | 1 | |
| 131072 | 2 | 1 | |
| 131072 | 3 | 1 | |

### 选定参数(填完两张表之后再填这一行)

`KDF_DEFAULT` / `AccountFlow.kdf` = `(m_kib=<?>, t=<?>, p=1)` —— Task 14(b)/(c) 据此改代码。
