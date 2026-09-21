# 拷成 env.sh(不入库)再填。deploy_api.sh 会 source 它。
export DATABASE_URL="postgresql://medme_app:<密码>@pgm-bp1o4l88va6pz8j3.pg.rds.aliyuncs.com:5432/medme?sslmode=prefer"
export VPC_ID=vpc-bp19034pe43gz6pxawixm
export VSWITCH_ID=vsw-bp1bjdnil2nrk705a0lcl
export SG_ID=sg-bp1d1d4t03k1rpcn3ucz
export PNVS_SIGN_NAME=""        # 短信签名(审核通过后填)
export PNVS_TEMPLATE_CODE=""    # 验证码模板 CODE(审核通过后填)
# API_JWT_SECRET / PHONE_HMAC_KEY 不填则每次部署随机生成 —— 生产上要固定:首次部署后从函数环境变量抄回来填在这里。
