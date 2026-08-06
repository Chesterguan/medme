# PostHog 配置清单

**2026-08-06**(补 1.6.0 的 dashboard 规格) · 采了什么 → [`analytics-catalog.md`](./analytics-catalog.md)

先随便设,回头照这张表核。**打勾项之外的都无所谓。**

## 必须对的(错了会出事)

| 项 | 该是什么 | 为什么 |
|---|---|---|
| `Discard client IP data` | **开** | 每条事件已带 `$geoip_disable`,但 **IP 是服务端记的,SDK 关不掉** |
| `Record user sessions`(录屏) | **关** | 录屏会把病历内容直接录进去 |
| Surveys | **关** | 同上,且 SDK 侧的 `beforeSend` 拦不住原生发起的事件 |
| Autocapture | **关** | 会抓页面/控件文本 |
| Feature flags | **一个都别建** | SDK 侧已关,后台建了也是浪费 |

> PostHog 自己的文档对 IP 那项的位置**自相矛盾**(一处写 `Settings > Project > General`,一处写 `> Privacy`)。按开关名 `Discard client IP data` 找,别按路径找。

## 无所谓的

- onboarding 选哪个 —— 只要别开录屏。选错了后台能改。
- 项目名 —— 随便。
- 区域 —— 选 **US**(代码默认 `https://us.i.posthog.com`)。**选了 EU 就告诉我**,要多传一个 `POSTHOG_HOST`。⚠️ 建完不能迁。

## 拿 Key

- 要 **Project API Key**(`phc_` 开头)。**这个可以公开** —— 它写死在客户端里,只能写不能读。
- **不要**建 Personal API Key。那个才是密钥,我们用不上。

## 拿到之后还要做一件事

⚠️ **仓库里目前没有任何地方注入 `POSTHOG_KEY`**(`.github/workflows/` 和 `scripts/` 里零命中)。

所以光有 Key 不够,**CI 出的包分析仍然是关的**,要单独改一次 workflow。给我 Key 时提醒我这条。

## 怎么确认通了

后台 **Activity → Live**,第一条应该是 `app_open`,带:

`vault_ok` · `tenure_bucket` · `session_index_bucket` · `mode` · `hour_bucket`

**没有 `library_size_bucket` 是对的** —— 那个要等档案屏载入才有,`app_open` 早于它。

**如果属性里出现了 IP 或省市,说明 IP 那项没设对。**

## 额度

免费层 100 万事件/月,数据留 1 年。我们这个量级用千分之几。**不要为了省额度砍事件。**

---

# Dashboard 规格

> ## ⚠️ 这一节是**照着建的说明书,不是「已经建好了」**
>
> PostHog 的 dashboard 在外部服务上。**代码仓库这边没有、也不该有你的 PostHog 凭据**,
> 所以这里交付的是一份规格 —— 每张图的名字、事件、分组维度、以及它回答什么问题。
> **需要你自己登进 PostHog 按这张表建。** 建完可以回来在这份文档上打勾。
>
> 建图的位置:左边栏 **Product analytics → New insight**,存进一个叫
> `MedMe 1.6.0` 的 dashboard。

## 建之前先改一处

`hour_bucket`、`tenure_bucket` 这些是**事件属性**不是 person 属性(我们没有持久 ID,
所以 PostHog 里的「人」是一次性的)。**所有分组都要选 `Event property`,别选
`Person property`** —— 选错了图是空的,而空图看起来像「没人用」,不像「配错了」。

## 一号板:这一版的五个赌注

> 1.6.0 一次性押了五件事(五 tab、记录、看病带这个、大字模式、趋势筛选)。
> 这五张图就是这五个赌注各自的判决。**先建这五张,别的都可以等。**

| # | 图名 | 事件 | 图型 | 分组 / 拆分 | 回答什么问题 |
|---|---|---|---|---|---|
| 1 | **五个席位谁在被点** | `home_tab_selected` | Trends,柱状,按周 | `tab`(事件属性) | **五个一级 tab 该给谁。** 垫底的那个就是下次要被挤掉的。特别看「趋势」和「应急卡」—— 这两格是这一版新占的 |
| 2 | **「记录」是记数值还是记问题** | `record_added` | Trends,饼图 | `kind_group` | 数值多 → 往趋势/单位/参考区间投;笔记多 → 往「我想问医生的」投。**两边现在都在做,这张图说该收哪一半** |
| 3 | **「看病带这个」有没有人找得到** | `visit_sheet_opened` | Trends,折线,按周 | `where` | 它刻意**不占 tab**,只靠两个顶栏入口。曲线贴地 = 赌注输了,这一屏要么给席位要么砍。`where` 说另一个入口该不该留 |
| 4 | **诊室里走的是复制还是出码** | `visit_sheet_action` | Trends,饼图 | `action` | `copy` 是本地几行代码,`qr` 要联网 + E2E + 托管查看器 + 过期清理,**成本差一个数量级**。出码占比很低 = 那条云链路该退成次要入口 |
| 5 | **「只看非正常项」默认开对不对** | `trends_filter_used` | Trends,柱状,按周 | `control` | 看 `abnormalOnlyOff` 的绝对量 —— 这是全 App 唯一一处替用户排序的默认值,**用户关掉它的次数就是这个默认唯一的检验** |

## 二号板:漏斗(这些必须用 Funnel,不能用两张 Trends 相减)

| # | 图名 | 类型 | 步骤 | 回答什么问题 |
|---|---|---|---|---|
| 6 | **导入漏斗** | Funnel | `doc_import_started` → `doc_import_completed` | 中途掉的那一截 = 放弃或崩溃。**这是最重要的一个数** |
| 7 | **「看病带这个」空转率** | Funnel | `visit_sheet_opened` → `visit_sheet_action` | 打开了却一颗按钮都没按 = 这一屏只是被瞄了一眼。**那是排版问题,不是入口问题** —— 与 3 号图要修的地方完全不同 |
| 8 | **代拍漏斗** | Funnel | `proxy_session_started` → `proxy_consent_signed` → `proxy_share_shown` | 同意书是最可能的流失点。第二段掉得多 = 拍完没交付 |
| 9 | **应急卡是不是只是个编辑页** | Funnel | `home_tab_selected`(筛 `tab=emergency`)→ `emergency_big_mode_opened` | 代码里说「大字模式才是这个 tab 的产品本体」。转化率极低 = 那句话是错的,**这个席位该还回去** |

> 9 号图的第一步要在步骤上加一个 filter:`tab equals emergency`。PostHog 的
> funnel 步骤支持逐步骤 filter,别在整张图上加全局 filter —— 那会把第二步也筛掉。

## 三号板:健康度(每周扫一眼,不用天天看)

| # | 图名 | 事件 | 图型 | 分组 / 拆分 | 回答什么问题 |
|---|---|---|---|---|---|
| 10 | **开箱失败率** | `app_open` | Trends,折线 | `vault_ok` | `false` 那条只要不是贴地,就是 P0。用户那边只看到一句红字 |
| 11 | **换不换 OCR** | `doc_import_completed` | Trends,柱状 | `per_doc_duration_bucket` | **单份**耗时才是引擎质量。别用 `duration_bucket` 看这个 —— 那个被份数主导,回答的是「用户要等多久」 |
| 12 | **「点拍照没反应」是哪一种病** | `doc_capture_degraded` + `doc_capture_aborted` | Trends,柱状 | `reason` | `userCancelled` 是正常的分母;`emptyResult` / `scannerModuleUnavailable` 才是 bug。`scannerSkippedUnavailable` 的占比 = 「装了 GMS 却用不了扫描器」的机器有多少 |
| 13 | **失败原因还认不认得出** | `doc_import_failed` | Trends,柱状 | `reason_code` | **`unknown` 占了大头就是信号** —— 该让 Rust 侧返回类型化错误码了 |
| 14 | **清空的人是新来的还是老用户** | `data_wiped` | Trends,柱状 | `tenure_bucket` | 没有持久 ID 就看不到卸载,清空是我们能看见的最强负面信号。`0d` 集中 = **首次体验**问题;`30d+` 集中 = 用着用着**出了什么事**。两种病要修的地方完全不同 |
| 15 | **示例数据该不该上第一屏** | `demo_data_loaded` | Trends,柱状 | `ok` | 量接近零 → 那条 Rust 流式 API + 合成成员是净负担,可以整个删。`ok=false` 不为零 → 它在安静地坏(这条流恒不返回 `Err`,天生会静默失败) |
| 16 | **多成员值不值它的复杂度** | `app_open` | Trends,饼图 | `member_count_bucket` | 每人一个 vault、切换要重开箱 —— 若几乎恒为 `1`,这一整套可以简化。⚠️ 载入过示例数据的设备会多一个合成成员,**这个数是上界**,要交叉 `demo_data_loaded` 看 |
| 17 | **有多少人把统计关了** | `analytics_opt_out` | Trends,数字 | 无 | 分母会随时间失真(关掉的人之后连 `app_open` 都不发)。**看绝对值不看比例** |

## 建完之后要知道的三件事

1. **没有留存曲线,而且永远不会有。** 我们每次启动都 `Posthog().reset()`,
   「用户」在 PostHog 眼里每次都是新的。**别去建 Retention / Stickiness 图** ——
   它们会画出来,而画出来的是错的。留存的替代品是 `tenure_bucket`:
   「今天的会话里有多少来自用了 30 天以上的设备」是同一个问题的另一种问法。
   理由(PIPL、敏感个人信息出境)见目录第二节。

2. **出码和认领是两台手机。** `claim_imported / proxy_share_shown` 只能看**总量比**,
   不能建成 funnel —— funnel 要按人串,而这两条事件天生在两个 distinct_id 上。
   建成 funnel 的话转化率会恒为 0%,看起来像「认领完全没人用」。

3. **医生打开查看器没有、看了多久 —— 永远测不到。** 那是一条红线不是暂缓,
   见 `docs/ADR/0009-no-analytics-in-viewer.md`。别在 dashboard 上给它留位置。

## 还差一步:CI 里没有 Key

⚠️ 见上面「拿到之后还要做一件事」—— 仓库里目前**没有任何地方注入 `POSTHOG_KEY`**。
**在那条改好之前,以上所有图都会是空的**,因为发出去的包里分析根本没启动。
建 dashboard 之前先把这条办了,否则你会对着 17 张空图排查半天。
