# 008 · Frontend / Tauri · 前端与桌面外壳(Plan C)

> v0.1 桌面前端设计。**网页版不做**(不安全);形态为 Tauri 桌面应用,以后可扩 mobile(Tauri v2)。
> 复用已建好的 `core-model`(Vault)+ `parser`。视图清单与交互底线见 [007_UI_Guidelines](007_UI_Guidelines.md)。

关联:[002_Architecture](002_Architecture.md) · [003_Core_Data_Model](003_Core_Data_Model.md) · [007_UI_Guidelines](007_UI_Guidelines.md)

---

## 1. 架构

```
React (Vite + TS + Tailwind v4 + lucide-react + motion)
        │  仅经 src/api.ts
        ▼
Tauri v2 command (IPC)
        │
        ▼
packages/pipeline::ingest / core-model::Vault   (Rust)
        ▼
SQLite + CAS(既有)
```

- `apps/desktop/` 新增:`src-tauri/`(Rust,依赖 `core-model` + `pipeline`)+ `src/`(React)。
- **UI 只经 `src/api.ts` 取数**——`api.ts` 是唯一封装 `@tauri-apps/api` `invoke` 的地方,其余组件不直接碰 IPC(解耦、易测、将来可替换)。
- **TS 类型手写** `src/types.ts` 镜像下面的 DTO(约 5 个结构)。不上 `ts-rs` 自动生成——面太小,手写更省机械开销;面变大再上。*(ponytail)*
- 启动时在系统 app-data 目录打开/创建 vault,放进 Tauri `State<Mutex<Vault>>`;所有命令借用它。

---

## 2. 必要重构:`packages/pipeline`

当前"导入→存 CAS→抽文本→建 document/ocr"编排写死在 `apps/cli/src/main.rs`。抽出新 crate:

- `packages/pipeline`(依赖 `core-model` + `parser`),导出:
  ```rust
  pub struct IngestOutcome { pub source_file_id: i64, pub name: String, pub status: IngestStatus, pub doc_type: Option<DocType> }
  pub enum IngestStatus { New, Deduped, Backfilled, StoredNoText }
  // New=新文件已索引;Deduped=已存在且已索引;Backfilled=已存在但之前没 document,这次补上;StoredNoText=存了但无文本层
  pub fn ingest(vault: &Vault, path: &Path) -> Result<IngestOutcome, anyhow::Error>;
  ```
  内含既有 CLI 逻辑:`import` → 若 deduped 且 `has_document` 则 `Deduped`;否则 `parser::extract` → `Ok` 建 document+ocr(New/Backfilled)、`Err` 记 `StoredNoText`。
- **CLI 改为调用 `pipeline::ingest`**(消除重复);Tauri `import_paths` 也调它。一条摄入路径,两个前端共用。

---

## 3. Tauri 命令契约(共享 DTO)

DTO(Rust `#[derive(Serialize)]`,TS 手写镜像):

```rust
struct DocumentSummary { id: i64, doc_type: String, doc_date: Option<String>, title: Option<String>, page_count: i32 }
struct SourceFileMeta  { id: i64, original_name: String, mime_type: String, byte_size: i64, imported_at: String }
struct SearchResult    { document: DocumentSummary, snippet: String }       // title 取真实 document.title(非 FTS 分词值)
struct DocumentDetail  { document: DocumentSummary, source_file: SourceFileMeta, ocr_text: String }
struct ImportOutcome   { name: String, source_file_id: i64, status: String, doc_type: Option<String> }
struct ExportSummary   { file_count: i64, byte_size: i64 }
```

命令(`#[tauri::command]`,包住 Vault):

| 命令 | 签名 | 说明 |
|---|---|---|
| `import_paths` | `(paths: Vec<String>) -> Vec<ImportOutcome>` | 逐路径 `pipeline::ingest`;状态映射给 UI |
| `list_timeline` | `() -> Vec<DocumentSummary>` | `Vault::timeline` → summary |
| `search` | `(query: String, limit: usize) -> Vec<SearchResult>` | `Vault::search` 命中后按 document_id **取真实 title**(修复 backlog 的分词 title 问题) |
| `get_document` | `(id: i64) -> DocumentDetail` | document + source_file 元数据 + 拼接各页 OCR 文本 |
| `read_source_bytes` | `(id: i64) -> Vec<u8>` | 读 CAS 原文件字节,供查看器渲染 PDF/图片 |
| `export_vault` | `(dest_path: String) -> ExportSummary` | 打包 `objects/` + JSON 清单(随时可离开) |

**core-model 需新增只读方法**(供命令用,均小):`document_summary(id)`、`source_file_by_id(id)`、`ocr_text(document_id)`(按 page_no 拼接)、`search` 结果的真实 title 由命令层 join(或加 `document_title(id)`)。

---

## 4. 视图(v0.1,按 007 + 设计语言 + 真 logo)

技术栈与视觉参照用户原型(见项目记忆 `medme-ui-design-language`):slate 底 + blue-600 主 + emerald 信任色;`rounded-xl/2xl` 卡片;中文主标 + 英文 mono 副标。侧栏品牌区用真 logo 图形(替换占位 `ShieldCheck`)。

| 视图 | 数据 | 关键交互 |
|---|---|---|
| **Sidebar** | `list_timeline` 计数 | 导航:生命时间线 / 纸质病历导入 / 搜索 / 设置 |
| **Timeline 生命时间线** | `list_timeline` | DocType 配色卡片,按 doc_date 分组、无日期归末;点开→查看器。**v0.1 文档级**(结构化化验/用药待 v0.2) |
| **Import 纸质病历导入** | `import_paths` | 拖拽/选择文件 → 显示每个 新增/去重/已补索引/无文本层 |
| **Search 搜索** | `search` | 输入即搜、片段高亮、点开→查看器 |
| **Document Viewer 查看器** | `get_document` + `read_source_bytes` | 原件(PDF/图片/文本)↔ OCR 文本对照(**溯源**) |
| **Settings 设置** | `export_vault` | vault 路径、导出整库;VLM 后端开关(占位) |

交互底线(007 §2)必须满足:原件永远可达、溯源可视、去重透明、全离线、可访问性基线、可导出带走。

---

## 5. 明确不做(v0.1)

AI 智析 / VaultAssistant(无 AI)· 化验/用药结构化渲染(需 v0.2 `clinical_event`)· 加密(backlog)· 自动更新 · i18n 框架(界面中文为主 + 英文副标即可)· mobile 构建(架构预留,不实现)。

---

## 6. 测试

- **Rust**:`packages/pipeline` 加 `ingest` 单测(New/Deduped/Backfilled/StoredNoText 四状态);命令层薄,靠 pipeline + core-model 既有测试兜底。
- **前端**:不引重测试框架。一个构建冒烟(`pnpm build` / `tsc --noEmit` 通过)+ 手动 E2E 驱动真 app(verify skill):拖入 fixture → 时间线出现 → 搜索命中 → 查看器对照原件。
- ponytail:UI 逻辑测试只在有非平凡纯函数时才写(如日期分组),不为展示组件写测试。

---

## 7. 长期兼容

命令 DTO 是 UI↔Rust 契约,变更需同步 `types.ts`。Vault 数据格式不受前端影响(前端只读写既有 schema)。mobile 扩展时命令层可复用,仅换外壳。
