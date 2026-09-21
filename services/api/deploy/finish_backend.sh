#!/bin/bash
# 后端收尾:RDS 服务关联角色到位后一条命令跑完。幂等:已存在的步骤跳过。
# 用法:bash finish_backend.sh   (需要 aliyun CLI 的 medme profile;密码只进函数环境变量与本地 env.sh / .dbpass(600,不入库))
set -euo pipefail
export PATH=/opt/homebrew/bin:$PATH
HERE=$(cd "$(dirname "$0")" && pwd)
R=cn-hangzhou; VPC=vpc-bp19034pe43gz6pxawixm; VSW=vsw-bp1bjdnil2nrk705a0lcl; ZONE=cn-hangzhou-j
DBNAME=medme; DBUSER=medme_app
say(){ printf '\n== %s\n' "$*"; }

say "1/6 RDS 实例"
IID=$(aliyun rds DescribeDBInstances --RegionId $R 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(next((i['DBInstanceId'] for i in d['Items']['DBInstance'] if i.get('DBInstanceDescription')=='medme-pg'),''))")
if [ -z "$IID" ]; then
  IID=$(aliyun rds CreateDBInstance --RegionId $R --ZoneId $ZONE --Engine PostgreSQL --EngineVersion 16.0 --DBInstanceClass pg.n2e.1c.1m \
    --DBInstanceStorage 20 --DBInstanceStorageType cloud_essd --Category Basic --PayType Postpaid --InstanceNetworkType VPC \
    --VPCId $VPC --VSwitchId $VSW --DBInstanceNetType Intranet --SecurityIPList 10.0.0.0/16 --DBInstanceDescription medme-pg \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['DBInstanceId'])")
  echo "created $IID"
else echo "exists $IID"; fi

say "2/6 等实例 Running(基础版通常 5–10 分钟)"
for i in $(seq 1 90); do
  ST=$(aliyun rds DescribeDBInstanceAttribute --DBInstanceId $IID | python3 -c "import sys,json; print(json.load(sys.stdin)['Items']['DBInstanceAttribute'][0]['DBInstanceStatus'])")
  [ "$ST" = Running ] && break; printf '%s ' "$ST"; sleep 20
done; echo "status=$ST"; [ "$ST" = Running ]

say "3/6 账号与库"
PW_FILE="$HERE/.dbpass"; [ -f "$PW_FILE" ] || { openssl rand -base64 24 | tr -d '/+=' | head -c 28 > "$PW_FILE"; chmod 600 "$PW_FILE"; }
PW=$(cat "$PW_FILE")
aliyun rds CreateAccount --DBInstanceId $IID --AccountName $DBUSER --AccountPassword "$PW" --AccountType Super 2>/dev/null | grep -q RequestId && echo "account created" || echo "account exists/skip"
aliyun rds CreateDatabase --DBInstanceId $IID --DBName $DBNAME --CharacterSetName UTF8 2>/dev/null | grep -q RequestId && echo "db created" || echo "db exists/skip"
aliyun rds GrantAccountPrivilege --DBInstanceId $IID --AccountName $DBUSER --DBName $DBNAME --AccountPrivilege DBOwner 2>/dev/null | grep -q RequestId && echo "dbowner granted" || echo "grant skip"

say "4/6 内网地址"
HOST=$(aliyun rds DescribeDBInstanceNetInfo --DBInstanceId $IID | python3 -c "import sys,json; d=json.load(sys.stdin); n=[x for x in d['DBInstanceNetInfos']['DBInstanceNetInfo'] if x.get('IPType')=='Private']; print(n[0]['ConnectionString'])")
PORT=$(aliyun rds DescribeDBInstanceNetInfo --DBInstanceId $IID | python3 -c "import sys,json; d=json.load(sys.stdin); n=[x for x in d['DBInstanceNetInfos']['DBInstanceNetInfo'] if x.get('IPType')=='Private']; print(n[0]['Port'])")
echo "host=$HOST port=$PORT"

say "5/6 写 env.sh 并更新函数"
python3 - "$HOST" "$PORT" "$DBUSER" "$PW" "$DBNAME" "$HERE/env.sh" <<'PY'
import sys, re, urllib.parse
host, port, user, pw, db, path = sys.argv[1:7]
url = f"postgresql://{user}:{urllib.parse.quote(pw, safe='')}@{host}:{port}/{db}?sslmode=prefer"
s = open(path).read()
s = re.sub(r'^export DATABASE_URL=.*$', f'export DATABASE_URL="{url}"', s, flags=re.M)
open(path, "w").write(s)
PY
chmod 600 "$HERE/env.sh"; bash "$HERE/deploy_api.sh" | tail -2

say "6/6 验证"
sleep 8
for p in /v1/skills/index.json /healthz; do printf '%s -> ' "$p"; curl -s -m 90 -o /tmp/fb_out -w '%{http_code}' "https://medme-api-sphuddkjsn.cn-hangzhou.fcapp.run$p"; echo; head -c 200 /tmp/fb_out; echo; done
