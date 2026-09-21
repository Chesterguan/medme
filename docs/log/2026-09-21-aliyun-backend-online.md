# 2026-09-21 · 后端 API 在阿里云上线

- `medme-api` 函数(FC 3.0,custom.debian11)挂 VPC,连 RDS PostgreSQL 16 基础版,HTTP 触发器 `https://medme-api-sphuddkjsn.cn-hangzhou.fcapp.run`;`/v1/skills/index.json` 200,病程档案包可拉取。CI 变量 `MEDME_API_BASE` 已指向。
- 配置现状与操作手册:`docs/ops/aliyun.md`;脚本:`services/api/deploy/`。
- 未完:短信签名/模板(登录验证码发不出);`AdministratorAccess` 待撤。
- 代价:三轮权限来回(VPC → ECS 安全组 → RDS 服务关联角色),下次一次列全见 `docs/ops/aliyun.md` §1。
