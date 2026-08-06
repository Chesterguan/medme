//! 部首字形对**下游抽取**的量化影响 —— 走 `pipeline::ingest` 那条真路。
//!
//! ## 这是一条「特征测试」(characterization test),不是「期望测试」
//!
//! 它钉住的是**当前(未修)行为与折叠后行为之间的差**,数字全部实测得来。
//! 之所以要钉:上一轮修医院名时,前一个 agent 拿 `parser::extract`(**会**折
//! 部首)量出「9 份修好 0 份变坏」,与真机完全相反 —— 因为 app 走的是
//! `ingest_pdf` → `ocr::recognize_pdf_mixed`,**不折**,部首原样落进
//! `ocr_result.text`。这里一律从 `ocr_result.text` 取文本,谁也别再量错路。
//!
//! ## 根因在 PDF 自己身上,不是 `pdf-extract` 读错了
//!
//! demo corpus 的 22 份全部由 Chrome 打印生成(`/Producer (Skia/PDF m150)`)。
//! 逐份解开它们的 `ToUnicode` CMap 可见:**PDF 自己就把常用字的字形映射到了
//! 康熙部首码位**(如 `2023-11-02_头颅MRI` 一份 195 条映射里有 15 条落在
//! U+2E80–2FDF)。`pdf-extract` 忠实照读,没有读错。所以这不能靠"换个更好的
//! PDF 库"解决,只能显式折。
//!
//! ## 已经修好了(2026-08-06)
//!
//! `pipeline::ingest_pdf` 现在在 `recognize_pdf_mixed` 返回之后、
//! `classify`/`guess_date_range`/`add_ocr` 之前折一次部首。上面那些成对常量
//! **已经收敛成同一个值**,断言随之从"量化欠债"改成了"钉住已还清":两条路
//! (照原样 / 先折一次)必须给出**相同**的结果 —— 因为入库文本本来就已经折过,
//! 再折一次是幂等的空操作。
//!
//! 所以这个文件现在的作用是**回归护栏**:哪天有人把 `ingest_pdf` 里那两处折叠
//! 拿掉(或者新加一条绕过它的入库路径),这里立刻红,并且报出来的差值就是
//! 当年那张影响表。**不要**因为"看起来两边总是相等、没什么用"就删掉它。

use core_model::Vault;
use std::path::{Path, PathBuf};

// ---- 实测基线(2026-08,demo-data 22 份,`cargo test -p pipeline`)----
/// 挂上疾病泳道(`parser::match_disease`)的诊断条数。这是差距最大的一项:
/// 部首把 `⾼⾎压` / `⾼尿酸⾎症` 打穿,`problem_map.json` 一条都对不上。
const AS_IS_LANED_CONDITIONS: usize = 4;
const FOLDED_LANED_CONDITIONS: usize = 4;
/// 映射到 ATC 的药物条数。
const AS_IS_MEDS_WITH_ATC: usize = 7;
const FOLDED_MEDS_WITH_ATC: usize = 7;
/// 药物总行数。修复前是 9 —— 其中两条是 `⼆甲双胍` / `⼝服阿司匹林` 被部首
/// 拆出来的重复条目,折叠后并回正条。
const MEDS_ROWS: usize = 7;
/// 影像/病理「诊断意见」段落抽出正文的份数(`意⻅` 的 `⻅` 是 U+2EC5,
/// 标签匹配不上,整段 impression 从医生摘要/分享里消失)。
const AS_IS_IMAGING_FINDINGS: usize = 3;
const FOLDED_IMAGING_FINDINGS: usize = 3;

fn demo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../apps/mobile_flutter/rust/demo-data")
}

fn collect_pdfs(dir: &Path, out: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(dir).expect("demo-data readable") {
        let p = entry.expect("dir entry").path();
        if p.is_dir() {
            collect_pdfs(&p, out);
        } else if p.extension().and_then(|e| e.to_str()) == Some("pdf") {
            out.push(p);
        }
    }
}

struct Doc {
    name: String,
    date: Option<chrono::NaiveDate>,
    doc_type: String,
    title: Option<String>,
    /// **正是 `ocr_result.text` 里存的那份**,一个字节都没动过。
    text: String,
}

/// 把 22 份 demo 走一遍 `pipeline::ingest`,再从 `ocr_result` 读回文本 ——
/// 与真机上「文档详情 · 文档内容」和所有抽取消费者看到的是同一份。
fn ingested_docs(dir: &Path) -> (Vault, Vec<Doc>) {
    let mut pdfs = Vec::new();
    collect_pdfs(&demo_root(), &mut pdfs);
    pdfs.sort();
    let v = Vault::open(dir).expect("vault opens");
    for p in &pdfs {
        pipeline::ingest(&v, p).expect("demo pdf ingests");
    }
    let docs = v
        .timeline()
        .expect("timeline")
        .into_iter()
        .map(|e| Doc {
            name: e.title.clone().unwrap_or_default(),
            date: e.doc_date.map(|d| d.date_naive()),
            doc_type: e.doc_type.as_str().to_string(),
            title: e.title.clone(),
            text: v.ocr_text(e.document_id).expect("ocr text"),
        })
        .collect();
    (v, docs)
}

fn texts(docs: &[Doc], fold: bool) -> Vec<String> {
    docs.iter()
        .map(|d| {
            if fold {
                core_model::normalize_cjk_radicals(&d.text)
            } else {
                d.text.clone()
            }
        })
        .collect()
}

fn source_docs<'a>(docs: &'a [Doc], texts: &'a [String]) -> Vec<parser::SourceDoc<'a>> {
    docs.iter()
        .enumerate()
        .map(|(i, d)| parser::SourceDoc {
            index: i,
            date: d.date,
            text: &texts[i],
            doc_type: Some(d.doc_type.clone()),
            title: d.title.clone(),
        })
        .collect()
}

/// **`ocr_result.text` 里一个部首码位都不许剩下。**
///
/// 这条是整个文件的地基。原本它断言的是反面(22 份全带部首),用来证明缺陷存在;
/// `ingest_pdf` 的折叠落地后翻过来:入库文本必须是干净的。
///
/// 它会在两种情况下红,两种都该红:
///   1. 有人拿掉了 `ingest_pdf` 里的折叠 —— 缺陷复发;
///   2. 有人新加了一条绕过 `ingest_pdf` 的 PDF 入库路径 —— 缺陷从新口子漏进来。
///
/// 报错里逐份列出还带部首的文件**以及具体是哪些码位** —— 因为 CJK Radicals
/// Supplement 块还有 114 个码位没有 NFKC 分解(见 `core_model::text` 的
/// `supplement_block_coverage_is_a_known_finite_number`)。真冒出新码位时,
/// 光知道「某份不干净」没用,得知道要往表里补哪个字。
#[test]
fn ocr_result_text_carries_no_radical_glyphs() {
    let td = tempfile::tempdir().expect("tempdir");
    let (_v, docs) = ingested_docs(td.path());
    assert_eq!(docs.len(), 22, "demo-data 的份数变了");
    let dirty: Vec<String> = docs
        .iter()
        .filter_map(|d| {
            let mut cps: Vec<String> = d
                .text
                .chars()
                .filter(|c| ('\u{2E80}'..='\u{2FDF}').contains(c))
                .map(|c| format!("{c}(U+{:04X})", c as u32))
                .collect();
            cps.sort();
            cps.dedup();
            (!cps.is_empty()).then(|| format!("{} → {}", d.name, cps.join(" ")))
        })
        .collect();
    assert!(
        dirty.is_empty(),
        "入库文本里仍有部首码位。要么 ingest_pdf 的折叠被拿掉了,要么有新的入库\
         路径绕过了它,要么这些码位不在折叠表里(Supplement 块还有 114 个没有 \
         NFKC 分解,得手工补):\n  {}",
        dirty.join("\n  ")
    );
}

/// 诊断 → 疾病泳道。**受伤最重的一处**:`⾼⾎压`/`⾼尿酸⾎症` 与
/// `problem_map.json` 里的 `高血压`/`痛风/高尿酸血症` 一个字都对不上,
/// 医生视图里那两条泳道整条空着。
#[test]
fn radicals_cost_three_quarters_of_the_disease_lanes() {
    let td = tempfile::tempdir().expect("tempdir");
    let (_v, docs) = ingested_docs(td.path());
    let count = |fold: bool| {
        let t = texts(&docs, fold);
        parser::aggregate(&source_docs(&docs, &t))
            .conditions
            .iter()
            .filter(|c| parser::match_disease(&c.raw_text).is_some())
            .count()
    };
    assert_eq!(count(false), AS_IS_LANED_CONDITIONS, "现状");
    assert_eq!(count(true), FOLDED_LANED_CONDITIONS, "折部首后");
}

/// 药物 → ATC。修复前 `达格列净⽚`(`⽚` U+2F49)对不上词典,折完就对上了
/// `A10BK01`;同时 `⼆甲双胍` / `⼝服阿司匹林` 两条被拆出来的重复条目并回正条
/// (9 行 → 7 行)。
///
/// 现在两条路必须给出**相同**结果 —— 入库文本已折过,再折是幂等空操作。
/// 行数那条不再写成「as-is 比 folded 多」:折叠落地后两边相等,那种写法按定义
/// 就永远失败,留着只会让人以为测试坏了。改成钉住修好之后的绝对值。
#[test]
fn radicals_cost_one_drug_its_atc_code_and_split_two_more_in_half() {
    let td = tempfile::tempdir().expect("tempdir");
    let (_v, docs) = ingested_docs(td.path());
    let measure = |fold: bool| {
        let t = texts(&docs, fold);
        let meds = parser::aggregate(&source_docs(&docs, &t)).meds;
        (meds.len(), meds.iter().filter(|m| m.atc.is_some()).count())
    };
    let (rows_asis, atc_asis) = measure(false);
    let (rows_folded, atc_folded) = measure(true);
    assert_eq!(atc_asis, AS_IS_MEDS_WITH_ATC, "现状:映射到 ATC 的条数");
    assert_eq!(atc_folded, FOLDED_MEDS_WITH_ATC, "折后:映射到 ATC 的条数");
    assert_eq!(
        rows_asis, rows_folded,
        "入库文本再折一次不该改变药物行数 —— 不相等说明 ingest_pdf 的折叠没生效,\
         同一种药又被拆成了额外的行(实测 {rows_asis} vs {rows_folded})"
    );
    assert_eq!(
        rows_asis, MEDS_ROWS,
        "药物行数变了。修复前是 9 行(其中两条是被部首拆出来的重复条目),\
         修复后并回 {MEDS_ROWS} 行"
    );
}

/// 化验是**唯一基本没受伤**的一项 —— 但原因是 corpus 的运气,不是设计:
/// 这些化验单印了 `TC` / `Cr` / `Glu` 这类拉丁缩写列,词典靠缩写就命中了,
/// 中文项目名被打穿也无所谓。**只印中文项目名的化验单不受这条保护。**
#[test]
fn labs_are_nearly_untouched_because_the_corpus_prints_latin_abbreviations() {
    let td = tempfile::tempdir().expect("tempdir");
    let (_v, docs) = ingested_docs(td.path());
    let measure = |fold: bool| {
        let t = texts(&docs, fold);
        let labs = parser::aggregate(&source_docs(&docs, &t)).labs;
        let keyed: Vec<_> = labs.iter().filter(|s| s.analyte_key.is_some()).collect();
        (
            labs.len(),
            labs.iter().map(|s| s.points.len()).sum::<usize>(),
            keyed.len(),
            keyed.iter().map(|s| s.points.len()).sum::<usize>(),
        )
    };
    assert_eq!(
        measure(false),
        measure(true),
        "化验的序列数/点数/命中 analyte_key 的序列数与点数应当完全一致"
    );
    assert_eq!(measure(false), (19, 48, 19, 48), "基线");
}

/// 影像/病理的「诊断意见」段:标签里的 `⻅`(U+2EC5)让整段 impression 抽不到,
/// 医生摘要与二维码分享上那一栏是空的 —— 用户以为分享出去了,其实只有个标题。
#[test]
fn radicals_swallow_two_of_three_imaging_impressions() {
    let td = tempfile::tempdir().expect("tempdir");
    let (_v, docs) = ingested_docs(td.path());
    let with_finding = |fold: bool| {
        let t = texts(&docs, fold);
        let summary = parser::assemble_summary(&source_docs(&docs, &t));
        summary
            .get("imaging")
            .and_then(|v| v.as_array())
            .map(|groups| {
                groups
                    .iter()
                    .filter_map(|g| g.get("studies").and_then(|s| s.as_array()))
                    .flatten()
                    .filter(|s| s.get("finding").is_some_and(|f| !f.is_null()))
                    .count()
            })
            .unwrap_or(0)
    };
    assert_eq!(with_finding(false), AS_IS_IMAGING_FINDINGS, "现状");
    assert_eq!(with_finding(true), FOLDED_IMAGING_FINDINGS, "折部首后");
}

/// **建档时定死、事后不自愈的两项现在算对了。**
///
/// `parser::classify` 的文档类型与 `parser::guess_date_range` 的时间线日期,
/// 在 `ingest` 里跑一次就写进 `DocumentAdded` **事件**,`rebuild_from_log` 重放
/// 也是同一个错值 —— 所以它们必须在**入库前**就拿到折过的文本,放 `materialize`
/// 侧补救来不及。这正是折叠点选在 `ingest_pdf` 而不是更下游的原因。
///
/// 判据:入库文本再折一次不应改变任何结论(折叠幂等 ⇒ 已经折过了)。
/// 修复前这里是 3 份 doc_type、2 份日期对不上;其中 `2023-05-20_门诊病历`
/// 被判成影像报告(时间线卡片写「检查」不写「病历」),`2023-11-02_头颅MRI`
/// 的日期变成横跨七个月的假区间。
#[test]
fn classify_and_dates_no_longer_shift_when_text_is_folded_again() {
    let td = tempfile::tempdir().expect("tempdir");
    let (_v, docs) = ingested_docs(td.path());
    let mut type_diffs = Vec::new();
    let mut date_diffs = Vec::new();
    for d in &docs {
        let folded = core_model::normalize_cjk_radicals(&d.text);
        if parser::classify(&d.text) != parser::classify(&folded) {
            type_diffs.push(d.name.clone());
        }
        if parser::guess_date_range(&d.text) != parser::guess_date_range(&folded) {
            date_diffs.push(d.name.clone());
        }
    }
    assert!(
        type_diffs.is_empty(),
        "这些文档的 doc_type 会因为再折一次而改变 —— 说明入库时用的是没折过的\
         文本,而 doc_type 一旦写进事件就不自愈:{type_diffs:?}"
    );
    assert!(
        date_diffs.is_empty(),
        "这些文档的时间线日期会因为再折一次而改变 —— 同上,日期错了会让卡片\
         排错位置甚至横跨数月:{date_diffs:?}"
    );
}

/// **这些词现在搜得到了。**
///
/// FTS body 是 `jieba` 分词后的 `ocr_result.text`。修复前部首把词切碎成单字,
/// 这七个词**一份都搜不到** —— 病历里白纸黑字写着「甘油三酯」,搜出来是空的。
///
/// 现在正走的库(`v`)与「先折一次再建索引」的对照库(`vb`)必须给出**相同**
/// 的命中数:入库文本已经折过了,再折是幂等空操作。
///
/// 注:同时存在**反向**的两例(`医院`、`尿酸`),那不是折叠的损伤,而是
/// `jieba` + FTS5 短语匹配的固有粒度问题 —— 折完 `华⼭医院` 成词为
/// `华山医院` 这一个 token,再搜单独的 `医院` 就不匹配了(`北京协和医院`
/// 这种本来就没部首的份,现在也一样搜不到 `医院`)。见
/// [`compound_tokens_are_a_pre_existing_fts_limitation`]。
#[test]
fn these_terms_are_searchable_now() {
    let td = tempfile::tempdir().expect("tempdir");
    let (v, _docs) = ingested_docs(td.path());
    let td2 = tempfile::tempdir().expect("tempdir");
    let vb = folded_vault(td2.path());
    for (kw, want) in [
        ("甘油三酯", 4usize),
        ("二甲双胍", 5),
        ("血红蛋白", 7),
        ("低密度脂蛋白", 4),
        ("华西医院", 4),
        ("胆囊结石", 4),
        ("高尿酸血症", 1),
    ] {
        assert_eq!(
            distinct_hits(&v, kw),
            want,
            "{kw}:正走的入库路径应该搜得到这么多份 —— 搜不到就说明 ingest_pdf \
             的折叠没生效"
        );
        assert_eq!(
            distinct_hits(&vb, kw),
            want,
            "{kw}:对照库(先折再建索引)必须与正走的路径一致 —— 不一致说明折叠\
             不幂等,或两条路的索引结构漂了"
        );
    }
}

/// 与 `pipeline::ingest_pdf` **结构逐点对齐**的第二个保险箱:同样每页一条
/// `ocr_result`(因而每页一条 FTS 行),只是每页文本先折了一次部首。
/// 不这样对齐,两边的 FTS 命中数就不可比(每份文档的索引行数不一样)。
fn folded_vault(dir: &Path) -> Vault {
    use core_model::{NewDocument, NewOcr, OcrBackendKind};
    let mut pdfs = Vec::new();
    collect_pdfs(&demo_root(), &mut pdfs);
    pdfs.sort();
    let v = Vault::open(dir).expect("vault opens");
    for p in &pdfs {
        let bytes = std::fs::read(p).expect("read demo pdf");
        let name = p
            .file_name()
            .expect("file name")
            .to_string_lossy()
            .to_string();
        let mixed = ocr::recognize_pdf_mixed(&bytes).expect("demo pdf parses");
        let whole = core_model::normalize_cjk_radicals(&mixed.text());
        let imp = v.import(&name, "application/pdf", &bytes).expect("import");
        let (doc_date, doc_date_end) = parser::guess_date_range(&whole);
        let doc = v
            .add_document(NewDocument {
                source_file_id: imp.source_file.id,
                doc_type: parser::classify(&whole),
                doc_date,
                doc_date_end,
                title: Some(name.clone()),
                language: parser::detect_language(&whole),
                page_count: mixed.page_count(),
            })
            .expect("add document");
        for page in &mixed.pages {
            let page_text = match &page.result {
                ocr::PdfPageText::TextLayer(t) => t.clone(),
                ocr::PdfPageText::Ocr { text, .. } => text.clone(),
                ocr::PdfPageText::Unrecognized => continue,
            };
            v.add_ocr(NewOcr {
                document_id: doc.id,
                page_no: page.page_no,
                backend: OcrBackendKind::Native,
                model_version: "text-layer".into(),
                text: core_model::normalize_cjk_radicals(&page_text),
                confidence: None,
            })
            .expect("add ocr");
        }
    }
    v
}

/// 上面那条的对照面,免得有人把 `医院`/`尿酸` 那两例读成「折叠有副作用」。
/// `北京协和医院` 全篇没有一个部首,`jieba` 照样把它切成一个 token,搜
/// 单独的 `医院` 同样搜不到 —— 这是分词粒度,与部首无关。
#[test]
fn compound_tokens_are_a_pre_existing_fts_limitation() {
    let toks = core_model::tokenize::tokenize("北京协和医院");
    assert_eq!(toks, "北京协和医院");
    assert!(
        !toks.split_whitespace().any(|t| t == "医院"),
        "整份没有部首的文本里,`医院` 本来就不是一个独立 token"
    );
}

/// 医院名是上一轮(`8fb35c4`)已经修掉的那一处:`extract_provider` 自己先折
/// 一次部首,所以它**不受**本文件其余各条的影响 —— 22 份里 21 份抽得出。
/// 这条在这里是为了说明「逐个消费者各折一次」这条路走得通但要人人记得。
#[test]
fn provider_extraction_already_folds_on_its_own() {
    let td = tempfile::tempdir().expect("tempdir");
    let (_v, docs) = ingested_docs(td.path());
    let n = |fold: bool| {
        texts(&docs, fold)
            .iter()
            .filter(|t| core_model::extract_provider(t).is_some())
            .count()
    };
    assert_eq!(n(false), 21);
    assert_eq!(n(false), n(true), "折不折都一样 —— 它在函数入口自己折过了");
}

/// FTS 索引每页一行,同一份文档会命中多次;用户可见的是「能搜到几份文档」。
fn distinct_hits(v: &Vault, kw: &str) -> usize {
    let mut ids: Vec<i64> = v
        .search(kw, 500)
        .expect("search")
        .into_iter()
        .map(|h| h.document_id)
        .collect();
    ids.sort_unstable();
    ids.dedup();
    ids.len()
}
