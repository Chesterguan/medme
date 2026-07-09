export interface DocumentSummary {
  id: number;
  doc_type: string;
  doc_date: string | null; // RFC3339
  doc_date_end: string | null;
  title: string | null;
  page_count: number;
  slice_count: number | null;
}
export interface EncounterSummary {
  id: number;
  kind: string; // inpatient | outpatient | emergency | exam
  provider: string | null;
  start_date: string | null;
  end_date: string | null;
  title: string | null;
  transferred: boolean;
  doc_count: number;
}
export type TimelineGroup =
  | { group_type: "encounter"; encounter: EncounterSummary; docs: DocumentSummary[] }
  | { group_type: "document"; doc: DocumentSummary };

export interface ImportOutcome {
  name: string;
  source_file_id: number;
  status: string;
  doc_type: string | null;
}
export interface ShareResult {
  passphrase: string;
  record_count: number;
  byte_size: number;
  path: string;
}
export interface PatientProfile {
  name: string | null;
  gender: string | null;
  birth_date: string | null;
  age: string | null;
  record_count: number;
}
