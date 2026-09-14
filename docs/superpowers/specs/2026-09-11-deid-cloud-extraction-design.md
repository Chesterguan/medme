# 子项目 A · 本地脱敏 + 云抽取管线(2026-09-11)

> 总纲见 `2026-09-11-advanced-edition-overview-design.md`。本文只写 A。

## 目标

手机上:OCR(PP-OCRv5,现有)→ **脱敏** → 经我们的代理送 DeepSeek → 结构化 JSON → **逐字校验** → 落盘进保险箱 → 摘要/趋势/分享改吃抽取结果。
验收标准不是「能跑」,是**评测台上打赢正则**:在 MedRepBench 683 份上,项目召回 / 值-名配对 / 参考区间归属三项全部高于正则基线(58.7% / 49.7% / 24.3%),且**幻觉率(校验不过被丢弃的条目占比)有数、可接受**。

## 数据流

```
图片 ──PP-OCR(现有)──▶ 文本 + 检测框
                            │
                    deid::redact ──▶ 脱敏文本 / 要涂黑的框 / 还原表(仅本机)
                            │
        ┌── 文本档:脱敏文本 ──────────────┐
        └── 图片档:按框涂黑的图片(缩放/切块)┘──▶ Dart HTTP ──▶ 代理 /v1/extract ──▶ DeepSeek
                                                                  │
                     Rust deid::restore + verify ◀── JSON ◀───────┘
                                                                  │
                  Event::ExtractionAdded + 结果 JSON 进 CAS ──▶ materialize ──▶ 摘要/趋势/分享
```

Rust 管脱敏、还原、校验、落盘;Dart 管 HTTP(`net.dart` / `claim_upload.dart` 已有网络层)。两档并存,评测决定默认档。

## 1. 脱敏层 `packages/deid`(新 crate)

输入:OCR 文本、检测框(带坐标和文本)、`KnownIdentity { name, id_number?, phone? }`(来自档案)、日期偏移天数。
输出:`Redacted { text, paint: Vec<Rect>, map: RestoreMap }`。`map` 永不离开手机。

三层 + 一道闸(顺序即优先级):

| 层 | 做什么 | 依据 |
|---|---|---|
| K 已知值 | 档案主人的姓名/证件号/手机全文精确删,含粘连形态(`姓名孟丁性别男`) | 要保护的人是已知的 |
| A 锚点 | `labs.rs:443` 的 `PAGE_FURNITURE` 词表 + 本 spec 清单里的锚点,锚点后的值换占位符 `[P1]` `[N1]` `[H1]` … | 复用现有词表,不造第二份 |
| P 模式 | 18 位身份证、11 位手机、6 位以上连续数字(条码/样本号/病历号)、URL、邮箱 | 参考区间和检验值不会这么长 |
| 闸 | 发送前断言:payload 不含已知姓名/证件号任何子串;命中即拒发,退回本地正则路径 | 可测试的硬保证 |

**保留不删**:年龄、性别、检验项目/值/单位/区间、科室(临床需要)。
**日期**:识别到的日期全部加同一偏移(±90 天内,按档案固定),还原时减回。偏移由档案的秘密派生(`HKDF(profile_secret, "date-shift") mod 181 − 90`),不用存、随档案同步;B 落地前 `profile_secret` 是 `profiles.json` 里一个随机 32 字节。
**医院名**:掩成 `[H1]`,本地还原(时间轴分组要用)。

图片档的涂黑规则:命中 K/A/P 的框 + **页眉带**(第一条可解析为化验行/含单位的行之上)+ **页脚带**(第一个 `检验者/审核者/打印时间` 锚点及以下)整块涂黑。二维码/条码靠页眉页脚带覆盖,清单里注明这是已知盲区。

### 清单 = fixture + 测试

`packages/deid/tests/fixtures/<类别>_<n>.txt` 与 `.expected.txt` 成对,按 HIPAA 18 项分类,每类至少一个**真实形态**样本(住院病案首页、门诊病历、影像报告各须补真实样本,现有语料 27 份几乎全是化验单)。测试断言:脱敏后全部命中,且保留项一个不少。新发现一种形态 = 加一对文件。会话 2026-09-11 已列出的中国单子形态表作为初始清单写进 `packages/deid/README.md`。

## 2. 代理端点(B 拥有,A 先用)

`POST /v1/extract` · Header `Authorization: Bearer <token>`(A 期:静态 token;B 后:账号 token)
Body:`{ "mode": "text"|"image", "schema": 1, "payload": "<脱敏文本>" | "<base64 图>" , "hints": { "doc_type_guess": "lab"|... } }`
服务端:拼系统 prompt + 固定输出 schema,调 DeepSeek,**不落盘 payload**,只记 token 数;原样回 JSON。

## 3. 输出 schema v1(服务端 prompt 与客户端校验共用)

```json
{ "doc_type": "lab|discharge|outpatient|imaging|prescription|other",
  "doc_date": "YYYY-MM-DD(偏移后)",
  "labs": [{"name":"","value":"","unit":"","ref_low":"","ref_high":"","flag":"H|L|"}],
  "meds": [{"name":"","dose":"","freq":"","route":""}],
  "diagnoses": [{"text":"","icd":""}],
  "impression": "",
  "notes": "" }
```
所有字符串**必须是原文逐字**;缺失留空,不许推断。ICD 码保留而不丢(memory `value-layer-roadmap-decisions` 的地基加固)。

## 4. 校验 `deid::verify`

| 档 | 规则 |
|---|---|
| 文本档 | 每个值必须是脱敏文本的**逐字子串**,否则丢弃该条并计入幻觉率 |
| 图片档 | 数值允许 `,`/`.` 归一后匹配本地 OCR 文本;匹配不上的**不丢**,标 `unverified`,UI 显示「需核对」并可跳到原件 |

## 5. 落盘

- `Event::ExtractionAdded { document_ref, backend: "deepseek", model_version, mode, schema: 1, result_hash, created_at }`,结果 JSON 存 CAS(与 `OcrAdded` 同构)。
- materialize 增 `extraction` 表;`assemble_summary` 有抽取结果则用之,无则退回正则(老文档、离线、拒发三种情况都走这里)。
- 原件不动,将来换模型全量重跑只需再 append 一条事件。

## 6. 评测(先于产品接入)

- 复用 `packages/ocr/examples/medrep.rs` 的三分母三指标,LLM 产出走它已有的「第 ④ 列按模型分子目录」口径;新增第四指标**幻觉率**。
- 跑法:MedRepBench 683 份(需重新下载,原 scratchpad 已清)→ 本地 PP-OCR → `deid::redact` → 直调 DeepSeek(评测期不经代理)→ `verify` → 评分。文本档、图片档各一列。
- 图片档先测 384 token/图整页够不够;不够按表格行带切块再送。
- 结果写 `docs/log/`,决定默认档。**不达标不接产品。**

## 7. 不做

- 不做 BYOK;不做云 OCR(OCR 仍在端上);不做定性结果(阴性/+)的结构化(沿用现状);不做用户级 prompt 配置。

## 8. 风险

- 384 token/图分辨率不够 → 切块,评测决定。
- DeepSeek vision 标 exp,接口可能变 → 代理层隔离,客户端只认 schema v1。
- 脱敏漏网(手写姓名 OCR 漏检、二维码)→ 页眉页脚整带涂黑 + 清单持续补;对外话术不承诺 100%。
