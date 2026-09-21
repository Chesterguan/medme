#!/usr/bin/env python3
"""Extract the demo corpus's document *text* into parser test fixtures.

`generate.sh` renders the corpus into PDFs and scan-look images, which are
gitignored and need macOS tooling to build — so tests can't depend on them.
This script lifts the plain text out of the heredocs instead and writes it to
`packages/parser/tests/fixtures/corpus/`, which IS checked in.

The point is that the fixtures stay *someone else's* text. Parser tests written
from the code's own vocabulary can only prove "the code matches my idea"; a
lane in the doctor's viewer went empty for weeks because every unit test fed
`match_disease` the table's spelling `2型糖尿病` while real reports typeset
`2 型糖尿病`. Re-run this after editing generate.sh; never hand-edit a fixture
to make a test pass.

Usage:  python3 examples/demo-dataset/extract_fixtures.py
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]

# (语料生成脚本, 抽出来的 fixture 目录)。两套语料:张建国(慢病,parser 用)与
# 合成 SLE 病程(profile 用)。合在一个病人身上会让既有 corpus 断言全部漂移。
CORPORA = [
    (ROOT / "examples/demo-dataset/generate.sh", ROOT / "packages/parser/tests/fixtures/corpus"),
    (ROOT / "examples/demo-dataset/generate_sle.sh", ROOT / "packages/profile/testdata/corpus"),
]

# write_txt/write_pdf/write_scan "<name>" [flags…] <<'EOF' … EOF
BLOCK = re.compile(
    r"^write_(?:txt|pdf|scan)\s+\"([^\"]+)\"[^\n<]*<<'EOF'\n(.*?)\n^EOF$",
    re.M | re.S,
)
# Every declaration, so we can prove none were skipped by the pattern above.
DECLARED = re.compile(r"^write_(?:txt|pdf|scan)\s+\"([^\"]+)\"", re.M)


def extract(src_path: pathlib.Path, dst: pathlib.Path) -> int:
    src = src_path.read_text(encoding="utf-8")
    blocks = BLOCK.findall(src)
    declared = DECLARED.findall(src)

    missed = sorted(set(declared) - {name for name, _ in blocks})
    if missed:
        print(f"ERROR: {len(missed)} document(s) declared but not extracted:", file=sys.stderr)
        for m in missed:
            print(f"  {m}", file=sys.stderr)
        print("The heredoc pattern needs updating — do not ship a partial corpus.", file=sys.stderr)
        return 1

    dst.mkdir(parents=True, exist_ok=True)
    for stale in dst.glob("*.txt"):
        stale.unlink()
    for name, body in blocks:
        (dst / f"{pathlib.Path(name).stem}.txt").write_text(body + "\n", encoding="utf-8")

    print(f"extracted {len(blocks)} documents -> {dst.relative_to(ROOT)}")
    return 0


def main() -> int:
    return max(extract(src, dst) for src, dst in CORPORA)


if __name__ == "__main__":
    raise SystemExit(main())
