#!/usr/bin/env python3
"""Arm 4 of the 4-way arena: whole-page image -> vision LLM -> (a) line text, (b) structured JSON.

One API call per (image, model). No ground truth ever enters the prompt.
"""
import base64
import json
import os
import re
import ssl
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import certifi
import httpx
from openai import OpenAI

BASE = "/private/tmp/claude-501/-Volumes-extraSupply-Projects-openmed/3c224b0f-768e-498c-b5ef-328c3ba3b549/scratchpad/arena"
PAGES = os.path.join(BASE, "pages")
OUT = os.path.join(BASE, "arm4_llm")
ENDPOINT = "https://api.ai.it.ufl.edu/v1"
MODELS = ["medgemma-27b-it", "gemma-3-27b-it", "mistral-small-3.1"]

PROMPT = """你是一个医疗单据的版面还原与信息抽取工具。下面是一张中文医疗单据的整页图片。

请完成两件事，严格按下面的格式返回，不要寒暄、不要解释、不要用 markdown 代码块。

第一部分，以单独一行 <<<TEXT>>> 开始：
逐行输出这一页的全部文字内容，保持页面自上而下的阅读顺序。
- 如果某一行是一条化验/检验结果，请整理成一行：项目名 数值 单位 参考范围，字段之间用单个空格分隔。
  一行的形态举例（仅示意格式，与本页内容无关）：某项目名 12.3 mmol/L 4.0-20.0
  参考范围写成「低值-高值」；若页面上是 >90、<5 这类单边范围就照写。
  若某项本来就没有单位或参考范围，就省略该字段，不要编造。
- 非化验内容（标题、医院名、患者信息、现病史、诊断、医嘱、用药、影像所见、印象、建议等）照原样逐行输出，不要改写、不要总结、不要翻译、不要补充。
- 不要输出表格边框字符，不要输出行号。

第二部分，以单独一行 <<<JSON>>> 开始：
输出一个 JSON 数组，把这一页上所有化验/检验项目结构化：
[{"name": "项目名", "value": "数值", "unit": "单位", "ref_low": "参考范围下限", "ref_high": "参考范围上限"}]
- value 保持页面上的原始写法。
- 缺失的字段用 null。
- 这一页若没有任何化验项目，输出 []
- 只输出 JSON 数组本身。
"""

_key = open(os.path.expanduser("~/.navigator_key")).read().strip()
_ctx = ssl.create_default_context(cafile=certifi.where())
client = OpenAI(
    base_url=ENDPOINT,
    api_key=_key,
    timeout=httpx.Timeout(300.0, connect=30.0),
    max_retries=0,
    http_client=httpx.Client(verify=_ctx, timeout=httpx.Timeout(300.0, connect=30.0)),
)

log_lock = threading.Lock()


def log(msg):
    with log_lock:
        print(msg, flush=True)


def split_sections(raw):
    """Return (text_part, json_part_raw, list_of_fixups_applied)."""
    fixups = []
    s = raw.strip()

    # fixup: strip a leading markdown fence wrapping the whole reply
    m = re.match(r"^```[a-zA-Z]*\s*\n(.*)\n```\s*$", s, re.S)
    if m:
        s = m.group(1).strip()
        fixups.append("stripped_outer_code_fence")

    ti = s.find("<<<TEXT>>>")
    ji = s.find("<<<JSON>>>")
    if ti != -1 and ji != -1 and ji > ti:
        text = s[ti + len("<<<TEXT>>>"):ji].strip()
        jraw = s[ji + len("<<<JSON>>>"):].strip()
    elif ji != -1:
        fixups.append("no_TEXT_marker")
        text = s[:ji].strip()
        jraw = s[ji + len("<<<JSON>>>"):].strip()
    elif ti != -1:
        fixups.append("no_JSON_marker")
        text = s[ti + len("<<<TEXT>>>"):].strip()
        jraw = ""
    else:
        fixups.append("no_markers_at_all")
        text = s
        jraw = ""

    # if no JSON section found, look for a fenced json block anywhere
    if not jraw:
        m = re.search(r"```json\s*\n(.*?)\n```", s, re.S)
        if m:
            jraw = m.group(1)
            fixups.append("recovered_json_from_fence")
    return text, jraw, fixups


def parse_json_part(jraw, fixups):
    if not jraw:
        return None
    s = jraw.strip()
    m = re.match(r"^```[a-zA-Z]*\s*\n(.*?)\n?```", s, re.S)
    if m:
        s = m.group(1).strip()
        fixups.append("stripped_json_code_fence")
    try:
        return json.loads(s)
    except Exception:
        pass
    # take the outermost [...] span
    a, b = s.find("["), s.rfind("]")
    if a != -1 and b > a:
        cand = s[a:b + 1]
        try:
            r = json.loads(cand)
            fixups.append("json_sliced_to_brackets")
            return r
        except Exception:
            pass
        # drop trailing commas
        cand2 = re.sub(r",(\s*[\]}])", r"\1", cand)
        try:
            r = json.loads(cand2)
            fixups.append("json_trailing_comma_fixed")
            return r
        except Exception:
            pass
        # salvage individual objects
        objs = []
        for om in re.finditer(r"\{[^{}]*\}", cand):
            try:
                objs.append(json.loads(om.group(0)))
            except Exception:
                continue
        if objs:
            fixups.append("json_salvaged_objects")
            return objs
    fixups.append("json_unparseable")
    return None


def clean_text(text, fixups):
    """Only strips per-line markdown artifacts; never edits content words."""
    lines = text.split("\n")
    out = []
    changed = False
    for ln in lines:
        o = ln
        ln = ln.rstrip()
        if ln.strip() in ("```", "```text", "```txt", "```markdown"):
            changed = True
            continue
        # markdown table row -> space separated cells
        if ln.strip().startswith("|") and ln.strip().endswith("|"):
            cells = [c.strip() for c in ln.strip().strip("|").split("|")]
            if all(re.fullmatch(r":?-{2,}:?", c or "-") for c in cells if c):
                changed = True
                continue  # separator row
            ln = " ".join(c for c in cells if c)
            changed = True
        if ln != o:
            changed = True
        out.append(ln)
    if changed:
        fixups.append("markdown_line_cleanup")
    # collapse >2 blank lines
    res = []
    blank = 0
    for ln in out:
        if not ln.strip():
            blank += 1
            if blank > 1:
                continue
        else:
            blank = 0
        res.append(ln)
    return "\n".join(res).strip()


def call_once(model, b64, timeout):
    r = client.chat.completions.create(
        model=model,
        messages=[{"role": "user", "content": [
            {"type": "text", "text": PROMPT},
            {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{b64}"}},
        ]}],
        max_tokens=4096,
        temperature=0.0,
        timeout=timeout,
    )
    usage = r.usage
    return r.choices[0].message.content or "", {
        "prompt_tokens": getattr(usage, "prompt_tokens", None),
        "completion_tokens": getattr(usage, "completion_tokens", None),
        "total_tokens": getattr(usage, "total_tokens", None),
        "finish_reason": r.choices[0].finish_reason,
    }


def degeneration_stats(text):
    """Detect repetition-loop collapse. Diagnostic only; never edits content."""
    lines = [l.strip() for l in text.split("\n") if l.strip()]
    if not lines:
        return {"max_line_repeat": 0, "distinct_ratio": 0.0, "degenerate": True}
    counts = {}
    for l in lines:
        counts[l] = counts.get(l, 0) + 1
    mx = max(counts.values())
    ratio = len(counts) / len(lines)
    return {"max_line_repeat": mx, "distinct_ratio": round(ratio, 3),
            "degenerate": mx >= 10 or ratio < 0.5}


def job(model, png):
    doc = os.path.splitext(os.path.basename(png))[0]
    outdir = os.path.join(OUT, model)
    os.makedirs(outdir, exist_ok=True)
    txt_p = os.path.join(outdir, doc + ".txt")
    json_p = os.path.join(outdir, doc + ".json")
    if os.path.exists(txt_p) and os.path.exists(json_p) and os.path.getsize(txt_p) > 0:
        log(f"SKIP (exists) {model} {doc}")
        return None

    b64 = base64.b64encode(open(png, "rb").read()).decode()
    attempts = []
    raw, usage = None, None
    for attempt in range(3):  # 1 try + 2 retries
        t0 = time.time()
        try:
            raw, usage = call_once(model, b64, 240)
            attempts.append({"attempt": attempt + 1, "ok": True, "secs": round(time.time() - t0, 1)})
            break
        except Exception as e:
            attempts.append({"attempt": attempt + 1, "ok": False,
                             "secs": round(time.time() - t0, 1),
                             "error": f"{type(e).__name__}: {str(e)[:300]}"})
            log(f"  RETRY {model} {doc} attempt{attempt+1}: {type(e).__name__}: {str(e)[:150]}")
            time.sleep(5 * (attempt + 1))

    rec = {"doc": doc, "model": model, "attempts": attempts, "usage": usage}
    if raw is None:
        rec["status"] = "FAILED"
        rec["fixups"] = []
        log(f"FAIL {model} {doc}")
        with open(os.path.join(outdir, doc + ".error.json"), "w") as f:
            json.dump(rec, f, ensure_ascii=False, indent=2)
        return rec

    with open(os.path.join(outdir, doc + ".raw.txt"), "w") as f:
        f.write(raw)

    text, jraw, fixups = split_sections(raw)
    parsed = parse_json_part(jraw, fixups)
    text = clean_text(text, fixups)

    with open(txt_p, "w") as f:
        f.write(text + "\n")
    with open(json_p, "w") as f:
        json.dump(parsed if parsed is not None else [], f, ensure_ascii=False, indent=2)

    rec["status"] = "OK"
    rec["fixups"] = fixups
    rec["n_text_lines"] = len([l for l in text.split("\n") if l.strip()])
    rec["n_json_items"] = len(parsed) if isinstance(parsed, list) else 0
    rec["json_ok"] = parsed is not None
    rec["secs"] = attempts[-1]["secs"]
    rec["degen"] = degeneration_stats(text)
    log(f"OK   {model} {doc}  {rec['secs']}s lines={rec['n_text_lines']} json={rec['n_json_items']} "
        f"degen={rec['degen']['degenerate']} fix={fixups}")
    return rec


def main():
    only_model = sys.argv[1] if len(sys.argv) > 1 else None
    only_doc = sys.argv[2] if len(sys.argv) > 2 else None
    pngs = sorted(os.path.join(PAGES, f) for f in os.listdir(PAGES) if f.endswith(".png"))
    if only_doc:
        pngs = [p for p in pngs if only_doc in p]
    models = [only_model] if only_model else MODELS
    tasks = [(m, p) for m in models for p in pngs]
    log(f"{len(tasks)} tasks ({len(models)} models x {len(pngs)} pages)")

    results = []
    with ThreadPoolExecutor(max_workers=4) as ex:
        for r in ex.map(lambda a: job(*a), tasks):
            if r:
                results.append(r)

    manifest = os.path.join(OUT, f"manifest_{models[0] if only_model else 'all'}_{int(time.time())}.json")
    with open(manifest, "w") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
    log(f"manifest -> {manifest}")


if __name__ == "__main__":
    main()
