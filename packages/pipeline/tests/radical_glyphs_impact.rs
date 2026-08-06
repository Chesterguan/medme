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
//! ## 修好之后怎么办
//!
//! 若哪天决定在 ingest 侧统一折(见调查报告),这个文件里成对的 `AS_IS_*` /
//! `FOLDED_*` 常量会收敛成同一个值 —— 那时把断言改成"两者相等",测试的意义
//! 从"量化欠债"变成"钉住已还清"。**不要**因为数字不再匹配就直接删掉它。

use core_model::Vault;
use std::path::{Path, PathBuf};

// ---- 实测基线(2026-08,demo-data 22 份,`cargo test -p pipeline`)----
/// 挂上疾病泳道(`parser::match_disease`)的诊断条数。这是差距最大的一项:
/// 部首把 `⾼⾎压` / `⾼尿酸⾎症` 打穿,`problem_map.json` 一条都对不上。
const AS_IS_LANED_CONDITIONS: usize = 1;
const FOLDED_LANED_CONDITIONS: usize = 4;
/// 映射到 ATC 的药物条数。
const AS_IS_MEDS_WITH_ATC: usize = 6;
const FOLDED_MEDS_WITH_ATC: usize = 7;
/// 影像/病理「诊断意见」段落抽出正文的份数(`意⻅` 的 `⻅` 是 U+2EC5,
/// 标签匹配不上,整段 impression 从医生摘要/分享里消失)。
const AS_IS_IMAGING_FINDINGS: usize = 1;
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

/// 部首字形**确实**活在 `ocr_result.text` 里,而且不是个别现象 —— 22 份全中。
///
/// 这条是所有后面几条的前提。哪天 corpus 换成不带这个毛病的 PDF、或者 ingest
/// 侧开始折了,它会第一个失败,提醒你别再拿本文件的数字当结论。
#[test]
fn radical_glyphs_survive_all_the_way_into_ocr_result_text() {
    let td = tempfile::tempdir().expect("tempdir");
    let (_v, docs) = ingested_docs(td.path());
    assert_eq!(docs.len(), 22, "demo-data 的份数变了");
    let clean: Vec<&str> = docs
        .iter()
        .filter(|d| {
            !d.text
                .chars()
                .any(|c| ('\u{2E80}'..='\u{2FDF}').contains(&c))
        })
        .map(|d| d.name.as_str())
        .collect();
    assert!(
        clean.is_empty(),
        "这些 demo 的 ocr_result.text 里已经没有部首码位了 —— 前提变了,\
         本文件其余断言的数字全部作废,请重新实测:{clean:?}"
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

/// 药物 → ATC。`达格列净⽚`(`⽚` U+2F49)对不上词典,折完就对上了
/// `A10BK01`;同时 `⼆甲双胍`/`⼝服阿司匹林` 两条重复条目并回正条。
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
    assert!(
        rows_asis > rows_folded,
        "现状下同一种药被部首拆成了额外的行(实测 {rows_asis} → {rows_folded})"
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

/// 建档时就定死、事后不会自愈的两项:`parser::classify` 的文档类型、
/// `parser::guess_date_range` 的时间线日期。它们在 `ingest` 里对着**没折过**的
/// 文本跑一次就写进 `document` 表,之后任何消费者都读那个错值。
#[test]
fn classify_and_dates_are_decided_once_at_ingest_on_unfolded_text() {
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
    assert_eq!(
        type_diffs.len(),
        3,
        "3 份的 doc_type 被部首带偏(其中 2023-05-20 门诊病历被判成了影像报告):{type_diffs:?}"
    );
    assert_eq!(
        date_diffs.len(),
        2,
        "2 份的时间线日期被部首带偏(变成横跨数月的假区间):{date_diffs:?}"
    );
}

/// 全文检索。FTS body 是 `jieba` 分词后的 `ocr_result.text`,部首把词切碎成单字,
/// 于是这些词**一份都搜不到**。折完索引后它们各自都能搜到。
///
/// 注:同时存在**反向**的两例(`医院`、`尿酸`),那不是折叠的损伤,而是
/// `jieba` + FTS5 短语匹配的固有粒度问题 —— 折完 `华⼭医院` 成词为
/// `华山医院` 这一个 token,再搜单独的 `医院` 就不匹配了(`北京协和医院`
/// 这种本来就没部首的份,现在也一样搜不到 `医院`)。见
/// [`compound_tokens_are_a_pre_existing_fts_limitation`]。
#[test]
fn radicals_make_these_terms_unsearchable() {
    let td = tempfile::tempdir().expect("tempdir");
    let (v, _docs) = ingested_docs(td.path());
    let td2 = tempfile::tempdir().expect("tempdir");
    let vb = folded_vault(td2.path());
    for (kw, want_folded) in [
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
            0,
            "{kw}:现状下 FTS 一份都搜不到(索引里是被部首切碎的单字)"
        );
        assert_eq!(
            distinct_hits(&vb, kw),
            want_folded,
            "{kw}:索引建在折过的文本上时能搜到的份数"
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
