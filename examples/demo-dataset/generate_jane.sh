#!/usr/bin/env bash
#
# Synthetic **English** course for the generic disease-profile layer
# (2026-10-22 spec §8.2): patient **Doe, Jane** — aortic valve replacement
# 2024-03, invasive pulmonary aspergillosis 2025-06, warfarin dose change
# 2025-01-14, voriconazole discontinued 2025-11-17. Same patient name as
# packages/pipeline/tests/import_bundle.rs; a different patient from 张建国
# (parser) and 李静 (SLE profile) so none of their corpus assertions move.
#
# Every document is written twice, from the same shell variables:
#   <stem>.txt   — the "printed" record (what OCR / the PDF text layer gives)
#   <stem>.json  — the Epic-adapter style sidecar (deid schema 1, labs with
#                  `loinc`, diagnoses with `icd`, meds with `rxnorm`)
# packages/profile/tests/generic_jane.rs runs deid::verify over every pair and
# fails if a sidecar value is not a verbatim substring of its text — so the two
# cannot drift.
#
# Output goes **directly** into packages/profile/testdata/corpus-jane/ (the
# checked-in fixtures). The clinic visits are templated by a function, so
# extract_fixtures.py's heredoc scanner cannot lift them; this script IS the
# fixture generator. Never hand-edit the fixtures — edit here and re-run.
#
# Idempotent. Usage:  bash examples/demo-dataset/generate_jane.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$SCRIPT_DIR/../../packages/profile/testdata/corpus-jane"
mkdir -p "$OUT"
rm -f "$OUT"/*.txt "$OUT"/*.json

echo "== MedMe synthetic Doe, Jane course generator =="
echo "Out: $OUT"

write() { # write <stem> <ext>  (content on stdin)
  cat > "$OUT/$1.$2"
  echo "  [$2] $1"
}

HDR="UF Health Shands Hospital
Patient: Doe, Jane    MRN: 00000000    DOB: 1965-02-11    Sex: F"

# ---------------------------------------------------------------------------
# 2024-03-03 Operative report (surgery) — inside admission 2024-03-01..03-10
# ---------------------------------------------------------------------------
write "2024-03-03_手术记录_UF" txt <<EOF
$HDR
OPERATIVE REPORT
Date of Procedure: 2024-03-03
Preoperative Diagnosis: Severe aortic stenosis (I35.0)
Procedure: Surgical aortic valve replacement with 23 mm bioprosthetic valve
Surgeon: J. Smith, MD
Findings: Heavily calcified trileaflet aortic valve. Valve excised and replaced without complication.
Estimated blood loss: 400 mL.
EOF
write "2024-03-03_手术记录_UF" json <<'EOF'
{"doc_type":"surgery","doc_date":"2024-03-03","labs":[],"meds":[],"diagnoses":[
 {"text":"Severe aortic stenosis","icd":"I35.0"}]}
EOF

# ---------------------------------------------------------------------------
# 2024-03-10 Discharge summary — admission 2024-03-01 → 2024-03-10 (9 days)
# ---------------------------------------------------------------------------
write "2024-03-10_出院记录_UF" txt <<EOF
$HDR
DISCHARGE SUMMARY
Admission Date: 2024-03-01    Discharge Date: 2024-03-10
Discharge Diagnoses:
1. Aortic stenosis, severe, status post surgical aortic valve replacement 2024-03-03 (I35.0)
2. Status post aortic valve replacement (Z95.2)
3. Hypertension

Hospital Course: Admitted with exertional dyspnea. Underwent surgical aortic valve replacement on 2024-03-03. Post-operative course uncomplicated. Anticoagulation started.

Discharge Medications:
Warfarin 5mg daily
Metoprolol 25mg twice daily

Labs at discharge:
INR 2.1 (2.0-3.0)
Creatinine 0.9 mg/dL (0.6-1.2)
BNP 210 pg/mL (0-100) H
EOF
write "2024-03-10_出院记录_UF" json <<'EOF'
{"doc_type":"discharge_summary","doc_date":"2024-03-10",
 "labs":[
  {"name":"INR","value":"2.1","unit":"","ref_low":"2.0","ref_high":"3.0","flag":"","loinc":"6301-6"},
  {"name":"Creatinine","value":"0.9","unit":"mg/dL","ref_low":"0.6","ref_high":"1.2","flag":"","loinc":"2160-0"},
  {"name":"BNP","value":"210","unit":"pg/mL","ref_low":"0","ref_high":"100","flag":"H","loinc":"30934-4"}],
 "meds":[
  {"name":"Warfarin","dose":"5mg","freq":"daily","route":"","rxnorm":"11289"},
  {"name":"Metoprolol","dose":"25mg","freq":"twice daily","route":"","rxnorm":"6918"}],
 "diagnoses":[
  {"text":"Aortic stenosis, severe, status post surgical aortic valve replacement 2024-03-03","icd":"I35.0"},
  {"text":"Status post aortic valve replacement","icd":"Z95.2"},
  {"text":"Hypertension","icd":""}]}
EOF

# ---------------------------------------------------------------------------
# Clinic visits (outpatient), templated. Args:
#   visit <date> <warfarin dose as printed> <inr> <bnp|-> <creat|-> <extra med line|-> <extra sidecar med|-> <dx variant>
# ---------------------------------------------------------------------------
visit() {
  local date="$1" wdose="$2" inr="$3" bnp="$4" crea="$5" extra_line="$6" extra_json="$7" dxv="$8"
  local stem="${date}_门诊病历_UF"
  local dx1 dx1_icd
  if [ "$dxv" = "A" ]; then
    dx1="Presence of prosthetic heart valve"
  else
    dx1="Status post AVR"
  fi
  {
    echo "$HDR"
    echo "OFFICE VISIT — Cardiology Clinic"
    echo "Visit Date: $date"
    echo "Assessment:"
    echo "1. $dx1 (Z95.2)"
    echo "2. Long term (current) use of anticoagulants (Z79.01)"
    echo "3. Hypertension"
    echo ""
    echo "Current Medications:"
    echo "Warfarin $wdose"
    echo "Metoprolol 25mg twice daily"
    echo "Zebrafoam 10mg daily"
    [ "$extra_line" != "-" ] && echo "$extra_line"
    echo ""
    echo "Labs today:"
    echo "INR $inr (2.0-3.0)"
    [ "$bnp" != "-" ] && echo "BNP $bnp pg/mL (0-100)"
    [ "$crea" != "-" ] && echo "Creatinine $crea mg/dL (0.6-1.2)"
    echo ""
    echo "Plan: continue current regimen; recheck INR in 6 weeks."
  } > "$OUT/$stem.txt"
  echo "  [txt] $stem"
  local wd wf
  wd="${wdose% *}"; wf="${wdose##* }"
  {
    echo '{"doc_type":"clinical_note","doc_date":"'"$date"'",'
    echo ' "labs":['
    echo '  {"name":"INR","value":"'"$inr"'","unit":"","ref_low":"2.0","ref_high":"3.0","flag":"","loinc":"6301-6"}'
    [ "$bnp" != "-" ] && echo '  ,{"name":"BNP","value":"'"$bnp"'","unit":"pg/mL","ref_low":"0","ref_high":"100","flag":"","loinc":"30934-4"}'
    [ "$crea" != "-" ] && echo '  ,{"name":"Creatinine","value":"'"$crea"'","unit":"mg/dL","ref_low":"0.6","ref_high":"1.2","flag":"","loinc":"2160-0"}'
    echo ' ],'
    echo ' "meds":['
    echo '  {"name":"Warfarin","dose":"'"$wd"'","freq":"'"$wf"'","route":"","rxnorm":"11289"},'
    echo '  {"name":"Metoprolol","dose":"25mg","freq":"twice daily","route":"","rxnorm":"6918"},'
    echo '  {"name":"Zebrafoam","dose":"10mg","freq":"daily","route":"","rxnorm":""}'
    [ "$extra_json" != "-" ] && echo "  ,$extra_json"
    echo ' ],'
    echo ' "diagnoses":['
    echo '  {"text":"'"$dx1"'","icd":"Z95.2"},'
    echo '  {"text":"Long term (current) use of anticoagulants","icd":"Z79.01"},'
    echo '  {"text":"Hypertension","icd":""}'
    echo ' ]}'
  } > "$OUT/$stem.json"
  echo "  [json] $stem"
}

#      date         warfarin        inr  bnp  crea  extra med line                       extra sidecar med                                                               dx
visit "2024-04-15" "5mg daily"     "2.6" "180" "1.0" "-" "-" A
visit "2024-07-15" "5 mg daily"    "2.3" "-"   "-"   "-" "-" B
visit "2024-10-14" "5mg qd"        "3.4" "150" "1.1" "-" "-" A
visit "2025-01-14" "4mg daily"     "2.2" "-"   "0.9" "-" "-" B
visit "2025-04-14" "4mg daily"     "2.5" "-"   "-"   "-" "-" A
visit "2025-09-15" "4mg daily"     "2.4" "120" "1.0" "Voriconazole 200mg twice daily" '{"name":"Voriconazole","dose":"200mg","freq":"twice daily","route":"","rxnorm":"121243"}' B
visit "2026-03-16" "4mg daily"     "2.7" "-"   "1.0" "Prednisone 5mg daily"           '{"name":"Prednisone","dose":"5mg","freq":"daily","route":"","rxnorm":"8640"}' A
visit "2026-09-14" "4mg daily"     "2.4" "-"   "1.1" "-" "-" B

# ---------------------------------------------------------------------------
# 2025-06-02 ED visit → admission 2025-06-02 → 2025-06-14 (12 days)
# ---------------------------------------------------------------------------
write "2025-06-02_急诊记录_UF" txt <<EOF
$HDR
ED Visit — Emergency Department
Arrival: 2025-06-02 03:40
Chief Complaint: Fever, productive cough, hemoptysis for 4 days.
Assessment: Febrile, hypoxic. Chest X-ray with right upper lobe consolidation. Admit to medicine.
Labs:
WBC 14.2 10*3/uL (4.0-10.0) H
CRP 96 mg/L (0-5) H
EOF
write "2025-06-02_急诊记录_UF" json <<'EOF'
{"doc_type":"clinical_note","doc_date":"2025-06-02",
 "labs":[
  {"name":"WBC","value":"14.2","unit":"10*3/uL","ref_low":"4.0","ref_high":"10.0","flag":"H","loinc":"6690-2"},
  {"name":"CRP","value":"96","unit":"mg/L","ref_low":"0","ref_high":"5","flag":"H","loinc":"1988-5"}],
 "meds":[],"diagnoses":[]}
EOF

write "2025-06-03_影像报告_UF" txt <<EOF
$HDR
CT CHEST WITH CONTRAST
Exam Date: 2025-06-03

FINDINGS: 3.2 cm cavitary nodular opacity in the right upper lobe with surrounding ground-glass halo. No pleural effusion. Prosthetic aortic valve in situ.

IMPRESSION: Cavitary right upper lobe lesion with halo sign, findings consistent with invasive aspergillosis in an immunocompromised host.

Electronically signed by R. Lee, MD 2025-06-03
EOF
write "2025-06-03_影像报告_UF" json <<'EOF'
{"doc_type":"imaging_report","doc_date":"2025-06-03","labs":[],"meds":[],"diagnoses":[]}
EOF

write "2025-06-05_病理报告_UF" txt <<EOF
$HDR
SURGICAL PATHOLOGY REPORT
Specimen: Right upper lobe, bronchoscopic biopsy
Collected: 2025-06-05

FINDINGS: Necrotic lung parenchyma with acute-angle branching septate hyphae invading vessel walls. GMS stain positive.

CONCLUSION: Invasive fungal infection, morphology consistent with Aspergillus species.

Signed by P. Chen, MD
EOF
write "2025-06-05_病理报告_UF" json <<'EOF'
{"doc_type":"pathology","doc_date":"2025-06-05","labs":[],"meds":[],"diagnoses":[]}
EOF

write "2025-06-14_出院记录_UF" txt <<EOF
$HDR
DISCHARGE SUMMARY
Admission Date: 2025-06-02    Discharge Date: 2025-06-14
Discharge Diagnoses:
1. Invasive pulmonary aspergillosis (B44.1)
2. Status post aortic valve replacement (Z95.2)
3. Hypertension

Hospital Course: Admitted from the ED with fever and hemoptysis. CT chest and biopsy confirmed invasive pulmonary aspergillosis. Started on voriconazole with therapeutic drug monitoring. Clinically improved.

Discharge Medications:
Voriconazole 200mg twice daily
Warfarin 4mg daily
Metoprolol 25mg twice daily

Labs at discharge:
Galactomannan 1.8 index (0-0.5) H
CRP 31 mg/L (0-5) H
WBC 9.1 10*3/uL (4.0-10.0)
INR 2.9 (2.0-3.0)
EOF
write "2025-06-14_出院记录_UF" json <<'EOF'
{"doc_type":"discharge_summary","doc_date":"2025-06-14",
 "labs":[
  {"name":"Galactomannan","value":"1.8","unit":"index","ref_low":"0","ref_high":"0.5","flag":"H","loinc":""},
  {"name":"CRP","value":"31","unit":"mg/L","ref_low":"0","ref_high":"5","flag":"H","loinc":"1988-5"},
  {"name":"WBC","value":"9.1","unit":"10*3/uL","ref_low":"4.0","ref_high":"10.0","flag":"","loinc":"6690-2"},
  {"name":"INR","value":"2.9","unit":"","ref_low":"2.0","ref_high":"3.0","flag":"","loinc":"6301-6"}],
 "meds":[
  {"name":"Voriconazole","dose":"200mg","freq":"twice daily","route":"","rxnorm":"121243"},
  {"name":"Warfarin","dose":"4mg","freq":"daily","route":"","rxnorm":"11289"},
  {"name":"Metoprolol","dose":"25mg","freq":"twice daily","route":"","rxnorm":"6918"}],
 "diagnoses":[
  {"text":"Invasive pulmonary aspergillosis","icd":"B44.1"},
  {"text":"Status post aortic valve replacement","icd":"Z95.2"},
  {"text":"Hypertension","icd":""}]}
EOF

# ---------------------------------------------------------------------------
# 2025-08-18 Infectious disease follow-up: galactomannan + CRP trend
# ---------------------------------------------------------------------------
write "2025-08-18_检验报告_UF" txt <<EOF
$HDR
LABORATORY REPORT
Collected: 2025-08-18
Galactomannan 0.6 index (0-0.5) H
CRP 12 mg/L (0-5) H
Voriconazole level 2.4 ug/mL (1.0-5.5)
EOF
write "2025-08-18_检验报告_UF" json <<'EOF'
{"doc_type":"lab_report","doc_date":"2025-08-18",
 "labs":[
  {"name":"Galactomannan","value":"0.6","unit":"index","ref_low":"0","ref_high":"0.5","flag":"H","loinc":""},
  {"name":"CRP","value":"12","unit":"mg/L","ref_low":"0","ref_high":"5","flag":"H","loinc":"1988-5"},
  {"name":"Voriconazole level","value":"2.4","unit":"ug/mL","ref_low":"1.0","ref_high":"5.5","flag":"","loinc":""}],
 "meds":[],"diagnoses":[]}
EOF

# ---------------------------------------------------------------------------
# 2025-11-17 ID clinic: voriconazole discontinued (verbatim), decoys for the stop regex
# ---------------------------------------------------------------------------
write "2025-11-17_门诊病历_UF" txt <<EOF
$HDR
OFFICE VISIT — Infectious Diseases Clinic
Visit Date: 2025-11-17
Assessment:
1. Invasive pulmonary aspergillosis, resolved (B44.1)
d/c summary reviewed.
Patient stopped smoking in 2020.
Voriconazole discontinued after 24 weeks of therapy.
Current Medications:
Warfarin 4mg daily
Metoprolol 25mg twice daily
Labs today:
Galactomannan 0.2 index (0-0.5)
CRP 3 mg/L (0-5)
EOF
write "2025-11-17_门诊病历_UF" json <<'EOF'
{"doc_type":"clinical_note","doc_date":"2025-11-17",
 "labs":[
  {"name":"Galactomannan","value":"0.2","unit":"index","ref_low":"0","ref_high":"0.5","flag":"","loinc":""},
  {"name":"CRP","value":"3","unit":"mg/L","ref_low":"0","ref_high":"5","flag":"","loinc":"1988-5"}],
 "meds":[
  {"name":"Voriconazole","dose":"","freq":"","route":"","rxnorm":"121243"},
  {"name":"Warfarin","dose":"4mg","freq":"daily","route":"","rxnorm":"11289"},
  {"name":"Metoprolol","dose":"25mg","freq":"twice daily","route":"","rxnorm":"6918"}],
 "diagnoses":[
  {"text":"Invasive pulmonary aspergillosis, resolved","icd":"B44.1"}]}
EOF

echo "Done: $(ls "$OUT"/*.txt | wc -l | tr -d ' ') documents."
