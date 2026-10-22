# packages/profile/testdata

`corpus/` 是李静三年 SLE 合成语料(`examples/demo-dataset/generate_sle.sh` 经 `extract_fixtures.py` 抽出,不手编);`golden_profile_view.json` 由 `tests/golden_sle_course.rs` 钉住(`UPDATE_GOLDEN=1` 重生成)。

## extractions/

`corpus/` 每份文本对应一份 **原始** DeepSeek schema 2 输出,由
`examples/demo-dataset/extract_sle_fixtures.py` 生成(temperature 0,与线上
`services/api/extract.py` 同 prompt 同参数)。未 verify、未 restore;`tests/llm_fixtures.rs`
读入时跑 `deid::verify`。不手编;prompt 或语料改了就重跑脚本并重新核对测试断言。
`_model` 字段记录生成用的模型名。

## corpus-jane/

通用病程档案层(2026-10-22 spec)的合成英文语料:**Doe, Jane**,瓣膜置换(2024-03)+
侵袭性肺曲霉病(2025-06),华法林 2025-01-14 减量,伏立康唑 2025-11-17 原文写停。
由 `examples/demo-dataset/generate_jane.sh` **直接写进本目录**(门诊记录是函数模板出来的,
`extract_fixtures.py` 的 heredoc 扫描抬不动它);每份 `.txt` 配同 stem 的 `.json`(Epic 适配器
样式 sidecar:labs 带 `loinc`、diagnoses 带 `icd`、meds 带 `rxnorm`),两者出自同一组变量,
`tests/generic_jane.rs` 用 `deid::verify` 钉住 sidecar 逐字在文本里。golden:
`golden_generic_view.json`(`UPDATE_GOLDEN=1` 重生成后人工看 diff)。不手编。
