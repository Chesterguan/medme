# 词典 / 解析层根本解法 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把「化验名字配错」(UPCR↔ACR、CH50↔CA50、/HP 归零)与「处方剂量读错」(规格压过用法、途径被吞)两类错从根上堵掉——词典变成单位感知 + 编码化,用药信息改由云端事实抽取给出并本机逐字核对,正则只做兜底且兜底宁缺毋错。

**Architecture:** 三层各自收口,互不越界。**词典层**(`packages/terminology`):新增 `Entry.dimension` 标签——声明了它就等于声明「我的 `units[]` 是封闭的」,于是 `resolve(name, unit)` 可以按印刷单位**拒绝**候选、而同名不同量纲的条目可以共用裸别名(`aliases` 索引由单值改成列表,由单位裁决);纯 ASCII 短代码永不模糊。**抽取层**(`packages/deid` + `services/api`):开 schema 3 = v2 字节前缀 + 用药块,用药的途径/剂型/频次以受控词表代码回传、剂量拆成数值+单位,全部本机逐字核对,核不过置空。**聚合层**(`packages/parser`):有 schema 3 抽取结果就用事实,没有才用正则;`MedSpan.latest_raw_name` 退休,换成显式 `latest_form`/`latest_route`;`LabPoint` 带上自己那张单子的参考区间。每日剂量始终由本机 `dose × frequency` 算(`profile::rules::gc_daily_mg` 已有,不新增)。

**Tech Stack:** Rust 2021 workspace(`terminology` / `parser` / `deid` / `profile` / `ocr` example),Python FastAPI(`services/api`),Dart/Flutter(仅 `cloud_extract.dart` 一个常量)。依赖零新增:`serde`/`serde_json`/`regex`/`ureq`(已在 `packages/ocr` 的 dev-dependencies)。

**Spec:** `docs/superpowers/specs/2026-09-18-dictionary-parser-root-fix-design.md`(A1–A6 / B1–B5 / C 顺序 / E 决定)。相关 ADR:[0010](../../ADR/0010-cloud-llm-extraction-and-accounts.md)(云抽取边界、schema 版本、计量)、[0011](../../ADR/0011-disease-profile-skill-packages.md)(覆盖层只能加不能改、A32 缺口清单)。已知隐患对照:[2026-09-18 log](../../log/2026-09-18-known-hazards-before-beta.md) 第 1–6 条。

## Global Constraints

- **库代码里不许有 `unwrap()` / `expect()` / `unsafe`。** 测试代码里可以。库里要表达不变式用 `unwrap_or_else(PoisonError::into_inner)`、`ok_or`、`let ... else` 这些现成写法(`terminology::set_overlay` 是现成范例)。
- **不许新增 crate。** workspace 依赖表(根 `Cargo.toml`)一个字不动。
- **每个任务结束时 `cargo test --workspace` 全绿**;改到的 crate 另跑 `cargo clippy -p <crate> --all-targets -- -D warnings` 与 `cargo fmt --check -p <crate>`。
- **`packages/parser/tests/corpus_summary.rs` 与 `downstream_fidelity.rs` 的数字不许动**,除非某个任务显式重新定基线并在该任务里写下 before/after 与原因。
- **移动端 FRB 线上契约**:`recognize_image_pp` 必须留在派发下标 44(`apps/mobile_flutter/rust/tests/frb_dispatch_indices.rs` 守着)。本计划**不新增任何 FFI 函数**;只改 DTO 字段和已有函数的参数值,派发表不受影响。
- **云端只走我们的代理**(`services/api`),不绑模型名(`DEEPSEEK_MODEL_TEXT`/`DEEPSEEK_MODEL_VISION` 是环境变量)。批量校准的请求必须先过 `deid::assert_clean`、必须有显式同意开关,**永不发送报告原图、数值、任何身份信息**——只发项目名与印刷单位。
- **`apps/mobile_flutter/rust` 不在 workspace 里。** 改 `terminology::Entry` 的字段会打断它的两处结构体字面量(`vault_profile.rs:247`/`:267`),`cargo test --workspace` **看不见**;改完必须另跑 `cargo test --manifest-path apps/mobile_flutter/rust/Cargo.toml`。
- **移动端构建纪律**(`apps/mobile_flutter/CLAUDE.md`):不跑 release、不跑全 ABI;日常只 `flutter analyze` + `dart test` + Rust 单测。
- 散文用中文,代码与标识符用英文。注释写「为什么」,不写「做了什么」。
- **每个任务最后一步是 commit**,message 结尾两行逐字:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
  ```

---

## 文件结构(先看清哪个文件负责什么)

| 文件 | 职责 | 本计划怎么动 |
|---|---|---|
| `packages/terminology/src/lib.rs` | 词典索引与查询(`normalize`/`resolve`/`fuzzy_lookup`/`pick_best`/覆盖层) | 加 `dimension`、短代码闸、别名索引改列表、单位拒绝 |
| `packages/terminology/dictionary.json` | 642 条内置词条(编译进二进制) | +2 条(`urine_rbc_hpf`/`urine_wbc_hpf`),给 4 条打 `dimension` |
| `packages/terminology/testdata/confusions.json` | **新**:易混对清单(A5 闸的数据) | 新建,逐轮追加 |
| `packages/terminology/tests/confusions.rs` | **新**:A5 闸(CI 跑,不依赖外部语料) | 新建 |
| `packages/terminology/examples/term_gaps.rs` | **新**:从语料抽「名+单位」并按今天的词典分类 | 新建(dev 工具,非 CI) |
| `packages/ocr/examples/calibrate_terms.rs` | **新**:A6 批量校准客户端(经我们的代理) | 新建(dev 工具,非 CI) |
| `packages/deid/prompts/extract_v3_system.txt` | **新**:schema 3 提示词(v2 字节前缀 + 用药块) | 新建 |
| `packages/deid/prompts/calibrate_terms_system.txt` | **新**:校准提示词(只有规则,键表走 user 消息) | 新建 |
| `packages/deid/src/verify.rs` | schema 结构体 + 逐字校验 | `MedItem` 加 7 个字段,加 3 张受控词表 |
| `services/api/extract.py` | 代理:按 schema 选提示词 | 加 schema 3 与 `terms-calib` 两条分支 |
| `packages/parser/src/meds.rs` | 正则用药抽取 | B4 兜底规则 + 途径/剂型带出来 |
| `packages/parser/src/extraction.rs` | 云抽取 JSON → `LabObservation` | 加 `meds_from_json` |
| `packages/parser/src/aggregate.rs` | 跨文档聚合(`MedSpan`/`AnalyteSeries`/`LabPoint`) | 用药优先级、`latest_form`/`latest_route`、每点参考区间 |
| `packages/profile/src/rules.rs` | 病程档案规则求值 | `form_haystack` 改读代码、序列 JSON 带每点区间 |
| `apps/mobile_flutter/lib/cloud_extract.dart` | 发请求 + 落盘的 schema 号 | `extractSchema` 2 → 3 |
| `apps/mobile_flutter/rust/src/api/vault_profile.rs` | 覆盖层条目构造 | 补 `dimension: None` |

---

## 阶段 C1 —— 最便宜、收益最大(spec §C.1)

### Task 1: 短代码只走精确表(A2)

**Files:**
- Modify: `packages/terminology/src/lib.rs`(`fuzzy_lookup` 顶部 + 常量区 + `mod tests`)

**Interfaces:**
- Consumes: 已有 `normalize_term`、`FUZZY_MIN_LEN`、`FUZZY_CONFIDENCE`、`resolve`、`dictionary_entries`。
- Produces: `const SHORT_CODE_MAX_LEN: usize = 6;` 与 `fn is_short_code(norm: &str) -> bool`(crate 私有,Task 8 的测试会再用一次)。

- [ ] **Step 0: 先量一下今天有多大(证据,不是印象)**

```bash
python3 - <<'PY'
import json
d = json.load(open('packages/terminology/dictionary.json', encoding='utf-8'))
names = [(e['key'], a.replace(' ', '')) for e in d['entries'] for a in e['aliases']]
short = [(k, n) for k, n in names if n.isascii() and 4 <= len(n) <= 6]
have = {n.lower() for _, n in names}
seen, out = set(), []
for _, n in short:                      # 只变字母,不动数字(数字护栏本来就挡着)
    for i, c in enumerate(n):
        if c.isdigit():
            continue
        for rep in 'nbuo':
            m = n[:i] + rep + n[i+1:]
            if rep == c.lower() or m.lower() in have or m in seen:
                continue
            seen.add(m); out.append({"name": m, "unit": ""})
json.dump({"reports": [{"items": out[:1500]}]}, open('/tmp/mut.json', 'w'), ensure_ascii=False)
print(len(out), "个变体,取前 1500")
PY
cargo run --quiet -p terminology --example coverage -- /tmp/mut.json | head -6
```
2026-09-19 实测:**1500 个变体里 1172 个有命中,其中 1170 个是 `<1.0` 的非精确命中** ——
短代码那 1 字编辑距离预算基本是敞开的。把这个数记下来,Step 4 之后再跑一次对照。

- [ ] **Step 1: 写失败的测试**

加到 `packages/terminology/src/lib.rs` 的 `mod tests` 里(**只有这一条**——不要再写
「`resolve("CH5O")` 必须 miss」那种举例式的:实测它今天就已经 miss 了,因为
`fuzzy_lookup` 的数字前缀护栏挡着 `5` ≠ `50`,写了也是一条从来不红的假测试):

```rust
    #[test]
    fn no_short_ascii_alias_can_be_reached_by_fuzzy() {
        // 性质测试,不是举例:把词典里每一条**纯 ASCII 且 ≤6 字符**的别名逐位替换成
        // OCR 常见的形近字符,结果只允许三种——miss、精确命中(1.0,变体恰好撞上另一条
        // 真别名,如 C3→C4)、OCR 混淆表命中(0.5)。**0.4 的模糊命中一条都不许有。**
        for e in dictionary_entries() {
            for a in &e.aliases {
                let norm = normalize_term(a);
                if norm.chars().count() < FUZZY_MIN_LEN || !is_short_code(&norm) {
                    continue;
                }
                let chars: Vec<char> = norm.chars().collect();
                for i in 0..chars.len() {
                    for rep in ['o', '0', 'i', '1', 's', '5', 'a', 'h'] {
                        if chars[i] == rep {
                            continue;
                        }
                        let mut v = chars.clone();
                        v[i] = rep;
                        let mutated: String = v.into_iter().collect();
                        if let Some(m) = resolve(&mutated, None) {
                            assert!(
                                m.confidence > FUZZY_CONFIDENCE,
                                "{mutated:?}(由 {a:?} 变异)被模糊配到 {} —— 短代码不许模糊",
                                m.key
                            );
                        }
                    }
                }
            }
        }
    }
```

- [ ] **Step 2: 跑测试,确认它红**

Run: `cargo test -p terminology --lib no_short_ascii_alias`
Expected: FAIL —— 先是编译错(`is_short_code` 还不存在);把 Step 3 的两个函数加上、
**不加 `fuzzy_lookup` 里那三行**再跑一次,应当红在断言上,报出某个变体被配到 0.4。
这是预期的第一次红。

- [ ] **Step 3: 写最小实现**

在 `packages/terminology/src/lib.rs` 的 `FUZZY_MIN_LEN` 常量**之后**加:

```rust
/// 纯 ASCII 短代码的长度上限。**CH50 / CA50 / C3 / IL-2 / CD4 这类缩写差一个字符
/// 就是另一个临床概念**,不是字形误读——它们不该吃 `fuzzy_max_distance` 那 1 字
/// 的编辑距离预算。CJK 名字不受影响(汉字确实会被认错,那是模糊匹配的本职)。
/// 6 = 词典里最长的一批纯 ASCII 别名(`CA19-9`/`CA125`/`ANTI-CCP` 的前两个)仍在闸内。
const SHORT_CODE_MAX_LEN: usize = 6;

/// 这个**已归一化**的查询是不是纯 ASCII 短代码(见 [`SHORT_CODE_MAX_LEN`])。
/// 归一化后 ASCII 串的 `len()` 就是字符数,不必再数一遍。
fn is_short_code(norm: &str) -> bool {
    norm.is_ascii() && norm.len() <= SHORT_CODE_MAX_LEN
}
```

在 `fuzzy_lookup` 里,紧跟在 `if len < FUZZY_MIN_LEN { return None; }` 之后加:

```rust
    // A2:纯 ASCII 短代码永不模糊(见 [`is_short_code`])。
    if is_short_code(&norm) {
        return None;
    }
```

并在 `fuzzy_lookup` 的文档注释「策略」列表第 1 条后面补一行:

```rust
/// 1b. **纯 ASCII 短代码不模糊**([`is_short_code`]):缩写差一个字母是另一个概念。
```

- [ ] **Step 4: 跑测试,确认它绿**

Run: `cargo test -p terminology`
Expected: PASS(全部)。若 `no_short_ascii_alias_can_be_reached_by_fuzzy` 报出某条 0.4 命中,说明闸没盖住那条路径——**不要放宽断言**,去看那条别名是不是含非 ASCII 或超过 6 字符。

再跑一次 Step 0 的对照:`cargo run --quiet -p terminology --example coverage -- /tmp/mut.json | head -6`
Expected: 「非精确命中」那个数从 **1170** 掉到接近 0(剩下的只可能是 OCR 混淆表 0.5 与
药名剥壳 0.8 —— 两者都是有人核对过的对应关系,不是猜)。把这个数记进 Task 16 的 log。

- [ ] **Step 5: 全量回归**

Run: `cargo test --workspace`
Expected: PASS。重点看 `packages/parser/tests/corpus_summary.rs` 与 `downstream_fidelity.rs` ——短代码闸只会让**猜**变成 miss,这两份语料用的是拉丁缩写,若数字动了要先弄清是哪一条从「配错」变成了「没配」,把它记进 Task 3 的 `confusions.json`。

- [ ] **Step 6: Commit**

```bash
git add packages/terminology/src/lib.rs
git commit -m "$(cat <<'EOF'
fix(terminology): 纯 ASCII 短代码永不模糊匹配(A2)

CH50/CA50 这类缩写差一个字符就是另一个临床概念,不该吃 1 字编辑距离的预算。
加性质测试:词典里每条 ≤6 字符的纯 ASCII 别名逐位变异后,都不许被 0.4 模糊捡起。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
EOF
)"
```

---

### Task 2: 正则兜底宁缺毋错(B4)

**Files:**
- Modify: `packages/parser/src/meds.rs`(`parse_dose`、`extract_meds`、常量区、`mod tests`)

**Interfaces:**
- Consumes: 已有 `dose_re()`、`strip_trailing_route`、`MedObservation`。
- Produces: `fn spec_shape_re() -> &'static Regex`、`const USAGE_MARKERS: &[&str]`、`const FORM_WORDS: &[&str]`(均为 crate 私有)。`parse_dose` 签名不变:`fn parse_dose(line: &str) -> Option<(f64, String, usize)>`。

- [ ] **Step 1: 写失败的测试**

加到 `packages/parser/src/meds.rs` 的 `mod tests` 里:

```rust
    #[test]
    fn usage_beats_package_spec_on_a_prescription_line() {
        // A32 ⑥ / ADR 0011 记的真实写法:一行里既有包装规格(5mg×60片)又有医嘱用法
        // (7.5mg 每日一次)。取规格 = 激素日剂量直接错,而 DORIS「泼尼松 <5mg」与
        // 骨保护「≥7.5mg」两条阈值读的正是这个数。
        let o = &extract_meds("醋酸泼尼松片 5mg×60片 用法:7.5mg 每日一次")[0];
        assert_eq!(o.dose_num, Some(7.5), "必须取用法,不是规格");
        assert_eq!(o.dose_unit.as_deref(), Some("mg"));
        assert_eq!(o.frequency.as_deref(), Some("qd"));
    }

    #[test]
    fn spec_without_usage_yields_no_dose_at_all() {
        // 只有规格、没有用法 —— 这一行**读不出医嘱用量**。宁可没有剂量(下游进
        // 「换算不了」并如实显示),也绝不拿包装规格冒充每日用量。
        let o = &extract_meds("醋酸泼尼松片 5mg×60片")[0];
        assert_eq!(o.drug_key.as_deref(), Some("prednisone"), "药还是认得");
        assert_eq!(o.dose_num, None, "规格不是剂量");
        assert_eq!(o.dose_unit, None);
    }

    #[test]
    fn a_bare_dosage_form_word_is_not_a_drug_name() {
        // 切分把剂型词单独留成了名字(「片」「胶囊」)——那不是药,今天却会作为
        // drug_key = None 的未知药留在「用药」里污染列表。
        assert!(extract_meds("片 0.5g bid").is_empty());
        assert!(extract_meds("注射液 5ml qd").is_empty());
    }

    #[test]
    fn a_line_with_no_spec_is_unchanged_by_the_usage_rule() {
        // 回归护栏:没有规格的行,行为与加这条规则之前**逐字相同**。
        // 「每晚一次」里含着 USAGE_MARKERS 的「一次」,若无条件按它切,20mg 会被切没。
        let o = &extract_meds("阿托伐他汀钙片 20mg 每晚一次")[0];
        assert_eq!(o.dose_num, Some(20.0));
        assert_eq!(o.frequency.as_deref(), Some("qn"));
    }
```

- [ ] **Step 2: 跑测试,确认它红**

Run: `cargo test -p parser --lib meds::tests`
Expected: FAIL —— `usage_beats_package_spec_on_a_prescription_line` 得到 5.0(取了规格),`spec_without_usage_yields_no_dose_at_all` 得到 Some(5.0),`a_bare_dosage_form_word_is_not_a_drug_name` 得到 1 条。

- [ ] **Step 3: 写最小实现**

在 `packages/parser/src/meds.rs` 的 `ROUTE_WORDS` 之后加:

```rust
/// 处方行上「包装规格」的形状:`5mg×60片`、`0.5g*20片`、`5mg x 60`。规格里的那个
/// 剂量**不是医嘱用量**——把它读成用量,激素日剂量就直接错(A32 ⑥)。
fn spec_shape_re() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(
            r"(?i)\d+(?:\.\d+)?\s*(?:µg|μg|mcg|mg|iu|ml|ug|g|u)\s*[x×*]\s*\d+\s*(?:片|粒|袋|支|丸|ml)?",
        )
        .expect("spec shape re")
    })
}

/// 「用法」段的起点词:处方笺把医嘱用量写在这些词**后面**。
/// **只在同一行上还印着规格时**才拿它当切点(见 [`parse_dose`]):没有规格的行里,
/// 「每晚一次」的「一次」会把真剂量切到界外。
const USAGE_MARKERS: &[&str] = &[
    "用法", "用量", "服法", "Sig", "sig", "每次", "一次", "每日", "一日", "每天",
];

/// 剂型词单独成名不是药名(B4:药名切分不允许以剂型词单独成名)。
const FORM_WORDS: &[&str] = &[
    "片", "粒", "胶囊", "颗粒", "注射液", "注射剂", "乳膏", "软膏", "滴眼液", "口服液",
    "丸", "散", "栓", "贴", "喷雾剂", "混悬液",
];
```

把 `parse_dose` 改成:

```rust
/// Parse the first dose token: `(number, canonical_unit, byte_start_of_token)`.
///
/// B4「宁缺毋错」:同一行上既有**规格**(`5mg×60片`)又有**用法**(`用法:7.5mg`)时
/// 只取用法段里的那个;有规格却认不出用法段 → 返回 `None`(下游进「换算不了」),
/// **绝不拿规格冒充用量**。没有规格的行行为与本规则之前逐字相同。
///
/// 另外跳过两类「看着像剂量」的化验行:单位后紧跟 `/`(浓度,`132 g/L`)或紧跟字母
/// (`112 umol/L` 的 `112 u`)。
fn parse_dose(line: &str) -> Option<(f64, String, usize)> {
    let spec: Vec<(usize, usize)> = spec_shape_re()
        .find_iter(line)
        .map(|m| (m.start(), m.end()))
        .collect();
    let scan_from = if spec.is_empty() {
        0
    } else {
        // 有规格:必须先找到用法段,否则这一行给不出医嘱用量。
        USAGE_MARKERS.iter().filter_map(|w| line.find(w)).min()?
    };
    for caps in dose_re().captures_iter(line) {
        let whole = caps.get(0)?;
        if whole.start() < scan_from {
            continue;
        }
        // 落在规格区间里的剂量一律不算(用法段写在规格前面的少数写法也挡得住)。
        if spec
            .iter()
            .any(|(s, e)| whole.start() >= *s && whole.end() <= *e)
        {
            continue;
        }
        let after = &line[whole.end()..];
        if after.starts_with('/') {
            continue; // 浓度单位(g/L、mg/L…),不是剂量
        }
        if after.starts_with(|c: char| c.is_ascii_alphabetic()) {
            continue;
        }
        let num: f64 = caps.get(1)?.as_str().parse().ok()?;
        let unit = normalize_dose_unit(caps.get(2)?.as_str());
        return Some((num, unit, whole.start()));
    }
    None
}
```

在 `extract_meds` 里,紧跟在 `let name = strip_trailing_route(&cleaned[..name_end]);` 与那两条名字 guard 之后、`// 4) resolve the drug` 之前加:

```rust
        // 剂型词单独成名不是药(B4)。留着它,「用药」里会多出一条名叫「片」的未知药。
        if FORM_WORDS.contains(&name) {
            continue;
        }
```

- [ ] **Step 4: 跑测试,确认它绿**

Run: `cargo test -p parser --lib meds::tests`
Expected: PASS(含既有 8 条)。特别确认 `lab_umol_row_and_usage_lines_are_not_meds` 里那条 `"1.盐酸二甲双胍缓释片 0.5g×60片"` 仍然 `drug_key == Some("metformin")` ——它只断言药名,剂量变 `None` 是本任务的**预期**行为。

- [ ] **Step 5: 全量回归 + 语料核对**

Run: `cargo test --workspace`
Expected: PASS。`corpus_summary` / `downstream_fidelity` / `packages/profile/tests/drug_status.rs` 的数字**不许动**——语料里的处方笺按 ADR 0011 已被改写绕开「规格+用法」写法,所以本任务对它们应当零影响。若真动了,停下来报告是哪一行、动了什么,不要改语料去迁就代码。

- [ ] **Step 6: Commit**

```bash
git add packages/parser/src/meds.rs
git commit -m "$(cat <<'EOF'
fix(parser): 处方行「规格」不再压过「用法」,剂型词不再单独成药名(B4)

「醋酸泼尼松片 5mg×60片 用法:7.5mg 每日一次」此前解析成 5mg qd,激素日剂量直接错。
有规格无用法时返回 None(进「换算不了」),不拿规格冒充用量;没有规格的行行为不变。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
EOF
)"
```

---

## 阶段 C2 —— 词典单位感知 + 批量校准(spec §C.2)

### Task 3: 解析混淆闸(A5)

**Files:**
- Create: `packages/terminology/testdata/confusions.json`
- Create: `packages/terminology/tests/confusions.rs`
- Modify: `packages/terminology/testdata/README.md`(加一节说明这份不是盲集)

**Interfaces:**
- Consumes: `terminology::resolve(&str, Option<&str>) -> Option<Match>`、`Match { key, confidence, .. }`。
- Produces: `confusions.json` 的形状——数组,每项 `{"name","unit","expect","why"}`,其中 `expect` 为规范键字符串或 `null`(`null` = **必须 miss**)。Task 8 会往这份文件里追加 `/HP` 那几行;Task 16 会报它的条数。

- [ ] **Step 1: 建数据文件**

`packages/terminology/testdata/confusions.json`:

```json
[
  {"name": "尿蛋白肌酐比", "unit": "mg/g", "expect": "urine_pcr",
   "why": "A32 ①:补 urine_pcr 之前按 1 字编辑距离被模糊配成 urine_acr(白蛋白≠总蛋白)"},
  {"name": "尿蛋白/肌酐", "unit": "mg/g", "expect": "urine_pcr", "why": "同上,另一种印法"},
  {"name": "UPCR", "unit": "mg/g", "expect": "urine_pcr", "why": "同上,缩写印法"},
  {"name": "尿白蛋白肌酐比", "unit": "mg/g", "expect": "urine_acr",
   "why": "反向:ACR 自己不能被 PCR 抢走"},
  {"name": "ACR", "unit": "mg/g", "expect": "urine_acr", "why": "同上,缩写印法"},
  {"name": "CH50", "unit": "U/mL", "expect": "ch50",
   "why": "A32 ②:补 ch50 之前被模糊配成 ca50(糖类抗原50,肿瘤标志物)"},
  {"name": "总补体溶血活性", "unit": "U/mL", "expect": "ch50", "why": "同上,中文印法"},
  {"name": "CA50", "unit": "U/mL", "expect": "ca50", "why": "反向:CA50 自己不能被 CH50 抢走"},
  {"name": "CH5O", "unit": "U/mL", "expect": null,
   "why": "短代码的 OCR 误读只许 miss。今天靠 fuzzy 的数字前缀护栏(5≠50)已经挡住,A2 的短码闸是第二道 —— 两道都不许松"},
  {"name": "血清补体C3", "unit": "g/L", "expect": "complement_c3", "why": "C3/C4 一字之差"},
  {"name": "血清补体C4", "unit": "g/L", "expect": "complement_c4", "why": "同上,反向"}
]
```

> 跑之前先核一遍:`complement_c3` / `complement_c4` / `ca50` / `prednisone` 这些键必须真的在 `dictionary.json` 里。用 `python3 -c "import json;d=json.load(open('packages/terminology/dictionary.json'));print([e['key'] for e in d['entries'] if e['key'] in ('complement_c3','complement_c4','ca50','urine_acr','urine_pcr','ch50')])"` 核。键名对不上就按实际键名改这份 JSON,**不要**去改词典。

- [ ] **Step 2: 写闸(它现在应该就是绿的——这是回归闸,不是 TDD 的红)**

`packages/terminology/tests/confusions.rs`:

```rust
//! **解析混淆闸(spec A5)。** 一份已知易混对清单:每一行给「报告上印的项目名 +
//! 印刷单位」,断言 `resolve` 落在哪个规范键上(或必须 miss)。
//!
//! 为什么不挂在 MedRepBench 上:那份语料要 `MEDREP_ROOT`,CI 没有,挂上去等于没有闸。
//! 这份清单是**从评测里捞出来、钉进仓库**的常量,任何人改别名/改阈值/改模糊策略都
//! 当场知道有没有撞回已知的坑。新发现的混淆对往 `testdata/confusions.json` 里加一行,
//! 不改这个文件。
//!
//! 闸的判据(两条都要过):**混淆数为 0**,且任何一行都不许靠 0.4 的模糊命中过关——
//! 猜对了也是猜。

use std::path::Path;

#[derive(serde::Deserialize)]
struct Row {
    name: String,
    unit: String,
    expect: Option<String>,
    why: String,
}

fn rows() -> Vec<Row> {
    let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("testdata/confusions.json");
    let raw = std::fs::read_to_string(&p).expect("confusions.json 必须在 testdata/ 下");
    serde_json::from_str(&raw).expect("confusions.json 必须是合法 JSON 数组")
}

#[test]
fn every_known_confusion_pair_resolves_to_the_right_concept() {
    let rows = rows();
    assert!(rows.len() >= 11, "清单被截短了?只剩 {} 行", rows.len());
    let mut bad: Vec<String> = Vec::new();
    for r in &rows {
        let got = terminology::resolve(&r.name, Some(&r.unit));
        match (&r.expect, &got) {
            (Some(want), Some(m)) if &m.key == want => {
                if m.confidence <= 0.4 {
                    bad.push(format!(
                        "{:?}({}) 配到 {} 但只是 0.4 的模糊猜 —— {}",
                        r.name, r.unit, m.key, r.why
                    ));
                }
            }
            (Some(want), Some(m)) => bad.push(format!(
                "{:?}({}) 应为 {want},实得 {}({}) —— {}",
                r.name, r.unit, m.key, m.confidence, r.why
            )),
            (Some(want), None) => {
                bad.push(format!("{:?}({}) 应为 {want},实得 miss —— {}", r.name, r.unit, r.why))
            }
            (None, Some(m)) => bad.push(format!(
                "{:?}({}) 必须 miss,却配到了 {} —— {}",
                r.name, r.unit, m.key, r.why
            )),
            (None, None) => {}
        }
    }
    assert!(bad.is_empty(), "混淆数必须为 0,实得 {}:\n{}", bad.len(), bad.join("\n"));
    eprintln!("confusion gate: {} 行全过", rows.len());
}
```

`packages/terminology/Cargo.toml` 的 `[dependencies]` 已有 `serde`/`serde_json`,集成测试直接用,**不加 dev-dependencies**。

- [ ] **Step 3: 跑闸**

Run: `cargo test -p terminology --test confusions -- --nocapture`
Expected: PASS,并打印 `confusion gate: 11 行全过`。若某行红,说明 Task 1 或既有词典与这份清单的认知不一致——**先查清楚哪边对**,再决定是改清单(清单写错了)还是开新任务修词典。

- [ ] **Step 4: 在 README 里说清这份数据的性质**

在 `packages/terminology/testdata/README.md` 末尾追加:

```markdown
## `confusions.json` —— 不是盲集,是回归闸

盲集量的是**覆盖率**(认不认得),这份量的是**错配**(认成了别的)。每一行都来自一次
真实事故(WORKLIST A32、MedRepBench 评测),所以它从第一天起就是「污染」的,也**本该**
如此:它的用途就是防止已经修好的坑被重新踩回去。`cargo test -p terminology --test confusions`
在 CI 里跑,不需要 `MEDREP_ROOT`。新发现一对就加一行,连 `why` 一起写。
```

- [ ] **Step 5: 全量回归 + Commit**

```bash
cargo test --workspace
git add packages/terminology/testdata/confusions.json packages/terminology/tests/confusions.rs packages/terminology/testdata/README.md
git commit -m "$(cat <<'EOF'
test(terminology): 解析混淆闸 —— 11 对已知易混项钉进 CI(A5)

清单来自 WORKLIST A32 与 MedRepBench 评测,每行带 why。判据:混淆数为 0,
且不许靠 0.4 的模糊命中过关。不依赖 MEDREP_ROOT,CI 直接跑。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
EOF
)"
```

---

### Task 4: 从语料抽「名 + 单位」并分类(A6 第一步)

**Files:**
- Create: `packages/terminology/examples/term_gaps.rs`

**Interfaces:**
- Consumes: `terminology::{resolve, normalize_unit, dictionary_entries}`、`Match.confidence`。
- Produces: 命令 `cargo run -p terminology --example term_gaps -- --out <path>`,写出 JSON:
  ```json
  {"exact": [...], "fuzzy_only": [{"name","unit","key","confidence"}], "miss": [{"name","unit"}]}
  ```
  Task 5 读 `fuzzy_only` + `miss` 两组作为校准输入。

- [ ] **Step 1: 写工具**

`packages/terminology/examples/term_gaps.rs`:

```rust
//! **A6 第一步(离线,不碰网络)**:把评测语料里全部不同的「化验名 + 印刷单位」组合
//! 抽出来,按今天的词典分三类,写成一份 JSON。
//!
//! 只有项目名和单位 —— **没有数值、没有日期、没有任何病人信息**。这一点是 A6 能把
//! 名单送上云端的全部前提,所以分类逻辑写在这里、发送逻辑写在另一个文件里
//! (`packages/ocr/examples/calibrate_terms.rs`),两件事不混在一个函数里。
//!
//! 输入(都可缺,缺哪个跳哪个):
//! - `$MEDREP_ROOT/gt.tsv` —— MedRepBench 真值表(`medrep_make_gt.py` 生成)。
//!   逐行 TSV,字段含 name / unit;表头给出列序。
//! - `packages/terminology/testdata/blind_*.json` —— 仓库自带盲集(`reports[].items[]`)。
//!
//! 跑法:
//! ```text
//! MEDREP_ROOT=<dir> cargo run -p terminology --example term_gaps -- --out /tmp/term_gaps.json
//! ```

use std::collections::BTreeSet;

fn arg(flag: &str) -> Option<String> {
    let mut it = std::env::args();
    while let Some(a) = it.next() {
        if a == flag {
            return it.next();
        }
    }
    None
}

/// `(name, unit)`,都已 trim;unit 可以是空串(报告没印单位)。
fn collect() -> BTreeSet<(String, String)> {
    let mut out: BTreeSet<(String, String)> = BTreeSet::new();

    if let Ok(root) = std::env::var("MEDREP_ROOT") {
        let p = std::path::Path::new(&root).join("gt.tsv");
        match std::fs::read_to_string(&p) {
            Ok(text) => {
                let mut lines = text.lines();
                let header: Vec<&str> = lines.next().unwrap_or_default().split('\t').collect();
                let name_at = header.iter().position(|h| *h == "name");
                let unit_at = header.iter().position(|h| *h == "unit");
                match (name_at, unit_at) {
                    (Some(n), Some(u)) => {
                        for l in lines {
                            let f: Vec<&str> = l.split('\t').collect();
                            let (Some(name), Some(unit)) = (f.get(n), f.get(u)) else {
                                continue;
                            };
                            let name = name.trim();
                            if !name.is_empty() {
                                out.insert((name.to_string(), unit.trim().to_string()));
                            }
                        }
                    }
                    _ => eprintln!("gt.tsv 表头里没有 name/unit 两列,跳过:{}", p.display()),
                }
            }
            Err(e) => eprintln!("读不到 {}:{e}(跳过)", p.display()),
        }
    } else {
        eprintln!("MEDREP_ROOT 未设置 —— 只用仓库自带盲集");
    }

    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("testdata");
    let Ok(rd) = std::fs::read_dir(&dir) else {
        return out;
    };
    for e in rd.flatten() {
        let p = e.path();
        let is_blind = p
            .file_name()
            .and_then(|n| n.to_str())
            .is_some_and(|n| n.starts_with("blind_") && n.ends_with(".json"));
        if !is_blind {
            continue;
        }
        let Ok(raw) = std::fs::read_to_string(&p) else {
            continue;
        };
        let Ok(v) = serde_json::from_str::<serde_json::Value>(&raw) else {
            continue;
        };
        for r in v["reports"].as_array().into_iter().flatten() {
            for it in r["items"].as_array().into_iter().flatten() {
                let name = it["name"].as_str().unwrap_or_default().trim();
                let unit = it["unit"].as_str().unwrap_or_default().trim();
                if !name.is_empty() {
                    out.insert((name.to_string(), unit.to_string()));
                }
            }
        }
    }
    out
}

fn main() {
    let pairs = collect();
    let mut exact = Vec::new();
    let mut fuzzy_only = Vec::new();
    let mut miss = Vec::new();
    for (name, unit) in &pairs {
        let u = (!unit.is_empty()).then_some(unit.as_str());
        match terminology::resolve(name, u) {
            // 0.4 = 模糊推算,0.5 = OCR 混淆表 —— 前者没人核对过,正是校准要看的那批。
            Some(m) if m.confidence <= 0.4 => fuzzy_only.push(serde_json::json!({
                "name": name, "unit": unit, "key": m.key, "confidence": m.confidence
            })),
            Some(_) => exact.push(serde_json::json!({"name": name, "unit": unit})),
            None => miss.push(serde_json::json!({"name": name, "unit": unit})),
        }
    }
    eprintln!(
        "{} 个不同组合:精确 {} / 模糊 {} / 未覆盖 {}",
        pairs.len(),
        exact.len(),
        fuzzy_only.len(),
        miss.len()
    );
    let doc = serde_json::json!({"exact": exact, "fuzzy_only": fuzzy_only, "miss": miss});
    let out = arg("--out").unwrap_or_else(|| "term_gaps.json".to_string());
    match std::fs::write(&out, serde_json::to_string_pretty(&doc).unwrap_or_default()) {
        Ok(()) => eprintln!("写出 {out}"),
        Err(e) => eprintln!("写不出 {out}:{e}"),
    }
}
```

> `examples/` 里允许 `unwrap()`:它不是库代码,崩了就是开发者当场看见的错误信息。库代码那条硬规矩不适用于这里——但 `main` 里仍然走 `match`,因为「写不出文件」是常见的环境问题,不是 bug。

- [ ] **Step 2: 跑它(不设 MEDREP_ROOT 也必须能出结果)**

Run: `cargo run -p terminology --example term_gaps -- --out /tmp/term_gaps.json`
Expected: 打印三类计数(盲集大约几百个组合),写出 `/tmp/term_gaps.json`。

- [ ] **Step 3: 有语料时再跑一次,记下数字**

Run: `MEDREP_ROOT=<medrepbench 目录> cargo run -p terminology --example term_gaps -- --out /tmp/term_gaps.json`
Expected: 组合数显著上升;把三类计数记下来,Task 16 的 log 要用。拿不到语料就照实说「本轮只有盲集」。

- [ ] **Step 4: clippy + Commit**

```bash
cargo clippy -p terminology --all-targets -- -D warnings
cargo test --workspace
git add packages/terminology/examples/term_gaps.rs
git commit -m "$(cat <<'EOF'
feat(terminology): term_gaps 工具 —— 语料里的「名+单位」按词典分三类(A6 第一步)

离线、不碰网络。输出精确/模糊/未覆盖三组,后两组是批量校准的输入。
只取项目名与单位,没有数值与任何病人信息 —— 这是它能上云的前提。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
EOF
)"
```

---

### Task 5: 批量校准请求 —— 提示词 + 代理分支 + 同意闸(A6 第二步)

**Files:**
- Create: `packages/deid/prompts/calibrate_terms_system.txt`
- Modify: `services/api/extract.py`(常量区 + `run()` 的 schema 分支)
- Modify: `services/api/test_api.py`(加两条测试)
- Create: `packages/ocr/examples/calibrate_terms.rs`

**Interfaces:**
- Consumes: Task 4 的 `term_gaps.json`;`terminology::dictionary_entries()`;`deid::{assert_clean, KnownIdentity}`;现成的 `POST /v1/extract`(账号鉴权 + 体积上限 + 月度 token 天花板都已就位)。
- Produces:
  - 代理接受 `{"mode":"text","schema":"terms-calib","payload":"<JSON 字符串>"}`,用 `SYSTEM_PROMPT_CALIB` 作 system,其余与 text 臂完全相同。
  - 命令 `cargo run -p ocr --example calibrate_terms -- --gaps <path> --out <path>`;无 `MEDME_CALIB_CONSENT=1` 直接退出。
  - 产出 `calibration_raw.json`:`{"chunks":[{"request":…,"response":…}]}`,Task 6 读它。

- [ ] **Step 1: 写提示词**

`packages/deid/prompts/calibrate_terms_system.txt`(单行,与另外三份 prompt 同一风格,结尾不留换行):

```
你是医学检验术语对照器。用户消息里给你两样东西:keys(我们的规范键表,每项有 key、中文名、canonical_unit、units)和 terms(报告上印的项目名与印刷单位)。对 terms 里的每一项,只输出一个 JSON 对象:{"mappings":[{"name":"","unit":"","key":"","confidence":"high|low"}]}。name 与 unit 必须是 terms 里的原文逐字。key 只能从 keys 里选;不确定、或这一项不在 keys 里,key 一律写 unknown,不许发明新键、不许猜近似的键。单位对不上那个 key 的 units 就说明不是同一个量,同样写 unknown。不要解释、不要 markdown 围栏、不要输出 terms 以外的项。
```

- [ ] **Step 2: 代理加分支 + 测试**

在 `services/api/extract.py` 读 `extract_v2_system.txt` 之后加:

```python
# A6 批量校准(开发期工具,不是 App 的路径):system 只放规则,**规范键表走 user 消息**
# —— 642 条键表放进 system 就等于每次请求都多寄一份 26 KB 的常量,而这条路一共只跑几次。
with open(os.path.join(_PROMPTS_DIR, "calibrate_terms_system.txt"), encoding="utf-8") as _f:
    SYSTEM_PROMPT_CALIB = _f.read()
```

把 `run()` 里的 schema 分支改成:

```python
    if schema is not True and schema == 1:
        system_prompt = SYSTEM_PROMPT_V1
    elif schema is not True and schema == 2:
        system_prompt = SYSTEM_PROMPT_V2
    elif schema == "terms-calib":
        # 术语校准:只走文本臂。图片臂在这条路上没有意义,显式拒掉而不是默默降级。
        if mode == "image":
            raise SchemaError("schema")
        system_prompt = SYSTEM_PROMPT_CALIB
    else:
        raise SchemaError("schema")
```

在 `services/api/test_api.py` 里,紧挨着既有的 `test_extract_v2_prompt_is_v1_verbatim_plus_facts` 加:

```python
def test_calibration_schema_uses_its_own_prompt_and_refuses_image_mode():
    """术语校准是独立的一条 schema:提示词必须是 calibrate_terms_system.txt 本身
    (不是 v1/v2 的变体),且图片臂显式 400 —— 这条路只该发文字。"""
    assert extract.SYSTEM_PROMPT_CALIB != extract.SYSTEM_PROMPT_V1
    assert extract.SYSTEM_PROMPT_CALIB != extract.SYSTEM_PROMPT_V2
    assert "unknown" in extract.SYSTEM_PROMPT_CALIB
    with pytest.raises(extract.SchemaError):
        extract.run({"mode": "image", "schema": "terms-calib", "payload": "x"})


def test_calibration_prompt_file_is_the_one_the_tool_sends():
    """与 v1/v2 同一条约定:代理和工具读的必须是同一份文件,不许各存一份。"""
    import pathlib
    p = pathlib.Path(extract._PROMPTS_DIR) / "calibrate_terms_system.txt"
    assert p.read_text(encoding="utf-8") == extract.SYSTEM_PROMPT_CALIB
```

- [ ] **Step 3: 跑服务端测试**

Run: `cd services/api && python -m pytest test_api.py -k "calibration or prompt" -q`
Expected: PASS。既有的 v1/v2 提示词测试也必须仍绿——那两份文件一个字节都没动。

- [ ] **Step 4: 写客户端(同意闸 + 脱敏闸 + 分批)**

`packages/ocr/examples/calibrate_terms.rs`:

```rust
//! **A6 第二步:批量校准(开发期工具)。** 把词典的规范键表 + 语料里「今天配不准的
//! 那批项目名与单位」发给模型,拿回一份对照表,**本机核对后交人审**,再进词典。
//!
//! ## 这条路上的三道闸,一道都不能少
//! 1. **同意闸** —— 没有 `MEDME_CALIB_CONSENT=1` 就直接退出。与 App 侧「云端整理」
//!    开关同一性质:这是一次会把数据发出去的动作,必须是有人明确点过头的。
//! 2. **脱敏闸** —— 整个 payload 过 `deid::assert_clean`。这里本来就只有项目名和
//!    单位(Task 4 保证),闸是**结构性**的第二道保险,不是走形式。
//! 3. **只走我们的代理** —— `POST $MEDME_API_BASE/v1/extract`,账号鉴权、体积上限、
//!    月度 token 天花板全部复用线上那一套。**不直连 DeepSeek**(评测臂 `medrep_llm`
//!    直连是评测期的例外,这条不是)。
//!
//! ## 为什么不是「一个请求」
//! spec A6 写的是一次请求。实测不可行:642 条键表 ~26 KB,再加上千条待校准项,既顶破
//! `/v1/extract` 的 64 KiB 文本上限,也顶破文本臂 16384 的 `max_tokens`。所以按
//! `--chunk`(默认 150 条)分批,键表每批都带。本质仍是「一次跑完的批量作业」,
//! 只是分了几个 HTTP 请求;工具最后打印请求数与 token 合计。
//!
//! 跑法:
//! ```text
//! MEDME_CALIB_CONSENT=1 MEDME_API_BASE=https://… MEDME_API_TOKEN=… \
//!   cargo run --release -p ocr --example calibrate_terms -- \
//!   --gaps /tmp/term_gaps.json --out /tmp/calibration_raw.json
//! ```

use anyhow::{bail, Context, Result};
use serde_json::{json, Value};

fn arg(flag: &str) -> Option<String> {
    let mut it = std::env::args();
    while let Some(a) = it.next() {
        if a == flag {
            return it.next();
        }
    }
    None
}

/// 规范键表:key + 中文名 + 规范单位 + 接受的单位。**只发这四样** —— LOINC 对模型
/// 选键没有帮助,却让每批都胖一圈。
fn key_table() -> Vec<Value> {
    terminology::dictionary_entries()
        .iter()
        .filter(|e| e.canonical_unit.is_some())
        .map(|e| {
            json!({
                "key": e.key,
                "name": e.canonical_name,
                "canonical_unit": e.canonical_unit,
                "units": e.units.iter().map(|u| u.unit.clone()).collect::<Vec<_>>(),
            })
        })
        .collect()
}

fn main() -> Result<()> {
    if std::env::var("MEDME_CALIB_CONSENT").as_deref() != Ok("1") {
        bail!("没有同意闸:这条路会把项目名与单位发到云端。确认后再设 MEDME_CALIB_CONSENT=1");
    }
    let base = std::env::var("MEDME_API_BASE").context("MEDME_API_BASE 未设置(必须走我们的代理)")?;
    let token = std::env::var("MEDME_API_TOKEN").context("MEDME_API_TOKEN 未设置")?;
    let gaps_path = arg("--gaps").context("--gaps <term_gaps.json>")?;
    let out_path = arg("--out").unwrap_or_else(|| "calibration_raw.json".to_string());
    let chunk: usize = arg("--chunk").and_then(|s| s.parse().ok()).unwrap_or(150);

    let gaps: Value = serde_json::from_str(&std::fs::read_to_string(&gaps_path)?)?;
    let mut terms: Vec<Value> = Vec::new();
    for group in ["fuzzy_only", "miss"] {
        for t in gaps[group].as_array().into_iter().flatten() {
            terms.push(json!({"name": t["name"], "unit": t["unit"]}));
        }
    }
    if terms.is_empty() {
        bail!("{gaps_path} 里没有需要校准的项 —— 先跑 term_gaps");
    }
    let keys = key_table();
    // 语料里只该有项目名与单位;这道闸防的是「将来有人把别的东西塞进 gaps 文件」。
    let known = deid::KnownIdentity { name: String::new(), id_number: None, phone: None };

    let mut chunks_out: Vec<Value> = Vec::new();
    let (mut tin, mut tout) = (0u64, 0u64);
    for (i, part) in terms.chunks(chunk).enumerate() {
        let payload = serde_json::to_string(&json!({"keys": keys, "terms": part}))?;
        deid::assert_clean(&payload, &known).map_err(|e| anyhow::anyhow!("脱敏闸拒发:{e}"))?;
        if payload.len() > 64 * 1024 {
            bail!("第 {i} 批 {} 字节,超过代理的 64 KiB 上限 —— 调小 --chunk", payload.len());
        }
        let body = json!({"mode": "text", "schema": "terms-calib", "payload": payload});
        let mut resp = ureq::post(&format!("{base}/v1/extract"))
            .header("Authorization", &format!("Bearer {token}"))
            .send_json(&body)
            .with_context(|| format!("第 {i} 批请求失败"))?;
        let v: Value = resp.body_mut().read_json()?;
        tin += v["usage"]["prompt_tokens"].as_u64().unwrap_or(0);
        tout += v["usage"]["completion_tokens"].as_u64().unwrap_or(0);
        eprintln!("第 {i} 批 {} 项 ✓", part.len());
        chunks_out.push(json!({"terms": part, "response": v}));
    }
    std::fs::write(&out_path, serde_json::to_string_pretty(&json!({"chunks": chunks_out}))?)?;
    eprintln!(
        "{} 项 / {} 批,prompt {tin} + completion {tout} token,写出 {out_path}",
        terms.len(),
        chunks_out.len()
    );
    Ok(())
}
```

> `ureq` 的调用形状以仓库里现成的那处为准:照 `packages/ocr/examples/medrep_llm.rs:175` 的 `ureq::post(...)` 写法抄,版本是 3.3。若编译不过,以那个文件为准改这里,**不要**升级 ureq。

- [ ] **Step 5: 干跑一次(不发请求)**

Run: `cargo run --release -p ocr --example calibrate_terms -- --gaps /tmp/term_gaps.json`
Expected: 因为没有 `MEDME_CALIB_CONSENT=1` 而**立刻退出**并打印同意闸那句话。这就是同意闸的验收。

Run: `MEDME_CALIB_CONSENT=1 cargo run --release -p ocr --example calibrate_terms -- --gaps /tmp/term_gaps.json`
Expected: 报 `MEDME_API_BASE 未设置` ——闸的顺序对(同意在前,代理地址在后)。

- [ ] **Step 6: clippy + 全量 + Commit**

```bash
cargo clippy -p ocr --all-targets -- -D warnings
cargo test --workspace
cd services/api && python -m pytest test_api.py -q && cd ../..
git add packages/deid/prompts/calibrate_terms_system.txt services/api/extract.py services/api/test_api.py packages/ocr/examples/calibrate_terms.rs
git commit -m "$(cat <<'EOF'
feat(calibration): 术语批量校准走我们的代理(A6 第二步)

新 schema "terms-calib":system 只放规则,642 条规范键表走 user 消息。客户端三道闸:
同意开关 MEDME_CALIB_CONSENT、deid::assert_clean、只连自家代理。按 64 KiB/max_tokens
分批(spec 写的「一个请求」实测顶破两个上限,理由写在文件头)。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
EOF
)"
```

---

### Task 6: 本机核对校准结果 → 人审清单(A6 第三步)

**Files:**
- Modify: `packages/ocr/examples/calibrate_terms.rs`(加 `--verify` 与 `--selftest` 两条子命令)
- Create: `packages/ocr/examples/calibrate_terms_fixture.json`(自检用的合成响应)

**Interfaces:**
- Consumes: Task 5 的 `calibration_raw.json`;`terminology::{entry_for, resolve, normalize_unit}`。
- Produces:
  - `fn review(raw: &Value) -> (Vec<Value>, Vec<String>)` —— 返回(通过本机核对的映射,拒收原因列表)。
  - 命令 `--verify --raw <path> --out <review.md>`;命令 `--selftest`(离线,拿 fixture 跑,`assert` 失败即非零退出)。

- [ ] **Step 1: 写自检夹具(先写它,它就是本任务的「测试」)**

`packages/ocr/examples/calibrate_terms_fixture.json` —— 六条,覆盖六种结局:

```json
{"chunks": [{"terms": [], "response": {"mappings": [
  {"name": "尿蛋白肌酐比", "unit": "mg/g", "key": "urine_pcr", "confidence": "high"},
  {"name": "尿红细胞", "unit": "个/HP", "key": "urine_rbc_count", "confidence": "high"},
  {"name": "某新指标", "unit": "mg/L", "key": "unknown", "confidence": "low"},
  {"name": "某新指标2", "unit": "mg/L", "key": "no_such_key_at_all", "confidence": "high"},
  {"name": "总补体溶血活性", "unit": "U/mL", "key": "ch50", "confidence": "low"},
  {"name": "肌酐", "unit": "umol/L", "key": "creatinine", "confidence": "high"}
]}}]}
```

六条的预期结局,逐条:`urine_pcr` **accept**(键在、单位在族内、与今天 `resolve` 一致);`urine_rbc_count` + `个/HP` **reject(单位不在族内)**——这正是 Task 8 要拆的那条;`unknown` **skip**;`no_such_key_at_all` **reject(键不存在)**;`ch50` 低置信 **needs-human**;`creatinine` **accept 但无新信息**(与今天的 `resolve` 结果相同,不进人审清单)。

- [ ] **Step 2: 写核对逻辑 + 自检**

在 `calibrate_terms.rs` 里加(并在 `main` 开头按 `--selftest` / `--verify` 分流,**同意闸只管发送那条路**):

```rust
/// 一条映射的本机结论。模型说什么不算数,**词典说了算**(A6:「词典只核对不猜」)。
enum Verdict {
    /// 键存在、单位在族内、且与今天 `resolve` 的结果**不同** —— 这才是校准的收益。
    NewAlias { name: String, unit: String, key: String },
    /// 键存在、单位在族内,但今天就已经配对了 —— 无新信息。
    AlreadyKnown,
    /// 模型自己说不知道。
    Skipped,
    /// 拒收,带逐字原因(键不存在 / 单位不在族内 / 低置信)。
    Rejected(String),
}

fn verdict_of(m: &Value) -> Verdict {
    let name = m["name"].as_str().unwrap_or_default().to_string();
    let unit = m["unit"].as_str().unwrap_or_default().to_string();
    let key = m["key"].as_str().unwrap_or_default().to_string();
    if key.is_empty() || key == "unknown" {
        return Verdict::Skipped;
    }
    let Some(entry) = terminology::entry_for(&key) else {
        return Verdict::Rejected(format!("{name}:键 {key} 不在词典里(模型发明的)"));
    };
    if !unit.is_empty() {
        let u = terminology::normalize_unit(&unit);
        let ok = entry.canonical_unit.as_deref().map(terminology::normalize_unit) == Some(u.clone())
            || entry.units.iter().any(|r| terminology::normalize_unit(&r.unit) == u);
        if !ok {
            return Verdict::Rejected(format!("{name}:单位 {unit} 不在 {key} 的单位族里"));
        }
    }
    if m["confidence"].as_str() == Some("low") {
        return Verdict::Rejected(format!("{name}:模型自称低置信,留给人审"));
    }
    let u = (!unit.is_empty()).then_some(unit.as_str());
    match terminology::resolve(&name, u) {
        Some(cur) if cur.key == key && cur.confidence > 0.4 => Verdict::AlreadyKnown,
        _ => Verdict::NewAlias { name, unit, key },
    }
}

/// 一对多冲突:同一个 `name` 被映到了两个不同的 key —— 人必须看一眼,不许自动进词典。
fn conflicts(new: &[(String, String, String)]) -> Vec<String> {
    use std::collections::BTreeMap;
    let mut by_name: BTreeMap<&str, std::collections::BTreeSet<&str>> = BTreeMap::new();
    for (n, _, k) in new {
        by_name.entry(n.as_str()).or_default().insert(k.as_str());
    }
    by_name
        .into_iter()
        .filter(|(_, ks)| ks.len() > 1)
        .map(|(n, ks)| format!("{n}:同时被映到 {:?} —— 一对多,人审", ks))
        .collect()
}

fn selftest() {
    let raw: Value = serde_json::from_str(include_str!("calibrate_terms_fixture.json"))
        .expect("夹具必须是合法 JSON");
    let ms = raw["chunks"][0]["response"]["mappings"].as_array().expect("夹具形状");
    let vs: Vec<Verdict> = ms.iter().map(verdict_of).collect();
    assert!(matches!(vs[0], Verdict::NewAlias { .. }), "UPCR 该被接受为新别名");
    assert!(
        matches!(&vs[1], Verdict::Rejected(r) if r.contains("单位")),
        "尿红细胞 + 个/HP 必须因单位被拒 —— 这正是要拆条的那一对"
    );
    assert!(matches!(vs[2], Verdict::Skipped), "unknown 该跳过");
    assert!(
        matches!(&vs[3], Verdict::Rejected(r) if r.contains("不在词典里")),
        "发明的键必须拒收"
    );
    assert!(matches!(vs[4], Verdict::Rejected(_)), "低置信必须留给人审");
    assert!(matches!(vs[5], Verdict::AlreadyKnown), "肌酐今天就配得对,无新信息");
    eprintln!("selftest ok: 6/6");
}
```

`--verify` 那条路把每批的 `mappings` 逐条过 `verdict_of`,把 `NewAlias` 收成三元组、跑 `conflicts`,然后写一份 Markdown:三张表(建议新增别名 / 拒收原因 / 一对多冲突),表头写明「**本表不自动进词典**」。

- [ ] **Step 3: 跑自检(这就是本任务的可测交付物)**

Run: `cargo run --release -p ocr --example calibrate_terms -- --selftest`
Expected: 打印 `selftest ok: 6/6`,退出码 0。任何一条 `assert` 红就是核对逻辑错了。

- [ ] **Step 4: 有真数据时跑 verify**

Run: `cargo run --release -p ocr --example calibrate_terms -- --verify --raw /tmp/calibration_raw.json --out /tmp/calibration_review.md`
Expected: 产出人审清单。**人审之后**才把确认的别名/单位写进 `dictionary.json`,并把每一条同时加进 `packages/terminology/testdata/confusions.json`(Task 3 的闸)。这一步是**人的**,不是这个任务的自动产物;计划到此为止。

- [ ] **Step 5: clippy + Commit**

```bash
cargo clippy -p ocr --all-targets -- -D warnings
cargo run --release -p ocr --example calibrate_terms -- --selftest
git add packages/ocr/examples/calibrate_terms.rs packages/ocr/examples/calibrate_terms_fixture.json
git commit -m "$(cat <<'EOF'
feat(calibration): 本机核对模型给的对照表,产出人审清单(A6 第三步)

键必须在词典里、单位必须在族内、低置信一律留给人、一对多冲突单列 —— 模型说什么不算数。
--selftest 拿 6 条合成响应盖住六种结局,离线可跑。人审之后才进词典,工具不自动改。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
EOF
)"
```

---

### Task 7: 单位感知拒绝(A1)

**Files:**
- Modify: `packages/terminology/src/lib.rs`(`Entry` + `resolve` + `fuzzy_lookup` + `mod tests`)
- Modify: `apps/mobile_flutter/rust/src/api/vault_profile.rs:247,267`(补字段)

**Interfaces:**
- Consumes: 已有 `entry_accepts_unit`、`entry_for`、`pick_best`、`term_candidates`、`normalize`。
- Produces:
  - `Entry` 新增 `pub dimension: Option<String>`(`#[serde(default)]`)。
  - `fn reject_on_unit(hits: Vec<Match>, unit: Option<&str>) -> Vec<Match>`(crate 私有)。
  - `resolve` 行为改变:精确命中被单位否掉之后**不再退到模糊**。

- [ ] **Step 1: 写失败的测试**

加到 `packages/terminology/src/lib.rs` 的 `mod tests`:

```rust
    #[test]
    fn a_closed_unit_family_rejects_a_foreign_unit_instead_of_guessing() {
        // A1:声明了 `dimension` 的条目,单位族是**封闭**的 —— 印刷单位落在族外就是
        // 证据说「这不是这一条」,拒绝,不是降分。`urine_acr` 只认 mg/g,报告若印
        // 的是 /HP,那一行绝不可能是白蛋白肌酐比。
        let e = dictionary_entries()
            .iter()
            .find(|e| e.key == "urine_acr")
            .expect("urine_acr 必须在词典里");
        assert_eq!(
            e.dimension.as_deref(),
            Some("ratio_mg_per_g"),
            "比值族必须打 dimension —— 差一个「白」字就是另一个化验"
        );
        assert!(resolve("尿白蛋白肌酐比", Some("/HP")).is_none());
        // 同一个名字,单位对得上时照常命中(拒绝只针对族外单位)。
        assert_eq!(
            resolve("尿白蛋白肌酐比", Some("mg/g")).map(|m| m.key),
            Some("urine_acr".to_string())
        );
    }

    #[test]
    fn an_entry_without_a_dimension_keeps_the_old_lenient_behaviour() {
        // **刻意不一刀切。** 词典里大量条目的 `units[]` 并不完整,而 `normalize_unit`
        // 刻意不折大小写(`mU`≠`MU`,差 6 个数量级)—— 于是 `umol/l`(小写 L,OCR 最
        // 常见的印法之一)对 creatinine 来说就是「族外单位」。对这种条目也拒绝,召回
        // 的代价远大于收益。没声明 dimension = 单位族还没策展完,沿用旧行为。
        assert!(dictionary_entries()
            .iter()
            .find(|e| e.key == "creatinine")
            .is_some_and(|e| e.dimension.is_none()));
        assert_eq!(
            resolve("血清肌酐", Some("umol/l")).map(|m| m.key),
            Some("creatinine".to_string())
        );
    }

    #[test]
    fn a_dimension_tagged_entry_is_never_reached_by_fuzzy() {
        // A3 的另一半:「跨比值族禁止模糊」。声明了 dimension 的条目整条退出模糊匹配——
        // 这一族里差一个字就是另一个化验(UPCR vs UACR),编辑距离在这儿是噪音不是信号。
        assert!(resolve("尿白蛋白肌酐北", Some("mg/g")).is_none());
    }
```

- [ ] **Step 2: 跑测试,确认它红**

Run: `cargo test -p terminology --lib a_closed_unit_family`
Expected: FAIL —— `Entry` 还没有 `dimension` 字段(编译错)。

- [ ] **Step 3: 写最小实现**

`Entry` 里,在 `pub note` **之前**加:

```rust
    /// 量纲族标签(`per_hpf` / `per_ul` / `ratio_mg_per_g` …)。**声明它 = 声明「我的
    /// `units[]` 是封闭的」**,带来两条硬后果:
    /// 1. `resolve(name, unit)` 在印刷单位落在族外时**拒绝**这个候选(不是降分)——
    ///    见 [`reject_on_unit`];
    /// 2. 这条条目整条退出模糊匹配 —— 同族里差一个字就是另一个化验(UPCR vs UACR、
    ///    /HP vs /uL),编辑距离在这一族里是噪音。
    ///
    /// **没声明 = 单位族还没策展完**,沿用旧行为。一刀切开这条会掉召回:词典里很多
    /// 条目的 `units[]` 不完整,而 `normalize_unit` 刻意不折大小写(`mU`≠`MU`),
    /// `umol/l` 这种常见 OCR 印法会被整条判死。哪些条目够格打这个标签,由 A6 的批量
    /// 校准给答案、由 A5 的混淆闸守住。
    #[serde(default)]
    pub dimension: Option<String>,
```

在 `entry_accepts_unit` 之后加:

```rust
/// A1:**给了印刷单位时,单位不在候选词条单位族里就拒绝该候选。** 只对声明了
/// [`Entry::dimension`] 的条目生效,理由见那个字段的文档。
fn reject_on_unit(hits: Vec<Match>, unit: Option<&str>) -> Vec<Match> {
    let Some(u) = unit.map(str::trim).filter(|u| !u.is_empty()) else {
        return hits;
    };
    hits.into_iter()
        .filter(|m| {
            entry_for(&m.key)
                .is_none_or(|e| e.dimension.is_none() || entry_accepts_unit(&e, u))
        })
        .collect()
}
```

`resolve` 改成:

```rust
pub fn resolve(name: &str, unit: Option<&str>) -> Option<Match> {
    let cands = term_candidates(name);
    let hits: Vec<Match> = cands.iter().filter_map(|c| normalize(c)).collect();
    if !hits.is_empty() {
        // **拒绝是终局。** 精确命中被印刷单位否掉之后不再退到模糊 —— 那正是要根治的
        // 那条路:字典说「不是这一条」,模糊却接着猜一条更不像的。
        return pick_best(reject_on_unit(hits, unit), unit);
    }
    cands.iter().take(2).find_map(|c| fuzzy_lookup(c, unit))
}
```

`fuzzy_lookup` 的条目循环里,把跳过 drug 那一行改成:

```rust
        // 药名撞进化验语境只有风险;声明了 dimension 的条目整条退出模糊(见该字段文档)。
        if entry.category == Category::Drug || entry.dimension.is_some() {
            continue;
        }
```

给 `dictionary.json` 的 `urine_acr` 与 `urine_pcr` 各加一行 `"dimension": "ratio_mg_per_g"`(放在 `"panel"` 之后,保持字段顺序一致)。

- [ ] **Step 4: 补上非 workspace 的那两处构造点**

`apps/mobile_flutter/rust/src/api/vault_profile.rs` 的 `alias_only_entry`(:247)与 `analyte_entry`(:267)是 `terminology::Entry { ... }` 结构体字面量,加字段会打断它们。两处都补:

```rust
        // 包定义的分析物**不许自己声明单位族封闭**:那是内置词典策展过的条目才有的
        // 特权(声明了就能拒绝候选),包来自网络,不给它这个能力。
        dimension: None,
```

- [ ] **Step 5: 跑测试**

Run:
```bash
cargo test -p terminology
cargo test --workspace
cargo test --manifest-path apps/mobile_flutter/rust/Cargo.toml
```
Expected: 全 PASS,含 Task 3 的混淆闸。若 `corpus_summary` 动了:本任务只对打了 `dimension` 的两条生效,语料里不该有它们——先查清楚再动。

- [ ] **Step 6: clippy/fmt + Commit**

```bash
cargo clippy -p terminology --all-targets -- -D warnings
cargo fmt --check -p terminology
git add packages/terminology/src/lib.rs packages/terminology/dictionary.json apps/mobile_flutter/rust/src/api/vault_profile.rs
git commit -m "$(cat <<'EOF'
feat(terminology): Entry.dimension —— 封闭单位族按印刷单位拒绝候选(A1)

声明 dimension = 声明 units[] 封闭:族外单位直接拒收(不是降分),且整条退出模糊匹配。
没声明的沿用旧行为——一刀切会因 normalize_unit 不折大小写(umol/l)掉召回,理由写在字段文档里。
先给 urine_acr / urine_pcr 两条比值族打标。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
EOF
)"
```

---

### Task 8: 同名不同量纲拆条(A3)

**Files:**
- Modify: `packages/terminology/dictionary.json`(+2 条,4 条打 `dimension`)
- Modify: `packages/terminology/src/lib.rs`(`Index.aliases` 改列表、`build_index` 两趟、`normalize_all`、两条测试)
- Modify: `packages/terminology/tests/overlay.rs`(夹具改用非内置键)
- Modify: `packages/terminology/testdata/confusions.json`(+5 行)

**Interfaces:**
- Consumes: Task 7 的 `Entry.dimension` 与 `reject_on_unit`。
- Produces:
  - 内置键 `urine_rbc_hpf`(LOINC 13945-1 / OMOP 3035124)、`urine_wbc_hpf`(LOINC 5821-4 / OMOP 3035583),canonical_unit `/[HPF]`。
  - `Index.aliases: HashMap<String, Vec<AliasHit>>`;`fn normalize_all(raw_term: &str) -> Vec<Match>`(crate 私有);`normalize` 语义不变(取列表第一项)。
  - 词条总数 642 → **644**。

> **先核一遍编码(仓库外事实,别凭记忆)。** 本地 OMOP 库可直接查:
> ```bash
> /opt/homebrew/opt/postgresql@15/bin/psql "postgresql://postgres@localhost:5435/mimiciv_omop" \
>   -c "set search_path=omop_cdm; select concept_id, concept_code, concept_name from concept
>       where vocabulary_id='LOINC' and concept_code in ('13945-1','5821-4','30391-7','30405-5');"
> ```
> 2026-09-19 实查结果:13945-1 = Erythrocytes [#/area] in Urine sediment by Microscopy HPF → 3035124;5821-4 = Leukocytes [#/area] … → 3035583;内置那两条按体积的 30391-7 / 30405-5 **保持不动**(spec A3 写的 5808-1 是「尿沉渣镜检**按体积**」的另一个码,与今天内置那条不是同一个概念,不换)。

- [ ] **Step 1: 写失败的测试**

加到 `packages/terminology/src/lib.rs` 的 `mod tests`:

```rust
    #[test]
    fn urine_sediment_counts_split_by_printed_unit() {
        // A32 ③:报告印「尿红细胞 8 个/HP」时,内置那条按**体积**计数的
        // urine_rbc_count(/uL)会精确吃掉这一行,SLEDAI 血尿那 4 分于是永远算不出来,
        // 界面显示「未知」,没有任何报错。根治 = 按印刷单位拆成两条,共用裸别名,
        // **由单位选条**。
        for (unit, want) in [
            ("个/HP", "urine_rbc_hpf"),
            ("/HP", "urine_rbc_hpf"),
            ("/[HPF]", "urine_rbc_hpf"),
            ("/uL", "urine_rbc_count"),
            ("10*6/L", "urine_rbc_count"),
        ] {
            let m = resolve("尿红细胞", Some(unit)).unwrap_or_else(|| panic!("{unit} 该有命中"));
            assert_eq!(m.key, want, "尿红细胞 + {unit}");
            assert_eq!(m.confidence, 1.0, "两条都是精确别名命中");
        }
        // 白细胞侧用「尿白细胞计数」,**不是**裸「尿白细胞」—— 后者在词典里属于试纸
        // 定性项 `urine_leukocyte_esterase`(2026-09-19 实查),不是这一对里的任何一条。
        assert_eq!(
            resolve("尿白细胞计数", Some("个/HP")).map(|m| m.key),
            Some("urine_wbc_hpf".to_string())
        );
        assert_eq!(
            resolve("尿白细胞计数", Some("/uL")).map(|m| m.key),
            Some("urine_wbc_count".to_string())
        );
        // 没印单位时:**与拆条之前逐字相同** —— 取字典里靠前的那条(按体积)。
        assert_eq!(
            resolve("尿红细胞", None).map(|m| m.key),
            Some("urine_rbc_count".to_string())
        );
    }

    #[test]
    fn the_split_pair_shares_aliases_but_never_shares_a_unit() {
        // 共用别名之所以安全,只因为两条的单位族**不相交** —— 一个印刷单位永远只落进
        // 一条。这条不变式一旦破了,`resolve` 就裁决不出来,退化成「靠字典顺序」。
        let f = |k: &str| {
            dictionary_entries()
                .iter()
                .find(|e| e.key == k)
                .map(|e| {
                    e.canonical_unit
                        .iter()
                        .map(|u| normalize_unit(u))
                        .chain(e.units.iter().map(|r| normalize_unit(&r.unit)))
                        .collect::<std::collections::BTreeSet<_>>()
                })
                .expect("键必须在")
        };
        for (a, b) in [
            ("urine_rbc_hpf", "urine_rbc_count"),
            ("urine_wbc_hpf", "urine_wbc_count"),
        ] {
            assert!(f(a).is_disjoint(&f(b)), "{a} 与 {b} 的单位族必须不相交");
        }
    }
```

- [ ] **Step 2: 跑,确认它红**

Run: `cargo test -p terminology --lib urine_sediment`
Expected: FAIL —— `urine_rbc_hpf` 还不是内置键,`resolve("尿红细胞", Some("个/HP"))` 返回 `urine_rbc_count`。

- [ ] **Step 3: 加两条词条**

往 `dictionary.json` 的 `entries` 末尾加(`units` 把四种印法都收了:报告印 `/HP`、`个/HP`、`/HPF` 都见过,UCUM 写法是 `/[HPF]`;`normalize_unit` 不折 CJK 也不折大小写,所以必须逐条列出):

```json
{
  "key": "urine_rbc_hpf",
  "canonical_name": "尿红细胞(高倍视野)",
  "category": "lab",
  "system": "urine",
  "panel": "尿液",
  "dimension": "per_hpf",
  "codes": {"loinc": "13945-1", "omop_concept_id": 3035124},
  "canonical_unit": "/[HPF]",
  "units": [
    {"unit": "/[HPF]", "slope": 1.0, "intercept": 0.0},
    {"unit": "/HPF", "slope": 1.0, "intercept": 0.0},
    {"unit": "/HP", "slope": 1.0, "intercept": 0.0},
    {"unit": "个/HP", "slope": 1.0, "intercept": 0.0},
    {"unit": "个/HPF", "slope": 1.0, "intercept": 0.0},
    {"unit": "/高倍视野", "slope": 1.0, "intercept": 0.0},
    {"unit": "个/高倍视野", "slope": 1.0, "intercept": 0.0}
  ],
  "aliases": ["尿红细胞", "尿红细胞计数", "尿沉渣红细胞", "尿RBC", "U-RBC", "RBC-U", "Urine erythrocytes"],
  "ocr_confusions": [],
  "note": "按**面积**(每高倍视野)计数的尿沉渣红细胞,LOINC 13945-1(Erythrocytes [#/area] in Urine sediment by Microscopy high power field,PROPERTY=Naric;OMOP 标准概念 3035124,2026-09-19 对照本地 OMOP 库核过)。与 urine_rbc_count(30391-7,按体积 /uL)是两个不同的量:/HP 与 /uL 之间的换算取决于离心/浓缩倍数,**没有确定系数**,所以两条各有各的 units[],一行都不跨。别名与 urine_rbc_count **刻意重合**——报告上「尿红细胞」既可能印 /HP 也可能印 /uL,靠印刷单位选条(`dimension` 让 resolve 拒掉族外单位的那一条)。没印单位时按字典顺序回落到按体积那条,与拆条之前的行为逐字相同。SLEDAI-2K 血尿描述符用的是 /HP。"
},
{
  "key": "urine_wbc_hpf",
  "canonical_name": "尿白细胞(高倍视野)",
  "category": "lab",
  "system": "urine",
  "panel": "尿液",
  "dimension": "per_hpf",
  "codes": {"loinc": "5821-4", "omop_concept_id": 3035583},
  "canonical_unit": "/[HPF]",
  "units": [
    {"unit": "/[HPF]", "slope": 1.0, "intercept": 0.0},
    {"unit": "/HPF", "slope": 1.0, "intercept": 0.0},
    {"unit": "/HP", "slope": 1.0, "intercept": 0.0},
    {"unit": "个/HP", "slope": 1.0, "intercept": 0.0},
    {"unit": "个/HPF", "slope": 1.0, "intercept": 0.0},
    {"unit": "/高倍视野", "slope": 1.0, "intercept": 0.0},
    {"unit": "个/高倍视野", "slope": 1.0, "intercept": 0.0}
  ],
  "aliases": ["尿白细胞计数", "尿沉渣白细胞", "尿WBC", "U-WBC", "WBC-U", "Urine leukocytes"],
  "ocr_confusions": [],
  "note": "同 urine_rbc_hpf:按面积计数,LOINC 5821-4(Leukocytes [#/area] in Urine sediment by Microscopy high power field;OMOP 3035583,同日核过),与按体积的 urine_wbc_count(30405-5)不跨换算。别名与 urine_wbc_count **逐条相同**(由印刷单位选条)。裸「尿白细胞」刻意不收:那个别名 2026-09-19 实查归 urine_leukocyte_esterase(试纸定性项,没有 canonical_unit),抢过来会把一个定性项变成计数项;裸「白细胞」/「WBC」/「LEU」同样不收,那是血常规项。"
}
```

同时给 `urine_rbc_count` 与 `urine_wbc_count` 各加 `"dimension": "per_ul"`,并给 `urine_rbc_count` 补上 `"尿红细胞计数"` 之外它**已经有**的别名不动——只加 `dimension` 一行。

- [ ] **Step 4: 别名索引改成列表**

`Index.aliases` 的类型与文档:

```rust
    /// normalized alias -> hits(confidence 1.0)。**是列表不是单值**:同一个裸别名
    /// 可能被两条按印刷单位分家的条目共用(`尿红细胞` 既可能印 /HP 也可能印 /uL),
    /// 由 [`resolve`] 拿单位裁决。没有单位时取**列表第一项** = 字典里靠前的那条,
    /// 与拆条之前的行为逐字相同。见 [`build_index`] 的两趟写法。
    aliases: HashMap<String, Vec<AliasHit>>,
```

`build_index` 里 `aliases` 的填充改成**两趟**(先化验/体征,后药),这样「化验优先」不再依赖 `insert` 覆盖/`or_insert_with` 的先后,而是顺序本身:

```rust
    // 两趟:先把化验/体征的别名按字典顺序压进去,再压药。`normalize`(没有类别信息)
    // 取列表第一项,于是「叶酸」这种跨类同名词仍然优先解析成化验项 —— 与改成列表
    // 之前那套 `insert` / `or_insert_with` 的组合语义逐字等价,但不再靠覆盖顺序表达。
    for pass_drug in [false, true] {
        for (entry_idx, entry) in dict.entries.iter().enumerate() {
            if (entry.category == Category::Drug) != pass_drug {
                continue;
            }
            for alias in &entry.aliases {
                aliases
                    .entry(normalize_term(alias))
                    .or_default()
                    .push(AliasHit { entry_idx, alias: alias.clone() });
            }
        }
    }
```

(原来那个单循环里 `aliases` 的两条分支删掉;`confusions` / `drug_aliases` / `drug_confusions` 三张表**保持单值不动** —— 今天没有、也不打算有重复的混淆项或药名别名。)

加 `normalize_all`,并把 `normalize` 改成它的第一项:

```rust
/// [`normalize`] 的多命中版本:精确别名命中可能不止一条(见 [`Index::aliases`])。
/// 其余几条路径(OCR 混淆表、药名剥壳、覆盖层)天然只有一条,包成单元素列表。
fn normalize_all(raw_term: &str) -> Vec<Match> {
    let norm = normalize_term(raw_term);
    if norm.is_empty() {
        return Vec::new();
    }
    let idx = index();
    if let Some(hits) = idx.aliases.get(&norm) {
        return hits.iter().map(|h| idx.to_match(h, 1.0)).collect();
    }
    if let Some(hit) = idx.confusions.get(&norm) {
        return vec![idx.to_match(hit, 0.5)];
    }
    for cand in drug_stem_candidates(&norm) {
        if let Some(hit) = idx.drug_aliases.get(&cand) {
            return vec![idx.to_match(hit, STRIPPED_CONFIDENCE)];
        }
    }
    overlay_match(&norm, false).into_iter().collect()
}

pub fn normalize(raw_term: &str) -> Option<Match> {
    normalize_all(raw_term).into_iter().next()
}
```

`resolve` 里把 `filter_map(|c| normalize(c))` 换成 `flat_map(|c| normalize_all(c))`(其余不动,`reject_on_unit` 与 `pick_best` 已在 Task 7 就位)。

- [ ] **Step 5: 放宽重复别名闸(只放宽到「按单位分家」这一种)**

把 `no_duplicate_alias_within_category` 里的 `assert_eq!` 换成:

```rust
                if let Some(prev) = seen.get(&k) {
                    // **唯一的例外:按印刷单位分家的两条。** 条件是两边都声明了
                    // `dimension`、且单位族不相交 —— 那样一个印刷单位永远只落进一条,
                    // `resolve` 裁决得出来。其余任何重复仍是错(会静默遮住一条定义)。
                    let unit_set = |key: &str| {
                        dictionary_entries()
                            .iter()
                            .find(|x| x.key == key)
                            .map(|x| {
                                x.canonical_unit
                                    .iter()
                                    .map(|u| normalize_unit(u))
                                    .chain(x.units.iter().map(|r| normalize_unit(&r.unit)))
                                    .collect::<std::collections::BTreeSet<_>>()
                            })
                            .unwrap_or_default()
                    };
                    let prev_e = dictionary_entries().iter().find(|x| &x.key == prev);
                    let split_ok = prev_e.is_some_and(|p| p.dimension.is_some())
                        && e.dimension.is_some()
                        && unit_set(prev).is_disjoint(&unit_set(&e.key));
                    assert!(
                        prev == &e.key || split_ok,
                        "duplicate normalized alias {a:?} in entries {prev} and {} —— \
                         要共用别名,两条都得声明 dimension 且单位族不相交",
                        e.key
                    );
                }
```

并把 `total_entry_count_is_expected` 的 642 改成 644,在注释链末尾续一行:

```rust
        // +2 (2026-09-19:urine_rbc_hpf / urine_wbc_hpf,按面积计数的尿沉渣两项 ——
        // 补之前「尿红细胞 8 个/HP」被按体积的条目吃掉,SLEDAI 血尿项永远算不出,
        // 见 urine_sediment_counts_split_by_printed_unit)= 644。
```

- [ ] **Step 6: 修覆盖层测试的夹具键**

`packages/terminology/tests/overlay.rs` 拿 `urine_rbc_hpf` 当「包定义的新分析物」——它现在是内置键了,`entry_for` 永远返回内置那条,三条断言会红。**把夹具换成一个确实不在内置里的键**,其余逻辑一字不动:

```rust
/// 病种包定义的新分析物。**必须挑一个内置词典里没有的键** —— 内置永远优先,拿一个
/// 内置已有的键当夹具,测的就不再是覆盖层了(`urine_rbc_hpf` 2026-09-19 起已内置)。
fn overlay_analyte() -> Entry {
    serde_json::from_value(serde_json::json!({
        "key": "urine_cast_hpf", "canonical_name": "尿管型(高倍视野)", "category": "lab",
        "system": "urine", "panel": "尿液", "codes": {},
        "canonical_unit": "/[HPF]",
        "units": [{"unit": "/[HPF]", "slope": 1.0, "intercept": 0.0},
                  {"unit": "/HP", "slope": 1.0, "intercept": 0.0}],
        "aliases": ["高倍镜下管型", "尿红细胞"]
    }))
    .expect("夹具条目必须解析")
}
```

文件里 `urine_rbc_hpf()` 的三处调用改成 `overlay_analyte()`,`"高倍镜下红细胞"` 改成 `"高倍镜下管型"`,`"urine_rbc_hpf"` 改成 `"urine_cast_hpf"`。**「包把内置的『尿红细胞』也写进自己别名里、抢不走」那条断言保留**——它现在盖住的是「内置的两条(按体积/按面积)谁都不会被包抢走」,更有价值:把它的单位参数改成 `Some("/uL")` 与 `Some("个/HP")` 各断言一次,期望 `urine_rbc_count` 与 `urine_rbc_hpf`。

- [ ] **Step 7: 混淆闸补 5 行**

往 `packages/terminology/testdata/confusions.json` 里加:

```json
  {"name": "尿红细胞", "unit": "个/HP", "expect": "urine_rbc_hpf",
   "why": "A32 ③:拆条之前被按体积的 urine_rbc_count 吃掉,SLEDAI 血尿 4 分永远算不出"},
  {"name": "尿红细胞", "unit": "/uL", "expect": "urine_rbc_count", "why": "反向:按体积那条不能被抢走"},
  {"name": "尿白细胞计数", "unit": "个/HP", "expect": "urine_wbc_hpf", "why": "同 ③,白细胞侧(裸「尿白细胞」是试纸酯酶项,两条都不该抢)"},
  {"name": "尿白细胞计数", "unit": "/uL", "expect": "urine_wbc_count", "why": "反向"},
  {"name": "尿白细胞", "unit": "/uL", "expect": "urine_leukocyte_esterase",
   "why": "钉住现状:裸「尿白细胞」归试纸定性项。拆条时若手滑把它收进计数条目,这一行当场红"}
```

- [ ] **Step 8: 全量测试**

Run:
```bash
cargo test -p terminology
cargo test -p profile          # 病程档案:内置 urine_rbc_hpf 现在会遮住包里同名的定义
cargo test --workspace
cargo test --manifest-path apps/mobile_flutter/rust/Cargo.toml
```
Expected: 全 PASS。**特别核一条**:SLE 包(`skills/sle/2026.09.1.src.json`)里 `urine_rbc_hpf`/`urine_wbc_hpf` 的定义(LOINC 13945-1 / 5821-4,canonical `/[HPF]`,units 含 `/HP`)与新内置条目必须一致——内置优先意味着包里那份定义从此不再生效,两边打架的话病程档案的阈值判定会悄悄按另一套单位走。`packages/profile/tests/shipped_package.rs:383` 读的是包的**原 JSON**,守不住这件事,所以这一条要人眼核。

- [ ] **Step 9: clippy/fmt + Commit**

```bash
cargo clippy -p terminology --all-targets -- -D warnings
cargo fmt --check -p terminology
git add packages/terminology/ 
git commit -m "$(cat <<'EOF'
feat(terminology): 尿沉渣红/白细胞按印刷单位拆成两条(A3)

新增内置 urine_rbc_hpf(13945-1)/urine_wbc_hpf(5821-4),与按体积的两条**共用裸别名**、
由印刷单位选条;别名索引因此从单值改成列表,build_index 改两趟保住「化验优先」。
重复别名闸只对「两边都声明 dimension 且单位族不相交」放行。词条数 642 → 644。
LOINC/OMOP 对照本地 OMOP 库核过。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
EOF
)"
```

---

### Task 9: 隐私政策同步(数据流变了就必须改)

**Files:**
- Modify: `/Volumes/extraSupply/Projects/Medme-ghpages/privacy.html`(gh-pages worktree,**独立历史,推上去即上线**)

**Interfaces:**
- Consumes: Task 5 落地的事实——「术语校准会把**项目名与印刷单位**发到我们的代理再到境内模型,没有数值、没有身份信息、没有原图;由开发期的显式开关触发,不是 App 的任何用户操作」。
- Produces: 线上政策里一句与代码一致的话。

> **为什么这是硬规矩**:根 `CLAUDE.md` 第 4 条。网站与代码是两棵没有共同祖先的独立历史,`main` 里没有政策副本,改代码时看不见它,评审也评审不到。2026-07-30 那次的代价就是政策里还写着「这个过程不经过我们的服务器」。

- [ ] **Step 1: 先看现状,别凭记忆**

```bash
ls /Volumes/extraSupply/Projects/Medme-ghpages/privacy.html
grep -n "DeepSeek\|云端整理\|脱敏\|离开手机" /Volumes/extraSupply/Projects/Medme-ghpages/privacy.html
git -C /Volumes/extraSupply/Projects/Medme-ghpages status
git -C /Volumes/extraSupply/Projects/Medme-ghpages log --oneline -5
```
Expected: 看清「云端整理」那一节今天怎么说的,以及本地领先线上多少个提交(2026-09-18 的 log 第 14 条记着领先 18 个未推)。

- [ ] **Step 2: 改一句(只加,不重写)**

在描述云端整理的那一节末尾加一句,措辞照实:

```html
<p>此外,为了让本地的检验项目对照表更准,我们在<strong>开发过程中</strong>会把一批
<strong>检验项目名称与报告上印的计量单位</strong>(例如「尿蛋白肌酐比 / mg/g」)成批发给同一个
境内模型做对照。这批内容里<strong>没有任何检验数值、日期、报告原图或身份信息</strong>,
也不由 App 的任何操作触发——它发生在我们这边,不在你的手机上。</p>
```

- [ ] **Step 3: 核一遍这句话与代码一致**

逐条对回 `packages/ocr/examples/calibrate_terms.rs`:发的是 `{keys, terms}`、`terms` 只有 `name`/`unit`(Task 4 的 `term_gaps` 保证)、走 `POST /v1/extract`、有 `MEDME_CALIB_CONSENT` 闸。**任何一条对不上就改句子,不改代码去迁就句子。**

- [ ] **Step 4: 推 + 线上核实**

```bash
git -C /Volumes/extraSupply/Projects/Medme-ghpages add privacy.html
git -C /Volumes/extraSupply/Projects/Medme-ghpages commit -m "$(cat <<'EOF'
privacy: 说明开发期的术语校准会发送项目名与单位(无数值、无身份、无原图)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
EOF
)"
git -C /Volumes/extraSupply/Projects/Medme-ghpages push
sleep 30 && curl -s https://<线上域名>/privacy.html | grep -c "检验项目名称与报告上印的计量单位"
```
Expected: `curl` 数出 1。**数不出来就是没上线**,不要口头宣布完成(memory `verify-the-artifact-not-the-exit-code`)。

> ⚠️ 本地若领先线上多个提交,`push` 会把**那些**也一起推上线。推之前先 `git log origin/gh-pages..HEAD --oneline` 看清要上线的是哪几条,尤其是 2026-09-18 log 第 15 条记的那句「病程档案随加密分享给医生」——那件事还没做,不能跟着上线。拿不准就停下问,别推。

---

## 阶段 C3 —— 用药由事实抽取给出(spec §C.3)

### Task 10: schema 3 提示词(B1 的提示词一半)

**Files:**
- Create: `packages/deid/prompts/extract_v3_system.txt`
- Modify: `services/api/extract.py`(读文件 + schema 3 分支)
- Modify: `services/api/test_api.py`(字节前缀测试)
- Modify: `packages/ocr/examples/medrep_llm.rs`(`--schema 3` 与产出目录名)

**Interfaces:**
- Consumes: `extract_v2_system.txt`(1404 字节,内容 = v1 去掉结尾 `}` + `,"facts":[…]` + 散文)。
- Produces: `SYSTEM_PROMPT_V3`;`extract.run({"schema": 3, …})` 走它;评测臂 `--schema 3` 产出目录 `deepseek-<mode>-s3`。

- [ ] **Step 1: 生成 v3(不要手抄 v2)**

```bash
python3 - <<'PY'
from pathlib import Path
p = Path("packages/deid/prompts")
v2 = (p / "extract_v2_system.txt").read_text(encoding="utf-8")
add = ("另外:meds 的每一项改用这个形状 {\"name\":\"\",\"dose\":\"\",\"freq\":\"\",\"route\":\"\","
       "\"route_code\":\"\",\"form_code\":\"\",\"freq_code\":\"\",\"dose_value\":\"\",\"dose_unit\":\"\","
       "\"start\":\"\",\"stop\":\"\"}。name/dose/freq/route/start/stop 仍是单据原文逐字。"
       "route_code 只能从 po|iv|ivgtt|sc|im|topical|inhaled|sl|ng|other 里选,"
       "form_code 只能从 tablet|capsule|injection|granule|cream|drops|solution|pill|patch|other 里选,"
       "freq_code 只能从 qd|bid|tid|qid|qn|qod|q8h|q12h|qw|prn|other 里选,选不准就留空。"
       "dose_value 是**每次**用量的数字(原文逐字,如 7.5),dose_unit 是它的单位(如 mg);"
       "写着包装规格(如 5mg×60片)而医嘱用法另写(如 用法:7.5mg 每日一次)时,"
       "dose_value/dose_unit 取**用法**里的那个,不是规格。"
       "**不要自己算每日总量**,也不要把规格和用法相乘。")
(p / "extract_v3_system.txt").write_text(v2 + add, encoding="utf-8")
print("v3 bytes:", len(( p / 'extract_v3_system.txt').read_bytes()))
PY
```

- [ ] **Step 2: 写字节前缀测试(先红)**

在 `services/api/test_api.py` 里,紧挨 `test_extract_v2_prompt_is_v1_verbatim_plus_facts` 加:

```python
def test_extract_v3_prompt_is_v2_verbatim_plus_meds():
    """v1→v2→v3 同一条做法:**后一版是前一版的字节前缀**再追加。钉住它,任何人想
    「顺手改一下 v2 的措辞」都会在这里红 —— 那会让两条 schema 的抽取结果不再可比。"""
    assert extract.SYSTEM_PROMPT_V3.startswith(extract.SYSTEM_PROMPT_V2)
    tail = extract.SYSTEM_PROMPT_V3[len(extract.SYSTEM_PROMPT_V2):]
    assert "dose_value" in tail and "route_code" in tail
    assert "不要自己算每日总量" in tail
```

- [ ] **Step 3: 代理加分支**

`extract.py` 读 v2 之后加 `SYSTEM_PROMPT_V3` 的读取(与 v2 同一写法),并在 schema 分支里 v2 之后加:

```python
    elif schema is not True and schema == 3:
        system_prompt = SYSTEM_PROMPT_V3
```

把 `run()` 那段注释里的「老 App 发 1、新 App 发 2,两条都在线」改成「1/2/3 三条都在线:老 App 发 1 或 2,新 App 发 3」。

- [ ] **Step 4: 评测臂跟上**

`packages/ocr/examples/medrep_llm.rs`:`system_prompt(schema)` 加 `3 => include_str!(".../extract_v3_system.txt")`;`arm_dir_name` 的 `match schema` 加 `3 => "-s3"` 分支;`--schema` 的解析从「只能是 1 或 2」放宽到 1/2/3(错误信息同步改)。

- [ ] **Step 5: 跑测试**

```bash
cd services/api && python -m pytest test_api.py -q && cd ../..
cargo test --workspace
cargo clippy -p ocr --all-targets -- -D warnings
```
Expected: PASS,含既有的 v1/v2 逐字测试。

- [ ] **Step 6: Commit**

```bash
git add packages/deid/prompts/extract_v3_system.txt services/api/extract.py services/api/test_api.py packages/ocr/examples/medrep_llm.rs
git commit -m "$(cat <<'EOF'
feat(deid): schema 3 提示词 = v2 字节前缀 + 用药块(B1)

用药多要 route_code/form_code/freq_code(受控词表)与 dose_value/dose_unit(每次用量,
原文逐字),并明说「规格与用法同行时取用法、不要自己算每日总量」。
v3 是 v2 的字节前缀,由 test_extract_v3_prompt_is_v2_verbatim_plus_meds 钉住。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
EOF
)"
```

---

### Task 11: schema 3 结构体与逐字校验(B1 的字段 + B2)

**Files:**
- Modify: `packages/deid/src/verify.rs`(`MedItem` + 三张词表 + `verify` 的 meds 段 + `mod tests`)

**Interfaces:**
- Consumes: 已有 `FieldKind::{Numeric, Unit, Enum, Text, Name}`、`field_ok`、`Mode`。
- Produces:
  - `MedItem` 新增 `pub route_code/form_code/freq_code/dose_value/dose_unit/start/stop: String`(全部 `#[serde(default)]`)。
  - `const ROUTE_CODE_VALUES/FORM_CODE_VALUES/FREQ_CODE_VALUES: &[&str]`(与 v3 提示词里的词表**逐字一致**)。

- [ ] **Step 1: 写失败的测试**

加到 `packages/deid/src/verify.rs` 的 `mod tests`:

```rust
    #[test]
    fn schema3_med_fields_are_verified_field_by_field() {
        // B2:数值与单位逐字子串核对(带数字边界),枚举按允许值表核,核不过置空不猜。
        let src = "醋酸泼尼松片 5mg×60片 用法:7.5mg 每日一次 口服";
        let json = r#"{"meds":[{"name":"醋酸泼尼松片","dose":"7.5mg","freq":"每日一次",
            "route":"口服","route_code":"po","form_code":"tablet","freq_code":"qd",
            "dose_value":"7.5","dose_unit":"mg","start":"","stop":""}]}"#;
        let v = verify(parse_extraction(json).expect("解析"), src, Mode::Text);
        let m = &v.extraction.meds[0];
        assert_eq!(m.dose_value, "7.5");
        assert_eq!(m.dose_unit, "mg");
        assert_eq!(m.route_code, "po");
        assert_eq!(m.freq_code, "qd");
        assert_eq!(m.form_code, "tablet");
    }

    #[test]
    fn an_invented_enum_value_is_blanked_not_kept() {
        // 词表外的值**根本不在单据上**,也不在我们给的词表里 —— 两头都落空,置空。
        let json = r#"{"meds":[{"name":"醋酸泼尼松片","route_code":"intrathecal",
            "freq_code":"q3d","form_code":"suppository-xl","dose_value":"7.5","dose_unit":"mg"}]}"#;
        let v = verify(parse_extraction(json).expect("解析"), "醋酸泼尼松片 7.5mg", Mode::Text);
        let m = &v.extraction.meds[0];
        assert!(m.route_code.is_empty() && m.freq_code.is_empty() && m.form_code.is_empty());
    }

    #[test]
    fn a_dose_value_not_printed_on_the_document_is_blanked() {
        // 反幻觉:模型把规格和用法相乘、或干脆编一个数 —— 原文里查不到就置空。
        let json = r#"{"meds":[{"name":"醋酸泼尼松片","dose_value":"300","dose_unit":"mg"}]}"#;
        let v = verify(parse_extraction(json).expect("解析"),
                       "醋酸泼尼松片 5mg×60片 用法:7.5mg 每日一次", Mode::Text);
        assert!(v.extraction.meds[0].dose_value.is_empty(), "原文里没有 300");
    }
```

- [ ] **Step 2: 跑,确认它红**

Run: `cargo test -p deid schema3_med_fields`
Expected: FAIL(编译错:`MedItem` 没有这些字段)。

- [ ] **Step 3: 实现**

`MedItem` 加字段(全部 `#[serde(default)]`,与既有字段同一风格),并在结构体上写一句:

```rust
/// schema 3 起多出**编码化**的用法字段。原文逐字的 `dose`/`freq`/`route` 一并保留 ——
/// 那是证据(必须能在单据上找到),编码是给机器看的(必须在我们给的词表里)。
/// 每日剂量**不在这里**:它由本机 `dose_value × freq_code` 算(`profile::rules`),
/// 不让模型算,也不存模型算的数。
```

在 `ORGAN_VALUES` 等词表旁边加三张:

```rust
/// 给药途径代码。与 `extract_v3_system.txt` 里那一行**逐字一致** —— 两边分家,
/// 模型选的值就会被这边整批判空,而且没人会发现(字段只是变空,不报错)。
const ROUTE_CODE_VALUES: &[&str] =
    &["po", "iv", "ivgtt", "sc", "im", "topical", "inhaled", "sl", "ng", "other"];
const FORM_CODE_VALUES: &[&str] = &[
    "tablet", "capsule", "injection", "granule", "cream", "drops", "solution", "pill",
    "patch", "other",
];
const FREQ_CODE_VALUES: &[&str] =
    &["qd", "bid", "tid", "qid", "qn", "qod", "q8h", "q12h", "qw", "prn", "other"];
```

`verify` 的 meds 段改成:

```rust
        let ok = field_ok(&m.name, &src, mode, FieldKind::Name)
            && field_ok(&m.dose, &src, mode, FieldKind::Text)
            && field_ok(&m.freq, &src, mode, FieldKind::Text)
            && field_ok(&m.route, &src, mode, FieldKind::Text);
        // schema 3 的编码化字段**逐个独立判**:一个字段核不过只清那一个,不连坐整条。
        // 途径读错不该把剂量也抹掉 —— 两者的错法和后果都不一样。
        for (val, kind) in [
            (&mut m.route_code, FieldKind::Enum(ROUTE_CODE_VALUES)),
            (&mut m.form_code, FieldKind::Enum(FORM_CODE_VALUES)),
            (&mut m.freq_code, FieldKind::Enum(FREQ_CODE_VALUES)),
            (&mut m.dose_value, FieldKind::Numeric),
            (&mut m.dose_unit, FieldKind::Unit),
            (&mut m.start, FieldKind::Text),
            (&mut m.stop, FieldKind::Text),
        ] {
            if !field_ok(val, &src, mode, kind) {
                val.clear();
            }
        }
```

> 位置是 `packages/deid/src/verify.rs:754` 的 `e.meds.retain_mut(|m| { … })` —— 闭包里的 `m`
> **本来就是 `&mut`**,这段 `for` 直接插在 `let ok = …` 之后、`keep(ok, &mut m.unverified)`
> 之前(与紧邻那个 labs 闭包里 `l.flag.clear()` 同一手法)。`ok` 的算法一字不改:
> `ok == false` 时整条仍按既有规则处置(文本档丢、图片档标 `unverified`)。

- [ ] **Step 4: 跑测试**

Run: `cargo test -p deid`
Expected: PASS。既有的 schema 1/2 测试必须一字不动地绿——新字段在老 JSON 里缺失即空串,`field_ok` 对空串恒过。

- [ ] **Step 5: 全量 + Commit**

```bash
cargo test --workspace
cargo clippy -p deid --all-targets -- -D warnings
git add packages/deid/src/verify.rs
git commit -m "$(cat <<'EOF'
feat(deid): MedItem 补编码化用法字段并逐字段校验(B1/B2)

route_code/form_code/freq_code 按受控词表核,dose_value 按数值边界核、dose_unit 按单位核,
核不过只清那一个字段不连坐。原文 dose/freq/route 保留为证据。
词表与 extract_v3_system.txt 逐字一致 —— 分家会让字段整批变空且无人察觉。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
EOF
)"
```

---

### Task 12: 客户端切到 schema 3(B1 收口)

**Files:**
- Modify: `apps/mobile_flutter/lib/cloud_extract.dart:142`
- Modify: `apps/mobile_flutter/test/cloud_extract_test.dart`(跟着断言)

**Interfaces:**
- Consumes: Task 10 的代理分支、Task 11 的结构体。
- Produces: `const int extractSchema = 3;` —— 发出去的号与落盘 `NewExtraction.schema` 仍是**同一个常量**(两处都读它,不要各写一个字面量)。

- [ ] **Step 1: 看清今天怎么测的**

Run: `grep -n "extractSchema\|'schema'" apps/mobile_flutter/test/cloud_extract_test.dart`
Expected: 找到断言 schema 号的那几行。

- [ ] **Step 2: 改常量 + 注释**

```dart
/// 这个数有两个去处,必须是**同一个**:发给 `/v1/extract` 的 body,以及落盘时
/// `NewExtraction.schema`([runCloudExtraction] 里那次 commit)。两边不一致 = 库里
/// 的结果在说谎。schema 1/2 的老结果照常读得懂(`deid::parse_extraction` 对缺失的
/// 键给默认值),schema 3 多的是用药的编码化字段。
const int extractSchema = 3;
```

- [ ] **Step 3: 跟上测试**

把测试里断言 `2` 的地方改成 `extractSchema`(直接引常量,别再写字面量——这类测试写死数字就会在下次升 schema 时重演一遍今天的修改)。

- [ ] **Step 4: 验**

```bash
cd apps/mobile_flutter && flutter analyze && dart test test/cloud_extract_test.dart
```
Expected: PASS。**不要跑 release / 全 ABI 构建**(`apps/mobile_flutter/CLAUDE.md`)。

- [ ] **Step 5: Commit**

```bash
git add apps/mobile_flutter/lib/cloud_extract.dart apps/mobile_flutter/test/cloud_extract_test.dart
git commit -m "$(cat <<'EOF'
feat(mobile): 云端整理切到 schema 3

发送与落盘仍共用同一个常量;测试改为引用常量而不是写死数字。
发版顺序仍按 ADR 0010:先把新版本铺到该账号所有设备,再开云端整理。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
EOF
)"
```

---

### Task 13: 聚合优先级与 `latest_form`/`latest_route`(B3)

**Files:**
- Modify: `packages/parser/src/meds.rs`(`MedObservation` + `strip_trailing_route` + 两张映射表)
- Modify: `packages/parser/src/extraction.rs`(加 `meds_from_json`)
- Modify: `packages/parser/src/lib.rs`(re-export)
- Modify: `packages/parser/src/aggregate.rs`(`MedSpan`、`MedBuilder`、med 分支)
- Modify: `packages/profile/src/rules.rs`(`form_haystack`、`GC_INJECTION`)
- Modify: `packages/profile/tests/drug_status.rs`(那条钉住错误行为的绊线)

**Interfaces:**
- Consumes: Task 11 的 `deid::MedItem` 新字段。
- Produces:
  - `MedObservation` 新增 `pub route: Option<String>`、`pub form: Option<String>`(值是**代码**,与 schema 3 同一张表)。
  - `parser::meds_from_json(json: &str) -> Result<MedsFromJson, deid::DeidError>`,`pub struct MedsFromJson { pub meds: Vec<MedObservation>, pub dropped: usize }`。
  - `MedSpan`:**删除** `latest_raw_name`,新增 `pub latest_form: Option<String>`、`pub latest_route: Option<String>`。
  - `profile::rules::form_haystack` 改读这两个。

- [ ] **Step 1: 写失败的测试(三处各一条)**

`packages/parser/src/meds.rs` 的 `mod tests`:

```rust
    #[test]
    fn a_route_written_after_the_dose_is_carried_out_not_swallowed() {
        // A32 ⑤:「甲泼尼龙片 40mg 每日一次 静滴」—— 途径此前被 strip_trailing_route
        // 剥掉就丢了,病程档案的剂型门看不到,一次静脉冲击会被按口服等效量换算。
        let o = &extract_meds("甲泼尼龙片 40mg 每日一次 静滴")[0];
        assert_eq!(o.route.as_deref(), Some("ivgtt"), "途径必须带出来");
        assert_eq!(o.form.as_deref(), Some("tablet"), "剂型从药名尾部读");
        assert_eq!(o.raw_name, "甲泼尼龙片", "名字里不留途径");
    }
```

`packages/parser/src/aggregate.rs` 的 `mod tests`:

```rust
    #[test]
    fn extraction_meds_win_over_regex_when_present() {
        // 有 schema 3 抽取结果就用事实;正则是没开云端整理时的兜底。
        let j = r#"{"meds":[{"name":"醋酸泼尼松片","dose":"7.5mg","freq":"每日一次",
            "route":"口服","route_code":"po","form_code":"tablet","freq_code":"qd",
            "dose_value":"7.5","dose_unit":"mg"}]}"#;
        let docs = [SourceDoc {
            index: 0,
            date: None,
            text: "醋酸泼尼松片 5mg×60片",   // 正则在这行上读不出用量(B4)
            doc_type: Some("prescription".into()),
            title: None,
            extraction_json: Some(j),
        }];
        let c = aggregate(&docs);
        let m = c.meds.iter().find(|m| m.name.contains("泼尼松")).expect("该有一条");
        assert_eq!(m.latest_dose.as_deref(), Some("7.5mg qd"));
        assert_eq!(m.latest_route.as_deref(), Some("po"));
        assert_eq!(m.latest_form.as_deref(), Some("tablet"));
    }
```

`packages/profile/tests/drug_status.rs`:把 `a_route_written_after_the_dose_is_still_invisible_to_this_layer` **整条改写**成它一直在等的那个样子(这条测试的文档注释写着「修好那天它会红 —— 那正是它的作用」):

```rust
#[test]
fn a_route_written_after_the_dose_now_blocks_the_oral_conversion() {
    // 曾经的绊线:「静滴」写在剂量后面被 parser 剥掉就丢了,这一层看不见,于是把一次
    // 静脉冲击按口服等效换算成 50 mg/天。parser 现在把途径带到了 MedSpan.latest_route,
    // 剂型门读得到它 —— 绊线兑现,改成断言正确行为。
    let b = status(&[(TODAY, rx_doc("甲泼尼龙片 40mg 每日一次 静滴"))], vec![enable()]);
    assert!(b["gc"]["daily_pred_equiv_mg"].is_null(), "静滴不按口服换算");
    assert_eq!(b["gc"]["unconvertible"][0]["reason"], "注射剂型,不按口服换算");
}
```

- [ ] **Step 2: 跑,确认三条都红**

Run: `cargo test -p parser --lib meds::tests::a_route_written`、`cargo test -p parser --lib aggregate::tests::extraction_meds_win`、`cargo test -p profile a_route_written`
Expected: 三条都 FAIL。

- [ ] **Step 3: parser 侧实现**

`meds.rs`:

```rust
/// 途径原文 → 稳定代码。**与 `deid::verify` 的 `ROUTE_CODE_VALUES` 同一张表**:
/// 正则路径和云抽取路径产出的必须是同一套词,下游才只有一处需要读懂。
fn route_code_of(word: &str) -> &'static str {
    match word.to_ascii_lowercase().as_str() {
        "口服" | "po" => "po",
        "静滴" | "静脉滴注" => "ivgtt",
        "静脉注射" | "静推" | "iv" => "iv",
        "皮下" | "sc" => "sc",
        "肌注" | "im" => "im",
        "外用" => "topical",
        "含服" | "舌下" => "sl",
        "鼻饲" => "ng",
        _ => "other",
    }
}

/// 药名里的剂型词 → 代码。「注射用甲泼尼龙」这种**前缀**写法也认(它已经是今天
/// 能拦住静脉冲击的唯一线索,不能丢)。顺序要紧:「注射液」必须排在「片」前面。
fn form_code_of(name: &str) -> Option<&'static str> {
    for (w, code) in [
        ("注射液", "injection"),
        ("注射用", "injection"),
        ("粉针", "injection"),
        ("胶囊", "capsule"),
        ("颗粒", "granule"),
        ("乳膏", "cream"),
        ("软膏", "cream"),
        ("滴眼液", "drops"),
        ("口服液", "solution"),
        ("片", "tablet"),
        ("丸", "pill"),
    ] {
        if name.contains(w) {
            return Some(code);
        }
    }
    None
}
```

`strip_trailing_route` 改成同时返回剥掉的那个词:`fn strip_trailing_route(name: &str) -> (&str, Option<&'static str>)`(循环里记下**最后一次**剥掉的 `ROUTE_WORDS` 项);`extract_meds` 接住它,`MedObservation` 多填 `route: route_word.map(route_code_of).map(str::to_string)` 与 `form: form_code_of(name).map(str::to_string)`。

`extraction.rs` 加:

```rust
/// `labs_from_json` 的用药版(schema 3)。与它同一条约定:`Err` = 解析不了,调用方
/// 退回正则;`Ok` 之后不再回退。**编码化字段已由 `deid::verify` 核过**,核不过的
/// 在那边就清成了空串 —— 这里只做「空串 → None」,不重判、也不补猜。
pub struct MedsFromJson {
    pub meds: Vec<crate::MedObservation>,
    /// 名字为空、或既没有剂量也没有频次的条目数(与正则路径的 med-line 闸同一判据)。
    pub dropped: usize,
}

pub fn meds_from_json(json: &str) -> Result<MedsFromJson, deid::DeidError> {
    let e = deid::parse_extraction(json)?;
    let mut dropped = 0usize;
    let meds = e
        .meds
        .iter()
        .filter_map(|m| {
            let name = m.name.trim();
            let dose_num = m.dose_value.trim().parse::<f64>().ok().filter(|v| v.is_finite());
            let freq = (!m.freq_code.is_empty() && m.freq_code != "other")
                .then(|| m.freq_code.clone());
            if name.is_empty() || (dose_num.is_none() && freq.is_none()) {
                dropped += 1;
                return None;
            }
            let hit = terminology::resolve_drug(name);
            Some(crate::MedObservation {
                raw_name: name.to_string(),
                drug_key: hit.as_ref().map(|h| h.key.clone()),
                canonical_name: hit.as_ref().map(|h| h.canonical_name.clone()),
                ingredient: hit.as_ref().and_then(|h| h.ingredient.clone()),
                rxnorm: hit.as_ref().and_then(|h| h.codes.rxnorm.clone()),
                atc: hit.as_ref().and_then(|h| h.codes.atc.clone()),
                dose_num,
                dose_unit: (!m.dose_unit.is_empty()).then(|| m.dose_unit.clone()),
                frequency: freq,
                frequency_raw: (!m.freq.is_empty()).then(|| m.freq.clone()),
                route: (!m.route_code.is_empty()).then(|| m.route_code.clone()),
                form: (!m.form_code.is_empty()).then(|| m.form_code.clone()),
                confidence: hit.as_ref().map_or(0.0, |h| h.confidence),
            })
        })
        .collect();
    Ok(MedsFromJson { meds, dropped })
}
```

`lib.rs` 的 re-export 加 `meds_from_json, MedsFromJson`。

`aggregate.rs`:`MedSpan` 删 `latest_raw_name`、加两个新字段(文档写清「与 `latest_dose` 同一条 mention」);`MedBuilder` 的 `best_raw_name` 改成 `best_form`/`best_route`;med 分支最前面插一条(照 labs 分支的写法):

```rust
        let doc_meds = if is_manual_entry {
            Vec::new()
        } else if let Some(parsed) = doc
            .extraction_json
            .and_then(|j| crate::extraction::meds_from_json(j).ok())
            .filter(|p| !p.meds.is_empty())
        {
            // 有 schema 3 抽取结果、能解析、且真读出了药才用它(与 labs 同一条判据:
            // 零条退回正则,否则云端漏读一份处方会把「正则本来读得出」变成整份空白)。
            parsed.meds
        } else if wants_meds(dt) {
```

- [ ] **Step 4: profile 侧实现**

```rust
/// 非口服途径 / 注射剂型的判据。**两套并存**:`latest_form`/`latest_route` 给的是
/// 稳定代码(正则路径与 schema 3 都产这套),`m.name` 里可能还留着原文剂型词
/// (「注射用甲泼尼龙」词典归一后仍带着)。
const GC_INJECTION: [&str; 10] =
    ["注射", "针", "静滴", "静脉", "肌注", "iv", "im", "injection", "ivgtt", "sc"];

/// 剂型/途径关键词要找的那片干草:**规范名 + 最近一条医嘱的剂型代码与途径代码**,小写。
///
/// ⚠️ 读的必须是「**贡献了 `latest_dose` 的那一条 mention**」的剂型/途径,不是整条
/// span 的历史并集(`raw_names`)。用并集会让历史上任何一次冲击**永久**挡住今天的
/// 口服剂量 —— 而「冲击 → 口服维持」正是 SLE 最常见的激素用法(ADR 0011 的 C1 类教训)。
fn form_haystack(m: &parser::MedSpan) -> String {
    format!(
        "{} {} {}",
        m.name,
        m.latest_form.as_deref().unwrap_or_default(),
        m.latest_route.as_deref().unwrap_or_default()
    )
    .to_lowercase()
}
```

- [ ] **Step 5: 跑全套**

```bash
cargo test -p parser
cargo test -p profile
cargo test --workspace
cargo test --manifest-path apps/mobile_flutter/rust/Cargo.toml
```
Expected: 全 PASS。`packages/profile/testdata/golden_profile_view.json` 里的 `latest_dose` 三条若变了,**先查为什么**再决定要不要重定基线,并把 before/after 写进提交信息。`grep -rn "latest_raw_name" packages apps` 必须零命中。

- [ ] **Step 6: Commit**

```bash
cargo clippy -p parser -p profile --all-targets -- -D warnings
git add packages/parser packages/profile
git commit -m "$(cat <<'EOF'
feat(parser): 用药以 schema 3 事实为准、正则兜底;途径/剂型显式带到 MedSpan(B3)

MedSpan.latest_raw_name 退休,换成 latest_form/latest_route(与 latest_dose 同一条 mention)。
正则路径不再吞掉写在剂量后面的途径 —— profile 的剂型门因此看得见静脉冲击,
drug_status 里那条钉住错误行为的绊线如约变红,已改成断言正确行为。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
EOF
)"
```

---

### Task 14: 用法金标语料 + CI 闸(B5)

**Files:**
- Create: `packages/parser/tests/fixtures/meds_gold/*.txt`(6–10 份)
- Create: `packages/parser/tests/fixtures/meds_gold/expected.json`
- Create: `packages/parser/tests/meds_gold.rs`

**Interfaces:**
- Consumes: `parser::extract_meds`、`parser::aggregate`;`profile::rules` 的日剂量算法(`dose × per_day`)。
- Produces: `expected.json` 形状 —— `{"<文件名>": [{"drug","dose_num","dose_unit","frequency","route","form","daily_mg"}]}`,`daily_mg` 可为 `null`(读不出就是读不出)。

> **先找现成的,别造**(`CLAUDE.md` 硬规矩 2)。处方原文从这三处取,逐字复制,**不要编**:
> `examples/demo-dataset/`(张建国全套)、`packages/parser/tests/fixtures/corpus/` 里 4 份处方、
> `packages/profile/testdata/corpus/` 里 2 份处方。真实的「规格+用法」两列写法按 ADR 0011 的
> 记载补齐(那条 A32 ⑥ 的原句就是语料里被改写掉的那种)。非泼尼松激素(甲泼尼龙 / 地塞米松)
> 与多文档激素史各补至少一份 —— 2026-09-18 log 第 10 条点名了这两个缺口。

- [ ] **Step 1: 建语料**

```bash
mkdir -p packages/parser/tests/fixtures/meds_gold
```
逐份写 `.txt`,每份一张处方笺的原文。至少覆盖:①「规格 + 用法」同行;②途径写在剂量之后;③甲泼尼龙;④地塞米松;⑤同一个药跨两份文档改过剂量;⑥只有规格、没有用法(期望 `daily_mg: null`)。

- [ ] **Step 2: 写金标(人逐字核过原文再填)**

`expected.json` 的每个值都必须能在同名 `.txt` 里逐字找到;`daily_mg` 由人按 `每次量 × 每天次数` 手算,**不要**跑代码生成金标——那样测的只是「代码等于代码」。

- [ ] **Step 3: 写闸**

`packages/parser/tests/meds_gold.rs`:

```rust
//! **用法金标(spec B5)。** 真实处方笺上的「每次用量 / 每天几次 / 途径 / 剂型」,
//! 逐份人工核过。闸的判据是**每日剂量 0 错**:算出来的与金标不等,或金标说算不出
//! 而代码算出了一个数(反向也一样),都算错。
//!
//! 为什么不复用 `tests/fixtures/corpus/`:那套语料按 ADR 0011 的记载**被改写过**,
//! 刻意绕开了「规格+用法」两列的写法,以免把错数钉进 golden。真实处方笺仍会撞上,
//! 所以这里单开一套,专门收那些形状。改这里不影响 corpus_summary 的数字。

use std::collections::BTreeMap;
use std::path::Path;

#[derive(serde::Deserialize)]
struct Gold {
    drug: String,
    dose_num: Option<f64>,
    dose_unit: Option<String>,
    frequency: Option<String>,
    route: Option<String>,
    form: Option<String>,
    daily_mg: Option<f64>,
}

/// 每日 mg = 每次 mg × 每天次数。**与 `profile::rules::gc_daily_mg` 同一套算法**,
/// 在这里重写一遍是刻意的:金标闸不该依赖被测那一侧的实现,否则两边一起错就一起绿。
fn daily_mg(dose_num: Option<f64>, unit: Option<&str>, freq: Option<&str>) -> Option<f64> {
    let mg = match (dose_num?, unit?) {
        (v, "mg") => v,
        (v, "g") => v * 1000.0,
        _ => return None,
    };
    let times = match freq? {
        "qd" | "qn" => 1.0,
        "bid" | "q12h" => 2.0,
        "tid" | "q8h" | "tid ac" => 3.0,
        "qid" => 4.0,
        _ => return None,
    };
    Some(mg * times)
}

#[test]
fn every_prescription_line_yields_the_hand_checked_daily_dose() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/meds_gold");
    let gold: BTreeMap<String, Vec<Gold>> = serde_json::from_str(
        &std::fs::read_to_string(dir.join("expected.json")).expect("expected.json 必须在"),
    )
    .expect("expected.json 必须是合法 JSON");
    assert!(gold.len() >= 6, "金标至少 6 份,实得 {}", gold.len());

    let mut errs: Vec<String> = Vec::new();
    for (name, want) in &gold {
        let text = std::fs::read_to_string(dir.join(format!("{name}.txt")))
            .unwrap_or_else(|e| panic!("{name}.txt 读不到:{e}"));
        let got = parser::extract_meds(&text);
        for w in want {
            let Some(o) = got.iter().find(|o| o.raw_name.contains(&w.drug)) else {
                errs.push(format!("{name}:{} 一条都没抽到", w.drug));
                continue;
            };
            if o.dose_num != w.dose_num || o.dose_unit.as_deref() != w.dose_unit.as_deref() {
                errs.push(format!(
                    "{name}/{}:剂量 {:?}{:?},金标 {:?}{:?}",
                    w.drug, o.dose_num, o.dose_unit, w.dose_num, w.dose_unit
                ));
            }
            if o.frequency.as_deref() != w.frequency.as_deref() {
                errs.push(format!("{name}/{}:频次 {:?},金标 {:?}", w.drug, o.frequency, w.frequency));
            }
            if o.route.as_deref() != w.route.as_deref() {
                errs.push(format!("{name}/{}:途径 {:?},金标 {:?}", w.drug, o.route, w.route));
            }
            if o.form.as_deref() != w.form.as_deref() {
                errs.push(format!("{name}/{}:剂型 {:?},金标 {:?}", w.drug, o.form, w.form));
            }
            let d = daily_mg(o.dose_num, o.dose_unit.as_deref(), o.frequency.as_deref());
            if d != w.daily_mg {
                errs.push(format!("{name}/{}:每日 {:?} mg,金标 {:?}", w.drug, d, w.daily_mg));
            }
        }
    }
    assert!(errs.is_empty(), "每日剂量必须 0 错,实得 {} 条:\n{}", errs.len(), errs.join("\n"));
}
```

- [ ] **Step 4: 跑闸**

Run: `cargo test -p parser --test meds_gold -- --nocapture`
Expected: PASS。红了先看是金标写错还是代码错——**金标是人核的原文,优先怀疑代码**。

- [ ] **Step 5: 全量 + Commit**

```bash
cargo test --workspace
git add packages/parser/tests/fixtures/meds_gold packages/parser/tests/meds_gold.rs
git commit -m "$(cat <<'EOF'
test(parser): 用法金标语料 —— 每日剂量 0 错闸(B5)

6+ 份真实处方笺形状:规格+用法同行、途径写在剂量后、甲泼尼龙/地塞米松、多文档剂量变更、
只有规格无用法(期望算不出)。每日 mg 的算法在测试里独立重写,不复用被测实现。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
EOF
)"
```

---

## 阶段 C4 —— 跨院参考区间(spec §C.4)

### Task 15: 参考区间随点走(A4)

**Files:**
- Modify: `packages/parser/src/aggregate.rs`(`PendingPoint`、`LabPoint`、`finalize_lab_series`、两处构造)
- Modify: `packages/profile/src/rules.rs`(序列 JSON 的 `points[]`)
- Modify: `packages/profile/testdata/golden_profile_view.json`(跟着多出字段)

**Interfaces:**
- Consumes: `LabObservation` 已有的 `ref_low`/`ref_high`/`ref_low_canonical`/`ref_high_canonical`(每条观测自带,来源是那一行印的区间)。
- Produces: `LabPoint` 新增 `pub ref_low: Option<f64>`、`pub ref_high: Option<f64>`(**与该点的 `unit` 同基准**)。`AnalyteSeries` 的序列级 `ref_low`/`ref_high` **保留不动**(渲染层画参考带用),只改文档说清它是什么。

> **先说清这条修的到底是什么。** 「偏高/偏低」今天**已经**是按点自己的区间判的:`labs.rs`
> 与 `extraction.rs` 都是拿那一行的值比那一行印的区间算出 `flag`,`profile::rules` 的
> `flag_low`/`flag_high` 读的就是 `p.flag`。真正缺的是:**区间本身没跟着点传下去**,于是
> 证据链上只有「最新那张单子的区间」,跨院对照时显示的那对数字不属于这个点。本任务补的是
> 这一段;不动 `flag` 的算法,也不动渲染层画带子的取数(那是 UI 任务)。

- [ ] **Step 1: 写失败的测试**

加到 `packages/parser/src/aggregate.rs` 的 `mod tests`:

```rust
    #[test]
    fn each_point_keeps_the_reference_range_printed_on_its_own_report() {
        // A4:两家医院的肌酐参考区间不同。序列级只能留一套(画带子用),但**每个点**
        // 必须带着它自己那张单子上印的那一对 —— 否则跨院对照时显示的区间不属于这个点。
        let docs = [
            SourceDoc {
                index: 0,
                date: chrono::NaiveDate::from_ymd_opt(2025, 1, 1),
                text: "肌酐 Cr 90 umol/L 57 - 97",
                doc_type: Some("lab".into()),
                title: None,
                extraction_json: None,
            },
            SourceDoc {
                index: 1,
                date: chrono::NaiveDate::from_ymd_opt(2026, 1, 1),
                text: "肌酐 Cr 90 umol/L 44 - 133",
                doc_type: Some("lab".into()),
                title: None,
                extraction_json: None,
            },
        ];
        let c = aggregate(&docs);
        let s = c.labs.iter().find(|s| s.analyte_key.as_deref() == Some("creatinine")).expect("该有");
        assert_eq!((s.points[0].ref_low, s.points[0].ref_high), (Some(57.0), Some(97.0)));
        assert_eq!((s.points[1].ref_low, s.points[1].ref_high), (Some(44.0), Some(133.0)));
        // 序列级仍是「最新那张单子的」—— 不变,只是它的含义现在写清楚了。
        assert_eq!((s.ref_low, s.ref_high), (Some(44.0), Some(133.0)));
    }
```

- [ ] **Step 2: 跑,确认它红**

Run: `cargo test -p parser --lib each_point_keeps`
Expected: FAIL(编译错:`LabPoint` 没有 `ref_low`)。

- [ ] **Step 3: 实现**

`PendingPoint` 加 `ref_low/ref_high/ref_low_canonical/ref_high_canonical: Option<f64>`,在构造点从 `obs` 原样抄(与 `value_printed`/`value_canonical` 同一处、同一行抄,**不要**分开抄——分开抄就会造出「值换了区间没换」)。

`LabPoint` 加:

```rust
    /// **这个点自己那张单子上印的参考区间**,与 [`Self::value`] / [`Self::unit`] 同一基准
    /// (序列统一换算过时,这里也是换算后的那一对)。跨院时每份报告的区间不同,序列级
    /// 那一对只能留最新的一份 —— 判「这个值算不算高」要用这里的,不是序列级的。
    /// 报告没印区间时为 `None`(不替它补)。
    pub ref_low: Option<f64>,
    pub ref_high: Option<f64>,
```

`finalize_lab_series` 里组装 `LabPoint` 的 `.map(|(p, value)| …)` 那段,按 `canonical_basis` 与值同源地选一对:

```rust
            // 与 `unit`/`value` 同一条判据:基准是规范套就给规范套那一对,否则给印刷套。
            // 两者同源同一个仿射映射,不会出现「值换了区间没换」。
            ref_low: if canonical_basis { p.ref_low_canonical } else { p.ref_low },
            ref_high: if canonical_basis { p.ref_high_canonical } else { p.ref_high },
```

把 `AnalyteSeries::ref_low` 的文档补一句:

```rust
    /// ⚠️ **这是「最新一张印了区间的单子」那一对,不是每个点的。** 渲染层拿它画参考带;
    /// 要判某一个点算不算高/低,用 [`LabPoint::flag`](已按点自己的区间算好)或
    /// [`LabPoint::ref_low`]/[`LabPoint::ref_high`]。
```

`packages/profile/src/rules.rs:2039` 的 `point_row` 加两个键(序列级那两个字段不动):

```rust
        // 这个点自己那张单子印的区间 —— 跨院时与序列级那一对不是同一回事,
        // 证据行要显示的是这一对(`series_json` 的 `ref_low`/`ref_high` 只喂参考带)。
        "ref_low": p.ref_low,
        "ref_high": p.ref_high,
```

并把 `series_json` 文档注释里那份形状说明(`rules.rs:2178` 的 `"points": [{"date","value","flag","unverified","document_index"}]`)同步加上这两个键 —— 那行注释是渲染层唯一的契约说明,漏了它下游不会知道有这两个字段。

- [ ] **Step 4: 跑测试**

```bash
cargo test -p parser
cargo test -p profile
cargo test --workspace
```
Expected: `packages/profile/testdata/golden_profile_view.json` 会因为 `points[]` 多了两个键而不匹配——这是**预期的新增**,按测试输出更新 golden,并在提交信息里写明「只多了 points[].ref_low/ref_high 两个键,其余逐字不变」。用 `git diff` 核一遍确实只多这些。

- [ ] **Step 5: clippy + Commit**

```bash
cargo clippy -p parser -p profile --all-targets -- -D warnings
git add packages/parser packages/profile
git commit -m "$(cat <<'EOF'
feat(parser): LabPoint 带上自己那张单子的参考区间(A4)

跨院时每份报告的区间不同,序列级只能留最新一份;证据链因此显示过不属于该点的区间。
每点现在带着与自身 value/unit 同基准的那一对(规范套/印刷套同源同映射)。
flag 的算法不动 —— 它本来就是按点自己的区间算的。golden 只多 points[].ref_low/ref_high。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
EOF
)"
```

---

## 收尾

### Task 16: 重跑评测、记数字、立 ADR

**Files:**
- Create: `docs/log/2026-09-19-dictionary-parser-root-fix.md`
- Create: `docs/ADR/0012-unit-aware-dictionary-and-schema3-meds.md`
- Modify: `WORKLIST.md`(A32 那几条标状态)

**Interfaces:**
- Consumes: 前 15 个任务的全部产出。
- Produces: 一份 before/after 数字表 + 一条不可变的架构决策记录。

- [ ] **Step 1: 跑齐所有闸,逐条记数**

```bash
cargo test --workspace 2>&1 | tail -30
cargo test -p terminology --test confusions -- --nocapture       # 混淆数必须 0
cargo test -p parser --test meds_gold -- --nocapture             # 每日剂量 0 错
cargo test -p parser --test corpus_summary                        # 数字不许动
cargo test -p parser --test downstream_fidelity                   # 数字不许动
cargo test --manifest-path apps/mobile_flutter/rust/Cargo.toml
cd services/api && python -m pytest test_api.py -q && cd ../..
cd apps/mobile_flutter && flutter analyze && dart test && cd ../..
```

- [ ] **Step 2: 跑 MedRepBench(有语料才跑,没有就照实说没跑)**

```bash
export MEDREP_ROOT=<medrepbench 目录>
cargo run --release -p ocr --example medrep --features engine,testing -- --score --out out_dictfix
MEDREP_ROOT=$MEDREP_ROOT cargo run -p terminology --example term_gaps -- --out /tmp/term_gaps_after.json
```
要记的三个数与基线口径**完全一致**(ADR 0010 那张表):项目召回 / 值-名配对 / 参考区间归属,加错配率。基线 = 正则臂 `65.7 / 58.9 / 47.5`(schema 2 回归那轮的 682 份分母,见 `docs/log/2026-09-17-schema2-medrepbench-regression.md`)。**分母变了就必须说分母变了**,不许拿两个分母的数直接相减。

- [ ] **Step 3: 写 log(精炼,不是流水账)**

`docs/log/2026-09-19-dictionary-parser-root-fix.md`,结构照 `docs/log/2026-09-17-schema2-medrepbench-regression.md`:怎么跑的 → 数字表(before/after,同分母)→ 口径提醒。必须写进去的:

| | before | after |
|---|---|---|
| 混淆闸行数 / 混淆数 | —(没有闸) | N / 0 |
| 词条数 | 642 | 644 |
| 用法金标每日剂量错数 | —(没有金标) | 0 |
| term_gaps:精确 / 模糊 / 未覆盖 | … | … |
| MedRepBench 项目召回 / 值-名配对 / 区间归属 | 65.7 / 58.9 / 47.5 | … |
| corpus_summary / downstream_fidelity | (逐字不变) | (逐字不变) |

并把这五条 A32 的状态逐条写清:①UPCR ✅ ②CH50 ✅(+ 短代码闸)③/HP ✅ ④规格压用法 ✅ ⑤途径被吞 ✅ ⑥跨院区间 ✅(每点区间已落地,渲染层画带子仍取序列级)。**没做的也要写**:A6 在线那一半(schema 3 让模型在每行化验旁直接给规范键)**没做**,理由见 ADR。

- [ ] **Step 4: 写 ADR 0012**

Nygard 格式。Context:A32 九条逐条打补丁堵不完,根因两条(模糊匹配不看单位;用正则从处方笺猜用法)。Decision 至少这五条:
1. `Entry.dimension` = 「单位族封闭」的声明;声明了才拒绝候选、才退出模糊。**不一刀切**,理由(`normalize_unit` 不折大小写 / `units[]` 不完整)逐字写进去。
2. 同名不同量纲**拆条 + 共用别名 + 由印刷单位选条**;重复别名闸只对「都声明 dimension 且单位族不相交」放行。
3. 短代码(纯 ASCII ≤6)永不模糊。
4. schema 3 = v2 字节前缀 + 用药块;用药的**编码**字段按受控词表核、**原文**字段按逐字核;**每日剂量永远本机算**。
5. 术语批量校准走我们的代理 + 同意闸 + 脱敏闸,**只发项目名与单位**;已同步隐私政策(Task 9)。
Consequences 要写清代价:词典多了一个只有少数条目用得上的字段;`resolve` 的拒绝语义让一部分「本来能猜对」的行变成 miss(这是 spec 的「宁缺毋错」,由混淆闸与 MedRepBench 召回一起看着);A6 在线那一半没做(642 条键表放进每次请求 ≈26 KB,而离线校准已经把词典喂饱了,不值)。

- [ ] **Step 5: WORKLIST 标状态**

把 A32 ①–⑥ 逐条标上「已修 / 提交 / 测试名」,⑦(`packages/sync/src/keys.rs:71` 的 `manual_is_multiple_of`)**不在本计划范围**,原样留着。

- [ ] **Step 6: Commit**

```bash
git add docs/log/2026-09-19-dictionary-parser-root-fix.md docs/ADR/0012-unit-aware-dictionary-and-schema3-meds.md WORKLIST.md
git commit -m "$(cat <<'EOF'
docs: 词典/解析根治的评测数字与 ADR 0012

before/after 同分母;混淆闸 0、用法金标每日剂量 0 错、corpus_summary 逐字不变。
ADR 记下五条决定与三项代价,含「A6 在线那一半没做」及其理由。

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KMR1uVqpofrCC5Yjf9com8
EOF
)"
```

---

## 自查(writing-plans 的三项)

### 1. Spec 覆盖表

| spec 条目 | 要求 | 落在哪个任务 |
|---|---|---|
| **A1** 词条带量纲与单位族;给了单位就拒绝族外候选 | 单位族复用 `canonical_unit + units[]`(不另存 `unit_family`),新增 `dimension` 标签,拒绝只对声明了它的条目生效 | **Task 7**(拒绝逻辑)、**Task 8**(给 4 条打标) |
| **A2** 短代码只走精确表 | 纯 ASCII ≤6 永不模糊 + 性质测试 | **Task 1** |
| **A3** 同名不同量纲拆条(/HPF 13945-1、/uL);比值族禁止模糊 | 新增两条内置、共用别名、单位选条;`dimension` 条目整条退出模糊 | **Task 8**(拆条)、**Task 7**(禁模糊) |
| **A4** 跨院参考区间随点走 | `LabPoint` 带每点区间;`flag` 本来就是按点算的(已核) | **Task 15** |
| **A5** 评测闸:混淆数 0、召回不退 | 混淆表 + CI 闸(不依赖外部语料);召回在收尾轮跑 MedRepBench | **Task 3**(闸)、**Task 8**(补行)、**Task 16**(召回) |
| **A6** 批量云端校准:抽名+单位 → 一次请求 → 本机核对 → 人审进词典 | 三步拆开;分批(spec 的「一个请求」顶破 64 KiB 与 max_tokens,理由写在工具文件头) | **Task 4**(抽)、**Task 5**(发)、**Task 6**(核+人审) |
| **A6** 在线让模型每行给规范键 | **不做**,理由记进 ADR(642 键表 ≈26 KB/请求;离线校准已达成同一目的) | **Task 16**(ADR 记录) |
| **B1** schema 3 用药字段;每日剂量本机算;v2 字节前缀 | 提示词 + 结构体 + 客户端;日剂量沿用 `profile::rules` 现成算法,零新增 | **Task 10**、**Task 11**、**Task 12** |
| **B2** 数值/单位逐字核、枚举按词表核、核不过置空 | `FieldKind::{Numeric, Unit, Enum}` 逐字段判,不连坐 | **Task 11** |
| **B3** 有抽取结果用事实;`latest_raw_name` 退休换 `latest_form`/`latest_route` | 聚合优先级 + 字段替换 + profile 剂型门改读代码 | **Task 13** |
| **B4** 正则兜底宁缺毋错(规格 vs 用法、剂型词不单独成名) | 规格形状识别 + 用法切点 + 剂型词 guard | **Task 2** |
| **B5** 用法金标 + 每日剂量 0 错闸 | 新语料目录(不动 corpus,数字不移)+ 独立算法的闸 | **Task 14** |
| **C** 顺序 1→2→3→4 | Task 1–2(C1)→ 3–9(C2)→ 10–14(C3)→ 15(C4)→ 16 | 全局 |
| **D** 不换模型、不绑模型名、不在服务端解析 | 代理只加 schema 分支,解析全在端上;模型名仍由环境变量给 | **Task 5**、**Task 10** |
| **E2** schema 3 | 已采纳 | **Task 10** |
| 用户额外要求:privacy.html 同步 | A6 改了数据流 → 政策加一句 + 线上 curl 核实 | **Task 9** |

无遗漏项。

### 2. 占位符扫描

通读一遍,无 "TBD" / "待补" / "类似 Task N" / "加上适当的错误处理" / 只描述不给代码的步骤。两处**刻意**不给成品的地方,都已写明为什么以及判据是什么:Task 6 第 4 步(人审清单由人看,工具不自动改词典)、Task 14 第 1–2 步(语料必须从三处现成数据逐字取、金标必须人算,给代码生成就等于「代码等于代码」)。Task 9 的线上域名留成 `<线上域名>` 是因为它不在 `main` 仓库里,执行者要在 gh-pages worktree 里看 —— 同一步里已给出 `git -C` 的查看命令。

### 3. 类型一致性

- `Entry.dimension: Option<String>`(Task 7 定义)→ Task 8 的 JSON 写 `"dimension": "per_hpf"` / `"per_ul"` / `"ratio_mg_per_g"`,Task 7 测试读 `e.dimension.as_deref() == Some("ratio_mg_per_g")`,`vault_profile.rs` 两处补 `dimension: None`。一致。
- `Index.aliases: HashMap<String, Vec<AliasHit>>`(Task 8)→ `normalize_all` 用 `hits.iter().map(...)`,`confusions`/`drug_aliases`/`drug_confusions` 仍是单值、用 `vec![...]` 包一层。一致。
- `reject_on_unit(Vec<Match>, Option<&str>) -> Vec<Match>`(Task 7)→ Task 8 的 `resolve` 里 `pick_best(reject_on_unit(hits, unit), unit)`,`pick_best` 空输入返回 `None`。一致。
- `MedObservation.route/form: Option<String>`(Task 13)值域 = `route_code_of`/`form_code_of` 的返回 = `deid` 的 `ROUTE_CODE_VALUES`/`FORM_CODE_VALUES`(Task 11)= `extract_v3_system.txt` 的词表(Task 10)。**三处必须逐字一致**,Task 11 的常量文档已写明这条。一致。
- `MedSpan.latest_form/latest_route: Option<String>`(Task 13)→ `profile::rules::form_haystack` 读它们,`GC_INJECTION` 同时含中文词与代码(`ivgtt`/`injection`/`sc`),Task 13 已把表扩到 10 项。一致。
- `meds_from_json(&str) -> Result<MedsFromJson, deid::DeidError>`(Task 13)与 `labs_from_json` 同形;`MedsFromJson { meds, dropped }` 与 `LabsFromJson { labs, dropped_unparseable, unverified }` 字段名**不同**是刻意的(用药没有 `unverified` 计数这回事)。一致。
- `LabPoint.ref_low/ref_high: Option<f64>`(Task 15)与 `AnalyteSeries.ref_low/ref_high` 同名不同层,两边文档都写清了谁是谁。一致。
- `extractSchema = 3`(Task 12)= `extract.py` 的 `schema == 3`(Task 10)= `medrep_llm --schema 3`(Task 10)。一致。
- `"terms-calib"`(Task 5)在 `extract.py`、客户端 body、`test_api.py` 三处逐字相同。一致。
