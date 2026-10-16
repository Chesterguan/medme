# packages/profile/testdata

`corpus/` 是李静三年 SLE 合成语料(`examples/demo-dataset/generate_sle.sh` 经 `extract_fixtures.py` 抽出,不手编);`golden_profile_view.json` 由 `tests/golden_sle_course.rs` 钉住(`UPDATE_GOLDEN=1` 重生成)。

## extractions/

`corpus/` 每份文本对应一份 **原始** DeepSeek schema 2 输出,由
`examples/demo-dataset/extract_sle_fixtures.py` 生成(temperature 0,与线上
`services/api/extract.py` 同 prompt 同参数)。未 verify、未 restore;`tests/llm_fixtures.rs`
读入时跑 `deid::verify`。不手编;prompt 或语料改了就重跑脚本并重新核对测试断言。
`_model` 字段记录生成用的模型名。
