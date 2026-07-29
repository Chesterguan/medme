# 埋点目录(Analytics Catalog)

**最后更新:2026-07-29**

这份文档是「我们到底采了什么」的唯一权威清单。三个用途:

1. **半年后还能分析数据** —— 事件名孤零零躺在后台没人记得它当初想回答什么问题。
2. **工信部双清单的底稿** —— 「已收集个人信息清单」和「与第三方共享个人信息清单」直接从这里生成。
3. **隐私政策的事实依据** —— 政策里写的每一句「我们收集…」都必须能在这里找到对应行。

> `test/analytics_catalog_test.dart` **双向**钉住这份文档与 `lib/analytics.dart` 的
> `AnalyticsEvent` 枚举:代码里加了事件而这里没写(或反过来)都会让测试红。
> 所以这份文档不会烂 —— 它烂了 CI 就不过。

---

## 一、三条硬约束

1. **只采行为,不采内容。** 病历文字、文件名、OCR 结果、药名、诊断、检验值、就诊日期、医院名 —— 一个字都不出设备。
2. **用户可以关。** 设置 → 「帮助改进 MedMe」。默认开。
3. **绝不影响功能。** 上报失败静默丢弃,永不阻塞 UI(`Analytics.track` 是 fire-and-forget,见 `lib/analytics.dart`)。

## 二、两个刻意的取舍

### 不做跨会话持久 ID

每次启动 `Posthog().reset()`,`distinct_id` 只在本次会话内有效。

- **理由**:持久 ID 会让这些事件变成个人信息(PIPL 第 73 条:去标识化仍是个人信息,只有无法复原的匿名化才脱离管辖)。而这个 App 的数据属于**敏感个人信息**,出境没有「10 万人以下」豁免。
- **代价**:**没有队列留存曲线**。会话内漏斗算得出,跨会话拼接算不出。
- **替代品**:见下面的「设备任期」——不认人也能问出「有没有人留下来」。

### 查看器(hosted viewer)**永不埋点**

这是一条红线,不是暂缓。详见 `docs/ADR/0009-no-analytics-in-viewer.md`。

后果:**医生打开了没有、看了多久、翻没翻原件 —— 永远测不到。** 接受。

---

## 三、会话上下文(每条事件都自动带)

在 `_send` 里合并进每条事件(`lib/analytics.dart`)。**设备描述自己 ≠ 设备标识自己**:原始值(首次使用日期、精确份数、精确钟点)永不上传,只上传分桶后的 4-5 个取值,基数低到拼不出指纹。

| 属性 | 取值 | 来源 | 回答什么 |
|---|---|---|---|
| `tenure_bucket` | `0d` / `1-7d` / `8-30d` / `30d+` | 本机存的首次使用日期 | **留存的替代品**:今天的会话里有多少来自用了 30 天以上的设备 |
| `session_index_bucket` | `1` / `2-5` / `6-20` / `21-50` / `50+` | 本机启动计数 | 与 tenure 交叉:是天天用,还是隔一个月回来一次 |
| `library_size_bucket` | `0` / `1` / `2-5` / `6-20` / `21-50` / `50+` | `profile.recordCount`,档案屏载入时顺带记(`archive_screen.dart:_load`) | **有没有人在累积**。如果永远是 `0`/`1`,这是个一次性工具不是档案 |
| `mode` | `personal` / `doctor` / `unset` | `AppMode` | 每个指标都能按身份切开看 |
| `hour_bucket` | `00-06` / `06-12` / `12-18` / `18-24` | 发送时的**本地**钟点 | 关了 GeoIP 后服务端只剩 UTC。**代拍是不是发生在门诊时间**,是「医生真的在诊室用」最直接的证据 |

> `library_size_bucket` 在医生模式下不会出现(档案屏不构建),这是对的 —— 医生没有个人档案。

---

## 四、事件全集(17 条)

每条对应**一个决定**。答不出决定的事件不该存在。

### 基线

| 事件 | 属性 | 触发点 | 回答什么决定 |
|---|---|---|---|
| `app_open` | `vault_ok` | `main.dart:130` | 有人用吗。`vault_ok=false` = **开箱失败**,此前完全不可见,用户只看到一句红字 |

### 导入

| 事件 | 属性 | 触发点 | 回答什么决定 |
|---|---|---|---|
| `doc_import_started` | `source`, `count_bucket` | `import_flow.dart:165` | 三个采集入口(拍照/相册/文件)谁在被用 |
| `doc_import_completed` | `source`, `count_bucket`, `failed_bucket`, `duration_bucket`, `per_doc_duration_bucket`, `is_first` | `import_flow.dart:288` | **换不换 OCR 引擎**(看 `per_doc`);**要不要做后台导入**(看 `duration`);**首次导入成功率**(看 `is_first`) |
| `doc_import_failed` | 同上 + `stage`, `reason_code` | `import_flow.dart:288` | 失败集中在哪一步、哪个原因 |
| `doc_opened` | 无 | `archive_screen.dart:369` | **档案是被看的还是被堆的。** 导入了从不打开 = 垃圾桶不是助手 |

**两个耗时不是重复。** 总时长被份数主导,只能回答「用户要等多久」;单份时长才是引擎质量 —— 5 份各 2 秒,总时长报 `3-10s` 像是慢,单份报 `1-3s` 其实正常。当初只报总时长,等于把批量冒充成了引擎问题。

⚠️ **分桶看不见小幅改进**(4.0s → 3.5s 在任何合理的桶里都不动)。要精确耗时只能上真机基准测试,别指望埋点 —— 这是隐私换来的代价。

`source`:`camera` / `gallery` / `files`
`stage`:`capture` / `ocr` / `save`
`reason_code`:`unsupported` / `corrupt` / `ocrEmpty` / `storage` / `permission` / `unknown`(枚举 `ImportFailReason`)

> ⚠️ `reason_code` 由错误串粗分类得到,不是 core 返回的类型化错误。**如果 `unknown` 在数据里占了大头,就是该让 Rust 侧返回错误码的信号。**

### 导出与出码

| 事件 | 属性 | 触发点 | 回答什么决定 |
|---|---|---|---|
| `export_completed` | `ranged` | `export_screen.dart:143` | 导出有没有人用;用不用日期筛选(**不报是哪段日期** —— 那是就诊时间) |
| `share_qr_shown` | `record_count_bucket`, `size_bucket` | `qr_share_screen.dart:147` | 出码这条路走通了几次、载荷多大 |
| `share_upload_retry` | `choice`(retry/fallback) | `qr_share_screen.dart:164, 202` | **断连有多常见、用户愿不愿意等** |
| `share_qr_degraded` | `choice` | `qr_share_screen.dart:174` | 云那条路没走通的比例 |

「导出完成」= **文件已生成**。之后的系统分享面板用户可能取消,拿不到可靠回调 —— 与代拍交付同一口径。

### 医生代拍

> 这是最新、赌注最大的功能,此前**一个事件都没有**。

| 事件 | 属性 | 触发点 | 回答什么决定 |
|---|---|---|---|
| `mode_selected` | `mode`, `where`(first/settings) | `mode_picker_screen.dart:16`, `settings_screen.dart:194` | 几成用户是医生。**`where=settings` 占比高 = 「你是?」那一屏问得不清楚** |
| `proxy_session_started` | `resumed` | `proxy_intake_flow.dart:96` | 代拍到底有没有人用。`resumed=true` = 12 小时内回来补拍 |
| `proxy_consent_signed` | 无 | `proxy_intake_flow.dart:156` | **同意书是最可能的流失点。** started 与它的差 = 病人在同意环节走掉了 |
| `proxy_share_shown` | `count_bucket`, `duration_bucket` | `proxy_intake_flow.dart:477` | **一次代拍要多久。** 要五分钟就不会有第二次 |

`proxy_consent_signed` **不带同意书里的任何内容** —— 签名和姓名都在加密包里,不出设备。

### 认领

| 事件 | 属性 | 触发点 | 回答什么决定 |
|---|---|---|---|
| `claim_opened` | `entry`(cold/warm) | `claim_screen.dart:36` | **`cold` = App 被链接拉起来的**,基本意味着「刚装完就来认领」——最关键的转化路径 |
| `claim_imported` | `count_bucket`, `deduped`, `text_only` | `claim_screen.dart:68` | 认领闭环成不成立 |
| `claim_failed` | `reason`(gone/network/failed/unknown) | `claim_screen.dart:48` | **`gone` 每一条都代表一次白做的代拍** —— 说明 12 小时太短或流程太慢 |

⚠️ **出码和认领是两台手机。** 没有持久 ID 就无法逐条关联。只看**总量比**(`claim_imported` / `proxy_share_shown`),不做 per-link 关联。要精确到每条链接得带认领 id 的加盐哈希 —— 先看总量够不够用。

### 分析自身

| 事件 | 触发点 | 回答什么 |
|---|---|---|
| `analytics_opt_out` | `analytics.dart` `setEnabled(false)` | 有多少人关掉了。**这是最后一条上报**,发完即停 |

> 分母会随时间失真:关掉的人之后连 `app_open` 都不发了。接受。

---

## 五、分桶(`Bucket`,`lib/analytics.dart`)

精确值(几份、多少字节、多少毫秒)组合起来可能指认到人,所以一律分桶。

| 函数 | 桶 |
|---|---|
| `count` | `0` / `1` / `2-5` / `6-20` / `21-50` / `50+` |
| `duration` | `<3s` / `3-10s` / `10-30s` / `30-120s` / `>120s` |
| `perDoc` | `<1s` / `1-3s` / `3-6s` / `6-15s` / `>15s` ——分得开 `duration` 一个桶里塞着的 2 倍差异(4s vs 8s) |
| `bytes` | `<1MB` / `1-5MB` / `5-20MB` / `20-100MB` / `>100MB` |
| `tenure` | `0d` / `1-7d` / `8-30d` / `30d+` |
| `hour` | `00-06` / `06-12` / `12-18` / `18-24` |

`count(0)` 单独成桶:空档案和「用过一次」是完全不同的状态,混在一起「有没有人在累积」就白问了。

---

## 六、算得出但没有事件的量

不要为这些新增事件 —— 算术上可得:

| 想问的 | 怎么算 |
|---|---|
| 导入中途放弃 / 崩溃 | `doc_import_started − (completed + failed)` |
| 同意环节流失 | `proxy_session_started − proxy_consent_signed` |
| 拍完没交付 | `proxy_consent_signed − proxy_share_shown` |
| 认领转化率 | `claim_imported / proxy_share_shown`(总量比,非逐条) |
| 开箱失败率 | `app_open` 里 `vault_ok=false` 的占比 |

---

## 七、明确**不采**的

| | 为什么 |
|---|---|
| 录屏(session replay) | 会把病历内容直接录进去。SDK 侧已关死,后台也别开 |
| autocapture / 问卷 / feature flag 事件 | SDK 侧逐个关死。**`beforeSend` 钩子拦不住原生发起的事件**,所以只能在配置里关,不能靠白名单兜底 |
| IP 与 GeoIP | 每条事件带 `$geoip_disable: true`;**IP 本身是服务端记的,SDK 关不掉,必须在 PostHog 项目设置里关** |
| 任何文本内容 | 文件名、异常消息、OCR 结果、姓名、医院、药名、诊断 |
| 精确数值 | 一律分桶 |
| 就诊日期 / 日期区间 | 只报「用没用筛选」这个布尔 |
| 认领对象 id | 那是密文的指针 |
| 查看器里的一切 | 见 ADR 0009 |

---

## 八、加一个事件的规矩

1. **先写下它回答哪个决定。** 写不出来就别加。
2. 在 `AnalyticsEvent` 枚举里加一条(静态 snake_case)。
3. 在**本文档第四节**加一行 —— 否则 `analytics_catalog_test` 会红。
4. 属性只能是**分桶值、布尔、预定义枚举**。自由字符串一律不行。
5. 跑 `flutter test test/analytics_test.dart test/analytics_catalog_test.dart`。
6. 如果新事件采了新类型的信息,**同步改隐私政策和双清单**。
