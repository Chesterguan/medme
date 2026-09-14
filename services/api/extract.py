"""LLM 代理(子项目 A §2)。payload 已在手机上脱敏;这里**不落盘**,只记 token。"""
import json, os, urllib.request

DEEPSEEK_BASE = os.environ.get("DEEPSEEK_BASE", "https://api.deepseek.com/v1")
MODEL_TEXT = os.environ.get("DEEPSEEK_MODEL_TEXT", "deepseek-flash")
MODEL_VISION = os.environ.get("DEEPSEEK_MODEL_VISION", "deepseek-flash")

# 输出 schema v1 逐字来自 spec A §3;prompt 措辞与评测臂
# `packages/ocr/examples/medrep_llm.rs` 共用同一份文件(`packages/deid/prompts/`),
# 改哪边的行为都只改那份文件——两边 byte-identical 由
# `test_api.py::test_extract_system_prompt_matches_eval_fixture` 兜底。
_PROMPTS_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "packages", "deid", "prompts")
with open(os.path.join(_PROMPTS_DIR, "extract_v1_system.txt"), encoding="utf-8") as _f:
    SYSTEM_PROMPT_V1 = _f.read()
with open(os.path.join(_PROMPTS_DIR, "extract_v1_image_user.txt"), encoding="utf-8") as _f:
    IMAGE_USER_TEXT = _f.read()


class SchemaError(Exception):
    """请求本身不满足 schema v1(client 的错,对应 400)。"""


class UpstreamError(Exception):
    """DeepSeek 请求失败,或返回了解不出 schema v1 的内容(不是 client 的错,对应
    502;不回显上游原文——那可能是模型吐出来的任意内容,不能直接转发给调用方)。"""


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
        raise SchemaError("schema")
    if mode == "image":
        payload = body.get("payload")
        if not payload:
            raise SchemaError("payload")
        content = [{"type": "text", "text": IMAGE_USER_TEXT},
                   {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{payload}"}}]
        model = MODEL_VISION
    else:
        content = body.get("payload")
        if not content:
            raise SchemaError("payload")
        model = MODEL_TEXT
    try:
        out = _call_deepseek(model, [{"role": "system", "content": SYSTEM_PROMPT_V1}, {"role": "user", "content": content}])
        text = out["choices"][0]["message"]["content"]
        usage = out.get("usage", {})
        parsed = json.loads(text)
    except Exception as e:  # 上游 HTTP 失败 / 返回形状不对 / 内容不是合法 JSON,统统算上游的错
        raise UpstreamError("upstream") from e
    return parsed, int(usage.get("prompt_tokens", 0)), int(usage.get("completion_tokens", 0))
