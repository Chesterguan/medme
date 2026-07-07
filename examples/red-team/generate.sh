#!/usr/bin/env bash
# Red-team test corpus generator for MedMe v0.1 ingest pipeline.
# Probes every supported format + adversarial edge cases against parser
# (classify / guess_date / detect_language) and pipeline (ingest status).
# Filenames encode the EXPECTATION so the runner can flag surprises.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/corpus"
rm -rf "$OUT"; mkdir -p "$OUT"

w() { printf '%s\n' "$2" > "$OUT/$1"; }        # w <name> <content>

# ---------- DATE FORMAT red-team (all .txt, discharge/generic bodies) ----------
w "date_iso_ok__expect_2024-07-08.txt"        $'检验报告\n检测日期:2024-07-08\n肌酐 Creatinine 90'
w "date_slash_ok__expect_2024-07-08.txt"      $'检验报告\n采集 2024/07/08 07:52 血清\n血糖 Glucose 5.5'
w "date_cn_ok__expect_2025-03-09.txt"         $'超声报告\n检查日期:2025年3月9日\n脂肪肝'
w "date_labeled_glued__expect_2023-05-01.txt" $'出院记录\n出院日期:2023-05-01科室:神内\n脑梗死'
w "date_dot__GAP_expect_none.txt"             $'检验报告\n日期 2023.05.01\n点分隔日期我们不支持'      # GAP: dots unsupported
w "date_us_mdy__GAP_expect_none.txt"          $'处方\nDate 05-01-2024\nMM-DD-YYYY 美式格式'          # GAP: US order unsupported
w "date_2digit_year__GAP_expect_none.txt"     $'病历\n日期 23-05-01\n两位年份'                        # GAP: 2-digit year
w "date_invalid__expect_none.txt"             $'检验报告\n日期:2023-13-45\n非法月日应被拒'            # validation: reject
w "date_two_dates__probe_first_wins.txt"      $'出院记录\n入院日期:2023-01-01 出院日期:2023-01-20\n取到哪个?'  # heuristic: first (admission) wins
w "date_future__expect_2099-12-31.txt"        $'病历\n复诊日期 2099-12-31\n未来日期在1900-2100内被接受'
w "date_age_trap__expect_2025-02-18.txt"      $'CT报告\n年龄:60岁 检查日期:2025年02月18日\n年龄含年不应误取'

# ---------- DOC_TYPE red-team ----------
w "type_cn_discharge__expect_discharge_summary.txt" $'出院记录\n诊断:急性心梗\n日期 2024-02-02'
w "type_en_discharge__expect_discharge_summary.txt" $'Discharge Summary\nDiagnosis: pneumonia\nDate 2024-02-03'
w "type_cn_lab__expect_lab_report.txt"              $'检验报告单\nWBC 白细胞 8.0\n日期 2024-02-04'
w "type_en_lab__expect_lab_report.txt"             $'Laboratory Report\nHemoglobin 140 g/L\nDate 2024-02-05'
w "type_cn_prescription__expect_prescription.txt"  $'处方笺\n阿司匹林 100mg\n日期 2024-02-06'
w "type_cn_imaging_CT__expect_imaging_report.txt"  $'影像报告 胸部CT\n肺结节\n日期 2024-02-07'
w "type_lowercase_ct__GAP_expect_unknown.txt"      $'chest ct scan report\nnodule seen\nDate 2024-02-08'   # GAP: classify is case-sensitive on "CT"
w "type_en_ultrasound__GAP_expect_unknown.txt"     $'Ultrasound Report\nfatty liver\nDate 2024-02-09'      # GAP: no english imaging keyword
w "type_cn_pathology__expect_pathology.txt"        $'病理诊断报告\n慢性胃炎\n日期 2024-02-10'
w "type_multi_keyword__probe_precedence.txt"       $'出院记录\n附:处方 阿司匹林;检验 血常规\n日期 2024-02-11'  # precedence: discharge first
w "type_none__expect_unknown.txt"                  $'健康小贴士\n多喝水多运动\n日期 2024-02-12'

# ---------- LANGUAGE red-team ----------
w "lang_pure_en__expect_en.txt"        $'Emergency Department Note\nPatient stable, discharged home.\nDate 2024-03-01'
w "lang_pure_zh__expect_zh.txt"        $'门诊病历 患者一般情况良好 建议随访 日期二零二四'          # no ASCII digits date -> none; zh
w "lang_symbols__expect_null_lang.txt" $'#### ---- **** 1234 5678 !!!! ????'
w "lang_mixed__expect_mixed.txt"       $'检验报告 Creatinine 肌酐 90 umol/L Date 2024-03-02'

# ---------- CONTENT / FTS red-team ----------
w "fts_special_chars.txt"   $'检验报告\nC-reactive protein CRP 12; T2* 影像; 血型 "A"\n日期 2024-03-03'
w "content_empty.txt"       ''                                    # empty file
w "content_whitespace.txt"  $'   \n\t  \n   '                     # whitespace only
w "content_one_word.txt"    'CT'
python3 - "$OUT/content_very_long.txt" <<'PY'
import sys
open(sys.argv[1],"w").write("检验报告 长文档 日期 2024-03-04\n" + ("肌酐 Creatinine 结果 正常 " * 4000))
PY

# ---------- FILENAME red-team (all valid txt content) ----------
w "名称含空格 与符号 (2024).txt"  $'化验报告\n日期 2024-03-05\n中文文件名带空格括号'
w "emoji_🩺_report.txt"            $'处方\n日期 2024-03-06\nemoji 文件名'
w "noextension_file"               $'检验报告\n日期 2024-03-07\n无扩展名文件'    # mime octet; .? no ext -> parser bail -> StoredNoText

# ---------- NON-TXT FORMATS (real files via system tools) ----------
# PDF with text layer (cupsfilter, macOS) -> should EXTRACT text+date -> tests the untested PDF path
SRC_PDF="$OUT/.src_pdf.txt"
printf '%s\n' '腹部超声检查报告' '检查日期:2024-04-15' '脂肪肝(中度) Creatinine 未查' > "$SRC_PDF"
if command -v cupsfilter >/dev/null 2>&1; then
  cupsfilter "$SRC_PDF" > "$OUT/pdf_textlayer__expect_imaging_2024-04-15.pdf" 2>/dev/null \
    && echo "  [ok] generated PDF via cupsfilter" || echo "  [WARN] cupsfilter failed"
fi
rm -f "$SRC_PDF"

# DOCX (textutil, macOS) -> parser has no docx path -> EXPECT StoredNoText
if command -v textutil >/dev/null 2>&1; then
  SRC_DOCX="$OUT/.src_docx.txt"
  printf '%s\n' '出院记录 docx 格式' '出院日期 2024-05-20' > "$SRC_DOCX"
  textutil -convert docx "$SRC_DOCX" -output "$OUT/docx_report__GAP_expect_stored_no_text.docx" 2>/dev/null \
    && echo "  [ok] generated DOCX via textutil" || echo "  [WARN] textutil failed"
  rm -f "$SRC_DOCX"
fi

# Images (Pillow) -> parser can't read -> EXPECT StoredNoText (v0.1; OCR is Plan B)
python3 - "$OUT" <<'PY' 2>/dev/null && echo "  [ok] generated images via Pillow" || echo "  [WARN] Pillow image gen failed"
import sys
from PIL import Image, ImageDraw
out=sys.argv[1]
for ext in ("png","jpg","tiff"):
    im=Image.new("RGB",(600,300),(255,255,255))
    d=ImageDraw.Draw(im); d.text((20,20),"SCAN: lab report 2024-06-01\nCreatinine 100",fill=(0,0,0))
    im.save(f"{out}/image_scan__expect_stored_no_text.{ext}")
PY

# CSV / ZIP / bin -> unsupported by parser -> EXPECT StoredNoText
printf 'date,test,value,unit\n2024-07-01,Creatinine,100,umol/L\n2024-07-01,Glucose,5.5,mmol/L\n' > "$OUT/labs_csv__GAP_expect_stored_no_text.csv"
( cd "$OUT" && printf 'zipped medical record 2024-08-01' > .z.txt && zip -q "archive_zip__expect_stored_no_text.zip" .z.txt && rm -f .z.txt )
head -c 64 /dev/urandom > "$OUT/random_binary__expect_stored_no_text.bin"

# DEDUP red-team: byte-identical copy of an existing txt, different name
cp "$OUT/type_cn_lab__expect_lab_report.txt" "$OUT/dedup_copy__expect_deduped.txt"

echo "generated $(ls -1 "$OUT" | wc -l | tr -d ' ') files in $OUT"
