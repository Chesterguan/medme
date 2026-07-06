export interface DocumentSummary {
  id: number;
  doc_type: string;
  doc_date: string | null; // RFC3339
  doc_date_end: string | null; // RFC3339
  title: string | null;
  page_count: number;
}
export interface SourceFileMeta {
  id: number;
  original_name: string;
  mime_type: string;
  byte_size: number;
  imported_at: string;
}
export interface SearchResult {
  document: DocumentSummary;
  snippet: string;
}
export interface DocumentDetail {
  document: DocumentSummary;
  source_file: SourceFileMeta;
  ocr_text: string;
}
export interface ImportOutcome {
  name: string;
  source_file_id: number;
  status: string;
  doc_type: string | null;
}
export interface ExportSummary {
  file_count: number;
  byte_size: number;
}
export interface PatientProfile {
  name: string | null;
  gender: string | null;
  birth_date: string | null;
  age: string | null;
  record_count: number;
}
