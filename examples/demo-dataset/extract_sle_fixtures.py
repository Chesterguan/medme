#!/usr/bin/env python3
"""对 packages/profile/testdata/corpus/*.txt 各跑一次 schema 2 抽取,原始模型输出存到
packages/profile/testdata/extractions/<同名>.json。

请求形状逐字镜像 services/api/extract.py 的 _call_deepseek(text 臂):同一份 system
prompt、同一份 extract_params.json、temperature 0、response_format json_object。语料是
合成人物(李静),不脱敏。产出不做 verify —— 那是 Rust 测试的事(llm_fixtures.rs),
fixture 存的是模型说了什么,不是我们信了什么。

用法:DEEPSEEK_API_KEY=$(cat .deepseek_key) python3 examples/demo-dataset/extract_sle_fixtures.py
只重跑一份:... extract_sle_fixtures.py 2026-06-15_处方_协和
"""
import json, os, sys, time, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CORPUS = os.path.join(ROOT, "packages/profile/testdata/corpus")
OUT = os.path.join(ROOT, "packages/profile/testdata/extractions")
PROMPTS = os.path.join(ROOT, "packages/deid/prompts")
BASE = os.environ.get("DEEPSEEK_BASE", "https://api.deepseek.com/v1")
MODEL = os.environ.get("DEEPSEEK_MODEL_TEXT", "deepseek-flash")

with open(os.path.join(PROMPTS, "extract_v2_system.txt"), encoding="utf-8") as f:
    SYSTEM = f.read()
with open(os.path.join(PROMPTS, "extract_params.json"), encoding="utf-8") as f:
    PARAMS = json.load(f)["text"]


def call(text: str) -> dict:
    req = urllib.request.Request(
        f"{BASE}/chat/completions",
        data=json.dumps({
            "model": MODEL,
            "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": text}],
            "response_format": {"type": "json_object"}, "temperature": 0,
            "max_tokens": PARAMS["max_tokens"], "reasoning_effort": PARAMS["reasoning_effort"],
        }).encode(),
        headers={"Authorization": f"Bearer {os.environ['DEEPSEEK_API_KEY']}", "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        out = json.loads(r.read())
    choice = out["choices"][0]
    if choice.get("finish_reason") == "length":
        raise SystemExit(f"truncated by max_tokens: {MODEL}")
    return json.loads(choice["message"]["content"])


def main(only):
    os.makedirs(OUT, exist_ok=True)
    names = sorted(n[:-4] for n in os.listdir(CORPUS) if n.endswith(".txt"))
    if only:
        names = [n for n in names if n == only]
        if not names:
            raise SystemExit(f"no such corpus file: {only}")
    for n in names:
        with open(os.path.join(CORPUS, n + ".txt"), encoding="utf-8") as f:
            text = f.read()
        t0 = time.time()
        parsed = call(text)
        parsed["_model"] = MODEL
        with open(os.path.join(OUT, n + ".json"), "w", encoding="utf-8") as f:
            json.dump(parsed, f, ensure_ascii=False, indent=1)
            f.write("\n")
        print(f"{n}: labs={len(parsed.get('labs', []))} meds={len(parsed.get('meds', []))} "
              f"facts={len(parsed.get('facts', []))} {time.time() - t0:.1f}s")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else None)
