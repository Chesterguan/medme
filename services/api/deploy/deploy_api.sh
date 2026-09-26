#!/bin/bash
# 部署 medme-api 到函数计算(custom.debian11 / python3.9)。
# 前提:同目录 env.sh 里 export 了 VPC_ID、VSWITCH_ID、SG_ID、PNVS_SIGN_NAME、PNVS_TEMPLATE_CODE;
# 首次创建还要 DATABASE_URL。
# 密钥(DATABASE_URL / API_JWT_SECRET / PHONE_HMAC_KEY):env.sh 给了就用 env.sh 的;没给而函数
# 已存在,就沿用线上函数环境变量里现有的值(不落盘、不打印)——这样重部署不会把已发的
# token 全作废、手机号哈希也对得上旧数据;只有首次创建才现场随机生成。
set -euo pipefail
export PATH=/opt/homebrew/bin:$PATH
HERE=$(dirname "$0"); source "$HERE/env.sh"
: "${VPC_ID:?}" "${VSWITCH_ID:?}" "${SG_ID:?}"
LIVE_JSON=$(aliyun --profile medme fc GET /2023-03-30/functions/medme-api 2>/dev/null || true)
export LIVE_JSON
if [ -z "${DATABASE_URL:-}" ] || [ -z "${API_JWT_SECRET:-}" ] || [ -z "${PHONE_HMAC_KEY:-}" ]; then
  if [ -n "$LIVE_JSON" ]; then
    eval "$(python3 - <<'PY'
import json, os, shlex
env = json.loads(os.environ["LIVE_JSON"]).get("environmentVariables") or {}
for k in ("DATABASE_URL", "API_JWT_SECRET", "PHONE_HMAC_KEY"):
    if not os.environ.get(k) and env.get(k):
        print(f"export {k}={shlex.quote(env[k])}")
PY
)"
  fi
fi
: "${DATABASE_URL:?首次创建需要 env.sh 里给 DATABASE_URL}"
API_JWT_SECRET=${API_JWT_SECRET:-$(openssl rand -hex 32)}
PHONE_HMAC_KEY=${PHONE_HMAC_KEY:-$(openssl rand -hex 32)}
ROOT=$(cd "$HERE/../../.." && pwd)
DEEPSEEK_API_KEY=$(tr -d '[:space:]' < "$ROOT/.deepseek_key")   # 仓库根的 .deepseek_key(不入库)
AK_ID=$(python3 "$HERE/creds.py" medme id)
AK_SECRET=$(python3 "$HERE/creds.py" medme secret)
python3 - <<PY > "$HERE/create.json"
import json, os, sys
env = {
 "DATABASE_URL": os.environ["DATABASE_URL"], "API_JWT_SECRET": "$API_JWT_SECRET", "PHONE_HMAC_KEY": "$PHONE_HMAC_KEY",
 "ALIYUN_ACCESS_KEY_ID": "$AK_ID", "ALIYUN_ACCESS_KEY_SECRET": "$AK_SECRET",
 "PNVS_SIGN_NAME": os.environ.get("PNVS_SIGN_NAME",""), "PNVS_TEMPLATE_CODE": os.environ.get("PNVS_TEMPLATE_CODE",""),
 "APPLE_BUNDLE_ID": "com.medme.mobile",
 "OSS_ACCESS_KEY_ID": "$AK_ID", "OSS_ACCESS_KEY_SECRET": "$AK_SECRET", "OSS_BUCKET": "medme-vault", "OSS_ENDPOINT": "oss-cn-hangzhou.aliyuncs.com",
 "DEEPSEEK_API_KEY": "$DEEPSEEK_API_KEY", "DEEPSEEK_MODEL_TEXT": "deepseek-flash", "DEEPSEEK_MODEL_VISION": "deepseek-flash",
 "MEDME_SKILLS_DIR": "/code/skills", "MEDME_PROMPTS_DIR": "/code/prompts", "PYTHONPATH": "/code", "PATH": "/code/bin:/usr/local/bin:/usr/bin:/bin",
}
body = {"functionName": "medme-api", "runtime": "custom.debian11", "handler": "index.handler",
 "memorySize": 1024, "cpu": 0.5, "diskSize": 512, "timeout": 150, "instanceConcurrency": 10,
 "code": {"ossBucketName": "medme-deploy", "ossObjectName": "medme-api.zip"},
 "customRuntimeConfig": {"command": ["python3", "-m", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "9000"], "port": 9000},
 "environmentVariables": env,
 "vpcConfig": {"vpcId": os.environ["VPC_ID"], "vSwitchIds": [os.environ["VSWITCH_ID"]], "securityGroupId": os.environ["SG_ID"]}}
print(json.dumps(body))
PY
if [ -n "$LIVE_JSON" ]; then
  python3 -c "import json;d=json.load(open('$HERE/create.json'));d.pop('functionName');d.pop('runtime');print(json.dumps(d))" > "$HERE/update.json"
  aliyun --profile medme fc PUT /2023-03-30/functions/medme-api --header "Content-Type=application/json" --body "$(cat "$HERE/update.json")" >/dev/null && echo "updated medme-api"
else
  aliyun --profile medme fc POST /2023-03-30/functions --header "Content-Type=application/json" --body "$(cat "$HERE/create.json")" >/dev/null && echo "created medme-api"
  aliyun --profile medme fc POST /2023-03-30/functions/medme-api/triggers --header "Content-Type=application/json" \
    --body '{"triggerName":"http","triggerType":"http","triggerConfig":"{\"authType\":\"anonymous\",\"methods\":[\"GET\",\"POST\",\"PUT\",\"DELETE\"]}"}' \
    | python3 -c "import sys,json; print('url:', json.load(sys.stdin)['httpTrigger']['urlInternet'])"
fi
rm -f "$HERE/create.json" "$HERE/update.json"
