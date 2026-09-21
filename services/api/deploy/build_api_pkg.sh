#!/bin/bash
# 打 FC 自定义运行时的包:services/api + 依赖 + skills/;函数环境变量需设 MEDME_SKILLS_DIR=/code/skills(app.py 在包根)
set -euo pipefail
SRC=$(cd "$(dirname "$0")/../../.." && pwd)   # 仓库根
OUT=$(dirname "$0")/pkg; rm -rf "$OUT"; mkdir -p "$OUT"
cp "$SRC"/services/api/*.py "$SRC"/services/api/requirements.txt "$OUT"/
mkdir -p "$OUT/skills"; cp -R "$SRC"/skills/. "$OUT/skills/"
mkdir -p "$OUT/prompts"; cp "$SRC"/packages/deid/prompts/*.txt "$SRC"/packages/deid/prompts/*.json "$OUT/prompts/"
# FC 自定义运行时(Python 3.9.2, custom.debian11 x86_64):用 pip 下载对应平台的 wheel
python3 -m pip install -r "$SRC"/services/api/requirements.txt -t "$OUT" \
  --platform manylinux2014_x86_64 --python-version 3.9 --only-binary=:all: --implementation cp --upgrade -q
( cd "$OUT" && zip -qr ../medme-api.zip . )
ls -la "$(dirname "$0")/medme-api.zip"
