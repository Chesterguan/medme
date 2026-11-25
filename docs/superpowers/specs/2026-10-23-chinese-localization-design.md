# 英文病历给国内医生看:三层中文化 — 设计

日期 2026-10-23。上游:[ADR 0001](../../ADR/0001-language-cn-en.md)(中英文一等公民)、[ADR 0004](../../ADR/0004-core-model-independence.md)(core 只存码,映射在 L3)、[ADR 0010](../../ADR/0010-cloud-llm-extraction-and-accounts.md)(本地脱敏 → 境内模型)、[ADR 0012](../../ADR/0012-generic-chronic-profile-layer.md)(诊断按 ICD 归族)、[2026-10-21 结构化导入](2026-10-21-structured-import-design.md)、[2026-10-22 通用病程档案](2026-10-22-generic-chronic-profile-design.md)。状态:**已收口**(2026-10-24):§9.2 十题全部有答,Q1、Q3 由用户拍板,其余八题由父会话按本 spec 的原则替用户定,各处标明。第一层(P1)随即实施;**第二层(中文摘要)与第三层(翻译)是「下一期」**,等底部 tab 那条线合并后再排。已过一轮独立 builder check(2026-10-23),纠正已并入。

## 0. 一句话

英文病历不整篇翻译。三层:**①码 → 中文名**(ICD-10 / LOINC / RxNorm,离线、确定性、今天就能做一半);**②每份文档一段五行以内的中文「医生摘要」**,每句锚到英文原文的一句,点开能看原句,走 ADR 0010 那条脱敏 → 境内模型的路,回来逐字校验;**③整篇翻译按需、逐份、缓存,默认不做**。界面中文在前,「看原文」一键切换。零新事件类型。

## 1. 意图 / 读者 / 现状

- 用户 2026-10-23 原话:「可以开考虑翻译的问题了,英文太长如果国内医生不爱读咋办?」
- 背景:用户把 UF Health 的 Epic 全量英文病历经 myEHR 适配器导进 MedMe(包 686 份、导入后建档 675 份,ADR 0012;下文按包算 686、诊断 677 条带 ICD-10、化验 11666 条约 85% 带 LOINC、用药 667 条部分带 RxNorm、病程记录全英文),目标是给**国内医生和机构**看。
- **目标读者**:国内医生,诊室里 30 秒,中文,要的是「这个人什么病、现在吃什么、最近一次关键结果、上次医生让他干什么」。英文全文是**依据**,不是阅读对象。
- 现状(读代码核过):
  - 化验:`labs_from_json` 名字认不出时按 `loinc` 反查词典(`packages/terminology/src/lib.rs:934`;词典 308 条带 LOINC、307 个不同码——298 条化验 + 10 条生命体征,`14749-6` 重复一次;10-21 spec 写的 305 已过时),命中即显示 `canonical_name` 中文(313 条化验里 312 条是中文名)。**这一层通了**,词典外的行英文原样透传。
  - 用药:`resolve_rxnorm`(`lib.rs:950`,词典 324 条药有 241 条 RxNorm、271 条 ATC、全部有中文 `canonical_name`)。**通了**,缺口是词典覆盖。
  - 诊断:`diagnoses_from_json` 把 `text`(英文)+ `icd` 读出来按 ICD 归族(`packages/profile/src/generic_tables.rs`),族名是中文,**诊断本身仍是英文原文,没有 ICD → 中文名的表**。
  - 文档标题:适配器已经给一半中文(`化验 <日期>` / `病程记录 <日期>` / `麻醉记录` / `护理与康复记录` / `已取消医嘱`,见 `myEHR/epic_adapter/docs.py:106,130,170` 与常量);另一半是 Epic 的英文小节名(`Discharge Summary Note` / `ED Provider Note` / `Operative Notes` 等**闭集**,`docs.py:12-20`)和影像/病理的医嘱名(`CT CHEST W CONTRAST`,**开集**,`docs.py:117`)。类型标签已经是中文(`apps/mobile_flutter/lib/doc_labels.dart:12`)。
  - 病程记录 / 出院小结 / 影像结论正文:**全英文,没有任何中文入口**。查看器(`web/hosted-viewer/index.html:1613`)把 `record.text` 整段渲染。
  - 云抽取通道:`POST /v1/extract`(`services/api/app.py:473`),按 `schema` 字段选 prompt(`extract.py:84-94`),文本档上限 64 KiB、每账号每月 token 上限默认 200 万(`app.py:30,32`),结果经 `deid::verify` 逐字校验后 `ExtractionAdded` 落 CAS,**同一文档 latest-wins**(`core-model/src/materialize.rs:682-686`)。

## 2. 三层模型:边界与数据来源

```
英文文档 ──┬─ ① 码 → 中文名   离线 · 确定性 · 查表        诊断/化验/用药/标题     今天就能做
           ├─ ② 中文医生摘要  脱敏 → 境内模型 → 逐字校验   每份 ≤5 句,每句锚原文   需后端 + 英文脱敏
           └─ ③ 整篇翻译      同一通道,按需、逐份、缓存    默认不做               最后
```

三层互不依赖:①没有也能做②,②没有也能点③。界面规则统一:**中文在前,英文原文永远一键可达,凡是数值/单位/日期/码一律原样不翻**。

### 2.1 第一层:码 → 中文名(离线)

| 对象 | 码 | 中文名来源 | 现状 | 要做的 |
|---|---|---|---|---|
| 化验 | LOINC | 词典 `canonical_name` | 通 | 只补词典;覆盖率报告(§2.1.4) |
| 用药 | RxNorm(词典内直接到 key,不经 ATC) | 词典 `canonical_name` | 通 | 补词典;报告 |
| 诊断 | ICD-10 | **新表**:国家临床版 2.0(§2.1.1) | 无 | 建表 + 显示 |
| 文档标题 | Epic 小节名(闭集) | **新表**:十几行常量(§2.1.3) | 一半中文 | 显示层映射 |
| 影像/病理标题 | 医嘱名(开集) | 只翻检查方式前缀(§2.1.3) | 英文 | 前缀表 |

#### 2.1.1 ICD-10 中文名表:来源、许可、版本、体积

- **候选 A · 《疾病分类与代码国家临床版 2.0》**(卫健委统计信息中心组织、中国医院协会病案专业委员会编,在 ICD-10 四位码基础上扩到六位,对 19,638 个疾病做了扩展;各省卫健委网站以 `.xls/.xlsx` 附件公开发布,如福建省卫健委 2021-06-02 页面;2019 年起多省发文要求医院统一使用)。**优点**:医院病案系统用的就是它,医生看到的中文名与国内病历一致;Excel 结构化,直接可用。
- **候选 B · ICD-10 医保版 2.0**(国家医保局 `code.nhsa.gov.cn` 编码标准数据库,2019-06 起;2.0 以 PDF 发布,要自己抽表)。医保结算口径,医生不一定熟;PDF 抽取多一道活。
- **推荐 A。** 许可:两者都是政府发布的行业标准/编码库,官方页面**没有明确的再分发许可条款**(查过福建卫健委页与 code.nhsa.gov.cn,均无);国内医院信息系统普遍内置,实际无人主张版权,但**「随 App 分发」是否可接受只有用户能定**(§9 Q1)。两条路:(a) 派生表(只保留「码 + 中文名」两列,去掉其余列)编进 `packages/terminology`,随 App 发;(b) 首启从 `api.medmenow.com` 下载,走 `skills/` 那套签名信封(ADR 0011),不随包发。**推荐 (a)**:两列表不是原文件的复制,体积小,离线;(b) 多一条网络依赖,只为规避一个没人主张的许可。
- **对码规则(关键)**:Epic 给的是 **ICD-10-CM**(美国临床修订版,5–7 位),国家临床版是 WHO ICD-10 四位码 + 国内六位扩展,两者 4 位以上**互不兼容**。匹配只认 WHO 公共部分:`normalize_icd`(`generic_tables.rs`,已有)之后 **先试 4 位(`B44.1`)→ 再退 3 位类目(`B44`)**;命中哪一级就标哪一级(`match_level: exact4 | category3 | none`),界面上类目级命中的中文名后面带「(类目)」小字,原英文诊断文本始终在下一行。CM 独有码与 CM 带字母第三位的码(`D3A`/`M1A`,`normalize_icd` 归一失败当无码,ADR 0012 已接受)按此规则自然落位。**事实更正(2026-10-24,拿到表之后)**:`Z79`(目前长期用药)整类**不在**国家临床版 2.0 里,`Z79.01` 落到 `None`、界面保留英文,不是原先写的「退到 Z79 类目名」;临床版基于 2010 年前的 WHO 更新,`N18.1–N18.5` 不在,`N18.3` 只到类目「慢性肾衰竭」。表的派生规则、计数与缺口见 `packages/terminology/icd10_zh_methodology.md`。
- **版本与体积**:派生表只取 3 位类目 + 4 位亚目(六位扩展 Epic 永远不会发出,不进表),估 1.2–1.5 万行、每行码 + 中文名,原始 CSV 约 600 KB–1 MB,压缩进二进制 < 300 KB(估算,以实际文件为准;**行数由实施者下载后核实,写进 log**)。表文件带 `version`(文件来源 + 日期)字段,与词典 `version` 同一做法。
- **放哪**:`packages/terminology` 新文件 `icd10_zh.json`(或 CSV),新函数 `resolve_icd10_zh(code) -> Option<IcdMatch{zh, level}>`;ADR 0004:core 只存码,这张表是 L3 映射,与 LOINC/RxNorm 同一层。

#### 2.1.2 用药:RxNorm → 中文通用名,覆盖率怎么算

- 路径今天已是 `rxnorm → 词典 key → canonical_name`(`resolve_rxnorm`),**不需要经 ATC**;ATC 只用于分族/泳道。父会话提的「RxNorm→ATC→中文」那条不必建:ATC 到中文通用名本身没有现成开放表(查过:国家医保药品分类与代码库有通用名但不挂 ATC;台湾食药署有 ATC 中文类别名,是**类别**名不是药名,且与大陆用名不一致),绕 ATC 只会多一跳、不增加覆盖。
- 覆盖率估算方法(**不碰真实数据、不传任何内容**):CLI 加子命令 `medme --vault <dir> zh-coverage`,只打印**计数**:诊断 `exact4 / category3 / none` 各多少;用药 `rxnorm 命中词典 / 有 rxnorm 但词典没有 / 没 rxnorm 名字命中 / 全无` 各多少,并把**没命中的 RxNorm 码与 LOINC 码本身**(码,不是药名/值/日期)列出来供补词典;化验 `LOINC 命中 / 名字命中 / 透传` 各多少。用户在自己机器上对 686 份跑一次,把计数贴回来,补词典的清单就是那张「没命中的码」。补词典沿用 `atc_gaps_methodology.md` 的红线:中文通用名查药典/说明书,**不猜、不凑**。
- 词典的 `aliases` 里英文别名 294/324 条已有,Epic 的 `metformin (GLUCOPHAGE) 500 MG Oral Tablet` 这种整行名字靠 `resolve_drug` 剥壳命中,命不中再靠 `rxnorm`。两条都落空 → 英文原样。

#### 2.1.3 文档标题中文化:放 MedMe 显示层,不放适配器

- 事实:`DocumentAdded.title` **只写一次**(`materialize.rs` ON CONFLICT DO NOTHING,见 10-21 spec §3.1),改适配器的标题意味着用户要**删掉 686 份再导一遍**;MedMe 显示层映射对已导入的保险箱立刻生效。
- 所以:**闭集小节名在 MedMe 侧做显示映射**,表放 Rust(`parser` 或 `core-model` 一个 `display_title_zh(title) -> Option<&str>`),手机 `docDisplayTitle` 和分享 `records[].title`(`packages/share/src/share.rs:281`)同一来源,查看器跟着中文。表的来源是适配器实际会发出的三类英文标题(`docs.py`):(a) `SECTION_DOC_TYPE` 的 8 个键(`:12-20`)——`Discharge Summary Note → 出院小结`、`H&P Notes → 入院记录`、`ED Provider Note → 急诊医生记录`、`ED Notes → 急诊记录`、`ED Record → 急诊病历`、`Operative Notes → 手术记录`、`Reason for Visit → 就诊原因`、`Visit Information → 就诊信息`;(b) `"%s %s" % (enc_kind, dept)`(`:152,178`)——就诊类型是闭集(`ED to Hosp-Admission` / `Office Visit` / `Hospital Encounter` …)、科室是开集 → 规则「就诊类型查表译、科室原文保留」:`Office Visit Cardiology → 门诊 · Cardiology`;(c) 影像小节回退标题 `pages[0].section`(`:119`,`Radiology`/`Imaging → 影像`)。`Progress Notes` 不在表里——适配器已经发中文 `病程记录 <日期>`;`未命名小节`/`其他页`/`Epic 病历摘要` 也已是中文。表的具体行由实施者按真实包里出现的标题定(用户跑 `zh-coverage` 时顺带打印**标题去重后的集合**——标题不含 PHI,但以防万一只打印命中/未命中计数,未命中的标题集合由用户自己看着贴)。
- 影像/病理医嘱名(开集):只翻**检查方式前缀** `CT / MR(I) / XR / US / ECHO / NM / PET` → `CT / 磁共振 / X线 / 超声 / 心脏超声 / 核医学 / PET`,其余(部位、造影)原文保留:`CT CHEST W CONTRAST → CT · CHEST W CONTRAST`。不做部位词典(ponytail:开集,收益小)。
- 适配器侧**不改**。它已经给出的中文标题保持。

#### 2.1.4 第一层界面(与 §4 线框合看)

- 诊断:族卡与依据里每条诊断 **中文名(表)在前、英文原文 + 码在后一行小字**;表没命中就只有英文 + 码。
- 化验/用药:已是中文名;列表行原名(英文)在「看原文」展开时可见(今天趋势页已如此)。
- 标题:档案行 `UF Health Shands · 出院小结`(已有拼法),英文小节名退到详情页抬头第二行。

### 2.2 第二层:每份文档一段中文「医生摘要」

#### 2.2.1 边界

- **输入**:这一份文档的 PDF 文本层(`ocr_result`,Epic 包是 `pdftotext` 产物,逐字可靠)经 `deid::redact_text` 脱敏 + 日期偏移后的文本(**文本档**,不是图片档——ADR 0010 决定 2 说生产默认图片档,那是针对拍照的化验单;这里输入本来就是文本,没有「原件画面」可涂,文本档是**唯一**选择,不是退路。这一点要记 ADR,见 §6)。
- **输出**:≤5 句中文,固定槽位:`chief_complaint 主诉/就诊原因`、`diagnoses 诊断`、`key_findings 关键结果`、`plan 处理`、`follow_up 随访/交代`。按文档类型允许槽位为空(化验单没有主诉;影像报告只有 `key_findings`)。**每句必须带 ≥1 条英文原文逐字引文**。
- **不是什么**:不是病历总结、不跨文档、不下结论、不写原文没写的、不换算单位、不给建议。

#### 2.2.2 Schema(prompt 与客户端校验共用,文件放 `packages/deid/prompts/summarize_zh_v1_system.txt`,与 `extract_v1_system.txt` 同一机制;服务端按 `schema: 3` 选它)

```json
{ "summary_zh": {
    "chief_complaint": { "zh": "", "quotes": [""] },
    "diagnoses":       { "zh": "", "quotes": [""] },
    "key_findings":    { "zh": "", "quotes": [""] },
    "plan":            { "zh": "", "quotes": [""] },
    "follow_up":       { "zh": "", "quotes": [""] }
} }
```

- `zh`:一句中文,≤60 字。**原文没有就留空**(空槽位界面不画)。
- `quotes[]`:英文**原文逐字子串**(模型看到的是脱敏偏移后的文本,引文里会带占位符与偏移日期;校验在偏移文本里做,落库前还原,见 §2.2.3),每条 ≥ 12 个字符(短引文满篇都是,锚不住)、≤ 300 字符。
- 落库时客户端补几样(不在 prompt 里,`verify` 盖章,与 `unverified` 同一约定):每条 quote 的 `span: [start,end]`(**原文**里的 UTF-8 字节区间,本机搜出来的,不信模型给的偏移;搜不到 `null`,见 §2.2.3 第 3 条)与 `nth`(这条引文在原文里是第几次出现,0 起)、每条 quote 的 `ambiguous: bool`、每句 `verified: bool`、顶层 `model`(服务端回的名字,与 `/v1/extract` 同一做法)、`created_at`。
- **界面不传字节偏移**:FFI DTO 与分享包只带 `quote + nth`,Dart/JS 自己 `indexOf` 第 nth 次——Rust 的 `span` 是 UTF-8 字节,Dart 是 UTF-16 码元,Epic 正文里有 `—` 这类非 ASCII 字符,传偏移必错。`span` 只给 Rust 侧消费者(病程档案那套)用。

#### 2.2.3 校验规则(`deid::verify_summary_zh`,Mode::Text 一个字不放宽)

1. **在脱敏偏移后的文本里核**,不是还原后:每条 `quote` 必须是发出去那份文本(`vault_cloud_commit_extraction` 里的 `seen.text`,`vault.rs:2252-2256` 今天就是对它核)的子串——与现有云路径同一口径。唯一放宽:**空白折叠**(连续空白当一个空格,两侧同样折叠;`pdftotext -layout` 的多栏正文一句话常被换行与多空格切开),其它一个字不放宽。找不到 → 这条引文丢;一句的引文全丢 → **这句丢**,计 `rejected`。
   - 为什么不能还原后核:`dates::apply` 把所有命中的日期**改写成 ISO**(`dates.rs:97-111`,`2025年6月14日 → 2025-06-14`),`unshift_dates` 只减回 ISO/紧凑两种(`:130-133`),原拼法回不来;美式日期加偏移后同理。还原后的引文对原文做逐字子串会把带日期的句子全部误杀。
2. **数字闸**(同样在偏移空间里跑,然后 `zh` 与 `quotes` 一起 `restore`):`zh` 里每个**数字词**必须整词出现在这句自己的某条 `quote` 里;否则这句丢。数字词 = 去掉占位符(`[P1]`/`[N2]` …)后,`[A-Za-z]*\d[\dA-Za-z./:,-]*` 的最长匹配去掉尾部标点(`1.8`、`2025-06-14`、`B44.1`、`200mg`、`10*3/uL` 里的 `10` 与 `3/uL` 各算一个)。prompt 要求 `zh` 里的日期按原文拼法原样写(不写「6月14日」)、不写原文没有的计数(「5 项」会被闸掉,这是故意的)。这是挡「编值」的硬闸:中文可以说「肌酐升高」,但要说「肌酐 1.8」那 `1.8` 必须在引文里。
3. `span`/`nth` 在**原文**里找:先 `restore(quote)` 逐字(空白折叠)搜;搜不到(引文含被改写拼法的日期)就把还原后引文里的每个日期词换成「同一天的几种拼法」交替(ISO / `M/D/YYYY` / `MM/DD/YYYY` / `YYYY年M月D日`)再搜;仍搜不到 → `span: null, nth: null`,这句**照常显示**(它在偏移文本里核过了),只是点不出高亮、退成「打开这份文档」——与 `EvidenceOut.span: None` 同一语义。多处命中按「同一行里含槽位提示词的那处」打分,思路同 `EvidenceBook::cite`(`state.rs:64-110`,但那是 `profile` 的 `pub(crate)`,`deid` 不依赖 `profile`,在 `deid` 里**自写**一份),仍并列取第一处并标 `ambiguous: true`(2026-10-01 的教训「依据不能 find 第一处」说的是**无条件取第一处**,这里先打分再退第一处)。
4. 五句全丢 → 这份**没有摘要**(不落库空壳),计数进报告;界面显示英文原文 + 一行「未能生成中文摘要」。
5. 服务端 502/截断/超时 → 与抽取同一处置(重试一次,再不成留给下次队列),不退回任何「本地生成」——本地没有能生成中文摘要的东西,也不该有。
6. **禁词闸**(ADR 0011 决定 7「引擎从不下结论」的延伸,**是我们的规矩不是用户要求**,可改成只标记不丢):`zh` 含「建议 / 应该 / 提示可能 / 考虑为」整词 → 这句丢。

#### 2.2.4 存储:超集 `ExtractionAdded`,零新事件类型

三个候选,选第一个:

| 方案 | 做法 | 为什么选/不选 |
|---|---|---|
| **A · 超集 ExtractionAdded(选)** | 读这份文档现有的 `extraction_json`(sidecar 原文或云抽取结果),加一个顶层键 `summary_zh`,整份 JSON 作为新结果 `add_extraction{backend:"zh-summary", model_version:<服务端回的模型名>, mode:"text", schema:<原 schema 不变>}` 再 append 一条 | 零新事件;latest-wins 自然生效;`labs_from_json`/`meds_from_json`/`diagnoses_from_json` 都是 `serde(default)` 无 `deny_unknown_fields`(`packages/deid/src/verify.rs:7-125`,全仓库无 `deny_unknown_fields`),多一个键照常读;sidecar 里的 `loinc`/`rxnorm`/`icd` 原样保留。代价:每次生成都复制一遍 sidecar 进 CAS(每份几 KB,686 份几 MB,可接受);**若以后对同一份再跑云抽取,新结果会盖掉摘要**——云抽取 commit 路径(`vault.rs:2227-2270`:`parse_extraction → verify → to_string(&v.extraction) → restore → add_extraction`,`Extraction` 结构体没有这两个字段,重序列化就丢)须改成「保留旧 JSON 里的 `summary_zh`/`translation_zh` 键再落盘」,实施必做;demo 路径 `vault.rs:1774` 同一模式。**接受的代价**:这一行的 `backend/model_version/mode/schema` 从此是摘要的(`zh-summary` / 模型名 / `text` / 原 schema),sidecar 的 `epic-adapter` 出处只在事件日志里(前一条 `ExtractionAdded`),今天没有任何读者看这四个字段(`query.rs:674-681` 只取 `result_json`) |
| B · 合成文档(`DocumentAdded{doc_type:…}`) | 像 `profile_event`/`note` 那样把摘要当一份文本文档存 | 否:`DocumentAdded` 没有「属于哪份文档」的位,只能靠标题约定;会进时间线、进分享、进搜索,一份病历变两份 |
| C · 新 CAS 对象无事件引用 | 只 `cas::put` | 否:同步不带、重建丢、等于没存 |

`extraction.result_json` 之外不新增表、不改 materialize。`DocumentSummaryDto.extraction_item_count` 不受影响(它数 labs/meds/diagnoses,`dto.rs:91-116`)。

**手机侧要新写的四件**(现有云抽取三步都绑在「刚导入那一份」上:`vault_cloud_prepare_extraction` 吃导入结果、`runCloudExtractions` 吃 `PendingCloudExtraction`,`cloud_extract.dart:228,276-300`,对**已在库里**的文档没有入口):
1. `vault_zh_prepare(doc_id) -> {redacted_text, restore_map_json}`:对已落库文档按 `ocr_text` 跑 `redact_text` + `assert_clean`(文本档,无图);
2. `vault_zh_commit(doc_id, kind: summary|translation, llm_json, restore_map_json)`:校验(§2.2.3)+ 超集合并 + `add_extraction`;
3. Dart `postExtract` 的 `schema` 从常量改成参数(3/4),`runSummaryZh(docIds)` 队列对已有文档跑;
4. `vault_document_summary_zh(doc_id) -> Option<SummaryZhDto>` 读取。四个 FFI 名字按字典序放对位置,`frb_dispatch_indices` 守着。

#### 2.2.5 何时生成

- **触发**:(1) 整包导入完成后;(2) 单份文档导入后(英文 PDF 手动导入);(3) 用户在详情页点「生成中文摘要」(有网时立即,一份)。只对 `document.language == "en"` 的文档(`parser::detect_language` 只在**零个**汉字时判 `en`,`parser/src/lib.rs:98-107`;Epic 切片的 PDF 文本层里没有适配器写的中文标题,会判 `en`)。`zh`/`mixed` **不生成**。**`lab_report` 类型不生成**——化验单的中文已由第一层解决,五个槽位对它几乎全空,白花钱;`zh-coverage` 顺带打印每类文档数,费用按去掉化验单后的份数重算。
- **方式:后台队列,一份一份,最新在前**(按 `doc_date` 倒序,出院小结优先于同日其它),复用 `cloud_extract.dart` 的 `runCloudExtractions` 串行模式与 `import_queue.dart` 的 `_drain` 令牌(`import_queue.dart:248-258`),串行是**默认**不是约束(单请求 13–40 s,串行约 2.5–7.5 小时,见下);要不要并发、并发几路由实施者按实测与服务端并发额度定。可随时关、杀掉重开从没摘要的那份继续(是否已有摘要看 `extraction_json` 有没有 `summary_zh` 键,天然幂等)。
- **同意**:走 ADR 0010 **同一个开关**「我 → 云端 → 云端整理」(`cloud_extract_enabled`),不新开关——数据流向、去处、脱敏、校验完全一样,只是模型被要求整理出的东西不同(与「病程事实」加 schema 2 时的处理完全对称,隐私政策 §三.7 当时就是这么写的)。**不再问第二次**:政策今天承诺「第一次添加病历时问你一次,以后不用再点」(`privacy.html:245,248`),再弹一次就是自相矛盾;整包量级的知情靠**可见的进度与暂停**——首页一行「正在为 N 份生成中文摘要 · 已完成 m · [暂停]」,进度行上写明预计时长。
- **顺序约束**:英文脱敏的 fixture(§2.2.7)**先于**任何一份真实文档发出去。

#### 2.2.6 费用与速率(686 份,按 2026-10 官方价,实施时重算)

- 价(`api-docs.deepseek.com/quick_start/pricing`,2026-10-23 查):`deepseek-flash`(V4.1-Flash)输入未命中缓存 $0.15/M(低峰)– $0.30/M(高峰),输出 $0.60 – $1.20/M;高峰 = 周一到周五 UTC 01–04、06–10 时,其余全低峰。
- 量(估算,**用户跑 `zh-coverage` 时顺带打印每份文本字节数的分布**后重算):5600 页 / 686 份 ≈ 8 页/份;英文一页约 600 token → 输入约 5k token/份,全量 ≈ 3.4M;输出 5 句 + 引文 ≈ 600 token,`reasoning_effort: low` 下推理另算 1–2k(抽取实测文本档 ~3400 completion,`extract.py` 注释),按 2k 算 ≈ 1.8M。
- 钱:输入 $0.5–1.0,输出 $1.1–2.2,**一轮全量 ≈ $2–3(¥15–25)**;换 prompt 重跑一轮同价。
- 时间:文本档实测 13.5 s/份、长表 39 s(`cloud_extract.dart:67`);串行 686 份 **2.6–7.4 小时**,4 并发 40 分钟–2 小时。
- **两道现有上限会被打穿,实施必改**:(1) `EXTRACT_MONTHLY_TOKEN_CAP` 默认 200 万/账号/月,一轮全量约 520 万 → 要么抬环境变量,要么给摘要单独计量(§9 Q3);(2) 文本档 64 KiB(`EXTRACT_TEXT_MAX_BYTES`)——Epic 出院小结二三十页的那几份可能超,**不截断**(截了引文校验全废),超限的那份不发、报告里点名、界面「这份太长,未生成」;分段送是以后的事。

#### 2.2.7 硬前置(D0):英文脱敏 fixture

今天 `deid` 的锚点表是中文为主,英文只有 2026-09 加的十几个(`anchors.rs:76-92`:Signed by / Reported by / Physician / Doctor / MRN / Patient ID …),日期偏移只认「四位年在前」的 `YYYY-MM-DD`/`YYYY/M/D`/`YYYY.M.D`、`YYYY年M月D日`、`yyyymmdd`(`dates.rs:20-33`),美式「月在前」一概不认,K 层已知姓名是**精确子串**(`known.rs:24-26`,闸 `gate.rs:5` 同样精确)。Epic 页眉每页都印 `Doe, Jane` + `MRN: …, DOB: 1/1/1990, Legal Sex: F`,正文有 `Name: Jane Doe`、`Authorized by: Some Doctor, MD`、`Entered by: Nurse Amy B, RN`、`Arrival Date/Time: 03/01/2024 0943`(`myEHR/tests/fixtures/synthetic_record.txt`)。按今天的规则(builder check 逐条核过):`MRN: 00000000` 被锚点 `MRN`(`anchors.rs:91`)与 P 层 ≥6 位数字(`patterns.rs:49`)掩掉;`DOB: 1/1/1990`、`03/01/2024 0943` **原样发出**(四位年不在前,`dates.rs:20-23` 不认,也没有 `DOB`/`Name`/`Patient` 锚点);`Jane Doe`(与档案名 `Doe, Jane` 形态不同)**漏**,闸也放行;`Authorized by` / `Entered by` / `Attending` / `Ordered by` 不是锚点,医生名**漏**;英文锚点**区分大小写**(`anchors.rs:119-125` 无 `(?i)`),Epic 真实写法 `Electronically signed by:` / `Cosigned by:`(`notes.py:9`)里的小写 `signed by` **不命中** `Signed by`;锚点后的人名只取 Title-case(`anchors.rs:165-189`),`JANE DOE` 不取;英文医院名**完全不掩**(`hospital_re` 只认中文,`anchors.rs:128-130`),`UF Health Shands` 原样出去。

所以第二层开工第一步是 `packages/deid/tests/fixtures/epic_en_*.txt + .expected.txt`(合成,Doe, Jane),至少盖住:页眉行;`Name:`/`Patient:` 锚点(P);**`DOB:`/`Date of birth:` 锚点 → 整个掩掉(N),不偏移**——出生日期是直接标识符,年龄另有 `34 y.o.` 保留;美式日期 `M/D/YYYY`、`MM/DD/YYYY`、`MM/DD/YY`(`03/04/24`、`10/20/26` 都在 fixture 里),**偏移且保留原拼法**(`3/1/2024 → 3/11/2024`),时间顺序要保留;月日歧义按美式(只对 `language == en` 的文档启用这组正则,中文单据的 `2024/3/5` 本来就走 ISO 组);`Authorized/Entered/Ordered/Attending/(Electronically |Co)signed by … , MD|DO|RN|…`,锚点**不分大小写**,人名边界用 `notes.py:8` 的 `CLINICIAN_CREDS` 后缀集合;K 层与 `assert_clean` 对姓名三种形态(`Last, First` / `First Last` / 全大写)都掩、都拒;英文机构名(`… Hospital|Medical Center|Health|Clinic|University of …`)掩成 `[H1]`,与中文规则对称(§9 Q10)。**这一组 fixture 不绿,第二层一份真实文档都不发。** 它同时也是隐私政策要写的那段「英文病历脱敏规则」的事实依据(§5)。

### 2.3 第三层:整篇翻译(按需、逐份、缓存,默认不做)

- **触发**:只有用户在详情页点「翻译全文」。不批量、不自动、不进队列。
- **通道**:同一条(`schema: 4`,prompt `translate_zh_v1_system.txt`),同一脱敏、同一闸、同一计量。
- **校验**:整篇译文没法逐字锚;只做两条弱闸——(1) 译文里出现的**每个数字串**都必须在原文里逐字存在(同 §2.2.3 第 2 条,整篇口径);(2) 原文里的化验值/单位/码不翻(prompt 要求 + 闸)。过不了 → 不落库、提示「译文核对未通过」。
- **缓存**:同 §2.2.4 方案 A,顶层键 `translation_zh: {text, model, created_at}`;再次打开直接读,不再发。
- **与第二层的关系**:独立。有译文时「看原文」切换变三态:中文摘要 → 英文原文 → 中文译文,摘要的引文高亮**只锚英文原文**,不锚译文(译文不是依据)。
- **分享**:译文默认**不进**分享包(体积等于原文,且不是依据);摘要进(§4.3)。

## 3. 第一层与第二层在数据上的衔接

- 第二层 prompt **不**要求模型翻译诊断名/药名;`zh` 句子里可以直接写中文(模型自己的翻译),但界面上**诊断/用药列表**仍以第一层查表的中文为准——两处不一致时用户看到的是「摘要说某某病,诊断栏印另一个译名」,实施者用 §7 golden 钉住:摘要 `zh` 里的病名/药名若词典/ICD 表有中文名,prompt 里把这几个中文名**作为提示词一并给模型**(只给名,不给值),让它用同一个叫法。这不是校验项,是一致性手段。

## 4. 界面(文字线框,只定结构不定视觉;视觉交设计师,见 memory `visual-design-goes-to-designer`)

通用规则:**中文在前;「看原文」一个控件在固定位置;摘要句可点,点了高亮原文那一句并滚到它;数值/单位/日期/码永远原样。** 今天详情页已有 `highlight` 入参 + `_HighlightedText`(`apps/mobile_flutter/lib/screens/document_detail.dart:76,615`),从病程档案「依据」跳进来就是这么用的——但它**只高亮第一处匹配**、且要求 `ocrText.contains(h)`(`:378`);摘要要的「多句、各自定位」是在它上面**新写**,不是零改动复用。定位传参见 §2.2.2 的 `quote + nth`,手机/查看器都不碰字节偏移。

### 4.1 病历详情页(手机)

**稿 A · 摘要在上、原文折叠(推荐)**

```
← UF Health Shands · 出院小结                     2025-06-02 → 06-14 · 住院 12 天
  Discharge Summary Note                                    (英文小节名,小字)
┌ 中文摘要 ─────────────────────────────── 来源:境内模型 · 已逐字核对 ┐
│ 主诉  发热、咯血自急诊入院                                      ▸ │
│ 诊断  侵袭性肺曲霉病 (B44.1);主动脉瓣置换术后 (Z95.2);高血压     ▸ │
│ 结果  半乳甘露聚糖 1.8 index(参考 0-0.5)↑;CRP 31 mg/L ↑          ▸ │
│ 处理  开始伏立康唑 200mg bid,并做血药浓度监测                   ▸ │
│ 随访  (原文未写)                                                  │
└───────────────────────────────────────────────────────────────────┘
[ 看原文 ▾ ]                                          [ 翻译全文 ]
  (点「看原文」或任一句 ▸ → 下面展开英文全文,对应那句黄底高亮并滚到)
  …
  Hospital Course: Admitted from the ED with fever and hemoptysis. ← 高亮
  …
[ 看原件 ]  [ 没问题 ]            (底栏不变,`DocumentReviewActionBar`)
```

- 没有摘要(还没跑 / 太长 / 全丢):摘要卡换成一行「还没有中文摘要 · [现在生成]」,原文默认展开。
- 一句 `ambiguous` 的:高亮第一处,句末小字「原文多处相同」。
- 有译文:「看原文 ▾」变成分段控件 `原文 | 译文`,摘要点击只在「原文」态高亮。

**稿 B · 上下分屏常显**

```
← 标题行同上
┌ 中文摘要(同上,五行) ┐
├───────────────────────── 原文 ───────────────────────── [中文译文] ┤
│ 英文全文常显,可滚动;点上面任一句 → 这里滚到并高亮               │
└───────────────────────────────────────────────────────────────────┘
```
优点:一眼看到「中文怎么说、英文在哪」;缺点:摘要卡占去上半屏,长文档下半屏只剩一点。

**稿 C · 三个 tab:摘要 / 原文 / 译文**

```
← 标题行
[ 摘要 ] [ 原文 ] [ 译文 ]
```
最简单,但点摘要句要跳 tab 再高亮,「中文在前、原文一键」变成两键。不推荐。

### 4.2 档案列表 / 就诊卡(手机)

- 文档行:`出院小结`(类型中文,已有)+ **第一层标题映射**;展开后子行加一行灰字 = 摘要的 `diagnoses` 或 `key_findings`(取第一个非空槽位,≤30 字,截断)——解决 10-21 log 记的「一次住院几十份『病程记录』分不清」。没摘要就没有这行。

### 4.3 医生查看器(`web/hosted-viewer`,分享包)

分享包 `records[]` 每条多两个可选键:`summary_zh`(§2.2.2 形状,**去掉 `span`,只带 `quote + nth`**)与 `title_zh`(第一层映射结果);`build_encrypted_share` 从 `rec.extraction_json`(`share.rs:323`)读出来带上(译文不带)。查看器按 `records[i].text` 找第 nth 次 `quote`——`rec.text` 与保险箱 `ocr_text` 都是逐页 `\n` 拼(`query.rs:660-668`),实施加一条断言钉住两者相等。查看器:

**稿 A · 记录行中文摘要 + 原文折叠(与手机稿 A 同构,推荐)**

```
2025-06-14 · 出院小结 · UF Health Shands                     [ 原文 ]
  主诉 … / 诊断 … / 结果 … / 处理 …   (每句可点)
  ▾ 原文(点句子或「原文」展开;展开后对应句高亮,其余折叠成「展开全文」)
```
顶部一个总开关 `中文 / 原文`:「原文」态所有记录直接展开英文全文、不显示摘要(给看得懂英文的医生)。查看器已有的 `summary`(泳道、趋势)不动——它本来就是中文(化验名、族名)。

**稿 B · 左右两栏(桌面宽屏)**

```
左 40%:中文摘要列表(按就诊分组)     右 60%:当前记录英文全文 + 高亮
```
手机宽度退化成稿 A。实施成本高一截,只值得在确认医生主要用电脑看之后做。

### 4.4 「给医生看」页(手机 `for_doctor_screen.dart`)与病程档案

- 不改结构。病程档案「依据」里引用的英文句子旁边,若那份文档有摘要,加一行它所属槽位的中文句(同一 span 命中才加)。这是顺手的,不是本轮必做。

## 5. 隐私与合规

- **路径复用 ADR 0010**:同一脱敏(`redact_text` + `assert_clean`)、同一代理 `/v1/extract`(只是多两个 `schema` 值)、同一 key、同一不落盘 payload 只记 token、同一账号计量、同一开关。没有新的数据去处。
- **前提**:数据是用户**本人**在美国产生的病历,用户本人自愿把脱敏后的文本送境内模型给国内医生看。方向与 PIPL 关注的出境相反;MedMe 不是 HIPAA 下的 covered entity,用户持有自己病历副本不受 HIPAA 约束——但**用户隐私政策是我们对用户的承诺**,数据流一变就要改(CLAUDE.md 硬规矩 4)。
- **gh-pages `privacy.html` 必须同步的点**(worktree `../Medme-ghpages`,推上即上线,改完 `curl` 核):
  1. 「结构化整理 = 把画面读成化验项目、用药、诊断」这句话出现在五处——`<meta description>`(`:8`)、开头第 3 段(`:86`)、第一节例外(`:93`)、第二节末(`:131`)、七种情况总述(`:142-147`)——每处都要加「**以及为英文病历生成中文摘要、按你要求翻译全文**」。
  2. §三.7「什么时候发生」(`:248`)今天写的是「每导入一份病历…自动送一次,一份一份地送」。新增:**导入一整包英文病历后,会在后台把这一包逐份送出生成中文摘要**(几百份、几小时,首页有进度与暂停,不再另问);详情页「生成中文摘要」「翻译全文」按钮点一次发那一份。随之改:`:266`「关掉之后**新添加**的病历只用本机识别」→ 关掉后后台队列停、按钮不发;`:387` 权限表「导入完成后会自动多跑一次第 7 项」→ 加后台队列与手动按钮;`:305` 用量表「每整理一份病历都…」→ 摘要/翻译同样计 token。
  3. §三.7「发的是什么」(`:250,258`):今天说默认发**涂黑后的图**、「涂黑不可用时**退而**发脱敏后的识别文字」。新增:**带文本层的 PDF(英文病历包)发的是脱敏后的文字,不是图**——这条路径没有图,「退而」两个字对它不成立。
  4. §三.7「脱敏三层」那张清单(`:252-253`)是中文标签,医院名那句只对中文成立。新增一段**英文病历的脱敏规则**(§2.2.7 落地后的事实:英文姓名三种形态、MRN/Patient ID、**出生日期整个抹掉**、`Authorized/Entered/Signed by` 后的人名、美式日期偏移、英文机构名——若 Q10 决定不掩,就如实写「英文医院名不抹」),并如实写「英文规则是 2026-10 新加的,覆盖面不如中文成熟」。
  5. §三.7「留下的是」(`:255`):加「病程记录、出院小结、影像结论的**叙述文字**」——摘要要靠它,这一句今天只列了化验/诊断/用药;下一段(`:256`)「还会整理出病程事实…发出去的东西一个字节都没变」的句式照搬给摘要:**发出去的东西不变,变的是要模型整理出什么**。
  6. §三.7「做不到的地方」第 3 条「模型给的结果会在本机逐字核对…打『需核对』」:加一句**中文摘要每句都锚到英文原句,核对不上的句子不显示**;**整篇译文只核数字,不逐句核**。
  7. 第三节第 3 项(二维码分享,`:195-207`):分享包里**现在会带中文摘要**(密文,不改通道),一句话即可。**第 4 项代拍不提**——那条是医生 → 病人方向,病程档案也不走它(gh-pages `2a09189`),摘要同理。
  8. DeepSeek 保留期那段不变(我们核实不到的仍然核实不到)。
- 时点:**第二层上线那一版 App 发布前**改好并上线;第一层(离线)不动政策。

## 6. 非目标 / 反目标

**先声明哪些数字是我们定的、不是用户要的**(CLAUDE.md 硬规矩 1):「五句以内 / 五个槽位」是父会话向用户提的方向(§9 Q4 再确认);`zh ≤60 字`、引文 `12–300` 字符、串行默认、禁词闸(§2.2.3 第 6 条)都是**建造者默认值**,写进计划即可改,不构成拒绝或缩水的理由。

- **不编值**:中文句里的任何数字必须在它自己的引文里逐字存在(§2.2.3 第 2 条),译文同理。
- **不做诊断、不给建议、不下结论**:prompt 禁止「建议」「应该」「提示可能」;校验加一条禁词闸(与病程档案「不出现结论性措辞」同一精神,ADR 0011 决定 7),命中整句丢。
- **模型输出必须逐字锚定**:没有引文的句子不存在。
- **不翻译化验数值与单位、不翻码**:`1.8 index`、`mg/L`、`B44.1`、`200mg bid` 原样;prompt 要求 + 数字闸兜底。
- 不翻译引文本身;不跨文档合成「病史总结」(那是病程档案的事,ADR 0012);不做中文 → 英文;不做桌面 Tauri;不做 Pro 侧任何东西;不新增事件类型、不改保险箱格式;不改适配器;不把 ICD 六位扩展码进表。
- 不做「自动整篇翻译」——用户没要,费用是摘要的 5–10 倍,而且没法锚。

## 7. 与 ADR 的关系

- **0001**(中英文一等公民):不变。存储仍是原文 + 码;中文是显示层与一份附加产物;`document.language` 已经是 `en`,正好用来决定「要不要生成摘要」。
- **0004**(core 独立于 FHIR/OMOP):ICD → 中文名表是 L3 映射,与 LOINC/RxNorm 词典同层,core 不存中文名。
- **0010**(云 LLM 抽取):**复用并增补**。增补三点:(a) 两个新 `schema`(3 摘要、4 翻译)走同一通道;(b) 对文本层来源的文档,文本档不是退路而是唯一路径——决定 2「生产默认图片档」的适用范围要写清是「拍照/扫描件」;(c) 云抽取 commit 路径须保留旧 JSON 里的 `summary_zh`/`translation_zh`。这三点建议记成 **ADR 0013**(Amends 0010,不 supersede)。
- **0011/0012**(病程档案):不碰引擎;`EvidenceOut{quote, span, verified}` 的形状(`packages/profile/src/state.rs:15-40`)被摘要的引文直接复用——同一套「原文逐字 + 字节区间 + 核过没有」。
- **0003**(CAS + 事件溯源):零新事件,摘要与译文是 `ExtractionAdded` 的 latest-wins 结果 JSON 的一部分。

## 8. 留给实现者的决定与验收标准

### 8.1 决定(建造者自定,但要在计划里写明)

1. ICD 表的文件格式(JSON vs CSV)、加载方式(编进二进制 `include_str!` 同词典)、`IcdMatch` 字段名。
2. 标题映射表的具体行(按 `zh-coverage` 打印的标题集合定)与放在 `parser` 还是 `core-model`。
3. 摘要队列的并发度(1–4)与重试策略;后台跑时首页的进度表达(复用整包导入那种 SnackBar/进度行)。
4. 五个槽位按文档类型的允许/禁止矩阵(化验单禁 `chief_complaint`;影像只允许 `key_findings`+`plan`)——写进 prompt 与校验。
5. 槽位提示词(§2.2.3 第 3 条打分用)与禁词表的具体词。
6. `SummaryZhDto` / 分享包 `records[].summary_zh` 的字段名;查看器稿 A 的折叠实现。
7. 服务端 `schema: 3/4` 是否与 `/v1/extract` 共用一个 handler(推荐共用,与 schema 2 同一手法,`extract.py:88-96` 多两个分支;`:89` 注释「3 和别的形状照旧 400」同步改)。
8. 美式日期偏移正则的具体形状(含 `HHMM` 时间后缀、两位年)与「只对 `language == en` 启用」的落点(`redact_text` 多一个参数,或按文档语言选规则集)。
9. 超过 64 KiB 的文档:队列记「太长」跳过,不自动重试;限制改了之后用户点「生成中文摘要」再发。
10. 每条引文存 `ambiguous`,`rejected` 只进报告不落库。
11. 就诊类型(`enc_kind`)闭集的中文表,按 `zh-coverage` 打印的集合定。

### 8.2 验收(全部合成数据,Doe, Jane;真实病历只在用户设备上、只贴计数)

**第一层**
- `terminology` 单测:`resolve_icd10_zh("B44.1")` → 中文名 + `sub4`;`"Z79.01"` → `None`(整类不在表内,见 §2.1.1 更正);`"N18.3"` → 类目名 + `cat3`;`"I350"`(Epic 无点)经 `normalize_icd` 后命中;`"D3A.0"` → `None`;`"X99.9"` 编造码 → `None`。
- 标题映射单测:闭集每行一条;`CT CHEST W CONTRAST` → `CT · CHEST W CONTRAST`;已是中文的标题原样。
- `zh-coverage` 对 `packages/profile/testdata/corpus-jane/` 跑出的计数是确定的,钉成 golden(诊断 exact4/category3/none、用药、化验、标题各几条)。
- 通用病程档案 Jane golden(`golden_generic_view.json`)**不变**(中文名是显示层,不进引擎输出)——或若决定进 `family_cards`,golden 更新一次并在 log 里说明。

**第二层**
- 英文脱敏 fixture(§2.2.7)全绿:`epic_en_header_1`、`epic_en_names_2`、`epic_en_dates_3`、`epic_en_clinicians_4` 四对,断言姓名三形态/MRN/DOB/医生名全掩、美式日期偏移且往返还原、化验行一个字不动;`assert_clean` 对 `Jane Doe` 与 `JANE DOE` 拒发。
- golden 中文摘要三份(`packages/deid/tests/fixtures/summary_zh/` 或 `packages/profile/testdata/corpus-jane/*.summary_zh.json`,**由实施者手写、独立 subagent 逐句核到原文**,不是模型生成):
  - `2025-06-14_出院记录_UF`(出院小结):五槽位中四个非空(`follow_up` 空),`key_findings` 含 `1.8`、`31`,引文各一条;
  - `2025-11-17_门诊病历_UF`(病程记录,伏立康唑停用那次):`plan` 句写「停用伏立康唑」,引文是含 `discontinued` 的那一句;`chief_complaint` 可空;
  - `2025-06-03_影像报告_UF`(影像):只有 `key_findings`(+ 可选 `plan`),其余空。
- `verify_summary_zh` 单测:(a) golden 三份全过,`span` 都解析到且 `verified` 全真;(b) 负例:`zh` 写 `肌酐 1.9` 而引文只有 `0.9` → 这句丢、`rejected == 1`;(c) 负例:引文改一个字 → 这句丢;(d) 负例:`zh` 含「建议复查」→ 禁词闸丢;(e) 引文在原文出现两处 → 打分取含提示词那行,`ambiguous == false`;两行都含 → 第一处 + `ambiguous == true`;(f) 五句全丢 → 返回 `None`,不落库。
- 存储:pipeline 集成测试——Jane 包 `import_bundle` → 对一份文档 `add_summary_zh(golden)` → `extraction_json` 顶层同时有 `labs[].loinc`、`diagnoses[].icd` 与 `summary_zh`;再跑一次 `add_summary_zh` 幂等(不追加事件);**模拟云抽取 commit** 后 `summary_zh` 仍在。
- 服务端 `test_api.py`:`schema: 3` 选到 `summarize_zh_v1_system.txt`;`schema: 4` 选翻译 prompt;`5` 仍 400;prompt 文件与评测臂 byte-identical 的既有测试扩到新文件。
- 手机:`frb_dispatch_indices` 绿;详情页 widget 测试——有摘要时五行渲染、空槽位不画、点第二句后 `_HighlightedText` 高亮的是该句 `span`、「看原文」展开;没摘要时一行「还没有中文摘要」;`flutter analyze` 零。
- 查看器:`renderProfile.smoke.mjs` 旁加 `renderSummaryZh.smoke.mjs`——带 `summary_zh` 的 record 渲染五行、点句展开原文并高亮;不带的 record 渲染与今天逐字节一致(老分享不受影响)。

**第三层**(若本轮做)
- `verify_translation_zh` 单测:译文多出一个原文没有的数字 → 拒;单位被译(`毫克/升`)→ 拒(prompt + 闸);通过的译文落库到 `translation_zh` 且再次打开不发请求(mock 计数为 0)。

**不许自审**:golden 摘要、隐私政策改动、ICD 表抽样(随机 30 条对回原 Excel)三样各派独立只读 subagent 核到 `file:line`。

## 9. 分期与待拍板

### 9.1 分期

| 期 | 内容 | 依赖 | 离线? |
|---|---|---|---|
| **P1 · 第一层(本期)** | ICD 表 + `resolve_icd10_zh`;标题映射;`zh-coverage` CLI;词典按报告补码;详情页/族卡/查看器的「中文名在前、英文+码在后」;「看原文」最小切换 | 无 | 是,不动政策 |
| **P2a · 英文脱敏(下一期)** | §2.2.7 fixture 与锚点/日期/K 层三形态 | 无 | 是 |
| **P2b · 摘要(下一期)** | prompt + `schema 3` + `verify_summary_zh` + 超集落库 + 队列 + 详情页稿 A + 查看器稿 A + 隐私政策 §5 八点 + ADR 0013 | P2a 绿;服务端部署 | 否 |
| **P3 · 翻译(不做)** | `schema 4` + 弱闸 + 三态切换 | P2b | 否 |

P1 与 P2a 可并行(不同文件);P2b 等两者。实施计划放 `docs/superpowers/plans/2026-10-23-chinese-localization.md`,做完即删;每期收尾一条 `docs/log/`(≤40 行)。

### 9.2 拍板记录(2026-10-24;【用户】= 用户本人拍板,【父会话】= 父会话按 spec 原则替用户定)

- **Q1 ICD 中文名表**【用户】:国家临床版 2.0;两列派生表随 App 打包;Epic 的 ICD-10-CM 按前 4 位 → 3 位类目匹配。
- **Q2 摘要触发**【父会话】:整包导入后自动后台跑全部;同意沿用「只问一次」,首页进度行可暂停;化验单不生成摘要。(下一期)
- **Q3 费用与上限**【用户】:给他的账号抬上限;摘要与云端整理同一个计量。(下一期)
- **Q4 五个槽位**【父会话】:主诉/诊断/关键结果/处理/随访,五句以内,就按这个。(下一期)
- **Q5 第三层整篇翻译**【父会话】:本轮不做。
- **Q6 隐私政策**【父会话】:接受;如实写「英文脱敏规则是新加的、覆盖不如中文成熟」。(随下一期上线)
- **Q7 分享包带中文摘要**【父会话】:默认带;医生查看器中文在前。(下一期)
- **Q8 标题中文化**【父会话】:放 MedMe 显示层,适配器不动。
- **Q9 同意开关**【父会话】:复用「云端整理」同一个开关。(下一期)
- **Q10 英文医院名**【父会话】:对称掩掉。(下一期,属 P2a)
