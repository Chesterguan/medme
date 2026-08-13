#!/usr/bin/env python3
"""把 MedRepBench 的 items 列规范化成一行一条的 TSV,供 Rust 评分器直接读。

参考区间在原标注里有 18 种写法,统一在这一处解析成 (low, high),避免 Rust 侧再写
一遍、两边口径打架。**解析不了的不猜**,标成 qual(定性/不可比),评分时从"参考
区间归属"这条指标的分母里排除,并单独报数量。

输出列:image \t name \t value \t unit \t low \t high \t kind
  value: 纯数字;非数字(阴性/未见等)记 NA,kind=qual
  low/high: 数字或 NA
  kind: num(数值型) | qual(定性型)
"""
import csv, json, re, sys

D = "/private/tmp/claude-501/-Volumes-extraSupply-Projects-openmed/3c224b0f-768e-498c-b5ef-328c3ba3b549/scratchpad/datasets/medrepbench"
csv.field_size_limit(sys.maxsize)

NUM = r"[-+]?\d+(?:\.\d+)?"


def parse_range(s):
    """→ (low, high) 或 (None, None)。认不出就 (None, None),不猜。"""
    s = (s or "").strip()
    if not s:
        return None, None
    # 去掉包裹的括号和结尾的星号标记:(0.5-2.5) / 115-150※
    s = s.strip("()（）").rstrip("※*").strip()
    # a±b 是「均值±标准差」,不是参考区间,不折算 —— 折算了会把一个统计描述
    # 冒充成临床区间。
    if "±" in s:
        return None, None
    # 单边:<b / ≤b / >a / ≥a
    m = re.fullmatch(rf"[<＜]\s*({NUM})", s) or re.fullmatch(rf"≤\s*({NUM})", s)
    if m:
        return None, float(m.group(1))
    m = re.fullmatch(rf"[>＞]\s*({NUM})", s) or re.fullmatch(rf"≥\s*({NUM})", s)
    if m:
        return float(m.group(1)), None
    # 双边:a-b / a~b / a－b / **a--b**。
    #
    # `a--b` 是这份真值里非常常见的写法(618 条),意思是「a 到 b」,那个多出来的
    # 短横是排版,不是负号。此前这里用 `({NUM})\s*[-~－—]\s*({NUM})` 且 NUM 允许
    # 带符号,于是 `9.4--12.5` 被读成 (9.4, -12.5),再经 lo<=hi 交换变成
    # **(-12.5, 9.4)** —— 618 条真值区间被读反,占区间可评条目的三分之一强,
    # 把所有臂的「参考区间归属」都系统性地压低了。(是 B 线在自己的私有副本上
    # 复现出来报给我的,不是我自己发现的。)
    #
    # 改法:两端**都不允许带符号**,分隔符吃掉连续的短横/波浪。真实化验参考区间
    # 里下限为负的情况极少(碱剩余 BE 之类),这种写法在这里会解析不出来 → 返回
    # (None, None) → 该条从区间指标的分母里排除。**宁可少算也不算错**。
    m = re.fullmatch(r"(\d+(?:\.\d+)?)\s*[-~－—]+\s*(\d+(?:\.\d+)?)", s)
    if m:
        lo, hi = float(m.group(1)), float(m.group(2))
        return (lo, hi) if lo <= hi else (hi, lo)
    return None, None


def main():
    out = open(f"{D}/gt.tsv", "w")
    n_doc = n_item = n_num = n_qual = n_range = 0
    for r in csv.DictReader(open(f"{D}/meta.csv")):
        try:
            if json.loads(r["meta"]).get("type") != "Laboratory":
                continue
            items = json.loads(r["items"])
        except Exception:
            continue
        if not isinstance(items, list):
            continue
        n_doc += 1
        for it in items:
            if not isinstance(it, dict):
                continue
            name = str(it.get("item_name", "")).strip()
            if not name:
                continue
            val = str(it.get("item_value", "")).strip()
            unit = str(it.get("item_unit", "")).strip()
            lo, hi = parse_range(str(it.get("item_range", "")))
            n_item += 1
            if re.fullmatch(NUM, val):
                kind, v = "num", val
                n_num += 1
                if lo is not None or hi is not None:
                    n_range += 1
            else:
                kind, v = "qual", "NA"
                n_qual += 1
            f = lambda x: "NA" if x is None else repr(x)
            out.write(
                f"{r['image']}\t{name}\t{v}\t{unit}\t{f(lo)}\t{f(hi)}\t{kind}\n"
            )
    out.close()
    print(f"{n_doc} 份,{n_item} 条:数值型 {n_num},定性型 {n_qual}")
    print(f"其中数值型里参考区间能解析成数字区间的 {n_range} 条")


if __name__ == "__main__":
    main()
