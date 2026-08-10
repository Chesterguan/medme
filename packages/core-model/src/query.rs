use crate::types::{parse_dt, Document, Encounter, EncounterKind, SourceFile};
use crate::{DocType, MedmeError, Vault};
use chrono::{DateTime, Utc};
use rusqlite::OptionalExtension;

/// Column list shared by `document_by_id` and `documents_where` — keep order aligned
/// with the `Document` struct field order used when building rows.
const DOCUMENT_COLUMNS: &str = "id, source_file_id, doc_type, doc_date, doc_date_end, title, language, page_count, encounter_id, created_at";

fn row_to_document(r: &rusqlite::Row) -> rusqlite::Result<Document> {
    Ok(Document {
        id: r.get(0)?,
        source_file_id: r.get(1)?,
        doc_type: DocType::from_str(&r.get::<_, String>(2)?),
        doc_date: r.get::<_, Option<String>>(3)?.map(parse_dt),
        doc_date_end: r.get::<_, Option<String>>(4)?.map(parse_dt),
        title: r.get(5)?,
        language: r.get(6)?,
        page_count: r.get(7)?,
        encounter_id: r.get(8)?,
        created_at: parse_dt(r.get::<_, String>(9)?),
    })
}

#[derive(Debug, Clone)]
pub struct SearchHit {
    pub document_id: i64,
    pub title: Option<String>,
    pub snippet: String,
}

/// 页脚签名栏的标签。这些字段后面跟的是**人名**。
///
/// 中文姓名和机构名之间没有任何词边界可依:`王涛` 和 `北京` 在字符类上完全一样,
/// 所以一旦 OCR/PDF 文本层把签名与紧随其后的医院名连成一串
/// (`审核者:王涛四川大学华西医院医疗文书专用章` —— 真实语料,demo-dataset 的
/// PDF 文本层逐字如此),**没有任何正则能从这一串里切出正确的起点**:非贪婪只让
/// 匹配尽量短,起始位置仍然取最早的那个,于是人名被一起吞掉。这条结论到今天仍然
/// 成立 —— 变的只是切不准之后怎么办,见 [`extract_provider`] 的「取舍」一节。
///
/// 所以这些 token 排在最后一顺位:先让有干净左边界的候选赢;只有全场再没有别的
/// 候选时,才从签名串里退而求其次抽一个(会带上人名)。
///
/// 按**空白分隔的 token** 判定,不是整行:同一行里 `审核者:王涛 北京协和医院`
/// 的第三个 token 有自己的左边界,是干净的,不能被同行的签名连累。
const SIGNER_LABELS: &[&str] = &[
    "检验者",
    "审核者",
    "审核",
    "报告医师",
    "审核医师",
    "检验医师",
    "报告医生",
    "报告者",
    "记录者",
    "送检医生",
    "申请医生",
    "主治医师",
    "主诊医师",
    "医师",
    "医生",
];

/// 抬头/标题里被逐字拉开的机构名(`四 川 大 学 华 西 医 院`)—— PDF 文本层与
/// 部分排版把标题渲染成字间带空格。每个字后面都跟**恰好一个**空白才算,所以
/// `王涛 北京协和医院` 这种只在词间有空格的写法不会被误当成抬头连起来读。
///
/// 字符类里带上拉丁字母与数字:真实抬头会夹英文/数字
/// (`河 北 省 X X 县 人 民 医 院` —— demo scenarios 的急诊记录逐字如此)。少了
/// 这一条,整行匹配不上,扫描就滑到正文,把医嘱 `建议立即转上级医院` 当成院名。
fn spaced_provider_re() -> &'static regex::Regex {
    use std::sync::OnceLock;
    static RE: OnceLock<regex::Regex> = OnceLock::new();
    RE.get_or_init(|| {
        regex::Regex::new(
            r"((?:[\x{4e00}-\x{9fa5}A-Za-z0-9][ \t]){2,18}?(?:医[ \t]院|医[ \t]学[ \t]中[ \t]心))",
        )
        .expect("spaced provider regex")
    })
}

/// 泛指「某家医院」的说法,不是任何一家医院的名字。医嘱里到处都是
/// (`建议立即转上级医院`),抬头缺席时扫描一定会撞上它 —— 撞上就整个候选作废,
/// 就诊卡上宁可空着也不能印一句医嘱。
///
/// 判据是**后缀**:`医院` 结尾的匹配才可能出现在这里,而 `上级医院` 无论前面接
/// 什么(`转上级医院`/`建议立即转上级医院`)都仍然是泛指。
const GENERIC_HOSPITAL_REFS: &[&str] =
    &["上级医院", "下级医院", "当地医院", "外院", "我院", "本院"];

fn is_generic_reference(name: &str) -> bool {
    GENERIC_HOSPITAL_REFS.iter().any(|g| name.ends_with(g))
}

/// 紧凑写法的机构名(2-18 个中文字,以 医院/医学中心 结尾)。
fn tight_provider_re() -> &'static regex::Regex {
    use std::sync::OnceLock;
    static RE: OnceLock<regex::Regex> = OnceLock::new();
    RE.get_or_init(|| {
        regex::Regex::new(r"([\x{4e00}-\x{9fa5}]{2,18}?(?:医院|医学中心))").expect("provider regex")
    })
}

/// 把签名 token 前面的标签连同紧跟的分隔符切掉:`审核医师:孙立复旦大学附属华山
/// 医院` → `孙立复旦大学附属华山医院`。切到**最靠后**的那个标签末尾(`审核医师`
/// 而不是它内部的 `审核`),这样剩下的串尽量短、噪声尽量少。
///
/// 切不掉人名 —— 那正是 [`SIGNER_LABELS`] 说的「谁也切不准」。这里只保证标签本身
/// 不会被当成院名的一部分。
fn strip_signer_label(tok: &str) -> &str {
    let cut = SIGNER_LABELS
        .iter()
        .filter_map(|l| tok.find(l).map(|p| p + l.len()))
        .max();
    match cut {
        // `find` 与 `+ len()` 都落在字符边界上,切片安全。
        Some(p) => tok[p..].trim_start_matches([':', ':', ' ', '\u{3000}']),
        None => tok,
    }
}

fn first_named_provider(tok: &str) -> Option<String> {
    tight_provider_re()
        .captures(tok)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .filter(|name| !is_generic_reference(name))
}

/// 从文本抽取医院/医学中心名。
///
/// ## 三层根因,少修一层就抽不出来
///
/// 1. **部首字形。** 生成 corpus 的字体把常用字映射到部首码位,`pdf-extract` 于是
///    吐出 `四 川 ⼤ 学 华 ⻄ 医 院`(`⼤` U+2F24、`⻄` U+2EC4)。这些码位掉在
///    `\x{4e00}-\x{9fa5}` 之外,**任何一条**院名正则都匹配不上。`parser::extract`
///    早就折叠了部首,但抽 provider 读的是 `ocr_result.text` —— 那份文本由
///    `ocr::recognize_pdf_mixed` 产出,**根本不经过** `parser::extract`。所以这里
///    必须自己折一次(`crate::text::normalize_cjk_radicals`)。22 份 demo 里 13 份
///    栽在这一层,而且只在真机上看得见:拿 `pdftotext` 或 `parser::extract` 量,
///    这一层是隐身的。
/// 2. **抬头没被看见。** 文档自报家门的地方是抬头(第一行),被逐字拉开成
///    `北 京 协 和 医 院`,紧凑正则匹配不上,扫描一路滑到页脚签名栏。
/// 3. **页脚那一串切不准。** 见 [`SIGNER_LABELS`]:人名与机构名之间没有词边界。
///
/// ## 取舍:这个字段宁可带噪,也不能为空
///
/// 上一版在第 3 层选了「切不准就返回 `None`」。**这条取舍对化验数值是对的,对这个
/// 字段是错的**,原因是错法的后果不是一回事:
///
/// * 化验数值读错 → 用户据此得出错误的临床结论,危害是实的,宁可空着。
/// * 院名读成 `王涛北京协和医院` → 用户一眼看出多了俩字,照样知道「这次是在协和
///   看的」。而时间线卡片(`archive_screen.dart` 的 `门诊 · {provider}`)存在的
///   全部意义就是回答「在哪家看的」;抽不出来,整张卡就没有理由存在。
///
/// 所以顺位是:**干净的赢,带噪的兜底,只有文档里确实没有医院才是 `None`**。
/// 家庭自测记录那种压根没有机构的文档,仍然、也应该返回 `None`。
pub fn extract_provider(text: &str) -> Option<String> {
    // 第 0 步:折部首。不折,后面三轮全部空手而归(见上「三层根因」第 1 条)。
    let text = crate::text::normalize_cjk_radicals(text);
    // 第一轮:抬头,权威出处。字间空格只是排版,收进结果前去掉。
    if let Some(m) = spaced_provider_re().captures(&text).and_then(|c| c.get(1)) {
        let name: String = m.as_str().chars().filter(|c| !c.is_whitespace()).collect();
        if !is_generic_reference(&name) {
            return Some(name);
        }
    }
    // 第二轮:正文/页脚的紧凑写法,逐 token —— 有自己左边界的候选,干净。
    let (signer_toks, clean_toks): (Vec<&str>, Vec<&str>) = text
        .lines()
        .flat_map(str::split_whitespace)
        .partition(|tok| SIGNER_LABELS.iter().any(|l| tok.contains(l)));
    if let Some(name) = clean_toks.iter().find_map(|tok| first_named_provider(tok)) {
        return Some(name);
    }
    // 第三轮:兜底。只剩签名串了,切不准也要给出名字 —— 带上人名前缀也比空着强。
    signer_toks
        .iter()
        .find_map(|tok| first_named_provider(strip_signer_label(tok)))
}

/// 给定一组文档 id,返回各文档 OCR 文本命中的 provider 名(未去重,用于统计众数)。
fn providers_for_doc_ids(
    conn: &rusqlite::Connection,
    ids: &[i64],
) -> Result<Vec<String>, MedmeError> {
    if ids.is_empty() {
        return Ok(Vec::new());
    }
    let placeholders = std::iter::repeat_n("?", ids.len())
        .collect::<Vec<_>>()
        .join(",");
    let sql = format!("SELECT text FROM ocr_result WHERE document_id IN ({placeholders})");
    let mut stmt = conn.prepare(&sql)?;
    let params: Vec<&dyn rusqlite::ToSql> = ids.iter().map(|i| i as &dyn rusqlite::ToSql).collect();
    let rows = stmt.query_map(params.as_slice(), |r| r.get::<_, String>(0))?;
    let mut out = Vec::new();
    for r in rows {
        let text = r?;
        if let Some(p) = extract_provider(&text) {
            out.push(p);
        }
    }
    Ok(out)
}

/// 组内 provider 众数(第一个达到最高频次的);transferred = 是否出现 ≥2 家不同医院。
fn provider_summary(providers: &[String]) -> (Option<String>, bool) {
    use std::collections::HashMap;
    let mut order: Vec<&String> = Vec::new();
    let mut counts: HashMap<&String, usize> = HashMap::new();
    for p in providers {
        if !counts.contains_key(p) {
            order.push(p);
        }
        *counts.entry(p).or_insert(0) += 1;
    }
    let transferred = order.len() >= 2;
    let mut best: Option<&String> = None;
    let mut best_count = 0usize;
    for p in &order {
        let c = counts[*p];
        if c > best_count {
            best_count = c;
            best = Some(p);
        }
    }
    (best.cloned(), transferred)
}

/// 这个 `doc_type`(数据库原始字符串,`DocType::as_str()` 的取值)能不能**单独**
/// 撑起 [`Vault::rebuild_encounters`] 同日聚合(§2)里的一次门诊/急诊。
///
/// 用**允许清单**而不是排除清单:只有 `classify()` 里那几个真正代表"去看过病"的
/// 分支——化验/影像/出院小结/处方/病历/病理/手术——才算数。这样以后 `DocType`
/// 再加新变体,默认就是"不算数"(不必每加一种新类型就记得回来把它列进排除名单,
/// `rebuild_encounters` 也不会替它瞎担保一次就诊)。
///
/// **不算数的四类,和为什么:**
/// - `note` —— 患者自己写的笔记,不是病历原文;
/// - `other` —— `classify()` 明确判定"不是病历"的东西(目前只有家庭自测记录:
///   血压/血糖/体温监测关键词命中的那几行,见 `parser::classify`);
/// - `self_measurement` —— 手动录入的自测数值(`Vault::add_self_measurement`),
///   和 `other` 同一件事,只是从「记录」表单进来而不是从导入的原件解析出来;
/// - `unknown` —— 分类器完全没把握。包成"门诊"等于替它担保了一个我们其实
///   不知道的结论,比诚实地留着"待归类"更容易误导人。
///
/// **但这四类都能搭车**——同一天只要还有至少一份下面这几个真正的锚点文档,这天
/// 就是一次真实就诊,笔记/自测记录跟着一起归进去合情合理(比如就诊当天顺手记的
/// 笔记)。所以判据是"这一天有没有锚点",不是逐份文档各自判断:见调用处
/// (`rebuild_encounters` 第 2 步)的完整说明,以及
/// `apps/mobile_flutter/rust/src/api/vault_projections.rs` 里「复制给医生」纯文本
/// 过滤笔记那段——那段过滤和这里是两回事:这里管"建不建就诊组",那段管"笔记原文
/// 上不上医生看的纯文本",两者互不依赖,不会重复过滤。
fn is_encounter_anchor(doc_type: &str) -> bool {
    matches!(
        doc_type,
        "lab_report"
            | "imaging_report"
            | "discharge_summary"
            | "prescription"
            | "clinical_note"
            | "pathology"
            | "surgery"
    )
}

#[derive(Debug, Clone)]
pub struct TimelineEntry {
    pub document_id: i64,
    pub doc_date: Option<DateTime<Utc>>,
    pub doc_date_end: Option<DateTime<Utc>>,
    pub doc_type: DocType,
    pub title: Option<String>,
}

impl Vault {
    pub fn search(&self, query: &str, limit: usize) -> Result<Vec<SearchHit>, MedmeError> {
        // 把每个 token 包成 FTS5 字面短语("...",内部引号翻倍),并丢弃纯标点 token,
        // 使 '-'/':'/'"'/'(' 等运算符字符被当作字面量,原始用户输入不会触发 FTS5 语法错误。
        let match_q: String = crate::tokenize::tokenize(query)
            .split_whitespace()
            .filter(|t| t.chars().any(|c| c.is_alphanumeric()))
            .map(|t| format!("\"{}\"", t.replace('"', "\"\"")))
            .collect::<Vec<_>>()
            .join(" ");
        if match_q.is_empty() {
            return Ok(vec![]);
        }
        let mut stmt = self.conn().prepare(
            "SELECT document_id, title, snippet(document_fts, 1, '[', ']', '…', 12) AS snip
             FROM document_fts WHERE document_fts MATCH ?1 LIMIT ?2",
        )?;
        let rows = stmt.query_map(rusqlite::params![match_q, limit as i64], |r| {
            Ok(SearchHit {
                document_id: r.get(0)?,
                title: r.get(1)?, // FTS 里存的是分词后的 title;仅作展示提示
                snippet: r.get(2)?,
            })
        })?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    }

    pub fn timeline(&self) -> Result<Vec<TimelineEntry>, MedmeError> {
        let mut stmt = self.conn().prepare(
            "SELECT id, doc_date, doc_date_end, doc_type, title FROM document
             ORDER BY doc_date IS NULL, doc_date DESC, id DESC",
        )?;
        let rows = stmt.query_map([], |r| {
            let date_s: Option<String> = r.get(1)?;
            let date_end_s: Option<String> = r.get(2)?;
            Ok(TimelineEntry {
                document_id: r.get(0)?,
                doc_date: date_s.map(parse_dt),
                doc_date_end: date_end_s.map(parse_dt),
                doc_type: DocType::from_str(&r.get::<_, String>(3)?),
                title: r.get(4)?,
            })
        })?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    }

    /// 该 source_file 是否已建立 document(用于判断是否需要补索引)。
    pub fn has_document(&self, source_file_id: i64) -> Result<bool, MedmeError> {
        let n: i64 = self.conn().query_row(
            "SELECT COUNT(*) FROM document WHERE source_file_id = ?1",
            [source_file_id],
            |r| r.get(0),
        )?;
        Ok(n > 0)
    }

    pub fn document_by_id(&self, id: i64) -> Result<Option<Document>, MedmeError> {
        let row = self
            .conn()
            .query_row(
                &format!("SELECT {DOCUMENT_COLUMNS} FROM document WHERE id = ?1"),
                [id],
                row_to_document,
            )
            .optional()?;
        Ok(row)
    }

    /// 复用 `document_by_id` 的列顺序;`cond` 是不带 WHERE 的谓词片段(如 "encounter_id = ?1")。
    pub(crate) fn documents_where(
        &self,
        cond: &str,
        params: &[&dyn rusqlite::ToSql],
    ) -> Result<Vec<Document>, MedmeError> {
        let mut stmt = self.conn().prepare(&format!(
            "SELECT {DOCUMENT_COLUMNS} FROM document WHERE {cond}
             ORDER BY doc_date IS NULL, doc_date DESC, id DESC"
        ))?;
        let rows = stmt.query_map(params, row_to_document)?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    }

    /// Look up the (unique, per v0.1) document for a source file — used by
    /// `add_document` to return the materialized row after appending its event,
    /// and by the mobile FFI to report the ingested document id (review queue).
    pub fn document_by_source_file_id(
        &self,
        source_file_id: i64,
    ) -> Result<Option<Document>, MedmeError> {
        Ok(self
            .documents_where("source_file_id = ?1", &[&source_file_id])?
            .into_iter()
            .next())
    }

    /// 删除一份文档:追加 [`Event::DocumentDeleted`] 事件 → 重放 → 重算就诊分组。
    /// **原始字节留在 CAS**(只移除派生投影,Raw Never Dies + 同步安全)。文档不存在
    /// (已删)→ `Ok(())`(no-op)。删除作为事件同步,各端重放后一致。
    pub fn delete_document(&self, doc_id: i64) -> Result<(), MedmeError> {
        let source_file_hash: Option<String> = self
            .conn()
            .query_row(
                "SELECT sf.content_hash FROM document d
                 JOIN source_file sf ON d.source_file_id = sf.id WHERE d.id = ?1",
                [doc_id],
                |r| r.get(0),
            )
            .optional()?;
        let Some(hash) = source_file_hash else {
            return Ok(()); // 已经不在了
        };
        self.append_event(crate::event::Event::DocumentDeleted {
            source_file_hash: hash,
            deleted_at: Self::now_rfc3339(),
        })?;
        self.materialize()?;
        self.rebuild_encounters()?;
        Ok(())
    }

    pub fn rebuild_encounters(&self) -> Result<(), MedmeError> {
        use std::collections::HashSet;
        let tx = self.conn().unchecked_transaction()?;
        tx.execute("UPDATE document SET encounter_id = NULL", [])?;
        tx.execute("DELETE FROM encounter", [])?;
        // load docs sorted by doc_date (NULLs last)
        // (id, doc_type, doc_date, doc_date_end, title)
        type DocRow = (i64, String, Option<String>, Option<String>, Option<String>);
        let docs: Vec<DocRow> = {
            let mut stmt = tx.prepare(
                "SELECT id, doc_type, doc_date, doc_date_end, title FROM document
                 ORDER BY doc_date IS NULL, doc_date ASC, id ASC",
            )?;
            let rows = stmt.query_map([], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
            })?;
            let mut v = Vec::new();
            for x in rows {
                v.push(x?);
            }
            v
        };
        let now = Self::now_rfc3339();
        let mut assigned: HashSet<i64> = HashSet::new();

        // helper: parse rfc3339 -> DateTime
        let parse = |s: &Option<String>| {
            s.as_ref()
                .and_then(|x| chrono::DateTime::parse_from_rfc3339(x).ok())
                .map(|d| d.with_timezone(&chrono::Utc))
        };

        // 1) 住院:每个 discharge_summary 带区间 → inpatient 窗;区间内文档归入
        for (id, dtype, dd, dde, _t) in &docs {
            if dtype != "discharge_summary" {
                continue;
            }
            let (Some(start), Some(end)) = (parse(dd), parse(dde)) else {
                continue;
            };
            let _ = id;
            // 先收集区间内(且未被更早住院窗占用)的文档 id,再统计 provider,最后一次性写入
            let mut member_ids: Vec<i64> = Vec::new();
            for (id2, _dt2, dd2, _dde2, _t2) in &docs {
                if assigned.contains(id2) {
                    continue;
                }
                if let Some(date2) = parse(dd2) {
                    if date2 >= start && date2 <= end {
                        member_ids.push(*id2);
                        assigned.insert(*id2);
                    }
                }
            }
            let providers = providers_for_doc_ids(&tx, &member_ids)?;
            let (provider, transferred) = provider_summary(&providers);
            let mut title = format!(
                "住院 · {} → {}",
                start.format("%Y-%m-%d"),
                end.format("%Y-%m-%d")
            );
            if transferred {
                title.push_str(" · 转院");
            }
            tx.execute(
                "INSERT INTO encounter (kind, provider, start_date, end_date, title, transferred, created_at) VALUES ('inpatient', ?1, ?2, ?3, ?4, ?5, ?6)",
                rusqlite::params![provider, start.to_rfc3339(), end.to_rfc3339(), title, transferred, now],
            )?;
            let enc_id = tx.last_insert_rowid();
            for id2 in &member_ids {
                tx.execute(
                    "UPDATE document SET encounter_id = ?1 WHERE id = ?2",
                    rusqlite::params![enc_id, id2],
                )?;
            }
        }

        // 2) 同日聚合:剩余有日期文档按天分组
        //
        // 只把有日期的文档扔进按天分桶——这一步本身不看 `doc_type`,笔记/自测记录/
        // 待归类文档一样进桶,好让它们在"这天还有别的锚点文档"时能搭车归进同一个
        // 就诊组(design 见 `is_encounter_anchor` 文档)。真正的判断在分桶之后:
        // 一天里有没有至少一份 `is_encounter_anchor` 认可的文档,没有就不建这次
        // "就诊",桶里的文档全部留 `encounter_id = NULL`——`load_archive` /
        // `standalone_documents` 会把它们当独立文档条目照常显示在时间线上,
        // 不会从档案里消失,只是不再冒充一次门诊/急诊。
        use std::collections::BTreeMap;
        let mut byday: BTreeMap<String, Vec<(i64, bool, bool)>> = BTreeMap::new(); // day -> (doc_id, is_emergency_by_title, is_anchor)
        for (id, dtype, dd, _dde, title) in &docs {
            if assigned.contains(id) {
                continue;
            }
            let Some(date) = parse(dd) else {
                continue;
            };
            let day = date.format("%Y-%m-%d").to_string();
            let emerg = title
                .as_deref()
                .map(|t| t.contains("急诊"))
                .unwrap_or(false);
            byday
                .entry(day)
                .or_default()
                .push((*id, emerg, is_encounter_anchor(dtype)));
        }
        for (day, group) in byday {
            // 全天没有一份锚点文档 → 这天不构成"就诊",跳过建组,文档保持独立。
            if !group.iter().any(|(_, _, anchor)| *anchor) {
                continue;
            }
            let emergency = group.iter().any(|(_, e, _)| *e);
            let kind = if emergency { "emergency" } else { "outpatient" };
            let label = if emergency { "急诊" } else { "门诊" };
            let start = format!("{day}T00:00:00+00:00");
            let member_ids: Vec<i64> = group.iter().map(|(id, _, _)| *id).collect();
            let providers = providers_for_doc_ids(&tx, &member_ids)?;
            let (provider, transferred) = provider_summary(&providers);
            let mut title = format!("{label} · {day}");
            if transferred {
                title.push_str(" · 转院");
            }
            tx.execute(
                "INSERT INTO encounter (kind, provider, start_date, end_date, title, transferred, created_at) VALUES (?1, ?2, ?3, NULL, ?4, ?5, ?6)",
                rusqlite::params![kind, provider, start, title, transferred, now],
            )?;
            let enc_id = tx.last_insert_rowid();
            for id in member_ids {
                tx.execute(
                    "UPDATE document SET encounter_id = ?1 WHERE id = ?2",
                    rusqlite::params![enc_id, id],
                )?;
            }
        }
        // 3) 无日期文档保持 encounter_id NULL
        tx.commit()?;
        Ok(())
    }

    pub fn encounters_with_docs(&self) -> Result<Vec<(Encounter, Vec<Document>)>, MedmeError> {
        let mut stmt = self.conn().prepare(
            "SELECT id, kind, provider, start_date, end_date, title, transferred, created_at FROM encounter
             ORDER BY start_date IS NULL, start_date DESC, id DESC",
        )?;
        let encs: Vec<Encounter> = stmt
            .query_map([], |r| {
                Ok(Encounter {
                    id: r.get(0)?,
                    kind: EncounterKind::from_str(&r.get::<_, String>(1)?),
                    provider: r.get(2)?,
                    start_date: r.get::<_, Option<String>>(3)?.map(parse_dt),
                    end_date: r.get::<_, Option<String>>(4)?.map(parse_dt),
                    title: r.get(5)?,
                    transferred: r.get::<_, i64>(6)? != 0,
                    created_at: parse_dt(r.get::<_, String>(7)?),
                })
            })?
            .collect::<Result<_, _>>()?;
        let mut out = Vec::new();
        for e in encs {
            let docs = self.documents_where("encounter_id = ?1", &[&e.id])?;
            out.push((e, docs));
        }
        Ok(out)
    }

    pub fn standalone_documents(&self) -> Result<Vec<Document>, MedmeError> {
        self.documents_where("encounter_id IS NULL", &[])
    }

    pub fn source_file_by_id(&self, id: i64) -> Result<Option<SourceFile>, MedmeError> {
        let row = self
            .conn()
            .query_row(
                "SELECT id, content_hash, original_name, mime_type, byte_size, storage_path, imported_at
                 FROM source_file WHERE id = ?1",
                [id],
                |r| {
                    Ok(SourceFile {
                        id: r.get(0)?,
                        content_hash: r.get(1)?,
                        original_name: r.get(2)?,
                        mime_type: r.get(3)?,
                        byte_size: r.get(4)?,
                        storage_path: r.get(5)?,
                        imported_at: parse_dt(r.get::<_, String>(6)?),
                    })
                },
            )
            .optional()?;
        Ok(row)
    }

    /// 该文档已经落库的 OCR 页码集合(升序)。配合 `document.page_count` 就能算出
    /// 「哪些页仍然缺文本」——reindex 补页(`pipeline::reindex_existing_document`)
    /// 用它判断该重试哪些页、以及重试后是否补完了。
    pub fn ocr_page_numbers(&self, document_id: i64) -> Result<Vec<i32>, MedmeError> {
        let mut stmt = self.conn().prepare(
            "SELECT page_no FROM ocr_result WHERE document_id = ?1 ORDER BY page_no ASC",
        )?;
        let rows = stmt.query_map([document_id], |r| r.get::<_, i32>(0))?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    }

    pub fn ocr_text(&self, document_id: i64) -> Result<String, MedmeError> {
        let mut stmt = self
            .conn()
            .prepare("SELECT text FROM ocr_result WHERE document_id = ?1 ORDER BY page_no ASC")?;
        let rows = stmt.query_map([document_id], |r| r.get::<_, String>(0))?;
        let mut parts = Vec::new();
        for r in rows {
            parts.push(r?);
        }
        Ok(parts.join("\n"))
    }

    /// 所有 OCR 文本(用于派生病人档案等跨文档聚合)。
    pub fn all_ocr_texts(&self) -> Result<Vec<String>, MedmeError> {
        let mut stmt = self.conn().prepare("SELECT text FROM ocr_result")?;
        let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    }

    /// 文档的 OCR 置信度:取各页非空 confidence 的最小值(最保守 —— 有一页差就
    /// 提示)。若所有页均无 confidence(如 native 文本层文档),返回 None。
    pub fn ocr_confidence(&self, document_id: i64) -> Result<Option<f32>, MedmeError> {
        let v: Option<f32> = self.conn().query_row(
            "SELECT MIN(confidence) FROM ocr_result WHERE document_id = ?1 AND confidence IS NOT NULL",
            [document_id],
            |r| r.get(0),
        )?;
        Ok(v)
    }

    /// 文档的 OCR 后端(如 "onnx"/"native"/"vlm"):取该文档 ocr_result 的第一条
    /// 记录(按 page_no)。无 ocr_result 行时返回 None。
    pub fn ocr_backend(&self, document_id: i64) -> Result<Option<String>, MedmeError> {
        let row = self
            .conn()
            .query_row(
                "SELECT backend FROM ocr_result WHERE document_id = ?1 ORDER BY page_no ASC LIMIT 1",
                [document_id],
                |r| r.get::<_, String>(0),
            )
            .optional()?;
        Ok(row)
    }
}

#[cfg(test)]
mod tests {
    use crate::query::extract_provider;
    use crate::types::{NewDocument, NewOcr};
    use crate::Vault;
    use crate::{DocType, EncounterKind, OcrBackendKind};

    fn seed(v: &Vault, title: &str, text: &str, date: Option<&str>) {
        let imp = v.import(title, "text/plain", text.as_bytes()).unwrap();
        let doc_date = date.map(|d| {
            chrono::DateTime::parse_from_rfc3339(d)
                .unwrap()
                .with_timezone(&chrono::Utc)
        });
        let doc = v
            .add_document(NewDocument {
                source_file_id: imp.source_file.id,
                doc_type: DocType::LabReport,
                doc_date,
                doc_date_end: None,
                title: Some(title.into()),
                language: Some("mixed".into()),
                page_count: 1,
            })
            .unwrap();
        v.add_ocr(NewOcr {
            document_id: doc.id,
            page_no: 1,
            backend: OcrBackendKind::Native,
            model_version: "text-layer".into(),
            text: text.into(),
            confidence: None,
        })
        .unwrap();
    }

    #[test]
    fn search_matches_chinese_and_english() {
        let dir = tempfile::tempdir().unwrap();
        let v = Vault::open(dir.path()).unwrap();
        seed(
            &v,
            "血常规",
            "肌酐 Creatinine 120 升高",
            Some("2023-05-01T00:00:00Z"),
        );
        seed(
            &v,
            "用药单",
            "美托洛尔 Metoprolol 25mg",
            Some("2024-01-02T00:00:00Z"),
        );

        assert_eq!(v.search("Creatinine", 10).unwrap().len(), 1);
        assert_eq!(v.search("肌酐", 10).unwrap().len(), 1);
        assert_eq!(v.search("Metoprolol", 10).unwrap().len(), 1);
        assert_eq!(v.search("nonexistent", 10).unwrap().len(), 0);
    }

    #[test]
    fn search_handles_fts5_special_chars_gracefully() {
        let dir = tempfile::tempdir().unwrap();
        let v = Vault::open(dir.path()).unwrap();
        seed(
            &v,
            "炎症",
            "C-reactive protein 反应蛋白 升高",
            Some("2023-05-01T00:00:00Z"),
        );

        // 连字符查询过去会报 Sqlite 错误;现在应正常命中
        let hits = v.search("C-reactive", 10).unwrap();
        assert_eq!(hits.len(), 1);
        // 杂散引号 / 冒号 / 括号:不得 panic 或返回 Err
        assert!(v.search("\"unterminated", 10).is_ok());
        assert!(v.search("col:val", 10).is_ok());
        assert!(v.search("a AND (b", 10).is_ok());
        // 纯标点:短路返回空
        assert!(v.search("---", 10).unwrap().is_empty());
    }

    #[test]
    fn timeline_orders_desc_nulls_last() {
        let dir = tempfile::tempdir().unwrap();
        let v = Vault::open(dir.path()).unwrap();
        seed(&v, "old", "a", Some("2023-05-01T00:00:00Z"));
        seed(&v, "new", "b", Some("2024-01-02T00:00:00Z"));
        seed(&v, "undated", "c", None);

        let t = v.timeline().unwrap();
        assert_eq!(t.len(), 3);
        assert_eq!(t[0].title.as_deref(), Some("new"));
        assert_eq!(t[1].title.as_deref(), Some("old"));
        assert!(t[2].doc_date.is_none()); // NULL 最后
    }

    #[test]
    fn reads_document_source_and_ocr_text() {
        let dir = tempfile::tempdir().unwrap();
        let v = Vault::open(dir.path()).unwrap();
        seed(
            &v,
            "血常规",
            "肌酐 Creatinine 120",
            Some("2023-05-01T00:00:00Z"),
        );

        let doc = v.timeline().unwrap()[0].clone();
        let full = v.document_by_id(doc.document_id).unwrap().unwrap();
        assert_eq!(full.title.as_deref(), Some("血常规"));

        let sf = v.source_file_by_id(full.source_file_id).unwrap().unwrap();
        assert_eq!(sf.original_name, "血常规");

        let text = v.ocr_text(doc.document_id).unwrap();
        assert!(text.contains("Creatinine"));

        // 不存在的 id → None / 空
        assert!(v.document_by_id(99999).unwrap().is_none());
        assert!(v.source_file_by_id(99999).unwrap().is_none());
        assert_eq!(v.ocr_text(99999).unwrap(), "");
    }

    #[test]
    fn ocr_confidence_is_min_across_pages_and_backend_is_first_page() {
        let dir = tempfile::tempdir().unwrap();
        let v = Vault::open(dir.path()).unwrap();
        let imp = v.import("scan.png", "image/png", b"fake-bytes").unwrap();
        let doc = v
            .add_document(NewDocument {
                source_file_id: imp.source_file.id,
                doc_type: DocType::LabReport,
                doc_date: None,
                doc_date_end: None,
                title: Some("scan.png".into()),
                language: None,
                page_count: 2,
            })
            .unwrap();
        v.add_ocr(NewOcr {
            document_id: doc.id,
            page_no: 1,
            backend: OcrBackendKind::Onnx,
            model_version: "ppocr-v5".into(),
            text: "page one".into(),
            confidence: Some(0.92),
        })
        .unwrap();
        v.add_ocr(NewOcr {
            document_id: doc.id,
            page_no: 2,
            backend: OcrBackendKind::Onnx,
            model_version: "ppocr-v5".into(),
            text: "page two, blurry".into(),
            confidence: Some(0.41),
        })
        .unwrap();

        // 最保守:取各页最小值,而非平均。
        assert_eq!(v.ocr_confidence(doc.id).unwrap(), Some(0.41));
        assert_eq!(v.ocr_backend(doc.id).unwrap(), Some("onnx".to_string()));

        // 无 OCR 行(如 native/无文本层)→ None。
        assert_eq!(v.ocr_confidence(99999).unwrap(), None);
        assert_eq!(v.ocr_backend(99999).unwrap(), None);

        // 全部 confidence 均为 NULL(如 native 文本层文档)→ None。
        let imp2 = v.import("native.txt", "text/plain", b"hello").unwrap();
        let doc2 = v
            .add_document(NewDocument {
                source_file_id: imp2.source_file.id,
                doc_type: DocType::Unknown,
                doc_date: None,
                doc_date_end: None,
                title: Some("native.txt".into()),
                language: None,
                page_count: 1,
            })
            .unwrap();
        v.add_ocr(NewOcr {
            document_id: doc2.id,
            page_no: 1,
            backend: OcrBackendKind::Native,
            model_version: "text-layer".into(),
            text: "hello".into(),
            confidence: None,
        })
        .unwrap();
        assert_eq!(v.ocr_confidence(doc2.id).unwrap(), None);
        assert_eq!(v.ocr_backend(doc2.id).unwrap(), Some("native".to_string()));
    }

    #[test]
    fn has_document_reflects_indexing() {
        let dir = tempfile::tempdir().unwrap();
        let v = Vault::open(dir.path()).unwrap();
        let imp = v.import("x.txt", "text/plain", b"hello").unwrap();
        assert!(!v.has_document(imp.source_file.id).unwrap()); // 存了但未建 document
        v.add_document(crate::types::NewDocument {
            source_file_id: imp.source_file.id,
            doc_type: crate::DocType::Unknown,
            doc_date: None,
            doc_date_end: None,
            title: None,
            language: None,
            page_count: 1,
        })
        .unwrap();
        assert!(v.has_document(imp.source_file.id).unwrap());
    }

    /// `ocr_page_numbers` 是 `pipeline::reindex_existing_document` 判断"该补哪些
    /// 页"的唯一依据——必须如实反映当前落库的页,升序,建档但没有任何一页
    /// OCR 成功时返回空(而不是 panic 或返回 `page_count` 撑出来的假页码)。
    #[test]
    fn ocr_page_numbers_reflects_only_pages_actually_stored() {
        let dir = tempfile::tempdir().unwrap();
        let v = Vault::open(dir.path()).unwrap();
        let imp = v.import("x.pdf", "application/pdf", b"pdfbytes").unwrap();
        let doc = v
            .add_document(NewDocument {
                source_file_id: imp.source_file.id,
                doc_type: DocType::LabReport,
                doc_date: None,
                doc_date_end: None,
                title: None,
                language: None,
                page_count: 3,
            })
            .unwrap();
        // 建档但还没有任何一页 OCR 成功:空,不是 [1,2,3]。
        assert_eq!(v.ocr_page_numbers(doc.id).unwrap(), Vec::<i32>::new());

        // 乱序写入第 3、1 页,验证返回值升序而不是插入顺序。
        for page_no in [3, 1] {
            v.add_ocr(NewOcr {
                document_id: doc.id,
                page_no,
                backend: OcrBackendKind::Native,
                model_version: "text-layer".into(),
                text: format!("page {page_no}"),
                confidence: None,
            })
            .unwrap();
        }
        assert_eq!(v.ocr_page_numbers(doc.id).unwrap(), vec![1, 3]);
    }

    #[test]
    fn rebuild_groups_by_time() {
        let dir = tempfile::tempdir().unwrap();
        let v = Vault::open(dir.path()).unwrap();
        // 住院:入院-出院区间 + 区间内一份化验
        let d = |s: &str| {
            chrono::DateTime::parse_from_rfc3339(s)
                .unwrap()
                .with_timezone(&chrono::Utc)
        };
        let mk = |v: &Vault, dt: DocType, start: &str, end: Option<&str>, title: &str| {
            let imp = v.import(title, "text/plain", title.as_bytes()).unwrap();
            v.add_document(crate::types::NewDocument {
                source_file_id: imp.source_file.id,
                doc_type: dt,
                doc_date: Some(d(start)),
                doc_date_end: end.map(d),
                title: Some(title.into()),
                language: None,
                page_count: 1,
            })
            .unwrap()
            .id
        };
        mk(
            &v,
            DocType::DischargeSummary,
            "2023-04-24T00:00:00Z",
            Some("2023-05-01T00:00:00Z"),
            "出院记录",
        );
        mk(
            &v,
            DocType::LabReport,
            "2023-04-26T00:00:00Z",
            None,
            "住院期间化验",
        );
        mk(
            &v,
            DocType::LabReport,
            "2024-01-15T00:00:00Z",
            None,
            "门诊化验a",
        );
        mk(
            &v,
            DocType::ImagingReport,
            "2024-01-15T00:00:00Z",
            None,
            "门诊影像b",
        );
        v.rebuild_encounters().unwrap();

        let groups = v.encounters_with_docs().unwrap();
        // 住院组含 2 份(出院记录 + 区间内化验),门诊组含同日 2 份
        let inpatient = groups
            .iter()
            .find(|(e, _)| e.kind == EncounterKind::Inpatient)
            .unwrap();
        assert_eq!(inpatient.1.len(), 2);
        let outpatient = groups
            .iter()
            .find(|(e, _)| e.kind == EncounterKind::Outpatient)
            .unwrap();
        assert_eq!(outpatient.1.len(), 2);
        assert!(v.standalone_documents().unwrap().is_empty());
    }

    /// 复现产品实测发现的 bug:档案里一份**家庭血压自测记录**(`classify()` 判成
    /// `DocType::Other`)被 `rebuild_encounters` 单独包成了一次"门诊"。
    /// 同类的还有笔记、手动录入的自测数值、待归类文档——这四类**单独一天**都不该
    /// 建出就诊组(见 `is_encounter_anchor` 文档),但如果同一天还有一份真正的
    /// 锚点文档(如化验单),就该照旧搭车归进同一个就诊组——这条是历史行为
    /// (`apps/mobile_flutter/rust/src/api/vault_projections.rs` 的"复制给医生"
    /// 过滤笔记那段就是靠这条设计撑住的),不能被这次修复改掉。
    #[test]
    fn rebuild_does_not_wrap_non_visit_doc_types_into_their_own_encounter() {
        let dir = tempfile::tempdir().unwrap();
        let v = Vault::open(dir.path()).unwrap();
        let d = |s: &str| {
            chrono::DateTime::parse_from_rfc3339(s)
                .unwrap()
                .with_timezone(&chrono::Utc)
        };
        let mk = |v: &Vault, dt: DocType, start: &str, title: &str| {
            let imp = v.import(title, "text/plain", title.as_bytes()).unwrap();
            v.add_document(crate::types::NewDocument {
                source_file_id: imp.source_file.id,
                doc_type: dt,
                doc_date: Some(d(start)),
                doc_date_end: None,
                title: Some(title.into()),
                language: None,
                page_count: 1,
            })
            .unwrap()
            .id
        };

        // 四份"单独一天、没有别的文档陪着"的非就诊文档,日期各不相同。
        let other_id = mk(
            &v,
            DocType::Other,
            "2026-04-30T00:00:00Z",
            "血压记录_家庭监测",
        );
        let note_id = mk(&v, DocType::Note, "2026-05-01T00:00:00Z", "笔记");
        let self_measurement_id = mk(
            &v,
            DocType::SelfMeasurement,
            "2026-05-02T00:00:00Z",
            "自测心率",
        );
        let unknown_id = mk(&v, DocType::Unknown, "2026-05-03T00:00:00Z", "待归类");

        // 混合一天:笔记 + 真正的锚点文档(化验单)—— 应该照旧搭车归进同一个就诊组。
        let lab_id = mk(&v, DocType::LabReport, "2026-05-10T00:00:00Z", "门诊化验");
        let riding_note_id = mk(&v, DocType::Note, "2026-05-10T00:00:00Z", "就诊当天的笔记");

        v.rebuild_encounters().unwrap();

        // 只有混合的那一天建出了就诊组,四份孤零零的非就诊文档都没有。
        let groups = v.encounters_with_docs().unwrap();
        assert_eq!(
            groups.len(),
            1,
            "只有 2026-05-10 那天该建出就诊组,实际={:?}",
            groups
                .iter()
                .map(|(e, docs)| (e.title.clone(), docs.len()))
                .collect::<Vec<_>>()
        );
        let (encounter, docs) = &groups[0];
        assert_eq!(encounter.kind, EncounterKind::Outpatient);
        let doc_ids: std::collections::HashSet<i64> = docs.iter().map(|d| d.id).collect();
        assert_eq!(
            doc_ids,
            [lab_id, riding_note_id].into_iter().collect(),
            "笔记该跟着同日的化验单一起搭车进就诊组"
        );

        // 四份非就诊文档都还在——没有从档案里消失,只是没被包成"门诊"。
        let standalone_ids: std::collections::HashSet<i64> = v
            .standalone_documents()
            .unwrap()
            .into_iter()
            .map(|d| d.id)
            .collect();
        assert_eq!(
            standalone_ids,
            [other_id, note_id, self_measurement_id, unknown_id]
                .into_iter()
                .collect(),
            "孤零零的自测记录/笔记/待归类文档该留在独立文档里,不该消失也不该被包成就诊"
        );
    }

    #[test]
    fn rebuild_marks_transfer_across_providers_in_inpatient_window() {
        let dir = tempfile::tempdir().unwrap();
        let v = Vault::open(dir.path()).unwrap();
        let d = |s: &str| {
            chrono::DateTime::parse_from_rfc3339(s)
                .unwrap()
                .with_timezone(&chrono::Utc)
        };
        let mk =
            |v: &Vault, dt: DocType, start: &str, end: Option<&str>, title: &str, text: &str| {
                let imp = v.import(title, "text/plain", title.as_bytes()).unwrap();
                let doc = v
                    .add_document(crate::types::NewDocument {
                        source_file_id: imp.source_file.id,
                        doc_type: dt,
                        doc_date: Some(d(start)),
                        doc_date_end: end.map(d),
                        title: Some(title.into()),
                        language: None,
                        page_count: 1,
                    })
                    .unwrap();
                v.add_ocr(crate::types::NewOcr {
                    document_id: doc.id,
                    page_no: 1,
                    backend: crate::OcrBackendKind::Native,
                    model_version: "text-layer".into(),
                    text: text.into(),
                    confidence: None,
                })
                .unwrap();
                doc.id
            };
        // 住院窗:两份文档来自不同医院 → 转院
        mk(
            &v,
            DocType::DischargeSummary,
            "2023-04-24T00:00:00Z",
            Some("2023-05-01T00:00:00Z"),
            "出院记录",
            "北京协和医院 出院记录",
        );
        mk(
            &v,
            DocType::LabReport,
            "2023-04-26T00:00:00Z",
            None,
            "住院期间化验",
            "上海华山医院 化验单",
        );
        v.rebuild_encounters().unwrap();

        let groups = v.encounters_with_docs().unwrap();
        let (inpatient, _) = groups
            .iter()
            .find(|(e, _)| e.kind == EncounterKind::Inpatient)
            .unwrap();
        assert!(inpatient.transferred, "should be marked as transferred");
        assert!(
            inpatient.provider.as_deref() == Some("北京协和医院")
                || inpatient.provider.as_deref() == Some("上海华山医院"),
            "provider should be one of the two hospitals, got {:?}",
            inpatient.provider
        );
        assert!(
            inpatient.title.as_deref().unwrap_or("").contains("转院"),
            "title should note 转院, got {:?}",
            inpatient.title
        );
    }

    /// 干净的候选永远赢过签名串 —— 这是上一版的成果,原样保留。
    ///
    /// 同一行里 `审核者:王涛 北京协和医院` 的第三个 token 有自己的左边界,不能被
    /// 同行的签名连累;抬头在场时更是抬头说了算,页脚的签名串根本轮不到。
    #[test]
    fn a_clean_candidate_always_beats_the_signature_block() {
        assert_eq!(
            extract_provider("检验者:韩梅 审核者:王涛 北京协和医院").as_deref(),
            Some("北京协和医院")
        );
        // 抬头在场:页脚那串 `王涛四川大学华西医院医疗文书专用章` 一个字都进不来。
        assert_eq!(
            extract_provider(
                "\n四 川 大 学 华 西 医 院\n检验科 生化检验报告单\n\
                 检验者:李梅 审核者:王涛四川大学华西医院医疗文书专用章\n"
            )
            .as_deref(),
            Some("四川大学华西医院")
        );
    }

    /// 只剩签名串时的取舍 —— **这一版和上一版在这里、也只在这里不同**。
    ///
    /// 上一版返回 `None`,理由是「中文姓名与机构名字符类相同,谁也切不准,切不准
    /// 就不能猜」。那条技术结论至今成立(见 [`SIGNER_LABELS`]),但由它推出的取舍
    /// 对**这个字段**是错的,因为两种错法的后果不是一回事:
    ///
    /// * 化验数值读错 → 用户据此得出错误的临床结论,宁可空着;
    /// * 院名多两个字 → 用户一眼看出是医生名,照样知道在哪家看的。而卡片
    ///   (`门诊 · {provider}`)存在的全部意义就是回答这个问题,空着整张卡就废了。
    ///
    /// 所以:切不准也要给,带上人名前缀也接受。
    #[test]
    fn an_unsplittable_signature_yields_a_noisy_name_rather_than_nothing() {
        // 真实语料逐字:demo-dataset 的 PDF 文本层把签名与公章文字连成一串。
        for (line, want) in [
            ("审核者:王涛北京协和医院", "王涛北京协和医院"),
            (
                "报告医师:郑华浙江大学医学院附属第一医院",
                "郑华浙江大学医学院附属第一医院",
            ),
            (
                "检验者:李梅 审核者:王涛四川大学华西医院医疗文书专用章",
                "王涛四川大学华西医院",
            ),
        ] {
            assert_eq!(
                extract_provider(line).as_deref(),
                Some(want),
                "切不准就空着了,而产品要的是「至少要显示医院名」: {line:?}"
            );
        }
        // 标签本身不是院名的一部分:`审核医师` 被切掉,剩下的人名切不掉。
        assert_eq!(
            extract_provider("审核医师:孙立复旦大学附属华山医院").as_deref(),
            Some("孙立复旦大学附属华山医院")
        );
    }

    /// 页脚之所以会被读到,是因为**抬头压根没被看见**:PDF 文本层把抬头逐字拉开
    /// 成 `北 京 协 和 医 院`,紧凑正则匹配不上,扫描就一路滑到签名栏。抬头是文档
    /// 自报家门的地方,必须先在那里找。
    #[test]
    fn a_letter_spaced_letterhead_is_the_first_place_looked() {
        // demo-dataset/corpus/2024-01-15_检验报告_血脂.pdf 的文本层,逐字。
        let doc = "\n\n四 川 大 学 华 西 医 院\n\n检验科 生化检验报告单\n\n\
                   检验者:李梅 审核者:王涛四川大学华西医院医疗文书专用章\n";
        assert_eq!(extract_provider(doc).as_deref(), Some("四川大学华西医院"));
        assert_eq!(
            extract_provider("\n\n北 京 协 和 医 院\n\n神经内科 门诊病历\n").as_deref(),
            Some("北京协和医院")
        );
        assert_eq!(
            extract_provider("国 家 儿 童 医 学 中 心\n").as_deref(),
            Some("国家儿童医学中心")
        );
        // 字间空格是排版,词间空格不是:`王涛 北京协和医院` 不能被当成抬头连读。
        assert_eq!(
            extract_provider("王涛 北京协和医院").as_deref(),
            Some("北京协和医院")
        );
    }

    /// 抬头里夹拉丁字母 —— demo scenarios/2023-04-24_急诊记录_县医院转院.pdf 的
    /// 抬头是 `河 北 省 X X 县 人 民 医 院`。字符类只认汉字时整行匹配不上,扫描
    /// 滑到正文的 `建议立即转上级医院`,就诊卡上印出一句医嘱。
    #[test]
    fn a_letterhead_may_contain_latin_and_digits() {
        assert_eq!(
            extract_provider(
                "河 北 省 X X 县 人 民 医 院\n急诊科 急诊病历\n\
                 病情较重且在溶栓时间窗内,建议立即转上级医院(北京协和医院)进一步诊治。\n"
            )
            .as_deref(),
            Some("河北省XX县人民医院")
        );
    }

    /// PDF 文本层的部首字形 —— **这条是真机上抽不出医院名的头号原因**,而且只有
    /// 走 app 那条真路才看得见:`parser::extract` 折叠了部首,`pdftotext` 也不吐
    /// 部首码位,拿它们量会得出「全好」的假象。app 读的是 `ocr_result.text`,由
    /// `ocr::recognize_pdf_mixed` 产出,不经过 `parser::extract`。
    ///
    /// 逐份的真实回归钉在 `packages/pipeline/tests/demo_provider.rs`(那里才拿得
    /// 到真实 PDF 字节);这里钉住 `extract_provider` 自己必须先折一次部首。
    #[test]
    fn radical_glyphs_in_the_text_layer_do_not_hide_the_hospital() {
        // `⼤` U+2F24(康熙部首,有 NFKC 分解)、`⻄` U+2EC4(部首补充,靠显式映射)。
        assert_eq!(
            extract_provider("四 川 ⼤ 学 华 ⻄ 医 院\n放射科 头颅 MRI 检查报告\n").as_deref(),
            Some("四川大学华西医院")
        );
        // `⺠` U+2EA0:部首补充块,**没有** NFKC 分解 —— 漏进映射表就整份抽不出来。
        assert_eq!(
            extract_provider("河 北 省 X X 县 ⼈ ⺠ 医 院\n急诊科 急诊病历\n").as_deref(),
            Some("河北省XX县人民医院")
        );
        // 紧凑抬头同样得先折(demo 里 2024-05-18 / 2024-06-10 两份是这个形态)。
        assert_eq!(
            extract_provider("四川⼤学华⻄医院 检验科 肾功能+⾎糖检验报告单\n").as_deref(),
            Some("四川大学华西医院")
        );
    }

    /// 医嘱里的泛指不是一家医院。抬头缺席时扫描必然撞上它,撞上就作废 ——
    /// 就诊卡上宁可空着,也不能印半句医嘱。
    #[test]
    fn a_generic_reference_to_some_hospital_is_not_a_name() {
        for line in [
            "病情较重且在溶栓时间窗内,建议立即转上级医院。",
            "转上级医院",
            "请于当地医院复查",
        ] {
            assert_eq!(extract_provider(line), None, "{line:?}");
        }
    }

    /// 紧凑写法的老行为原封不动 —— 这次改动只加左边界与抬头,不动别的。
    #[test]
    fn ordinary_provider_lines_are_unchanged() {
        for (text, want) in [
            ("北京协和医院", "北京协和医院"),
            ("北京协和医院 出院记录", "北京协和医院"),
            ("四川大学华西医院 检验科 生化检验报告单", "四川大学华西医院"),
            (
                "上海交通大学医学院附属瑞金医院 超声医学科 检查报告单",
                "上海交通大学医学院附属瑞金医院",
            ),
            ("独墅湖科教创新区医院化验报告单", "独墅湖科教创新区医院"),
            ("某三甲医院 检验科 甲状腺功能检验报告单", "某三甲医院"),
            // 行尾公章:前面是句号,左边界干净。
            (
                "提示:凝血功能正常,可耐受手术。复旦大学附属华山医院 医疗文书专用章",
                "复旦大学附属华山医院",
            ),
        ] {
            assert_eq!(extract_provider(text).as_deref(), Some(want), "{text:?}");
        }
        assert_eq!(extract_provider("本院 转入我院 医院"), None);
    }

    #[test]
    fn rebuild_is_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let v = Vault::open(dir.path()).unwrap();
        let imp = v.import("门诊化验", "text/plain", b"x").unwrap();
        v.add_document(crate::types::NewDocument {
            source_file_id: imp.source_file.id,
            doc_type: DocType::LabReport,
            doc_date: Some(
                chrono::DateTime::parse_from_rfc3339("2024-01-15T00:00:00Z")
                    .unwrap()
                    .with_timezone(&chrono::Utc),
            ),
            doc_date_end: None,
            title: Some("门诊化验".into()),
            language: None,
            page_count: 1,
        })
        .unwrap();
        v.rebuild_encounters().unwrap();
        v.rebuild_encounters().unwrap(); // 再来一次不应重复
        let n: i64 = v.debug_count("encounter");
        assert_eq!(n, 1);
    }
}
