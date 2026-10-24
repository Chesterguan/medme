#!/usr/bin/env python3
"""把《疾病分类与代码国家临床版 2.0(2022 汇总版)》xlsx 派生成两列中文名表 icd10_zh.json。

只分发「码 + 中文名」两列,不分发原文件;派生规则与已知缺口见 icd10_zh_methodology.md。
用法:python3 -I build_icd10_zh.py <xlsx> <out.json>   (只依赖 openpyxl)

规则(对 sheet「2.0(2022版)」每一行,码先剥 †* 与空白):
  Xnn.d00        → sub4[Xnn.d] = 疾病名称          WHO 四位亚目本身(国内扩展位为 00)
  Xnn.x00        → cat3[Xnn]   = 疾病名称          WHO 只有三位的类目(临床版用 x 占位)
  Xnn.900        → cat3[Xnn]   = 名称去尾部「,未特指」 仅当上一条没给出 cat3 时作兜底
  带 x 扩展(A00.000x001)与其余六位扩展一律跳过 —— Epic 永远不会发出它们。
"""
import hashlib
import json
import re
import sys
from datetime import date

import openpyxl

SHEET = "2.0（2022版）"
SOURCE = {
    "title": "疾病分类与代码国家临床版2.0(2022汇总版)",
    "publisher": "河南省卫生健康委员会 病案管理站点 hncis.hnwsjk.cn(国家卫健委统计信息中心组织修订)",
    "url": "http://hncis.hnwsjk.cn/bingan/contents/248/4170.html",
    "sheet": SHEET,
}
SUB4 = re.compile(r"^([A-Z]\d\d)\.(\d)00$")
CAT3_X = re.compile(r"^([A-Z]\d\d)\.x00$")
CAT3_9 = re.compile(r"^([A-Z]\d\d)\.900$")
UNSPEC = re.compile(r"[,，]?\s*(未特指的?|其他特指的?)$")


def main(xlsx: str, out: str) -> int:
    with open(xlsx, "rb") as f:
        sha = hashlib.sha256(f.read()).hexdigest()
    ws = openpyxl.load_workbook(xlsx, read_only=True)[SHEET]
    rows = ws.iter_rows(values_only=True)
    header = next(rows)
    assert header[0] == "主要编码" and header[2] == "疾病名称", header
    sub4, cat3, cat3_fallback = {}, {}, {}
    for r in rows:
        code = str(r[0] or "").strip().rstrip("†*").strip()
        name = str(r[2] or "").strip()
        if not code or not name:
            continue
        if m := SUB4.match(code):
            sub4[f"{m.group(1)}.{m.group(2)}"] = name
        elif m := CAT3_X.match(code):
            cat3[m.group(1)] = name
        # `.900` 既是 WHO 亚目 Xnn.9(进 sub4),也是类目名的兜底来源 —— 两边都要,不是 elif。
        if m := CAT3_9.match(code):
            cat3_fallback[m.group(1)] = UNSPEC.sub("", name)
    for k, v in cat3_fallback.items():
        cat3.setdefault(k, v)
    assert len(sub4) >= 8500 and len(cat3) >= 1300, (len(sub4), len(cat3))
    doc = {
        "version": "clinical-2.0-2022",
        "source": {**SOURCE, "sha256": sha, "fetched": date.today().isoformat()},
        "sub4": dict(sorted(sub4.items())),
        "cat3": dict(sorted(cat3.items())),
    }
    with open(out, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=0)
        f.write("\n")
    print(f"sub4 {len(sub4)} cat3 {len(cat3)} I35.0={sub4['I35.0']} I10={cat3['I10']} "
          f"Z79 {'present' if 'Z79' in cat3 else 'absent'} N18.3 {'present' if 'N18.3' in sub4 else 'absent'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
