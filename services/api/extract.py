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


# 请求参数与评测臂(`packages/ocr/examples/medrep_llm.rs`)共用同一份文件,理由与
# prompt 那两份完全一样:**两边发的请求必须逐字段相同,否则线上抽取和评测数字量的
# 不是同一个模型行为**。改哪边的行为都只改那份 JSON。
#
# `max_tokens`:`deepseek-flash` 是推理模型,不封顶时 `reasoning_tokens` 会自己跑飞
# ——实测一张血常规照片烧掉 10124 个 completion token(其中 9354 是 reasoning),
# 外推 >70 s,正好顶爆下面那个上游超时,用户侧就是「抽了两分钟,什么都没有」
# (extract-repro-report.md §1)。22 行的化验表正文实测只要 ~800 token,6000 足够宽。
#
# `reasoning_effort`:`none` 会整个关掉推理(表格读数会掉条),`low` 只是把预算收紧
# ——这是 DeepSeek 文档里 `/chat/completions` 唯一能约束推理长度的参数
# (none/low/high/max)。与 `max_tokens` 是两道独立的闸:前者限「想多久」,后者限
# 「最多吐多少」,单靠后者只会让请求在推理中途被截断、依然拿不到结果(实测
# high + 6000 上限 = 24 s 后 content 为空)。
with open(os.path.join(_PROMPTS_DIR, "extract_v1_params.json"), encoding="utf-8") as _f:
    REQUEST_PARAMS = json.load(_f)
MAX_TOKENS = REQUEST_PARAMS["max_tokens"]
REASONING_EFFORT = REQUEST_PARAMS["reasoning_effort"]


class SchemaError(Exception):
    """请求本身不满足 schema v1(client 的错,对应 400)。"""


class UpstreamError(Exception):
    """DeepSeek 请求失败,或返回了解不出 schema v1 的内容(不是 client 的错,对应
    502;不回显上游原文——那可能是模型吐出来的任意内容,不能直接转发给调用方)。"""


def _call_deepseek(model: str, messages: list) -> dict:
    req = urllib.request.Request(
        f"{DEEPSEEK_BASE}/chat/completions",
        data=json.dumps({"model": model, "messages": messages, "response_format": {"type": "json_object"}, "temperature": 0,
                         "max_tokens": MAX_TOKENS, "reasoning_effort": REASONING_EFFORT}).encode(),
        headers={"Authorization": f"Bearer {os.environ['DEEPSEEK_API_KEY']}", "Content-Type": "application/json"},
        method="POST",
    )
    # 120 s 而不是 60 s:上面两道闸把正常延迟压到 ~20 s,但慢一点的图仍会在 60 s 附近
    # 徘徊,而这一趟失败的代价是整份文档「没内容」。客户端那边 `extractTimeout`
    # (`cloud_extract.dart`)必须比这个宽。
    with urllib.request.urlopen(req, timeout=120) as r:
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
        choice = out["choices"][0]
        # 被 MAX_TOKENS 截断的回答**不是**结果:JSON 断在半截,`json.loads` 多半会炸,
        # 但偶尔也会恰好断在一个合法的位置上,于是我们把一份**缺了后半张表**的抽取
        # 当成完整结果落进保险箱。显式判掉,归为上游错误(502),让客户端退回正则 ——
        # 少几条总比悄悄少半张表强。
        if choice.get("finish_reason") == "length":
            raise ValueError("truncated by max_tokens")
        text = choice["message"]["content"]
        usage = out.get("usage", {})
        parsed = json.loads(text)
    except Exception as e:  # 上游 HTTP 失败 / 返回形状不对 / 被截断 / 内容不是合法 JSON,统统算上游的错
        raise UpstreamError("upstream") from e
    # 实际用的模型名回给客户端。抽取结果要连模型版本一起落进保险箱(溯源:这条结果
    # 是谁抽的),而那个名字只有这里知道 —— MODEL_TEXT/MODEL_VISION 都是环境变量,
    # 运维随时能换,客户端硬编码一个默认值就是在溯源上说谎。
    # 多出来的这个 key 不会进保险箱:`deid::verify` 的结构体没有 deny_unknown_fields,
    # 落盘的 result_json 是由校验后的 extraction 重新序列化出来的。
    # 上游吐出来的 JSON 不是对象(数组/字面量)时不硬塞 —— 那本来就是坏数据,
    # 客户端的 commit 会拒,别在这儿多炸一个 500。
    if isinstance(parsed, dict):
        parsed["model"] = model
    return parsed, int(usage.get("prompt_tokens", 0)), int(usage.get("completion_tokens", 0))
