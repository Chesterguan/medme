import { invoke } from "@tauri-apps/api/core";
import type {
  DocumentSummary,
  SearchResult,
  DocumentDetail,
  ImportOutcome,
  ExportSummary,
} from "./types";

export const api = {
  listTimeline: () => invoke<DocumentSummary[]>("list_timeline"),
  search: (query: string, limit = 30) =>
    invoke<SearchResult[]>("search", { query, limit }),
  getDocument: (id: number) => invoke<DocumentDetail>("get_document", { id }),
  importPaths: (paths: string[]) =>
    invoke<ImportOutcome[]>("import_paths", { paths }),
  readSourceBytes: (id: number) => invoke<number[]>("read_source_bytes", { id }),
  exportVault: (destPath: string) =>
    invoke<ExportSummary>("export_vault", { destPath }),
};
