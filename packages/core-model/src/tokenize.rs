use jieba_rs::Jieba;
use std::sync::OnceLock;

fn jieba() -> &'static Jieba {
    static J: OnceLock<Jieba> = OnceLock::new();
    J.get_or_init(Jieba::new)
}

/// 中文分词 + 英文按原样;结果用单空格连接,供 FTS body 与 MATCH 查询共用。
pub fn tokenize(text: &str) -> String {
    jieba().cut(text, false).join(" ")
}

#[cfg(test)]
mod tests {
    use super::tokenize;
    #[test]
    fn splits_chinese_and_keeps_english() {
        let out = tokenize("肌酐 Creatinine 升高");
        // 分词后应有空格分隔的多个 token,且保留英文原词
        assert!(out.contains("肌酐"));
        assert!(out.contains("Creatinine"));
        assert!(out.split_whitespace().count() >= 3);
    }
}
