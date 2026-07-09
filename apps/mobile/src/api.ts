import { invoke } from "@tauri-apps/api/core";
import type {
  TimelineGroup,
  ImportOutcome,
  ShareResult,
  PatientProfile,
} from "./types";

export const api = {
  loadArchive: () => invoke<TimelineGroup[]>("load_archive"),
  ingestFile: (path: string) => invoke<ImportOutcome>("ingest_file", { path }),
  getPatientProfile: () => invoke<PatientProfile>("get_patient_profile"),
  createShare: (expiresDays?: number) =>
    invoke<ShareResult>("create_share", { expiresDays }),
  loadDemoData: () => invoke<number>("load_demo_data"),
  getVaultPath: () => invoke<string>("get_vault_path"),
};
