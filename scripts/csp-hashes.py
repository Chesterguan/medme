#!/usr/bin/env python3
"""重算查看器 CSP 里的内联脚本 sha256,并就地改写那条 meta。

**改了 `web/hosted-viewer/index.html` 里任何一段内联 `<script>` 就必须跑一遍。**
不跑的后果是页面白屏:CSP 里的 hash 对不上,浏览器直接拒绝执行脚本,而且这在
本地 `file://` 打开时**看不出来**(CSP meta 照样生效,但很多人只看渲染结果)。

用法:
    python3 scripts/csp-hashes.py           # 改写并报告
    python3 scripts/csp-hashes.py --check   # 只校验,不一致则退出码 1(给 CI 用)
"""
import base64
import hashlib
import re
import sys
from pathlib import Path

HTML = Path(__file__).resolve().parent.parent / "web/hosted-viewer/index.html"

# 只算**内联**脚本(有 src 的不算),且跳过非可执行的数据节点(type="application/json")。
SCRIPT_RE = re.compile(r"<script(?P<attrs>[^>]*)>(?P<body>.*?)</script>", re.S)


def inline_hashes(html: str) -> list[str]:
    out = []
    for m in SCRIPT_RE.finditer(html):
        attrs = m.group("attrs")
        if "src=" in attrs:
            continue
        # 数据节点不执行,CSP 不需要为它放行。
        if 'type="application/json"' in attrs:
            continue
        digest = hashlib.sha256(m.group("body").encode("utf-8")).digest()
        out.append("sha256-" + base64.b64encode(digest).decode())
    return out


def main() -> int:
    html = HTML.read_text(encoding="utf-8")
    want = inline_hashes(html)
    if not want:
        print("✗ 一段内联脚本都没找到 —— 正则是不是漂了?")
        return 1

    # ⚠️ **必须锚在 `<meta http-equiv="Content-Security-Policy">` 内部。**
    # 早先只写 `script-src ([^;]*)`,结果匹配到了文件开头**注释里**那段解释 CSP 的
    # 文字,于是脚本一直在改注释、真正的 meta 纹丝不动 —— 线上页面的 CSP 与脚本
    # 长期对不上,表现是查看器永远转圈(主脚本被浏览器拒绝执行),而 `--check`
    # 还报「一致」。这是这个脚本存在的全部意义所在,不能再错。
    meta_re = re.compile(
        r'(<meta[^>]*http-equiv="Content-Security-Policy"[^>]*content=")([^"]*)(")',
        re.I,
    )
    meta = meta_re.search(html)
    if not meta:
        print("✗ 找不到 Content-Security-Policy 的 meta 标签")
        return 1
    csp_re = re.compile(r"(script-src )([^;]*)(;)")
    m = csp_re.search(meta.group(2))
    if not m:
        print("✗ meta 的 CSP 里找不到 script-src")
        return 1
    # 把相对 meta 内容的偏移换算成相对整篇 HTML 的偏移
    off = meta.start(2)

    class _M:
        def __init__(self, mm, o):
            self._m, self._o = mm, o
        def group(self, i):
            return self._m.group(i)
        def start(self, i):
            return self._m.start(i) + self._o
        def end(self, i):
            return self._m.end(i) + self._o

    m = _M(m, off)

    have = re.findall(r"sha256-[A-Za-z0-9+/=]+", m.group(2))
    if have == want:
        print(f"✓ {len(want)} 段内联脚本,hash 与 CSP 一致")
        return 0

    if "--check" in sys.argv:
        print(f"✗ CSP 与内联脚本不一致\n  CSP 里: {have}\n  实际是: {want}")
        print("  跑 `python3 scripts/csp-hashes.py` 修")
        return 1

    new_src = " ".join(f"'{h}'" for h in want)
    html = html[: m.start(2)] + new_src + html[m.end(2) :]
    HTML.write_text(html, encoding="utf-8")
    print(f"✓ 已更新 {len(want)} 个 hash")
    for h in want:
        print("   ", h)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
