# 埋点目录(Analytics Catalog)

**最后更新:2026-08-06**(补齐 1.6.0 五 tab / 记录 / 看病带这个 / 趋势筛选 / 数据主权)

这份文档是「我们到底采了什么」的唯一权威清单。三个用途:

1. **半年后还能分析数据** —— 事件名孤零零躺在后台没人记得它当初想回答什么问题。
2. **工信部双清单的底稿** —— 「已收集个人信息清单」和「与第三方共享个人信息清单」直接从这里生成。
3. **隐私政策的事实依据** —— 政策里写的每一句「我们收集…」都必须能在这里找到对应行。

> `test/analytics_catalog_test.dart` **双向**钉住这份文档与 `lib/analytics.dart`:
>
> | 钉住什么 | 漂了会怎样 |
> |---|---|
> | 第四节的事件 ↔ `AnalyticsEvent` 枚举 | 代码里加了事件而这里没写(或反过来)→ 红 |
> | 第四节每行的「属性」列 ↔ `AnalyticsEvent.props` | 属性漂了 → 红 |
> | 第四节标题里的**条数** ↔ 枚举长度 | 标题写着 19 条而实际 27 条 → 红 |
> | 第三节的会话上下文 ↔ `Analytics.contextKeys` | 上下文多了一个键而这里没写 → 红 |
>
> 所以这份文档不会烂 —— 它烂了 CI 就不过。

---

## 一、三条硬约束

1. **只采行为,不采内容。** 病历文字、文件名、OCR 结果、药名、诊断、检验值、就诊日期、医院名 —— 一个字都不出设备。
2. **没问过就不采,而且用户随时可以关。** **默认关**(`Analytics._defaultEnabled = false`);
   首启告知与同意屏(`screens/first_run_consent.dart`)上用户按下「同意」的那一刻才打开,
   之后在设置 → 「帮助改进 MedMe」里随时关得掉。
   > ⚠️ **这一条 2026-08-06 更正。** 原文写的是「默认开」—— 那是 `_defaultEnabled`
   > 还是 `true` 的年代留下的,代码早已改成默认关 + 同意门(理由见 `analytics.dart`
   > 里 `_defaultEnabled` 的文档:默认开会让隐私政策里「数据离开手机的每一种情况都由
   > 你主动触发」这句话变成假的)。**这份文档是隐私政策与工信部双清单的底稿,
   > 而它声称我们采得比实际更早 —— 这是最糟的一种漂。**
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
| `member_count_bucket` | `1` / `2-5`(成员上限 5,更大的桶到不了) | 成员表长度,`profile_manager.dart:_publishMemberCount` | **多成员值不值它的复杂度**(每人一个 vault、切换要重开箱)。若几乎恒为 `1`,这一整套可以简化掉 |
| `mode` | `personal` / `doctor` / `unset` | `AppMode` | 每个指标都能按身份切开看 |
| `hour_bucket` | `00-06` / `06-12` / `12-18` / `18-24` | 发送时的**本地**钟点 | 关了 GeoIP 后服务端只剩 UTC。**代拍是不是发生在门诊时间**,是「医生真的在诊室用」最直接的证据 |

> 这张表与 `Analytics.contextKeys` 逐字对钉(`analytics_catalog_test.dart`)。
> 上下文比事件属性更该钉:它跟着**每一条**事件出去,覆盖面比任何单条事件都大,
> 而它此前是全自由的 —— 谁在哪一屏 `setContext` 一把就多一个键,漂了没有任何地方会红。

> `library_size_bucket` 在医生模式下不会出现(档案屏不构建),这是对的 —— 医生没有个人档案。
>
> ⚠️ **`library_size_bucket` 从 1.6.0 起不再等于「导入了几份」** —— 手动录入的每一条
> (自测数值、笔记)也是一份文档,同样计进 `recordCount`。要区分两条入库路径,
> 看 `doc_import_completed` 与 `record_added` 的比。
>
> ⚠️ **`member_count_bucket` 是上界** —— 载入过示例数据的设备会多出一个合成成员
> (「张建国(示例)」)。真实多成员占比要按 `demo_data_loaded` 切开看。
> 成员**名字**永不上报:那是病历里最直接的身份信息。

---

## 四、事件全集(27 条)

每条对应**一个决定**。答不出决定的事件不该存在。

> 标题里那个数字由 `analytics_catalog_test.dart` 对着 `AnalyticsEvent.values.length`
> 钉住 —— 它此前是手写的,而手写的计数是最先烂的东西(加事件的人在下面补了一行,
> 不会想起回头改标题)。这个数字有实际用途:双清单和隐私政策审阅时,第一眼看的
> 就是「一共采几条」。

> **「触发点」只写文件,不写行号。** 行号必然漂(实测一轮下来 8 条全错),而漂了没人会去
> 更新,于是整列变成误导。要找就 grep 事件名。属性列则由
> `test/analytics_catalog_test.dart` 与 `AnalyticsEvent.props` 逐字对钉,漂了 CI 会红。

### 基线

| 事件 | 属性 | 触发点 | 回答什么决定 |
|---|---|---|---|
| `app_open` | `vault_ok` | `main.dart`、`screens/first_run_consent.dart` | 有人用吗。`vault_ok=false` = **开箱失败**,此前完全不可见,用户只看到一句红字 |

### 导入

| 事件 | 属性 | 触发点 | 回答什么决定 |
|---|---|---|---|
| `doc_import_started` | `source`, `count_bucket` | `import_flow.dart`、`screens/doctor/proxy_intake_flow.dart` | 三个采集入口(拍照/相册/文件)谁在被用 |
| `doc_import_completed` | `source`, `count_bucket`, `failed_bucket`, `duration_bucket`, `per_doc_duration_bucket`, `is_first` | `import_flow.dart`、`screens/doctor/proxy_intake_flow.dart` | **换不换 OCR 引擎**(看 `per_doc`);**要不要做后台导入**(看 `duration`);**首次导入成功率**(看 `is_first`) |
| `doc_import_failed` | `source`, `count_bucket`, `failed_bucket`, `duration_bucket`, `per_doc_duration_bucket`, `is_first`, `stage`, `reason_code` | `import_flow.dart`、`screens/doctor/proxy_intake_flow.dart` | 失败集中在哪一步、哪个原因 |
| `doc_capture_degraded` | `source`, `reason` | `import_flow.dart` | **「点拍照没反应」到底是哪一种病因。** 采集器没起来、已降级到普通相机 —— 是 GMS 检测自己炸了、扫描器抛异常、还是扫描器永久挂起 |
| `doc_capture_aborted` | `source`, `reason` | `import_flow.dart` | **用户主动取消 vs 采集器静默返回空。** 这两者在屏上完全一样,不分开就永远算不出「没反应」的真实占比 |
| `doc_opened` | 无 | `screens/archive_screen.dart`、`overview_screen.dart`、`trends_screen.dart`、`emergency_card_screen.dart`、`visit_summary_sheet.dart` | **档案是被看的还是被堆的。** 导入了从不打开 = 垃圾桶不是助手 |

> 五 tab 之后「点开一份」有五个入口,这条**仍然不带来源** —— 「被看还是被堆」不需要
> 知道从哪一屏点的,而多一维就多一次泄露面评估。(触发点那一列 2026-08-06 补齐:
> 此前只写了档案屏,而它早就散到五处。)

**两个耗时不是重复。** 总时长被份数主导,只能回答「用户要等多久」;单份时长才是引擎质量 —— 5 份各 2 秒,总时长报 `3-10s` 像是慢,单份报 `1-3s` 其实正常。当初只报总时长,等于把批量冒充成了引擎问题。

⚠️ **分桶看不见小幅改进**(4.0s → 3.5s 在任何合理的桶里都不动)。要精确耗时只能上真机基准测试,别指望埋点 —— 这是隐私换来的代价。

`source`:`camera` / `gallery` / `files`(代拍另报 `proxy`)

> ⚠️ **手动录入(「记录」)刻意不在这个字段里,也不发 `doc_import_*`。**
> 这三条事件的存在理由是 **OCR 引擎质量**(`per_doc_duration_bucket` 直接决定
> 「换不换 OCR」)。手动录入没有 OCR 这一步、耗时接近零 —— 加一个 `source=manual`
> 会把引擎指标稀释成一个没人能解释的数。它单独由 `record_added` 计数,
> **入库总量要看两条之和**(见第六节)。

`stage`:`capture` / `ocr` / `save`
`reason_code`:`unsupported` / `corrupt` / `ocrEmpty` / `storage` / `permission` / `unknown`(枚举 `ImportFailReason`)

> ⚠️ `reason_code` 由错误串粗分类得到,不是 core 返回的类型化错误。**如果 `unknown` 在数据里占了大头,就是该让 Rust 侧返回错误码的信号。**

#### 采集环节(`doc_capture_*`)

`doc_import_*` 要**拿着文件**才发,所以在它之前的整个采集环节此前是彻底的盲区:
抛异常 / 永久挂起 / 返回空列表 —— 三种病因在 UI 上渲染成字节级相同的症状(什么都没
发生),在数据里也一样都是零。这两条事件就是把那三种分开。

`source`:`camera` / `gallery` / `files` —— 是**哪个采集器**坏了。
⚠️ 与 `doc_import_*` 的 `source` **口径不同**:那里代拍统一报 `proxy`,这里永远报具体采集器。
个人模式与代拍由会话上下文的 `mode` 切开,不占这个字段。

`reason`(枚举 `ImportCaptureIssue`,`lib/analytics.dart`)。归属事件写在枚举上,调用点只管说出原因:

**`doc_capture_degraded`(采集器没起来,已落到普通相机,后面可能还是成功的)**

- `gmsCheckThrew` —— Google Play 服务可用性检测本身抛异常,按「无 GMS」处置
- `scannerStalled` —— 启动看门狗触发:5 秒没结果且 App 仍在前台 `resumed` → 扫描器根本没起来
- `scannerThrew` —— 文档扫描器抛异常(设备不支持、权限被拒)
- `scannerModuleUnavailable` —— 扫描器回了空、用户在补救提示里点了「用普通相机」= 这台机器拉不到 ML Kit 文档扫描模块(GMS 在场但下载不到 `mlkit.docscan.ui`)。**插件把它和「用户取消」返回成同一个空列表,这一下点击是唯一的分流信号**
- `scannerSkippedUnavailable` —— 记住上一条之后,本次拍照**直接跳过扫描器**、静默走普通相机。占比 = 「装了 GMS 却用不了扫描器」的机器有多少

**`doc_capture_aborted`(这一轮一份都没拿到)**

- `userCancelled` —— 用户主动取消。**正常,不是 bug** —— 但它是上面那些的分母
- `emptyResult` —— 采集器返回了结果却什么都没有。用户没取消,东西却没了 = bug。哪一种看 `source`:`camera` = 扫描器回了 0 页;`files` = 选中的文件在本机取不到(云盘上没下载完)
- `pickerThrew` —— 系统相机 / 相册 / 文件选择器抛异常
- `unknown` —— 外层兜底 catch。占比一高说明还有没枚举到的分支

> **⚠️ 这段曾经写错,2026-08-04 用可复现环境更正。** 原文说病因是
> 「`getStartScanIntent` 的 Task 既不 success 也不 failure → future 永久 pending」,
> 并把 `scannerStalled` 当作这两条事件存在的首要理由。AVD 实测(Pixel_7 /
> Android 17 / google_apis 无 Play 商店 / docscan 模块从未缓存)证明**不是挂起**:
>
> 1. `getStartScanIntent` **成功**,scanner Activity 也真的被拉起(所以插件自带的
>    `addOnFailureListener` → 备用裁剪器从未触发);
> 2. 失败在 GMS 内部 —— `No registered Chimera impl` + `Zapp module request failed`;
> 3. **GMS 自己**弹英文报错页(`ModuleDownloadActivity`)占前台 20 秒以上;
> 4. 用户点 Cancel → `RESULT_CANCELED` → 插件 `success(emptyList())` → 空列表。
>
> 所以 `scannerStalled` **盖不住这个病因**:第 3 步里前台是 GMS、App 不是 `resumed`,
> 看门狗判定「正常」,一次都不触发。真正接住它的是 `scannerModuleUnavailable`
> (补救入口)+ `scannerSkippedUnavailable`(记住后跳过)。`scannerStalled` 降级为
> 纯兜底 —— 它若还有非零占比,说明存在第三种、目前没见过的失败形态。

⚠️ **`reason` 之外的一切不上报。** 异常字符串**只显示在屏上**(屏上探针,见
`docs/log/2026-07-18-qr-share-security-and-community-prep.md` 的 07-21 追记),
因为异常文本里常带文件名和绝对路径 —— 那是病历内容。

### 界面骨架(五 tab)

> 1.6.0 把三 tab(健康档案 / 导出分享 / 设置)换成五 tab(概览 / 趋势 / 档案 /
> 应急卡 / 设置)。**席位之争是这一版最大的赌注,而它此前一个数都没有。**

| 事件 | 属性 | 触发点 | 回答什么决定 |
|---|---|---|---|
| `home_tab_selected` | `tab`(枚举 `AnalyticsTab`:`overview`/`trends`/`archive`/`emergency`/`settings`) | `main.dart` | **五个一级席位该给谁。** `HomeShell` 的文档里那句「做成 tab 就是给一个一年用十次的动作一个常驻席位,而把它挤掉的会是应急卡」到今天为止纯属推理 —— 这条把它变成可证伪的 |

**只在手点底栏时发。** 程序化跳转(`goToArchive()`、载入示例后的「去看看」)不发 ——
那是别的功能的副作用,不是用户想去哪;混进来会把一个功能的成功记成另一个 tab 的人气。

`tab` 上报的是**名字不是下标**:下标会随 tab 顺序调整而变,顺序一改后台里所有历史
数据整体错位,而且看不出来。

### 记录(手动录入)

> 本版新开的**第二条入库路径**:自测数值(血压/心率/体重/体温/血糖)+ 笔记。

| 事件 | 属性 | 触发点 | 回答什么决定 |
|---|---|---|---|
| `record_added` | `kind_group`(`measurement`/`note`), `edited` | `screens/manual_entry_sheet.dart` | **这条路该往数值走还是往笔记走。** 数值喂趋势与概览的自测序列(单位换算、参考区间、血压双值),笔记喂「看病带这个」的「我想问医生的」—— 两边现在都在做,这个比值说该收哪一半。`edited` 回答第二个:编辑走「先删再写」,那条顺序有过一个会**静默丢数据**的必现 bug;几乎没人编辑的话这类风险优先级就低 |

⚠️ **不报是哪一种自测项。** 「这台设备在测血糖」是对机主的**健康推断**,属于敏感个人
信息,与「不采内容」这条红线同级。`measurement` / `note` 两分不指向任何身体系统,却
已经足够分开两条产品路线 —— 这是这条事件上能安全拿到的最大信息量。
数值、单位、笔记原文、测量时间一概不出设备。

### 看病带这个

> 原名「就诊单」。**刻意不是 tab**,只从概览与档案两处顶栏以浮层唤起。

| 事件 | 属性 | 触发点 | 回答什么决定 |
|---|---|---|---|
| `visit_sheet_opened` | `where`(`overview`/`archive`) | `screens/visit_summary_sheet.dart` | **「它不占 tab」这个赌注成不成立。** 打开次数接近零 = 没人找得到它,那这一屏(本版最重的一屏)要么给席位要么砍。`where` 说两个入口谁在起作用,决定另一个该不该留 |
| `visit_sheet_action` | `action`(`copy`/`qr`/`addNote`) | `screens/visit_summary_sheet.dart` | **诊室里真正走的是「复制全文」还是「出示二维码」。** 两条路成本差一个数量级:复制是本地几行代码,出码要联网 + E2E 加密 + 托管查看器 + 12 小时过期清理。出码几乎没人按的话,那整条云链路该退成次要入口而不是并列 |

两条组成漏斗:**打开了却一颗都没按** = 这一屏只是被瞄了一眼,内容没用起来 ——
那是排版问题不是入口问题,两者要修的地方不同。

`action=qr` 与 `action=addNote` 只做**入口归属**:出码本身仍由 `share_qr_shown` 计数
(出码还能从设置 →「导出 · 分享」进,两条路的占比决定哪条是主路径),存下来的笔记
仍由 `record_added` 计数。

⚠️ 复制走的文本就是整页病历摘要,**一个片段都不上报**;二维码载荷、笔记原文同理。

### 应急卡

| 事件 | 属性 | 触发点 | 回答什么决定 |
|---|---|---|---|
| `emergency_big_mode_opened` | 无 | `screens/emergency_card_screen.dart` | **应急卡该不该继续占一个一级席位。** 代码里写着「大字模式才是这个 tab 的产品本体,平时这一屏只是它的维护界面」—— 若 tab 有人进(`home_tab_selected`)而大字模式没人开,那句话就是错的:它实际是个资料编辑页,「急救现场」的前提从未被验证 |

**无属性**是刻意的:这一屏上的每一样东西(姓名、血型、过敏史、紧急联系人和电话)
都是最敏感的那一类,一个都不带。

### 趋势

| 事件 | 属性 | 触发点 | 回答什么决定 |
|---|---|---|---|
| `trends_filter_used` | `control`(枚举 `TrendsFilterControl`) | `screens/trends_screen.dart` | **「只看非正常项」默认开对不对** —— 这是全 App 唯一一处替用户排序的默认值,代码里为它写了整整一段辩护,而用户把它**关掉**的频次就是那段辩护唯一的检验。顺带:检验大类 chip 是本版新做的(Rust 一份 panel 目录 + 词典投入),chip 与搜索各自被用了多少,决定要不要继续往词典里投、那颗放大镜还留不留 |

`control` 取值:

- `abnormalOnlyOff` —— 「只看非正常项」被**关掉**。默认开,所以**这一档才是信号**
- `abnormalOnlyOn` —— 被重新打开。是上一档的分母,单独看没有意义
- `panel` —— 点了某个检验大类 chip(取消选中也计一次,一样是「在用这个控件」)
- `search` —— **展开了搜索栏**。只在展开时发一次

⚠️ **绝不报是哪个大类,绝不报搜索词。** 大类指向身体系统(「这台设备在看肝功能」是
健康推断);搜索词更是用户直接打进去的字,会是指标名甚至病名。搜索也**不随输入发** ——
按键上报既是噪音,又一步步逼近内容本身。

### 导出与出码

> **「导出 · 分享」1.6.0 起不再是一级 tab**,收进了「设置」(数据主权:我的数据往哪去)。
> 事件本身**没有变**,该发的照发 —— 变的只是入口深了一层。若 `export_completed` 在
> 1.6.0 之后明显掉下来,那是**入口变深**的代价,不是导出没人要,别读反。
> 出码另有第二个入口:「看病带这个」浮层底部(见 `visit_sheet_action` 的 `qr`)。

| 事件 | 属性 | 触发点 | 回答什么决定 |
|---|---|---|---|
| `export_completed` | `ranged` | `screens/export_screen.dart` | 导出有没有人用;用不用日期筛选(**不报是哪段日期** —— 那是就诊时间) |
| `share_qr_shown` | `record_count_bucket`, `size_bucket` | `screens/qr_share_screen.dart` | 出码这条路走通了几次、载荷多大 |
| `share_upload_retry` | `choice`(**interrupted**=传到一半断了,自动发 / **retry**=用户点了重试), `progress_bucket` | `screens/qr_share_screen.dart` | **断连有多常见、用户愿不愿意等**;`progress_bucket` 看断在进度哪一段 |
| `share_qr_degraded` | `choice`(恒为 `fallback`) | `screens/qr_share_screen.dart` | 云那条路没走通的比例。**「降级」记在这里,不在 `share_upload_retry`** —— 目录一度把两者混成一个 `retry/fallback` |

「导出完成」= **文件已生成**。之后的系统分享面板用户可能取消,拿不到可靠回调 —— 与代拍交付同一口径。

### 医生代拍

> 这是最新、赌注最大的功能,此前**一个事件都没有**。

| 事件 | 属性 | 触发点 | 回答什么决定 |
|---|---|---|---|
| `mode_selected` | `mode`, `where`(first/settings) | `screens/mode_picker_screen.dart`、`screens/settings_screen.dart` | 几成用户是医生。**`where=settings` 占比高 = 「你是?」那一屏问得不清楚** |
| `proxy_session_started` | `resumed` | `screens/doctor/proxy_intake_flow.dart` | 代拍到底有没有人用。`resumed=true` = 12 小时内回来补拍 |
| `proxy_consent_signed` | 无 | `screens/doctor/proxy_intake_flow.dart` | **同意书是最可能的流失点。** started 与它的差 = 病人在同意环节走掉了 |
| `proxy_share_shown` | `count_bucket`, `confirmed_bucket`, `size_bucket`, `duration_bucket` | `screens/doctor/proxy_intake_flow.dart` | **一次代拍要多久**(要五分钟就不会有第二次);`confirmed_bucket` 与 `count_bucket` 的差 = 医生确认了却没交付的份数 |

`proxy_consent_signed` **不带同意书里的任何内容** —— 签名和姓名都在加密包里,不出设备。

### 认领

| 事件 | 属性 | 触发点 | 回答什么决定 |
|---|---|---|---|
| `claim_opened` | `entry`(cold/warm) | `screens/claim_screen.dart` | **`cold` = App 被链接拉起来的**,基本意味着「刚装完就来认领」——最关键的转化路径 |
| `claim_imported` | `count_bucket`, `deduped`, `text_only` | `screens/claim_screen.dart` | 认领闭环成不成立 |
| `claim_failed` | `reason`(gone/network/failed/unknown) | `screens/claim_screen.dart` | **`gone` 每一条都代表一次白做的代拍** —— 说明 12 小时太短或流程太慢 |

⚠️ **出码和认领是两台手机。** 没有持久 ID 就无法逐条关联。只看**总量比**(`claim_imported` / `proxy_share_shown`),不做 per-link 关联。要精确到每条链接得带认领 id 的加盐哈希 —— 先看总量够不够用。

### 数据主权(设置)

| 事件 | 属性 | 触发点 | 回答什么决定 |
|---|---|---|---|
| `demo_data_loaded` | `ok` | `screens/settings_screen.dart` | **示例数据该提到空态里,还是该整个砍掉。** 它现在埋在「设置」第三节,而需要它的人正站在「概览」的空态上。载入的人多它就该上第一屏;几乎没人载入,那条 Rust 流式 API + 合成成员 + 一串进度文案就是净负担 |
| `data_wiped` | 无 | `screens/settings_screen.dart` | **我们能看见的最强负面信号。** 没有持久 ID 就永远看不到卸载,清空是仅次于它的一步,而且在二次确认之后 —— 不会误触。配合 `tenure_bucket` 分得开「第一天就清掉」(首次体验问题)和「用了一个月才清」(出了什么事),这是两种病 |

`ok=false` 另有用处:`load_demo_data` **恒不返回 `Err`**(失败靠字段带出来),
这是个天然会安静坏掉的地方 —— 坏了用户只看到一句提示,而我们此前一无所知。

⚠️ 失败原因是 Rust 侧的一段文本、可能带路径,**不上报**(与 `doc_import_failed`
只报 `reason_code` 同一条规矩)。`data_wiped` 无属性 —— 而且此刻设备上已经什么都不剩了。

### 分析自身

| 事件 | 属性 | 触发点 | 回答什么决定 |
|---|---|---|---|
| `analytics_opt_out` | 无 | `analytics.dart` | 有多少人关掉了。**这是最后一条上报**,发完即停 |

> 这张表的表头 2026-08-06 补上了「属性」两个字 —— 它此前只写了三列而数据行有四格,
> `analytics_catalog_test.dart` 为此专门按**位置**取第二格(而不是按表头文字找列)。
> 那道绕行仍然留着(它更结实),但表头本身不该继续是错的:这份文档要给人读。

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
| **入库总量**(两条路之和) | `doc_import_completed + record_added` —— 手动录入刻意不发 `doc_import_*`,理由见「导入」一节 |
| 「看病带这个」空转率 | `visit_sheet_opened − visit_sheet_action`(打开了一颗按钮都没按) |
| 应急卡是不是只是个编辑页 | `emergency_big_mode_opened / home_tab_selected(tab=emergency)` |
| 「记录」入口谁在用 | `record_added` 减去 `visit_sheet_action(action=addNote)`,余下的基本是概览那颗快捷键 |
| 多成员真实占比 | `member_count_bucket ≥ 2` 里剔掉发过 `demo_data_loaded` 的会话(示例成员会多算一个) |

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
| **手动录入的是哪一种**(血压/心率/体重/体温/血糖) | 「这台设备在测血糖」是对机主的**健康推断**,敏感个人信息。只报 `measurement` / `note` 两分 —— 不指向任何身体系统,却已足够分开两条产品路线 |
| **趋势选的是哪个检验大类** | 同上:大类直接指向身体系统(肝功能 / 肿瘤标志物 / 甲状腺)。只报「chip 这条路被走了」 |
| **趋势的搜索词** | 用户直接打进去的字,会是指标名甚至病名 —— 是内容里最直白的一种。搜索只在**展开搜索栏**时计一次,不随输入发 |
| **成员名字** | 病历里最直接的身份信息。只报成员**个数**的桶(上限 5,实际只有 `1` / `2-5` 两档) |
| **手动录入的数值、单位、测量时间、笔记原文** | 那就是病历本身 |
| **「看病带这个」复制走的文本 / 二维码载荷** | 整页病历摘要,一个片段都不带 |
| **应急卡上的任何字段** | 姓名、血型、过敏史、紧急联系人和电话 —— 这一屏是全 App 最敏感的一屏,所以 `emergency_big_mode_opened` **一个属性都没有** |
| 载入示例数据的失败原因文本 | Rust 侧的字符串,可能带路径。只报 `ok` 这个布尔 |

---

## 八、加一个事件的规矩

1. **先写下它回答哪个决定。** 写不出来就别加。判据不是「每个按钮都埋」,是
   **「这条数据会改变我们的决定吗」** —— `doc_import_completed` 的两个耗时是样板:
   总时长只能回答「用户要等多久」,单份时长才是引擎质量、是换不换 OCR 的依据。
2. 在 `AnalyticsEvent` 枚举里加一条(静态 snake_case)。
3. 在**本文档第四节**加一行,并把标题里的条数改对 —— 两处漂了 `analytics_catalog_test`
   都会红。
4. 属性只能是**分桶值、布尔、预定义枚举**。自由字符串一律不行。
   **枚举写在 `analytics.dart` 里**(与 `ImportFailReason` / `TrendsFilterControl`
   同处),不要在调用点拼字符串 —— 拼出来的取值集合没有任何地方可审。
5. 在注释里写明**为什么它不泄露内容**。分不清的时候用这条判据:
   *这个取值能不能推断出机主的身体状况、身份、或行踪?* 能就不报,或者退到更粗的分档
   (`RecordKindGroup` 从「六种自测项」退成「数值 / 笔记」就是这么来的)。
6. 加**会话上下文**的键要另走一步:进 `Analytics.contextKeys` + 本文档第三节。
   上下文比事件属性更该慎重 —— 它跟着**每一条**事件出去。
7. 跑 `flutter test test/analytics_test.dart test/analytics_catalog_test.dart`。
8. 如果新事件采了新类型的信息,**同步改隐私政策和双清单**。
