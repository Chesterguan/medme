# 无 ATC 码的 53 条药物 — 方法与清单(WORKLIST #9)

**版本**: 草案 v2 · 2026-08-05(v1)/2026-08-08(v2 第二轮独立复核)· MedMe（医我）

## 背景

`dictionary.json` 中 `category == "drug"` 的 323 条条目里，53 条 `codes.atc` 为
空。**结构性后果**：`packages/parser/data/problem_map.json` 的疾病泳道一律按
`atc.starts_with(prefix)` 把药挂到对应疾病上（见
`packages/parser/data/problem_map.methodology.md`）——没有 ATC 的药，不管临床上
多常用，**永远挂不到任何泳道**，医生查看器里看不见它们。这 53 条不是遗漏统计，
而是从产品能力上凭空消失。

## 方法（一句话）

**每一条 53 都已经在自己的 `note` 字段里写明白了留空的理由**——这不是本轮新发现
的缺口，是之前扩容批次逐条查过 OMOP 本地词表（LOINC/RxNorm/ATC）后诚实记录的
结论。本文档做的事是**把散在 53 个 JSON `note` 里的理由收拢成一张可复核的表**，
并在有 web 访问的情况下逐条拿 WHOCC 官方 ATC/DDD Index
（`https://atcddd.fhi.no/atc_ddd_index/`）交叉核实，确认没有本地 vocab 之外、
WHOCC 官方确实收录但本地词表漏收的码。

**红线一如既往**：ATC 是 WHO 官方分配的编码，不能靠"这类药通常是……"去推断，
更不能凑一个前缀。本轮核对中，好几个"看起来很像"的候选码——逐一核对官方定义
后**主动放弃**了，原因见下表"曾考虑但放弃的候选码"一列。这不是本轮第一次犯
这个错误的诱惑：`problem_map.methodology.md`「已知缺口」一节记录过两次真正犯
错后被纠正的案例（C02CA 的排除理由被 WHOCC 定义证伪；C08D 的排除标准没有对
已收录的 C07A 一视同仁）——本轮核对刻意把同一把尺子用严，宁可 53 条全留空，
也不重复那两次的错误。

## 本轮 WHOCC 交叉核实：新查 vs 已有结论

有 web 访问（`atcddd.fhi.no`，WebSearch 配额已耗尽但 WebFetch 可直连该站）的
情况下，对本表里看起来最可能有码的候选逐条查证，**结果是对已有 53 条 `note`
的独立复核，没有发现任何一条应该改判**：

| 候选 | 查到的官方码 | 为什么不采用 |
|---|---|---|
| `vitamin_k2`（维生素K2，OMOP 通用 ingredient 19106287） | `M05BX08` = menatetrenone | 与既有 `note` 结论一致：M05BX08 对应的是**另一个** OMOP ingredient 概念（19072027，四烯甲萘醌/骨质疏松适应证的特定形式），不是本条目代表的通用 vitamin K2（含 MK-4/MK-7 多种形式）。套用会把一个更窄的概念的码，套到一个更宽的概念上。 |
| `compound_methoxyphenamine`（复方甲氧那明） | `R03CB02` = methoxyphenamine（单方） | 与既有 `note` 结论一致：本条目是甲氧那明+那可丁+氨茶碱+氯苯那敏四组分复方，R03CB02 只是其中一个组分的单方码，WHOCC 无对应复方 5th 码。 |
| `compound_reserpine_triamterene`（复方利血平氨苯蝶啶） | `C02LA01`/`C02LA51` 等「利血平+利尿剂」类 | 与既有 `note` 结论一致：本方是利血平+氨苯蝶啶+氢氯噻嗪+双肼屈嗪四组分，C02LA 系是"利血平+利尿剂（+其他药）"的分类桶，但没有对应到这个具体四组分配方的 5th 码——挂 C02LA51 这类桶码需要确认桶内确有该配方，本次未能确认，不套用。 |
| `sodium_bicarbonate`（碳酸氢钠） | `B05CB04`（冲洗液）/ `B05XA02`（静脉电解质添加剂） | 与既有 `note` 结论一致：两个码都是静脉/冲洗用途，本条目在词典里代表的是不限剂型的通用条目（含口服片剂用法），套用任一个都会隐含"这是静脉用药"，不准确。 |
| `iron_sucrose`（蔗糖铁） | `B03AC`（4 位组码，"Iron, parenteral preparations"，WHOCC 直接在该层挂 DDD，无 5th 级子码） | 与既有 `note` 结论一致：词典里其余 269 条 ATC 全部是 7 位 5th 级码，`B03AC` 是 4 层组码，套用会破坏字典自身"只收 5th 级"的一贯约定，且 WHOCC confirmed 没有更细的蔗糖铁专属码可用。 |
| `bacillus_subtilis_enterococcus` / `bifidobacterium`（活菌制剂） | `A07FA`（止泻用微生物制剂组）下仅 3 个具名子码：乳酸菌（01）、布拉氏酵母菌（02）、大肠杆菌（03） | 本方涉及的枯草杆菌、屎肠球菌、双歧杆菌都不在这 3 个子码里，WHOCC 未单独收录，与既有 `note` 一致。 |
| `xuesaitong`（血塞通，三七总皂苷） | 无 | 查 "notoginseng" 无命中，WHOCC 不收录中成药提取物，与既有 `note` 一致。 |
| `lianhua_qingwen`（连花清瘟） | 无 | 查 "lianhua" 无命中，与既有 `note` 一致。 |
| `compound_glycyrrhizin`（复方甘草酸苷）/ `compound_licorice`（复方甘草片） | 无 | 查 "glycyrrhizin"/"licorice" 均无命中，与既有 `note` 一致。 |

结论：**这轮独立核实没有找到任何一条应该从"留空"改判为"补码"的条目**。53 条
维持留空。

## 53 条清单（按理由归四类）

### 一、中成药复方专利制剂（24 条）—— WHO ATC/DDD 方法学上不收录

WHOCC 的 ATC/DDD 体系是按**单一活性成分**（或明确定义的国际通用复方，如
"reserpine and diuretics"）分类的，不给个别国家的中成药专利配方单独发码——这不
是词典漏查，是 ATC 体系的覆盖范围本就不包含这类产品（同样的方法学结论已见于
`problem_map.methodology.md`"代谢相关脂肪性肝病"一条："无任何以脂肪肝为适应证
的 ATC 药物类别……不臆造'保肝药'类别"）。

| key | canonical_name | ingredient（词典记录） |
|---|---|---|
| lianhua_qingwen | 连花清瘟 | Lianhua Qingwen (TCM compound) |
| bailing | 百令 | Bailing (fermented Cordyceps sinensis mycelium powder) |
| jinshuibao | 金水宝 | Jinshuibao (fermented Cordyceps powder Cs-4) |
| xuesaitong | 血塞通 | Xuesaitong (Panax notoginseng saponins) |
| compound_danshen_dripping_pill | 复方丹参滴丸 | Salvia miltiorrhiza + Panax notoginseng + borneol |
| liuwei_dihuang | 六味地黄丸 | Liuwei Dihuang Wan |
| huoxiang_zhengqi | 藿香正气 | Huoxiang Zhengqi |
| shenshuaining | 肾衰宁 | Shenshuaining |
| niaoduqing | 尿毒清 | Niaoduqing |
| huangkui | 黄葵胶囊 | Abelmoschus manihot flower extract |
| tongxinluo | 通心络 | Tongxinluo |
| wenxin_keli | 稳心颗粒 | Wenxin Keli |
| shensong_yangxin | 参松养心 | Shensong Yangxin |
| shexiang_baoxin_pill | 麝香保心丸 | Shexiang Baoxin Wan |
| suxiao_jiuxin_pill | 速效救心丸 | Suxiao Jiuxin Wan |
| qili_qiangxin | 芪苈强心胶囊 | Qili Qiangxin |
| sanjin_pian | 三金片 | 金樱根、菝葜、羊开口等 |
| shenqi_jiangtang | 参芪降糖颗粒 | 人参茎叶皂苷、黄芪、地黄等 |
| danshen_chuanxiongqin | 丹参川芎嗪 | Danshen and Ligustrazine injection |
| xueshuantong | 血栓通 | Panax notoginseng saponins（与 xuesaitong 同类不同品） |
| shuxuetong | 疏血通 | Hirudo + Pheretima extract |
| shenyan_kangfu | 肾炎康复片 | Shenyan Kangfu Pian |
| xianling_gubao | 仙灵骨葆 | 淫羊藿、续断、丹参等 |
| tripterygium_glycosides | 雷公藤多苷 | Tripterygium wilfordii glycosides（中药提取物,非成方但同样未被 ATC 收录） |

### 二、多组分复方，无对应"复方专属"ATC 5th 码（11 条）

ATC 对复方制剂只在 WHO 认定"国际通用固定复方"时才发码（如 `A10BD`、
`C09DA`）；这些是国产 OTC/处方复方，组分列表明确，但没有对应的国际复方码，套用
其中任一单方成分的码都会误导（详见上表"曾考虑但放弃的候选码"）。

| key | canonical_name | ingredient（复方成分） | 曾核实、未套用的近似码 |
|---|---|---|---|
| compound_alpha_ketoacid | 复方α-酮酸 | Compound alpha-ketoacid | 无（WHOCC 查无 "alpha-keto acid" 相关条目） |
| compound_paracetamol_amantadine | 复方氨酚烷胺 | Paracetamol/Amantadine/Chlorphenamine/Caffeine/人工牛黄 | 无 |
| compound_paracetamol_pseudoephedrine | 氨酚伪麻美芬 | Paracetamol/Pseudoephedrine/Dextromethorphan(±Chlorphenamine) | 无 |
| compound_licorice | 复方甘草片 | Compound licorice (Glycyrrhiza) | 无 |
| compound_methoxyphenamine | 复方甲氧那明 | Methoxyphenamine/Noscapine/Aminophylline/Chlorphenamine | R03CB02（甲氧那明单方，不套用） |
| compound_reserpine_triamterene | 复方利血平氨苯蝶啶 | Reserpine/Triamterene/Hydrochlorothiazide/Dihydralazine | C02LA01/C02LA51（利血平+利尿剂类，组分不完全对应，不套用） |
| compound_ferrous_sulfate | 复方硫酸亚铁 | Ferrous sulfate/Vitamins | B03AA07（硫酸亚铁单方）/B03AD03（硫酸亚铁+叶酸，成分不符）均不套用 |
| compound_glycyrrhizin | 复方甘草酸苷 | Glycyrrhizin/Glycine/L-Cysteine | 无（WHOCC 查无 glycyrrhizin 相关条目） |
| potassium_magnesium_aspartate | 门冬氨酸钾镁 | Potassium aspartate/Magnesium aspartate | 无对应复方码（单方门冬氨酸钾 A12CC05 不套用） |
| bacillus_subtilis_enterococcus | 枯草杆菌二联活菌 | Bacillus subtilis/Enterococcus faecium | A07FA 组下仅收乳酸菌/布拉氏酵母菌/大肠杆菌 3 种，不含本方菌种 |
| bifidobacterium | 双歧杆菌（活菌复方） | Bifidobacterium | 同上，A07FA 组不含双歧杆菌 |

### 三、单一活性成分在本地 OMOP vocab 中查无 Ingredient/ATC（9 条）

多为中国/日本本地化学药，OMOP 的 RxNorm Extension 里虽有 concept（供内部编码
唯一性用），但**不是真实 RxNorm CUI**，且 ATC 未收录——这是"vocab 缺口"而不是
"漏查"：查过、确认查无。

| key | canonical_name | 备注 |
|---|---|---|
| butylphthalide | 丁苯酞 | ATC 未收录该成分 |
| iguratimod | 艾拉莫德 | 国产/日本上市抗风湿药，vocab 无 Ingredient、无 ATC |
| oryzanol | 谷维素 | ATC 无对应 5th 码 |
| bicyclol | 双环醇 | OMOP concept 为 RxNorm Extension（非真实 RXCUI），ATC 未收录 |
| bifendate | 联苯双酯 | 国产合成保肝药，vocab 无 Ingredient/ATC |
| epalrestat | 依帕司他 | OMOP concept 为 RxNorm Extension（非真实 RXCUI），ATC 未收录 |
| hyzetimibe | 海博麦布 | 国产胆固醇吸收抑制剂（依折麦布类似物），vocab 无 Ingredient/ATC |
| magnesium_isoglycyrrhizinate | 异甘草酸镁 | OMOP concept 为 RxNorm Extension（非真实 RXCUI），ATC 未收录 |
| anisodamine | 山莨菪碱 | OMOP concept 为 RxNorm Extension（非真实 RXCUI），ATC 未收录 |

### 四、条目代表的概念比某个"看起来很像"的 ATC 码更宽/更模糊，套用会误导（9 条）

这组最危险——每一条都**存在**一个表面相关的 ATC 码，套上去表面能过测试，但要么
对应的是不同 ingredient 概念、要么剂型/给药途径不明，套用即是本文档开头说的
"凑前缀"。

| key | canonical_name | 存在但不套用的码 | 不套用的原因 |
|---|---|---|---|
| sodium_bicarbonate | 碳酸氢钠 | B05CB04（冲洗）/ B05XA02（静脉电解质） | 词典条目不限剂型，两码都只对应静脉/冲洗用法，与常见口服片剂不符 |
| multivitamin | 多种维生素 | A11AA01-04（依是否含矿物质分支） | 组方不定，无法确定唯一分支 |
| vitamin_k2 | 维生素K2 | M05BX08（menatetrenone） | M05BX08 对应更窄的 ingredient 概念（四烯甲萘醌/骨质疏松适应证），本条目是含 MK-4/MK-7 的通用 vitamin K2 |
| vitamin_b_complex | 复合维生素B | A11EA（B族维生素，仅 4 位组码） | 无 5th 级码，套 4 位组码会破坏字典"只收 5th 级"的约定 |
| silibinin | 水飞蓟宾 | A05BA03（silymarin 水飞蓟素） | silibinin 是 silymarin 的主要活性成分之一，但 vocab 里是两个不同 Ingredient 概念，不能互代 |
| hemocoagulase_agkistrodon | 尖吻蝮蛇血凝酶 | （无干净候选） | OMOP 为 RxNorm Extension 概念，ATC 无对应 5th 码；"血凝酶"处方语境常泛指同类药（如巴曲亭/Batroxobin），本条目刻意只代表尖吻蝮蛇来源这一种 |
| iron_sucrose | 蔗糖铁 | B03AC（4 位组码，铁剂胃肠外制剂，WHOCC 未再拆分子码） | 无 5th 级码，套 4 位组码会破坏字典"只收 5th 级"的约定 |
| polysaccharide_iron_complex | 多糖铁复合物 | （无干净候选） | OMOP vocab 无对应 Ingredient / ATC 5th |
| water_for_injection | 注射用水 | （无干净候选） | RxNorm Ingredient「water」(11295) 实查存在，但 ATC 无对应 5th 码——它是溶媒而非治疗药物，ATC 体系本就不覆盖 |

## 结构性后果与建议（不在本次改动范围内）

这 53 条在 `problem_map.json` 按 ATC 前缀匹配的疾病泳道机制下永远不可见。本次
改动**只动 `packages/terminology/**`，不碰 `problem_map.json`**（另有工作在
`packages/parser/**` 进行，且 ATC 前缀本身的增补需要臨床裁定，参见
`problem_map.methodology.md`"已知缺口"一节的教训）。留给后续讨论的方向：

- **中成药（24 条）和活菌制剂（部分）**：即使有对应的中国临床指南把它们列为
  某疾病的常用药（如 niaoduqing/shenshuaining 用于慢性肾病、wenxin_keli/
  shensong_yangxin 用于心律失常），也不该硬套 ATC 前缀去挂泳道——正确做法是
  给 `problem_map.json` 增加一种**按 `key`/`ingredient` 精确名单匹配**的旁路
  （而不是 ATC 前缀），且需要臨床签字确认每条适应证归属，工作量和裁定性质与
  ATC 前缀补齐完全不同，留待专门的一轮。
- **组三、组四（18 条）**：本地 vocab 缺口，理论上可以等未来 OMOP vocab 更新
  后重新核对（尤其是几个"RxNorm Extension 非真实 RXCUI"的国产药，未来官方
  RxNorm 收录后可能有真实 Ingredient/ATC）。

## 待人工查证（v1 遗留，已在 v2 用完整 WebSearch 配额核实 —— 见下节）

以下几条 v1 查证时间有限，标记为"下一轮用完整 WebSearch 配额（而非仅 WebFetch
直连单个 URL）重新核实"：

- `iron_sucrose`（蔗糖铁）—— 确认 WHOCC 是否曾经或在其他年份索引中给过更细的
  5th 级码（本轮查的是 2026 版 Index）。
- `hemocoagulase_agkistrodon` —— 确认"血凝酶类"在 ATC B02BX 组下是否有本轮
  搜索词未覆盖到的具名子码。
- 组一的 24 条中成药 —— 本轮仅抽查 3 条（xuesaitong/lianhua_qingwen/
  compound_glycyrrhizin）作为方法学验证，未逐条查证；抽查结果支持"WHO ATC
  不收录中成药专利制剂"这一方法学结论对全组成立，但未做到逐条实查。

## 第二轮独立复核（v2，2026-08-08，WebSearch 配额可用）

**触发**：产品要求交付一版"给 53 条补 ATC"的 PR。动手前先按本文档开头的方法论
独立核实了缺口数字与机制（`dictionary.json` 逐条统计，`category == "drug"` 的
322 条里仍有 53 条 `codes.atc` 为空，与 v1 清单逐一比对 key 完全一致，无新增无
减少），然后用**本轮可用的完整 WebSearch + WebFetch 直连 WHOCC**（v1 记录
WebSearch 配额已耗尽，只能 WebFetch 单 URL）对 v1 结论做独立复核，而不是直接
信任 v1 的记录。

**复核范围与方法**：
1. 用 WebFetch 直连 `atcddd.fhi.no/atc_ddd_index/?name=<term>` 逐条查询；
2. 先用已知有码的药（`metformin`）验证该搜索接口本身工作正常（返回 23 条真实
   结果，含 A10BA02 及全部 A10BD 系复方），排除"接口本身返回空白导致误判为
   无码"的可能；
3. 对 v1「待人工查证」标记的两条（`iron_sucrose`、`hemocoagulase_agkistrodon`
   /`batroxobin`）逐一查证；
4. 对组三全部 9 条单方化学药（`butylphthalide`、`iguratimod`、`oryzanol`、
   `bicyclol`、`epalrestat`、`hyzetimibe`、`bifendate`、`anisodamine`、
   `magnesium_isoglycyrrhizinate`）逐条查证（v1 未逐条查这组，只在 note 里记了
   "vocab 无对应"的结论）；
5. 对组四补查 `silibinin`（区别于已核实的 silymarin）、`polysaccharide_iron_
   complex`、`water_for_injection`；
6. 对组二补查 `potassium_magnesium_aspartate`（查 "potassium aspartate"）、
   `compound_paracetamol_pseudoephedrine`/`compound_paracetamol_amantadine`
   （查 "paracetamol" 全部复方分支）、`compound_ferrous_sulfate`（查 "ferrous
   sulfate" 核对 B03AA07/B03AD03 两码）；
7. 对组一中成药在 v1 已查的 3 条之外，再抽查若干条的**核心药材/组分**而非中文
   商品名（WHOCC 不收中文名，只收国际非专利名）：`Tongxinluo`/`Wenxin Keli`/
   `Shexiang Baoxin`（WebSearch 未见 ATC）、`Tripterygium wilfordii`（WebSearch
   未见 ATC）、`salvia miltiorrhiza`/丹参（WebFetch 无匹配）、`cordyceps`/
   虫草（百令、金水宝的活性来源，WebFetch 无匹配）、`hirudin`/水蛭素（疏血通
   组分之一，WebFetch 无匹配）。

**结果**：全部复核项在 2026 版 WHOCC ATC/DDD Index 中**均无匹配**
（"No match found"）或**确认匹配的是不同层级/不同概念**（与 v1 结论一致，无
一条改判）。逐项证据：

| key | 复核方法 | 结果 |
|---|---|---|
| iron_sucrose | WebFetch `?name=iron+sucrose`；并用 `?code=B03AC` 核对该 4 位组码本身 | name 搜索无匹配；`B03AC`("Iron, parenteral preparations")确认只在 4 位组码层带 DDD（0.1g Fe，肠外），WHOCC 页面未列任何 5th 级子码 —— 与 v1 结论一致 |
| hemocoagulase_agkistrodon | WebFetch `?name=hemocoagulase`（含 batroxobin 同义词） | 无匹配 |
| butylphthalide / iguratimod / oryzanol / bicyclol / epalrestat / hyzetimibe / bifendate / anisodamine / magnesium_isoglycyrrhizinate | WebFetch `?name=<INN>` 逐条查询（9 条） | 全部无匹配 |
| silibinin | WebFetch `?name=silibinin` | 无匹配（与已核实的 silymarin=A05BA03 是不同 OMOP Ingredient 概念，不可互代，v1 结论成立） |
| polysaccharide_iron_complex / water_for_injection | WebFetch `?name=polysaccharide+iron` / `?name=water` | 无匹配；"water" 命中的 3 条（V08AA/AB/AC）全部是水溶性 X 光造影剂类别，与"注射用水"无关 |
| potassium_magnesium_aspartate | WebFetch `?name=potassium+aspartate` | 无匹配 |
| compound_paracetamol_pseudoephedrine / compound_paracetamol_amantadine | WebFetch `?name=paracetamol` | 仅 N02BE51（不含精神安定药的复方，4 位组码桶）/N02BE71（含精神安定药），无伪麻黄碱/金刚烷胺专属子码，且均非 5th 级专属码，不套用 |
| compound_ferrous_sulfate | WebFetch `?name=ferrous+sulfate` | B03AA07（硫酸亚铁单方）、B03AD03（硫酸亚铁+叶酸）——本条目是"硫酸亚铁+多种维生素"，成分与 B03AD03 不符，不套用，与 v1 结论一致 |
| Tongxinluo / Wenxin Keli / Shexiang Baoxin / Tripterygium wilfordii / salvia miltiorrhiza（丹参）/ cordyceps（虫草）/ hirudin（水蛭素） | WebSearch + WebFetch 组合查询核心药材/复方英文名 | 均无 ATC 码命中，支持"WHO ATC 不收录中成药专利制剂及其药材来源"对组一全组成立的结论 |

**结论**：v2 复核**没有发现任何一条应该从"留空"改判为"补码"的条目**。53 条
（`dictionary.json` 中 `codes.atc` 为空的 drug 条目）维持留空，`atc_gaps_
methodology.md` 与 `packages/terminology/src/lib.rs` 里的
`drugs_without_atc_are_all_explained` 测试（锁定数量 = 53、每条必有 `note`）均
未改动。**本轮没有向 `dictionary.json` 写入任何 ATC 码** —— 红线一如既往：
查不到官方码就不填，53 条全部诚实留空好过编一个"看起来对"的前缀。

本轮改动范围与 v1 相同：只动 `packages/terminology/atc_gaps_methodology.md`
本身（记录复核过程），不碰 `dictionary.json`、不碰 `problem_map.json`、不碰
`problem_map.methodology.md`（后者的"45 条药物映射"统计因此不受影响，无需
重新生成）。
