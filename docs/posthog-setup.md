# PostHog 配置清单

**2026-07-29** · 采了什么 → [`analytics-catalog.md`](./analytics-catalog.md)

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
