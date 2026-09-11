"""LLM 代理(子项目 A §2)。payload 已在手机上脱敏;这里**不落盘**,只记 token。"""
import json, os, urllib.request

DEEPSEEK_BASE = os.environ.get("DEEPSEEK_BASE", "https://api.deepseek.com/v1")
MODEL_TEXT = "deepseek-v4-flash"
MODEL_VISION = "deepseek-v4-flash-vision-exp"

# 输出 schema v1 逐字来自 spec A §3;子项目 A 负责调 prompt 措辞,schema 字段不改。
SYSTEM_PROMPT_V1 = """你是医疗单据结构化助手。只输出一个 JSON 对象,不要任何解释。所有字符串必须是输入原文的逐字子串;不确定的留空字符串,绝不推断或补全。
{"doc_type":"lab|discharge|outpatient|imaging|prescription|other","doc_date":"YYYY-MM-DD","labs":[{"name":"","value":"","unit":"","ref_low":"","ref_high":"","flag":"H|L|"}],"meds":[{"name":"","dose":"","freq":"","route":""}],"diagnoses":[{"text":"","icd":""}],"impression":"","notes":""}"""


def _call_deepseek(model: str, messages: list) -> dict:
    req = urllib.request.Request(
        f"{DEEPSEEK_BASE}/chat/completions",
        data=json.dumps({"model": model, "messages": messages, "response_format": {"type": "json_object"}, "temperature": 0}).encode(),
        headers={"Authorization": f"Bearer {os.environ['DEEPSEEK_API_KEY']}", "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())


def run(body: dict) -> tuple[dict, int, int]:
    mode = body.get("mode", "text")
    if body.get("schema") != 1:
        raise ValueError("schema")
    if mode == "image":
        content = [{"type": "text", "text": "请按 schema 输出这份单据的内容。"},
                   {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{body['payload']}"}}]
        model = MODEL_VISION
    else:
        content = body["payload"]
        model = MODEL_TEXT
    out = _call_deepseek(model, [{"role": "system", "content": SYSTEM_PROMPT_V1}, {"role": "user", "content": content}])
    text = out["choices"][0]["message"]["content"]
    usage = out.get("usage", {})
    return json.loads(text), int(usage.get("prompt_tokens", 0)), int(usage.get("completion_tokens", 0))
