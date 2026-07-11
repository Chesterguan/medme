#!/usr/bin/env python3
"""Render a MedMe demo .txt medical record into a realistic hospital-report PDF
(with a real text layer, via Chrome headless print-to-PDF). Preserves the exact
medical content; only makes it *look* like a printed/stamped report."""
import re, sys, html, subprocess, os, tempfile

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

CSS = """
@page { size: A4; margin: 14mm 14mm; }
* { box-sizing: border-box; }
body { font-family: "PingFang SC","STHeiti","Songti SC",serif; color:#111; font-size:12.5px; line-height:1.6; }
.head { text-align:center; border-bottom:2.5px solid #1a3a6b; padding-bottom:8px; margin-bottom:4px; }
.hosp { font-size:20px; font-weight:800; letter-spacing:3px; color:#1a3a6b; }
.title { font-size:15px; font-weight:700; margin-top:3px; letter-spacing:1px; }
.subrule { height:1px; background:#1a3a6b; margin:2px 0 12px; }
.pinfo { display:flex; flex-wrap:wrap; gap:2px 26px; font-size:12px; margin-bottom:10px; }
.pinfo span b { font-weight:700; }
table { width:100%; border-collapse:collapse; margin:6px 0 12px; font-size:12px; }
th,td { border:1px solid #94a3b8; padding:5px 7px; text-align:left; }
th { background:#eef3fb; font-weight:700; }
td.num { text-align:right; font-variant-numeric:tabular-nums; }
.up { color:#c0392b; font-weight:800; }
.down { color:#1d6fb8; font-weight:800; }
.body { white-space:pre-wrap; font-size:12.5px; }
.foot { margin-top:14px; display:flex; justify-content:space-between; align-items:flex-end; font-size:12px; }
.sign { line-height:2.0; }
.stamp { position:fixed; right:60px; bottom:120px; width:130px; height:130px; border:3px solid #c0392b;
  border-radius:50%; color:#c0392b; display:flex; align-items:center; justify-content:center; text-align:center;
  font-size:12px; font-weight:800; transform:rotate(-14deg); opacity:.75; padding:8px; letter-spacing:1px; }
.note { margin-top:10px; padding:8px 10px; background:#fbfaf3; border-left:3px solid #b8860b; font-size:12px; }
"""

def esc(s): return html.escape(s)

def parse(txt):
    lines = [l.rstrip() for l in txt.splitlines()]
    lines = [l for l in lines if l.strip() != ""]
    hosp = lines[0] if lines else "医院"
    # patient-info lines: contain 姓名/性别/号
    pinfo, body, table_hdr, table_rows, notes = [], [], None, [], []
    i = 1
    # gather leading patient-info lines
    while i < len(lines) and re.search(r"(姓名|性别|年龄|号|日期|科室|样本|时间)[:：]", lines[i]):
        pinfo.append(lines[i]); i += 1
    # detect a result table: a header line with 结果 and 参考范围
    for j in range(i, len(lines)):
        if ("参考范围" in lines[j]) and ("结果" in lines[j] or "单位" in lines[j]):
            table_hdr = re.split(r"\s{2,}", lines[j].strip())
            # rows until a footer keyword
            k = j + 1
            while k < len(lines) and not re.search(r"^(检验者|审核者|医师|医生|报告医师|提示|建议|意见)[:：]?", lines[k]):
                cells = re.split(r"\s{2,}", lines[k].strip())
                if len(cells) >= 3:
                    table_rows.append(cells)
                k += 1
            notes = lines[k:]
            body = lines[i:j]
            break
    else:
        body = lines[i:]
    return hosp, pinfo, body, table_hdr, table_rows, notes

def render_table(hdr, rows):
    ncol = max(len(hdr), max((len(r) for r in rows), default=0))
    def cell(c):
        cl = "up" if c.strip() == "↑" else ("down" if c.strip() == "↓" else "")
        num = "num" if re.fullmatch(r"[-<>≤≥]?\s*[\d.]+.*", c.strip()) else ""
        return f'<td class="{num} {cl}">{esc(c)}</td>'
    out = ["<table><thead><tr>"] + [f"<th>{esc(h)}</th>" for h in hdr] + ["</tr></thead><tbody>"]
    for r in rows:
        r = r + [""] * (ncol - len(r))
        out.append("<tr>" + "".join(cell(c) for c in r) + "</tr>")
    out.append("</tbody></table>")
    return "".join(out)

def build_html(txt, stamp_text):
    hosp, pinfo, body, thdr, trows, notes = parse(txt)
    parts = [f'<div class="head"><div class="hosp">{esc(hosp.split()[0])}</div>',
             f'<div class="title">{esc(" ".join(hosp.split()[1:]) or "医疗记录")}</div></div>',
             '<div class="subrule"></div>']
    if pinfo:
        parts.append('<div class="pinfo">' +
                     "".join(f"<span>{esc(p)}</span>" for line in pinfo for p in re.split(r"\s{2,}", line)) +
                     "</div>")
    if body:
        parts.append('<div class="body">' + esc("\n".join(body)) + "</div>")
    if thdr and trows:
        parts.append(render_table(thdr, trows))
    sign_lines = [n for n in notes if re.search(r"^(检验者|审核者|医师|医生|报告医师)[:：]", n)]
    note_lines = [n for n in notes if n not in sign_lines]
    if note_lines:
        parts.append('<div class="note">' + esc("\n".join(note_lines)) + "</div>")
    parts.append('<div class="foot"><div class="sign">' +
                 "<br>".join(esc(s) for s in sign_lines) + "</div>" +
                 f'<div class="stamp">{esc(stamp_text)}</div></div>')
    return f"<!doctype html><html><head><meta charset='utf-8'><style>{CSS}</style></head><body>{''.join(parts)}</body></html>"

def to_pdf(html_str, out_pdf):
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False, encoding="utf-8") as f:
        f.write(html_str); tmp = f.name
    subprocess.run([CHROME, "--headless", "--disable-gpu", "--no-pdf-header-footer",
                    f"--print-to-pdf={out_pdf}", "file://" + tmp],
                   check=True, capture_output=True)
    os.unlink(tmp)

if __name__ == "__main__":
    src, out = sys.argv[1], sys.argv[2]
    txt = open(src, encoding="utf-8").read()
    hosp = txt.splitlines()[0].split()[0] if txt.strip() else "医院"
    stamp = hosp + "\n医疗文书专用章"
    to_pdf(build_html(txt, stamp), out)
    print("→", out)
