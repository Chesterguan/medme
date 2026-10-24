# 2026-10-24 · 中文化第一层:ICD 中文名、用药中文名覆盖、标题中文化、看原文

spec:`docs/superpowers/specs/2026-10-23-chinese-localization-design.md`(§9.2 十题已拍板:Q1、Q3 用户本人,其余父会话按 spec 原则代定)。分支 `claude/zh-spec-bc5c05`,基于 `feat/generic-profile`。背景:686 份 Epic 英文病历导进来后,国内医生看到的诊断、标题全是英文;用户 10-23 原话「英文太长如果国内医生不爱读咋办?」。第一层全部离线、确定性、零新事件;第二层(中文摘要,需后端 + 英文脱敏硬前置 + 隐私政策)是下一期。

**做了什么**
- **ICD-10 → 中文名表**(`packages/terminology/icd10_zh.json`,416 KB):《疾病分类与代码国家临床版 2.0(2022 汇总版)》河南卫健委病案站公开 xlsx(sha256 `e927d8ec…`,与山东副本只差 5 新增 2 改名)派生两列,**原文件不进仓库**;`Xnn.d00` → 四位亚目 8,574 条,`Xnn.x00` / `Xnn.900` → 类目 1,340 条;脚本 `scripts/build_icd10_zh.py` + `icd10_zh_methodology.md`。`terminology::resolve_icd10_zh`:归一(大写、剥 `†*`、无点补点、CM 第 3 位字母当无码)→ 前 5 位 → 前 3 位 → `None`;`profile::normalize_icd` 改为委托。
- **族卡诊断中文在前**:`DiagnosisOut` 多 `name_zh` / `name_zh_level`(`skip_serializing_if`,SLE golden 逐字节不变,Jane golden 只多这两个键);Flutter `profile_sections.dart` 主行中文、英文原文小字、`cat3` 标「(类目)」,头部「看原文 / 看中文」切换(只在有 `name_zh` 时出现)。
- **标题中文化放显示层**(`DocumentAdded.title` 只写一次,改适配器要删掉重导):`parser::display_title_zh` 三张表——Epic 小节名闭集(`Discharge Summary Note → 出院小结` 等 11 行)、就诊类型前缀 + 科室原文(`Office Visit Cardiology → 门诊 · Cardiology`)、影像方式前缀(`CT CHEST W CONTRAST → CT · CHEST W CONTRAST`);中文标题返回 `None` 不二次映射。手机 `DocumentSummaryDto.title_zh`(FRB 重生成,只加字段)→ `docDisplayTitle` 中文在前;分享包 `records[].title_zh` → 查看器中文标题在前、英文原标题小字(内联脚本改了,CSP 哈希同步重算)。
- **用药中文名**:`resolve_rxnorm` → `canonical_name` 本来就通(golden 里已是美托洛尔/泼尼松),本次零代码;覆盖缺口靠下一条量。
- **`medme --vault <dir> zh-coverage`**(`parser::tally` 纯函数 + CLI):只打计数与未命中的 ICD/LOINC/RxNorm 码、英文标题去重集合,不含任何值/日期/人名。用户在自己机器上对真实包跑一次,贴回计数,补词典按那张清单来。

**拿到表之后的事实更正**(已改进 spec §2.1.1):`Z79`(目前长期用药)**整类不在**国家临床版里,`Z79.01` 落到 `None`、保留英文,不是原先写的「退到 Z79 类目」;临床版基于 2010 年前的 WHO 更新,`N18.1–N18.5` 不在,`N18.3` 只到类目「慢性肾衰竭」。CM 7 位码截到四位亚目。

**验证**:`cargo fmt --check` / `cargo clippy --workspace --all-targets -D warnings` 干净;`cargo test --workspace` 49 个测试二进制 1,010 条全绿;手机 crate 86 条绿(`frb_dispatch_indices` 不动);`flutter analyze` 零 issue;`flutter test` 1,117 过、1 红 = `glossary_guard`「导入」(PR #243 起就红,本分支没动)。文案闸 `kBaseline` 从 d731618 挪到 cf127fe(「看原文 / 看中文 / (类目)」落地那次提交,闸自己的规矩)。`web/hosted-viewer/renderProfile.smoke.mjs` 在改之前的基线上就断言失败(「golden 渲染里少了:现在」),与本次无关,没动;查看器 4 个内联 `<script>` 块 `node --check` 通过 + CSP 哈希测试绿。

**留的**
- 补词典(RxNorm / LOINC)与补标题表:等用户跑 `zh-coverage` 的计数;表里没有的 ICD(`Z79`、`N18.1–5` 一类)逐条核后再定补不补,不猜。
- 第二层中文摘要 / 第三层翻译:下一期(spec §2.2、§2.3、§5 隐私政策八点、英文脱敏 fixture)。
- 详情页抬头英文原标题第二行、病程档案「依据」旁的中文句:本次没碰 `screens/`(另一条线在改)。
- 桌面 Tauri 不管。
