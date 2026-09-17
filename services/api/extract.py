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
# schema 2:族级病程 facts(spec §3)。措辞是免疫介导慢病族共用的,prompt 里不带
# 任何具体病名——服务端从这份 prompt 看不出用户开的是哪个 skill(spec §8)。
with open(os.path.join(_PROMPTS_DIR, "extract_v2_system.txt"), encoding="utf-8") as _f:
    SYSTEM_PROMPT_V2 = _f.read()


# 请求参数与评测臂(`packages/ocr/examples/medrep_llm.rs`)共用同一份文件,理由与
# prompt 那两份完全一样:**两边发的请求必须逐字段相同,否则线上抽取和评测数字量的
# 不是同一个模型行为**。改哪边的行为都只改那份 JSON。
#
# **按臂分开**(text / image),因为两条臂的截断风险根本不是一个量级:图片档每份
# ~3000 completion token,文本档 ~3400,但**合并后的多页文本**会把 reasoning 顶到
# 8190 而正文 0 字(sim-smoke-3-report.md §4:3 页 3009 字,重放 3 次 2 次 length)。
#
# `max_tokens`:`deepseek-flash` 是推理模型,不封顶时 `reasoning_tokens` 会自己跑飞
# ——实测一张血常规照片烧掉 10124 个 completion token(其中 9354 是 reasoning),
# 外推 >70 s,正好顶爆下面那个上游超时,用户侧就是「抽了两分钟,什么都没有」
# (extract-repro-report.md §1)。22 行的化验表正文实测只要 ~800 token。
# 图片档 **8192**:6000 那一版在 MedRepBench 683 份里有 6 份稳定截断,8192 给长表
# 留余量,同时拦得住失控推理(那一类实测烧到 10000+)。
# 文本档 **16384**:8192 在 50 份抽样上有 **5 份(10%)**被 length 截断(task-23 实测),
# 多页合并那份更是 2/3 概率。抬一档是 task-23 实测比出来的:见下面 `reasoning_effort`。
#
# `reasoning_effort`:`none` 会整个关掉推理,`low` 只是把预算收紧——这是 DeepSeek
# 文档里 `/chat/completions` 唯一能约束推理长度的参数(none/low/high/max)。
# **两档都实测过**(task-23,同 45 份、同分母 156 条可比):`none` 的项目召回
# 64.7% / 值-名配对 62.2%,比 `low` 的 68.6% / 64.7% 低 3.9 / 2.5 个点,超出
# 「1 个点以内就换」的判据,所以两条臂都留 `low`,改抬文本档的 `max_tokens`。
with open(os.path.join(_PROMPTS_DIR, "extract_params.json"), encoding="utf-8") as _f:
    REQUEST_PARAMS = json.load(_f)


class SchemaError(Exception):
    """请求本身不满足 schema v1(client 的错,对应 400)。"""


class UpstreamError(Exception):
    """DeepSeek 请求失败,或返回了解不出 schema v1 的内容(不是 client 的错,对应
    502;不回显上游原文——那可能是模型吐出来的任意内容,不能直接转发给调用方)。"""


class TruncatedError(UpstreamError):
    """上游把回答截断在 `max_tokens` 上。**仍然是 502**(对客户端的处置一样:重试
    一次,不成就退回正则),但 detail 是另一个码 —— 这两件事的成因和修法完全不同
    (截断要抬预算/拆页,宕机要等上游),日志里混成一个 `upstream` 就分不出来了。"""


class _Truncated(Exception):
    """内部哨兵:把「截断」从 `run()` 那个大 try 里原样带出来(见下面两条 except)。"""


def _call_deepseek(arm: str, model: str, messages: list) -> dict:
    params = REQUEST_PARAMS[arm]
    req = urllib.request.Request(
        f"{DEEPSEEK_BASE}/chat/completions",
        data=json.dumps({"model": model, "messages": messages, "response_format": {"type": "json_object"}, "temperature": 0,
                         "max_tokens": params["max_tokens"], "reasoning_effort": params["reasoning_effort"]}).encode(),
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
    schema = body.get("schema")
    # 老 App 发 1、新 App 发 2,两条都在线;3 和别的形状照旧 400。
    # `is` 比较避开 True == 1 这个 Python 陷阱(bool 是 int 的子类)。
    if schema is not True and schema == 1:
        system_prompt = SYSTEM_PROMPT_V1
    elif schema is not True and schema == 2:
        system_prompt = SYSTEM_PROMPT_V2
    else:
        raise SchemaError("schema")
    if mode == "image":
        payload = body.get("payload")
        if not payload:
            raise SchemaError("payload")
        content = [{"type": "text", "text": IMAGE_USER_TEXT},
                   {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{payload}"}}]
        model = MODEL_VISION
        arm = "image"
    else:
        content = body.get("payload")
        if not content:
            raise SchemaError("payload")
        model = MODEL_TEXT
        arm = "text"
    try:
        out = _call_deepseek(arm, model, [{"role": "system", "content": system_prompt}, {"role": "user", "content": content}])
        choice = out["choices"][0]
        # 被 MAX_TOKENS 截断的回答**不是**结果:JSON 断在半截,`json.loads` 多半会炸,
        # 但偶尔也会恰好断在一个合法的位置上,于是我们把一份**缺了后半张表**的抽取
        # 当成完整结果落进保险箱。显式判掉,归为上游错误(502),让客户端退回正则 ——
        # 少几条总比悄悄少半张表强。
        if choice.get("finish_reason") == "length":
            raise _Truncated("truncated by max_tokens")
        text = choice["message"]["content"]
        usage = out.get("usage", {})
        parsed = json.loads(text)
    except _Truncated as e:  # 截断单独一个码,别和上游宕机混在一条日志里
        raise TruncatedError("upstream_truncated") from e
    except Exception as e:  # 上游 HTTP 失败 / 返回形状不对 / 内容不是合法 JSON,统统算上游的错
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
