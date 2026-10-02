# 拷成 env.sh(不入库)再填。deploy_api.sh 会 source 它。
# export DATABASE_URL="postgresql://medme_app:<密码>@pgm-bp1o4l88va6pz8j3.pg.rds.aliyuncs.com:5432/medme?sslmode=prefer"   # 只在首次创建函数时填
export VPC_ID=vpc-bp19034pe43gz6pxawixm
export VSWITCH_ID=vsw-bp1bjdnil2nrk705a0lcl
export SG_ID=sg-bp1d1d4t03k1rpcn3ucz
export PNVS_SIGN_NAME=""        # 号码认证服务 → 短信认证 → 参数配置 → 签名配置 → 赠送签名里任选一个,原样抄(免审核)
export PNVS_TEMPLATE_CODE=""    # 同处 → 模板配置 → 赠送模板,「登录/注册」是 100001(免审核;必须与赠送签名搭配)
# API_JWT_SECRET / PHONE_HMAC_KEY / DATABASE_URL:函数已存在时 deploy_api.sh 自动沿用线上的值,这里不用填;只有首次创建才需要 DATABASE_URL(密钥随机生成)。
