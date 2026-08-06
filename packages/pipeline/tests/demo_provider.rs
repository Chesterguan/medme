//! 时间线卡片上的医院名 —— 逐份钉住 `apps/mobile_flutter/rust/demo-data` 的 22 份。
//!
//! ## 为什么这个测试非在 `pipeline` 里不可
//!
//! `core-model` 的单测只能喂手写字符串,而这条缺陷的第一层根因恰恰**只在真实
//! PDF 的字节里存在**:生成 corpus 的字体把常用字映射到部首码位,`pdf-extract`
//! 于是吐出 `四 川 ⼤ 学 华 ⻄ 医 院`(`⼤` U+2F24、`⻄` U+2EC4)。手写测试串里
//! 的 `大`/`西` 是正字,永远复现不出来。
//!
//! 更要命的是 **量错路会得出相反结论**:`parser::extract` 折叠了部首,`pdftotext`
//! 也不吐部首码位 —— 拿这两者量,22 份看着全好。app 走的是另一条路
//! (`pipeline::ingest_pdf` → `ocr::recognize_pdf_mixed` →
//! `pdf_extract::extract_text_from_mem_by_pages`),**不经过** `parser::extract`,
//! 部首原样落进 `ocr_result.text`,`extract_provider` 就在那份文本上跑。所以这个
//! 测试必须、且只能走 `recognize_pdf_mixed` 那条真路。
//!
//! ## 判据(产品定死)
//!
//! 时间线卡片(`archive_screen.dart` 的 `门诊 · {provider}`)存在的全部意义就是
//! 回答「这次是在哪家看的」。所以:
//!
//! * 文档里有医院名 → **必须**抽出来,不许为空;
//! * 允许带噪(`王涛北京协和医院` 比空着强,用户一眼看出多了俩字);
//! * **不许**是医嘱片段(`建议立即转上级医院` 是泛指,不是一家医院);
//! * 只有文档里确实没有机构时才是 `None` —— 家庭自测记录那一份。

use std::path::{Path, PathBuf};

/// 22 份 demo 各自应当抽到的 provider。`None` 只允许出现在确实没有机构的文档上。
///
/// 期望值全部是**干净的完整名**:这一版切得准,没有一份需要动用带噪兜底。哪天
/// 某份退化成带人名前缀的串,这里也应当照实改成那个带噪值再配一句为什么 ——
/// 唯独不许改成 `None`。
const EXPECTED: &[(&str, Option<&str>)] = &[
    // corpus/
    ("2023-04-24_出院记录_脑梗死.pdf", Some("北京协和医院")),
    ("2023-05-20_门诊病历_脑梗后随访.pdf", Some("北京协和医院")),
    ("2023-06-15_检验报告_血脂血糖.pdf", Some("北京协和医院")),
    ("2023-09-08_处方_神经内科.pdf", Some("北京协和医院")),
    ("2023-11-02_头颅MRI_脑梗随访.pdf", Some("四川大学华西医院")),
    ("2024-01-15_检验报告_血脂.pdf", Some("四川大学华西医院")),
    (
        "2024-03-22_腹部超声_脂肪肝.pdf",
        Some("上海交通大学医学院附属瑞金医院"),
    ),
    // 抬头是紧凑写法(不是逐字拉开),靠第二轮 token 扫描命中。
    ("2024-05-18_检验报告_肾功血糖.pdf", Some("四川大学华西医院")),
    ("2024-06-10_处方_心内科.pdf", Some("复旦大学附属中山医院")),
    (
        "2025-05-06_检验报告_血脂血糖.pdf",
        Some("上海交通大学医学院附属瑞金医院"),
    ),
    (
        "2025-07-30_病理报告_胃活检.pdf",
        Some("浙江大学医学院附属第一医院"),
    ),
    ("2025-11-05_检验报告_血常规肾功能.pdf", Some("北京协和医院")),
    ("2026-02-14_检验报告_肾功血脂.pdf", Some("北京协和医院")),
    (
        "2026-04-12_门诊病历_高血压随访.pdf",
        Some("复旦大学附属中山医院"),
    ),
    // 家庭自测记录:抬头是病人自己的名字,全篇没有任何机构 —— 这一份就该是 None。
    ("2026-04-30_血压记录_家庭监测.pdf", None),
    ("2026-06-20_处方_内分泌科.pdf", Some("四川大学华西医院")),
    // scenarios/
    // 抬头 `河 北 省 X X 县 ⼈ ⺠ 医 院`:夹拉丁 `XX`,`⺠` 又是 U+2EA0(CJK
    // Radicals Supplement,没有 NFKC 分解)。两处各自都足以让抬头匹配失败,
    // 失败后扫描滑到正文,把医嘱 `建议立即转上级医院` 当成院名印出来。
    (
        "2023-04-24_急诊记录_县医院转院.pdf",
        Some("河北省XX县人民医院"),
    ),
    (
        "2024-08-08_检验报告_术前评估.pdf",
        Some("复旦大学附属华山医院"),
    ),
    (
        "2024-08-09_手术记录_腹腔镜胆囊切除.pdf",
        Some("复旦大学附属华山医院"),
    ),
    (
        "2024-08-10_病理报告_胆囊切除标本.pdf",
        Some("复旦大学附属华山医院"),
    ),
    (
        "2024-08-12_出院记录_胆囊切除术后.pdf",
        Some("复旦大学附属华山医院"),
    ),
    (
        "2025-02-18_胸部CT_肺结节.pdf",
        Some("中国医学科学院肿瘤医院"),
    ),
];

fn demo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../apps/mobile_flutter/rust/demo-data")
}

fn collect_pdfs(dir: &Path, out: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(dir).expect("demo-data readable") {
        let p = entry.expect("dir entry").path();
        if p.is_dir() {
            collect_pdfs(&p, out);
        } else if p.extension().and_then(|e| e.to_str()) == Some("pdf") {
            out.push(p);
        }
    }
}

/// app 真实路径下每一份的 provider —— 和 `pipeline::ingest_pdf` 存进
/// `ocr_result.text` 的是同一份文本。
fn provider_of(path: &Path) -> Option<String> {
    let bytes = std::fs::read(path).expect("read demo pdf");
    let mixed = ocr::recognize_pdf_mixed(&bytes).expect("demo pdf parses");
    core_model::extract_provider(&mixed.text())
}

#[test]
fn every_demo_document_with_a_hospital_shows_it() {
    let mut pdfs = Vec::new();
    collect_pdfs(&demo_root(), &mut pdfs);
    assert_eq!(
        pdfs.len(),
        EXPECTED.len(),
        "demo-data 的份数变了({} 份,期望表里 {} 条)—— 新增/删除的那份必须在 \
         EXPECTED 里对应增删,不能让它悄悄溜过这道闸",
        pdfs.len(),
        EXPECTED.len()
    );

    let mut wrong = Vec::new();
    for (name, want) in EXPECTED {
        let path = pdfs
            .iter()
            .find(|p| p.file_name().and_then(|n| n.to_str()) == Some(*name))
            .unwrap_or_else(|| panic!("demo-data 里找不到 {name}"));
        let got = provider_of(path);
        if got.as_deref() != *want {
            wrong.push(format!("  {name}\n    期望 {want:?}\n    实得 {got:?}"));
        }
    }
    assert!(
        wrong.is_empty(),
        "{} 份 demo 的医院名不对:\n{}",
        wrong.len(),
        wrong.join("\n")
    );
}

/// 上面那条按逐份期望值钉;这条只钉产品那句底线,和期望表里具体写了什么无关:
/// **有医院名就不许空着,也不许印一句医嘱**。哪天有人图省事把 EXPECTED 里某份
/// 改成 `None` 蒙混过关,这条会拦住。
#[test]
fn no_document_that_names_a_hospital_is_left_blank_or_reads_as_an_order() {
    let mut pdfs = Vec::new();
    collect_pdfs(&demo_root(), &mut pdfs);
    pdfs.sort();
    for path in &pdfs {
        let name = path.file_name().unwrap().to_string_lossy().to_string();
        let bytes = std::fs::read(path).expect("read demo pdf");
        let mixed = ocr::recognize_pdf_mixed(&bytes).expect("demo pdf parses");
        let text = core_model::normalize_cjk_radicals(&mixed.text());
        // 「这份文档到底有没有自报家门」用一条与 extract_provider 无关的判据:
        // 折完部首后,去掉全部空白,文本里出现过 `医院`/`医学中心` 字样。
        let compact: String = text.chars().filter(|c| !c.is_whitespace()).collect();
        let names_a_hospital = compact.contains("医院") || compact.contains("医学中心");
        let got = core_model::extract_provider(&mixed.text());
        if names_a_hospital {
            let got = got.unwrap_or_else(|| {
                panic!("{name}:文本里出现了「医院」却没抽出任何名字 —— 就诊卡会是光秃秃的「门诊」")
            });
            for order in ["上级医院", "下级医院", "当地医院", "外院", "我院", "本院"]
            {
                assert!(
                    !got.ends_with(order),
                    "{name}:抽到的是医嘱里的泛指「{got}」,不是一家医院的名字"
                );
            }
            assert!(
                got.ends_with("医院") || got.ends_with("医学中心"),
                "{name}:抽到的 {got:?} 不像机构名"
            );
        } else {
            assert_eq!(
                got, None,
                "{name}:文本里根本没有「医院」二字,不该凭空抽出 {got:?}"
            );
        }
    }
}
