//! 端到端加密分享(v1.0,零服务器)。
//!
//! 患者在本机把全部病历打包成一份 **自包含加密 HTML**:文件里同时含有(a)用
//! AES-256-GCM 加密后的记录 JSON(base64),(b)一个纯前端查看器。患者把文件存到
//! 自己的云盘或直接发给医生,再 **另行单独** 告知一段 **口令**(=32 字节密钥的
//! base64url)。医生用任意浏览器打开文件、输入口令,浏览器用 Web Crypto 在 **本地**
//! 解密并渲染 —— 全程不经过任何服务器。
//!
//! 互操作要点(Rust 加密 ↔ 浏览器解密必须字节级一致):
//!   - Rust 用 `aes-gcm`(`Aes256Gcm`,128-bit tag,tag 追加在密文尾部)。
//!   - blob 布局:`nonce(12) || ciphertext_with_tag`,整体标准 base64 后内嵌进 HTML。
//!   - 口令 = 32 字节密钥的 URL-safe base64(无填充);显示时按 4 字符 **空格** 分组
//!     便于口述,查看器解码前只去掉空白字符。注意:分组分隔符只能用空格,不能用
//!     "-",因为 "-" 是 base64url 字母表本身的字符,去掉会破坏密钥。
//!   - Web Crypto 的 AES-GCM 同样期望 128-bit tag 追加在密文尾部 —— 与本模块输出一致。

use aes_gcm::aead::Aead;
use aes_gcm::{Aes256Gcm, KeyInit, Nonce};
use base64::engine::general_purpose::{STANDARD as B64, URL_SAFE_NO_PAD as B64URL};
use base64::Engine as _;
use core_model::Vault;
use rand::RngCore;

/// 把无填充 base64url 口令按 4 字符分组、空格连接,便于口述/抄写。
/// 查看器解码前会 `replace(/[\s-]/g,'')` 还原,因此分组仅影响显示。
fn group_passphrase(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    chars
        .chunks(4)
        .map(|c| c.iter().collect::<String>())
        .collect::<Vec<_>>()
        .join(" ")
}

fn fmt_date(d: Option<chrono::DateTime<chrono::Utc>>) -> Option<String> {
    d.map(|x| x.format("%Y-%m-%d").to_string())
}

/// 构建加密分享 HTML。返回 `(html, 分组后的口令, 记录数)`。
pub fn build_encrypted_share(v: &Vault, expires_days: u32) -> Result<(String, String, i64), String> {
    let records = crate::export::gather_records(v)?;
    let profile = pipeline::patient_profile(v).map_err(|e| e.to_string())?;

    let generated = chrono::Utc::now();
    let expires = generated + chrono::Duration::days(expires_days as i64);

    // ── 记录数组 ──
    let mut record_count: i64 = 0;
    let mut records_json: Vec<serde_json::Value> = Vec::new();
    for rec in &records {
        let doc = &rec.doc;
        let sf = &rec.source_file;
        let title = doc.title.clone().unwrap_or_else(|| sf.original_name.clone());

        // 仅内嵌 image/* 原件为 data-URI;DICOM 与 PDF v1.0 不内嵌(仅文字)。
        let mut images: Vec<String> = Vec::new();
        if sf.mime_type.starts_with("image/") {
            let bytes =
                std::fs::read(v.root_join(&sf.storage_path)).map_err(|e| e.to_string())?;
            let b64 = B64.encode(&bytes);
            images.push(format!("data:{};base64,{}", sf.mime_type, b64));
        }

        records_json.push(serde_json::json!({
            "doc_type": doc.doc_type.as_str(),
            "doc_date": fmt_date(doc.doc_date),
            "doc_date_end": fmt_date(doc.doc_date_end),
            "title": title,
            "text": rec.text,
            "images": images,
        }));
        record_count += 1;
    }

    let payload = serde_json::json!({
        "generated": generated.to_rfc3339(),
        "expires": expires.to_rfc3339(),
        "patient": {
            "name": profile.name,
            "gender": profile.gender,
            "age": profile.age,
            "record_count": record_count,
        },
        "records": records_json,
    });
    let plaintext =
        serde_json::to_vec(&payload).map_err(|e| format!("serialize payload: {e}"))?;

    // ── AES-256-GCM 加密 ──
    let mut key_bytes = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut key_bytes);
    let mut nonce_bytes = [0u8; 12];
    rand::rngs::OsRng.fill_bytes(&mut nonce_bytes);

    let cipher =
        Aes256Gcm::new_from_slice(&key_bytes).map_err(|e| format!("init cipher: {e}"))?;
    let nonce = Nonce::from_slice(&nonce_bytes);
    let ciphertext = cipher
        .encrypt(nonce, plaintext.as_ref())
        .map_err(|e| format!("encrypt: {e}"))?; // 密文尾部含 16 字节 tag

    // blob = nonce(12) || ciphertext_with_tag,整体标准 base64。
    let mut blob = Vec::with_capacity(12 + ciphertext.len());
    blob.extend_from_slice(&nonce_bytes);
    blob.extend_from_slice(&ciphertext);
    let blob_b64 = B64.encode(&blob);

    // 口令 = 密钥的 url-safe base64(无填充);显示时分组。
    let passphrase_raw = B64URL.encode(key_bytes);
    let passphrase_grouped = group_passphrase(&passphrase_raw);

    let html = VIEWER_TEMPLATE
        .replace("__BLOB__", &blob_b64)
        .replace("__EXPIRES__", &expires.to_rfc3339())
        .replace("__GENERATED__", &generated.to_rfc3339());

    Ok((html, passphrase_grouped, record_count))
}

/// 自包含查看器模板。占位符 `__BLOB__` / `__EXPIRES__` / `__GENERATED__` 用
/// `str::replace` 注入 —— 避免 `format!` 与内联 JS/CSS 的 `{}` 冲突。
/// 无任何外部引用,严格离线可用。
const VIEWER_TEMPLATE: &str = r####"<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>MedMe 加密病历分享</title>
<style>
  * { box-sizing: border-box; }
  body { font-family: -apple-system, "PingFang SC", "Microsoft YaHei", "Noto Sans CJK SC", "Segoe UI", sans-serif; color: #1e293b; margin: 0; padding: 0; background: #f8fafc; }
  .wrap { max-width: 900px; margin-inline: auto; padding: 24px; }
  /* 口令输入屏 */
  .gate { min-height: 100vh; display: flex; align-items: center; justify-content: center; padding: 24px; }
  .gate-card { background: #fff; border: 1px solid #e2e8f0; border-radius: 16px; padding: 32px; max-width: 420px; width: 100%; box-shadow: 0 8px 30px rgba(15,23,42,.06); }
  .gate-card h1 { font-size: 20px; color: #1d4ed8; margin: 0 0 6px; }
  .gate-card p { font-size: 13px; color: #64748b; line-height: 1.6; margin: 0 0 18px; }
  .gate-card label { display: block; font-size: 12px; font-weight: 600; color: #334155; margin-bottom: 6px; }
  .gate-card input { width: 100%; font-size: 15px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; padding: 11px 12px; border: 1px solid #cbd5e1; border-radius: 10px; letter-spacing: .5px; }
  .gate-card input:focus { outline: none; border-color: #2563eb; box-shadow: 0 0 0 3px rgba(37,99,235,.15); }
  .gate-card button { width: 100%; margin-top: 14px; font-size: 15px; font-weight: 600; color: #fff; background: #2563eb; border: none; border-radius: 10px; padding: 12px; cursor: pointer; }
  .gate-card button:hover { background: #1d4ed8; }
  .gate-err { color: #be123c; font-size: 13px; margin-top: 12px; min-height: 18px; }
  /* 头部 */
  .doc-header { border-bottom: 2px solid #2563eb; padding-bottom: 12px; margin-bottom: 20px; }
  .doc-header h1 { font-size: 22px; color: #1d4ed8; margin: 0 0 6px; }
  .patient { font-size: 14px; color: #334155; }
  .generated { font-size: 12px; color: #94a3b8; margin-top: 4px; }
  .privacy-note { font-size: 12px; color: #475569; background: #eff6ff; border: 1px solid #dbeafe; border-radius: 10px; padding: 10px 12px; margin-bottom: 20px; line-height: 1.6; }
  /* 记录卡片 */
  .record { background: #fff; border: 1px solid #e2e8f0; border-radius: 12px; padding: 16px 20px; margin-bottom: 16px; page-break-inside: avoid; }
  .record-head { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; margin-bottom: 10px; }
  .record-head h2 { font-size: 16px; margin: 0; color: #0f172a; flex: 1; min-width: 120px; }
  .badge { font-size: 11px; font-weight: 700; border-radius: 999px; padding: 2px 10px; }
  .date { font-size: 12px; color: #64748b; font-variant-numeric: tabular-nums; }
  .content { font-size: 15px; line-height: 1.7; color: #334155; }
  .content > * + * { margin-top: 10px; }
  .content table { width: 100%; border-collapse: collapse; font-size: 13px; border: 1px solid #e2e8f0; border-radius: 10px; overflow: hidden; }
  .content thead tr { background: #f8fafc; color: #64748b; font-size: 12px; }
  .content th { text-align: left; font-weight: 600; padding: 7px 12px; border-bottom: 1px solid #e2e8f0; white-space: nowrap; }
  .content td { padding: 6px 12px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; border-bottom: 1px solid #f1f5f9; white-space: nowrap; }
  .content tr.high td { color: #b45309; }
  .content tr.low td { color: #1d4ed8; }
  .content tr.normal td { color: #334155; }
  .content .section { font-weight: 600; color: #0f172a; padding-top: 2px; }
  .content .label { font-weight: 600; color: #0f172a; }
  .content .para { white-space: pre-wrap; word-break: break-word; }
  /* 处方 */
  .meds { display: flex; flex-direction: column; gap: 8px; }
  .med { display: flex; gap: 12px; background: #ecfdf5; border: 1px solid #d1fae5; border-radius: 12px; padding: 12px; }
  .med .n { width: 26px; height: 26px; border-radius: 8px; background: #d1fae5; color: #047857; display: flex; align-items: center; justify-content: center; flex-shrink: 0; font-weight: 700; font-size: 13px; }
  .med .name { font-weight: 600; color: #1e293b; }
  .med .usage { font-size: 13px; color: #64748b; line-height: 1.6; }
  .meds-label { font-size: 11px; font-family: ui-monospace, monospace; color: #94a3b8; letter-spacing: .15em; text-transform: uppercase; }
  .img { max-width: 100%; max-height: 480px; display: block; margin: 8px 0; border: 1px solid #e2e8f0; border-radius: 8px; }
  .statement { text-align: center; font-size: 11px; color: #94a3b8; margin-top: 24px; padding-top: 12px; border-top: 1px solid #e2e8f0; }
  .expired { max-width: 480px; margin: 80px auto; text-align: center; background: #fff; border: 1px solid #fecdd3; border-radius: 16px; padding: 40px 28px; }
  .expired h1 { font-size: 18px; color: #be123c; margin: 0 0 10px; }
  .expired p { font-size: 14px; color: #64748b; line-height: 1.7; margin: 0; }
  @media print {
    body { background: #fff; }
    .record { border: 1px solid #cbd5e1; box-shadow: none; }
    .privacy-note { background: #fff; }
    @page { margin: 16mm 14mm; }
  }
</style>
</head>
<body>
<div id="gate" class="gate">
  <div class="gate-card">
    <h1>MedMe 加密病历</h1>
    <p>这份文件已端到端加密。请输入本人另行告知的<b>口令</b>,浏览器将在本地解密并显示病历,数据不会上传任何服务器。</p>
    <label for="pw">口令</label>
    <input id="pw" type="password" autocomplete="off" spellcheck="false" placeholder="粘贴或输入口令">
    <button id="go" type="button">解密查看</button>
    <div id="err" class="gate-err"></div>
  </div>
</div>
<div id="app" class="wrap" style="display:none"></div>

<script>
const EMBEDDED_BLOB = "__BLOB__";

const TYPE_LABEL = { lab_report:"化验", imaging_report:"检查", discharge_summary:"出院", prescription:"处方", clinical_note:"病历", pathology:"病理", surgery:"手术", other:"其他", unknown:"未分类" };
// bg | color(与桌面端 TYPE_BADGE 一致)
const TYPE_BADGE = {
  lab_report:      ["#eff6ff","#1d4ed8"],
  imaging_report:  ["#fffbeb","#b45309"],
  discharge_summary:["#eef2ff","#4338ca"],
  prescription:    ["#ecfdf5","#047857"],
  clinical_note:   ["#f0f9ff","#0369a1"],
  pathology:       ["#fff1f2","#be123c"],
  surgery:         ["#faf5ff","#7e22ce"],
  other:           ["#f1f5f9","#475569"],
  unknown:         ["#f1f5f9","#475569"],
};

function b64ToBytes(b64) {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
function b64urlToBytes(s) {
  let t = s.replace(/-/g, "+").replace(/_/g, "/");
  while (t.length % 4) t += "=";
  return b64ToBytes(t);
}
function esc(s) {
  return String(s).replace(/[&<>"']/g, c =>
    ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;" }[c]));
}

// ── 内容解析(移植 ReportContent.tsx)──
function splitCells(line) { return line.trim().split(/\s{2,}|\t/).filter(c => c.length > 0); }
function isTableHeader(line) {
  const keys = ["项目","结果","单位","参考","提示","名称","缩写"];
  return keys.filter(k => line.includes(k)).length >= 2 && splitCells(line).length >= 3;
}
function isDataRow(line) { return splitCells(line).length >= 3 && /\d/.test(line); }
function rowStatus(cells) {
  const j = cells.join(" ");
  if (cells.includes("↑") || /↑|偏高|升高/.test(j)) return "high";
  if (cells.includes("↓") || /↓|偏低|降低|减低/.test(j)) return "low";
  if (/正常/.test(j)) return "normal";
  return "";
}
function parseBlocks(text) {
  const lines = text.split(/\r?\n/);
  const blocks = [];
  let i = 0;
  while (i < lines.length) {
    const trimmed = lines[i].trim();
    if (!trimmed) { i++; continue; }
    if (isTableHeader(trimmed) || isDataRow(trimmed)) {
      const start = i;
      const header = isTableHeader(trimmed) ? splitCells(trimmed) : null;
      if (header) i++;
      const rows = [];
      while (i < lines.length && lines[i].trim() && isDataRow(lines[i])) {
        rows.push(splitCells(lines[i])); i++;
      }
      if (rows.length >= 2) { blocks.push({ kind:"table", header, rows }); continue; }
      i = start;
    }
    if (/^[【[].+[】\]]$/.test(trimmed) || (trimmed.length <= 14 && /[:：]$/.test(trimmed))) {
      blocks.push({ kind:"section", text: trimmed });
    } else {
      blocks.push({ kind:"para", text: lines[i] });
    }
    i++;
  }
  return blocks;
}
const LABEL_RE = /^([一-龥A-Za-z]{2,10})([:：])(.*)$/;
function renderPara(text) {
  const t = text.replace(/\s+$/, "");
  const m = t.match(LABEL_RE);
  if (m && m[3].trim().length > 0) {
    return '<div class="para"><span class="label">' + esc(m[1]) + esc(m[2]) + "</span>" + esc(m[3]) + "</div>";
  }
  return '<div class="para">' + esc(text) + "</div>";
}
function renderBlocks(blocks) {
  let html = "";
  for (const b of blocks) {
    if (b.kind === "table") {
      const cols = Math.max(b.header ? b.header.length : 0, ...b.rows.map(r => r.length));
      html += '<div style="overflow-x:auto"><table>';
      if (b.header) {
        html += "<thead><tr>";
        for (const h of b.header) html += "<th>" + esc(h) + "</th>";
        html += "</tr></thead>";
      }
      html += "<tbody>";
      for (const r of b.rows) {
        const st = rowStatus(r);
        html += '<tr class="' + st + '">';
        for (let c = 0; c < cols; c++) html += "<td>" + esc(r[c] || "") + "</td>";
        html += "</tr>";
      }
      html += "</tbody></table></div>";
    } else if (b.kind === "section") {
      html += '<div class="section">' + esc(b.text) + "</div>";
    } else {
      html += renderPara(b.text);
    }
  }
  return html;
}
// ── 处方:用药清单(移植 parseMeds)──
function parseMeds(text) {
  const lines = text.split(/\r?\n/);
  const meds = [], intro = [], footer = [];
  let cur = null, started = false, ended = false;
  for (const raw of lines) {
    const line = raw.trim();
    const numbered = line.match(/^(\d+)\s*[.、)]\s*(.+)/);
    if (numbered) {
      started = true; ended = false;
      if (cur) meds.push(cur);
      cur = { name: numbered[2].trim(), usage: [] };
      continue;
    }
    if (/^(医师|药师|审核|备注|Rp\.?|处方)/.test(line)) {
      if (cur) { meds.push(cur); cur = null; }
      if (started) ended = true;
      if (line && !/^Rp\.?$/.test(line)) { if (started) footer.push(line); else intro.push(line); }
      continue;
    }
    if (cur && line) { cur.usage.push(line); continue; }
    if (line) { if (!started) intro.push(line); else if (ended) footer.push(line); }
  }
  if (cur) meds.push(cur);
  return meds.length ? { intro, meds, footer } : null;
}
function renderContent(text, docType) {
  if (!text || !text.trim()) return '<div style="color:#94a3b8;font-size:14px">无文本内容。</div>';
  if (docType === "prescription") {
    const p = parseMeds(text);
    if (p) {
      let html = "";
      if (p.intro.length) html += p.intro.map(renderPara).join("");
      html += '<div class="meds-label">用药</div><div class="meds">';
      p.meds.forEach((m, i) => {
        html += '<div class="med"><div class="n">' + (i + 1) + '</div><div><div class="name">' + esc(m.name) + "</div>";
        html += m.usage.map(u => '<div class="usage">' + esc(u) + "</div>").join("");
        html += "</div></div>";
      });
      html += "</div>";
      if (p.footer.length) html += '<div style="color:#64748b;font-size:13px">' + p.footer.map(renderPara).join("") + "</div>";
      return html;
    }
  }
  return renderBlocks(parseBlocks(text));
}

function render(payload) {
  const app = document.getElementById("app");
  const p = payload.patient || {};
  const parts = [];
  if (p.name) parts.push(esc(p.name));
  if (p.gender) parts.push(esc(p.gender));
  if (p.age) parts.push(esc(p.age) + "岁");
  const patientLine = parts.length ? parts.join(" · ") : "(未识别到患者基本信息)";
  const gen = (payload.generated || "").slice(0, 10);

  let html = '<header class="doc-header"><h1>MedMe 医我 · 加密病历分享</h1>';
  html += '<div class="patient">' + patientLine + "</div>";
  html += '<div class="generated">生成时间:' + esc(gen) + " · 共 " + (p.record_count || 0) + " 份记录</div></header>";
  html += '<div class="privacy-note">本页由 MedMe 端到端加密分享生成,数据在您的浏览器本地解密,未上传任何服务器。不构成医疗建议,以原件为准。</div>';

  for (const r of (payload.records || [])) {
    const type = r.doc_type || "unknown";
    const label = TYPE_LABEL[type] || TYPE_LABEL.unknown;
    const bc = TYPE_BADGE[type] || TYPE_BADGE.unknown;
    const title = r.title || label;
    let dateStr = "无日期";
    if (r.doc_date && r.doc_date_end && r.doc_date !== r.doc_date_end) dateStr = r.doc_date + " → " + r.doc_date_end;
    else if (r.doc_date) dateStr = r.doc_date;

    html += '<section class="record"><div class="record-head">';
    html += '<span class="badge" style="background:' + bc[0] + ";color:" + bc[1] + '">' + esc(label) + "</span>";
    html += "<h2>" + esc(title) + '</h2><span class="date">' + esc(dateStr) + "</span></div>";
    html += '<div class="content">' + renderContent(r.text || "", type);
    for (const img of (r.images || [])) {
      if (typeof img === "string" && img.startsWith("data:image/")) html += '<img class="img" src="' + img + '" alt="原件">';
    }
    html += "</div></section>";
  }
  html += '<footer class="statement">本页由 MedMe 端到端加密分享生成 · 数据以原件为准 · 不构成医疗建议</footer>';
  app.innerHTML = html;
  document.getElementById("gate").style.display = "none";
  app.style.display = "block";
}

function showExpired(expires) {
  document.getElementById("gate").style.display = "none";
  const app = document.getElementById("app");
  const until = (expires || "").slice(0, 10);
  app.innerHTML = '<div class="expired"><h1>此分享已过期</h1><p>有效期至 ' + esc(until) +
    ',请向本人重新索取。</p></div>';
  app.style.display = "block";
}

async function decryptAndRender(passphrase) {
  const blob = b64ToBytes(EMBEDDED_BLOB);
  const iv = blob.slice(0, 12);
  const data = blob.slice(12);
  // 仅去空白/换行还原分组;不可去 "-",因为它是 base64url 字母表的一部分。
  const keyBytes = b64urlToBytes(passphrase.replace(/\s+/g, ""));
  const key = await crypto.subtle.importKey("raw", keyBytes, { name: "AES-GCM" }, false, ["decrypt"]);
  const pt = await crypto.subtle.decrypt({ name: "AES-GCM", iv }, key, data); // 口令错误则抛异常
  const payload = JSON.parse(new TextDecoder().decode(pt));
  // 有效期在解密后的 payload 内强制执行
  if (payload.expires && Date.now() > Date.parse(payload.expires)) { showExpired(payload.expires); return; }
  render(payload);
}

const pw = document.getElementById("pw");
const errEl = document.getElementById("err");
async function submit() {
  errEl.textContent = "";
  const val = pw.value.trim();
  if (!val) { errEl.textContent = "请输入口令。"; return; }
  try {
    await decryptAndRender(val);
  } catch (e) {
    errEl.textContent = "口令错误,无法解密。请核对本人告知的口令。";
  }
}
document.getElementById("go").addEventListener("click", submit);
pw.addEventListener("keydown", e => { if (e.key === "Enter") submit(); });
pw.focus();
</script>
</body>
</html>
"####;

#[cfg(test)]
mod tests {
    use super::*;
    use aes_gcm::aead::Aead;

    #[test]
    fn build_share_produces_valid_html_and_key() {
        use core_model::{DocType, NewDocument, NewOcr, OcrBackendKind};
        let dir = tempfile::tempdir().unwrap();
        let vault = Vault::open(dir.path()).unwrap();
        let imp = vault.import("血常规.txt", "text/plain", b"data").unwrap();
        let doc = vault
            .add_document(NewDocument {
                source_file_id: imp.source_file.id,
                doc_type: DocType::LabReport,
                doc_date: Some(chrono::Utc::now()),
                doc_date_end: None,
                title: Some("血常规报告".into()),
                language: Some("zh".into()),
                page_count: 1,
            })
            .unwrap();
        vault
            .add_ocr(NewOcr {
                document_id: doc.id,
                page_no: 1,
                backend: OcrBackendKind::Native,
                model_version: "text-layer".into(),
                text: "白细胞 10.5".into(),
                confidence: None,
            })
            .unwrap();

        let (html, pass, n) = build_encrypted_share(&vault, 5).unwrap();
        assert_eq!(n, 1);
        assert!(html.starts_with("<!doctype html>"));
        assert!(html.contains("EMBEDDED_BLOB = \""));
        assert!(!html.contains("__BLOB__")); // 占位符已全部替换
        assert!(!html.contains("__EXPIRES__"));

        // 口令去空白后应能 base64url 解回 32 字节密钥。
        let stripped: String = pass.chars().filter(|c| !c.is_whitespace()).collect();
        let key = B64URL.decode(stripped).unwrap();
        assert_eq!(key.len(), 32);

        // 提取内嵌 blob → 用该密钥解密 → 应还原出合法 payload JSON(与浏览器查看器同路径)。
        let start = html.find("EMBEDDED_BLOB = \"").unwrap() + "EMBEDDED_BLOB = \"".len();
        let end = html[start..].find('"').unwrap() + start;
        let blob = B64.decode(&html[start..end]).unwrap();
        let cipher = Aes256Gcm::new_from_slice(&key).unwrap();
        let pt = cipher
            .decrypt(Nonce::from_slice(&blob[..12]), &blob[12..])
            .unwrap();
        let payload: serde_json::Value = serde_json::from_slice(&pt).unwrap();
        assert_eq!(payload["records"].as_array().unwrap().len(), 1);
        assert_eq!(payload["records"][0]["doc_type"], "lab_report");
        assert_eq!(payload["patient"]["record_count"], 1);
        assert!(payload["expires"].is_string());
    }

    #[test]
    fn round_trip_decrypt_in_rust() {
        // 加密一段已知 payload,再用同 key/nonce 在 Rust 侧解密,验证往返 + tag 布局。
        let plaintext = r#"{"hello":"世界","n":42}"#.as_bytes();
        let mut key_bytes = [0u8; 32];
        rand::rngs::OsRng.fill_bytes(&mut key_bytes);
        let mut nonce_bytes = [0u8; 12];
        rand::rngs::OsRng.fill_bytes(&mut nonce_bytes);

        let cipher = Aes256Gcm::new_from_slice(&key_bytes).unwrap();
        let nonce = Nonce::from_slice(&nonce_bytes);
        let ct = cipher.encrypt(nonce, plaintext.as_ref()).unwrap();

        // blob = nonce || ct(含 tag)
        let mut blob = nonce_bytes.to_vec();
        blob.extend_from_slice(&ct);
        assert_eq!(blob.len(), 12 + plaintext.len() + 16); // 12 nonce + pt + 16 tag

        // 还原:切出 nonce 与密文,解密
        let iv = &blob[..12];
        let data = &blob[12..];
        let cipher2 = Aes256Gcm::new_from_slice(&key_bytes).unwrap();
        let out = cipher2.decrypt(Nonce::from_slice(iv), data).unwrap();
        assert_eq!(out, plaintext);

        // 错误密钥应解密失败
        let mut wrong = key_bytes;
        wrong[0] ^= 0xff;
        let bad = Aes256Gcm::new_from_slice(&wrong).unwrap();
        assert!(bad.decrypt(Nonce::from_slice(iv), data).is_err());
    }

    #[test]
    fn passphrase_grouped_strips_back_to_key() {
        // 口令分组仅影响显示;去掉空格后应能 base64url 解回 32 字节密钥。
        let key = [7u8; 32];
        let raw = B64URL.encode(key);
        let grouped = group_passphrase(&raw);
        assert!(grouped.contains(' '));
        let stripped: String = grouped.chars().filter(|c| !c.is_whitespace()).collect();
        assert_eq!(stripped, raw);
        let decoded = B64URL.decode(stripped).unwrap();
        assert_eq!(decoded, key);
    }
}
