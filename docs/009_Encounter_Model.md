# 009 · Encounter Model · 就诊/事件分组模型

> 把零散文档按"就诊事件"归组,提升时间线可读性与搜索速度。照 OMOP visit_occurrence / MEDS / FHIR Encounter 的收敛做法:**一个 encounter 作分组键,文档/事件挂它的外键**。

关联:[003_Core_Data_Model](003_Core_Data_Model.md) · [005_AI_Principles](005_AI_Principles.md)(v0.2 抽取) · 记忆 `medme-content-aware-rendering`

---

## 1. 决策

- 新增 **`encounter`** 实体(≈ OMOP `visit_occurrence` / FHIR `Encounter`)。
- **`document.encounter_id`** 可空外键(≈ MEDS 可选 `hadm_id` / OMOP 事件表的 `visit_occurrence_id`)。一个文档属于 0 或 1 个 encounter。
- v0.2 的 `clinical_event` 同样加 `encounter_id`(事件回滚到就诊——OMOP 核心原则)。
- encounter 是**派生层**:可由文档重算重建(符合"原始永存 / 派生可重建")。
- **术语(重要)**:"encounter" 只是内部字段名,**UI 永不出现**。展示层用用户熟悉的中文:`inpatient=住院` · `outpatient=门诊` · `emergency=急诊` · `exam=体检`。
- **手术**:是**住院分组内的一份文档**(新增文档类型 `surgery` 手术记录),不是顶层分组类型;它随所属住院一起显示(手术刀图标)。日间手术无住院时可单独成一次就诊。更细的"住院内子事件"嵌套(≈ OMOP `visit_detail`)留 v0.2。

标准依据:[MEDS](https://github.com/Medical-Event-Data-Standard/meds)(扁平事件流 + 可选 encounter ID 列)· [OMOP visit_occurrence](https://build.fhir.org/ig/HL7/fhir-omop-ig/StructureDefinition-VisitOccurrence.html)(每事件挂 visit 外键)· FHIR `Encounter` + `EpisodeOfCare`(分组/按问题归集)。

---

## 2. Schema(迁移 v3,纯加法)

```sql
CREATE TABLE encounter (
    id          INTEGER PRIMARY KEY,
    kind        TEXT NOT NULL,      -- inpatient|outpatient|emergency|exam|other
    provider    TEXT,              -- 医院/机构名
    start_date  TEXT,              -- RFC3339;门诊=当日,住院=入院
    end_date    TEXT,              -- 住院=出院;门诊/单次为 NULL
    title       TEXT,              -- 如 "北京协和医院 · 住院 2023-04-24→05-01"
    created_at  TEXT NOT NULL
);
-- document 加列(v3 ALTER)
ALTER TABLE document ADD COLUMN encounter_id INTEGER REFERENCES encounter(id);
CREATE INDEX idx_document_encounter ON document(encounter_id);
CREATE INDEX idx_encounter_dates ON encounter(start_date);
```

Rust:`Encounter { id, kind: EncounterKind, provider, start_date, end_date, title, created_at }`;`Document` 加 `encounter_id: Option<i64>`。

---

## 3. 分组启发式(v0.1,可重建)—— **时间为主键**

个人拿到手的是**单人**数据,不需要大数据式跨患者消歧,**时间就是最准、最简单的聚合键**。`rebuild_encounters(vault)`:按所有文档的日期重算分组,幂等,导入后调用。

规则(纯时间,不依赖医院匹配):
1. **住院(时间窗,高置信)**:每个 `discharge_summary` 的 `[入院, 出院]`(`doc_date→doc_date_end`)定义一个 `inpatient` 分组;**所有 `doc_date` 落在该区间内的文档**(含 `surgery` 手术记录、化验、影像、用药)归入。
2. **同日聚合**:剩余文档按 `doc_date` **同一天**聚成一次就诊;默认 `outpatient`(门诊),文档类型/文本含急诊线索则 `emergency`。单份也成一次(统一渲染)。
3. **独立**:无日期的文档 `encounter_id = NULL`,时间线单列。
4. **provider(医院名,次级信号)**:从文档文本抽医院名。`encounter.provider` = 组内众数医院。
5. **转院(标清楚)**:若一个就诊窗(尤其住院)内出现 **≥2 家不同医院** → 这是一次**转院**;`encounter` 标记 `transferred=true`,`title` 追加 "· 转院",并保留涉及的医院列表(≈ FHIR EpisodeOfCare 把跨院的一串 encounter 归为一次就诊经历)。时间仍是主键(定窗),provider 是窗内的次级聚合/区分信号。

> ponytail:时间定窗为主;provider 只做窗内标注/转院识别,不改变"按时间聚合"的主逻辑。更强关联(accession、影像↔报告同检查)仍随结构化抽取推进。重算即重建。

---

## 4. 时间线 UX(可读性 + 搜索)

- **encounter = 可展开分组卡**:住院一张卡(`协和 · 住院 · 2023-04-24→05-01 · 6 份`),展开列出内部文档(化验/影像/出院/用药,各带类别图标)。门诊同理。
- **独立文档**:无 encounter 的,按现状单卡显示。
- 时间线按 encounter/文档的日期混排倒序。
- 搜索命中文档时,结果标注其所属 encounter,便于跳转上下文——提升"用户搜索速度"。

---

## 5. 命令契约(增量)

`list_timeline` 从"文档列表"升级为**分组结构**:
```
TimelineGroup =
  | { kind: "encounter", encounter: EncounterSummary, docs: DocumentSummary[] }
  | { kind: "document", doc: DocumentSummary }   // 独立文档
```
`EncounterSummary { id, kind, provider, start_date, end_date, title, doc_count }`。旧的扁平 `list_timeline` 可保留为内部用。

---

## 6. 标准导出映射(future)

- `encounter` → FHIR `Encounter` / OMOP `visit_occurrence`;`kind` → visit concept。
- `document.encounter_id` / `clinical_event.encounter_id` → OMOP 事件表的 `visit_occurrence_id`。
- 导出到 MEDS:每行事件 `(subject, time, code, value…)` 加 `encounter_id` 列。

---

## 7. 阶段

- **v0.1**:encounter 表 + `document.encounter_id` + `rebuild_encounters` 启发式 + 分组时间线 UI。
- **v0.2**:`clinical_event.encounter_id`;抽取带来的强关联(accession、影像↔报告同检查附属);跨 encounter 的化验趋势。
- 附属关系(图像从属于同检查的报告)是 encounter 内更细一层,v0.2 结构化后落地。
