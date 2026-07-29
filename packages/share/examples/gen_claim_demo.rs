//! 产出一份**真实的认领密文**(与医生代拍走同一条生产代码路径:`build_claim_blob`),
//! 外加一份把 `CLAIM_BASE`/CSP 指向本地的查看器副本 —— 于是整条认领链路可以在本机
//! 用浏览器实跑,不必等国内云账号到位。
//!
//! 用法:`cargo run -p medme-share --example gen_claim_demo -- <输出目录>`
//! 产出:
//!   <输出目录>/index.html   查看器(CLAIM_BASE 改成同源 `/c/`)
//!   <输出目录>/c/<id>       密文(nonce‖AES-256-GCM,与整份分享同格式)
//!   <输出目录>/fragment.txt 形如 `c1.<id>.<密钥>`,拼在查看器 URL 的 `#` 后面
//!
//! 刻意只吃桌面 demo-data 语料(不含 12 层 CT 序列):认领包本来就是医生当场拍的
//! 那几份,几百 KB;把影像塞进来只会让本地验证变慢,验不出额外东西。
use core_model::Vault;

fn collect(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return;
    };
    for e in rd.flatten() {
        let p = e.path();
        if p.is_dir() {
            collect(&p, out);
        } else {
            out.push(p);
        }
    }
}

fn main() {
    let out_dir = std::path::PathBuf::from(
        std::env::args()
            .nth(1)
            .unwrap_or_else(|| "target/claim-demo".into()),
    );

    let mut files = Vec::new();
    collect(
        std::path::Path::new("apps/desktop/src-tauri/demo-data"),
        &mut files,
    );
    files.sort();
    assert!(!files.is_empty(), "找不到 demo-data —— 请在仓库根目录运行");

    let tmp = tempfile::tempdir().unwrap();
    let vault = Vault::open(tmp.path()).unwrap();
    let mut doc_ids = Vec::new();
    for p in &files {
        match pipeline::ingest(&vault, p) {
            // ingest 只回 source_file_id,文档 id 要回查一次。
            Ok(r) => match vault.document_by_source_file_id(r.source_file_id) {
                Ok(Some(d)) => doc_ids.push(d.id),
                _ => eprintln!("  无文档记录:{}", p.display()),
            },
            Err(e) => eprintln!("  跳过 {}: {e}", p.display()),
        }
    }
    vault.rebuild_encounters().unwrap();
    println!("导入 {} 份", doc_ids.len());

    // 代拍流程里医生要逐份确认;这里全确认,等价于「医生看完都点了确认」。
    let confirmed: std::collections::HashSet<i64> = doc_ids.iter().copied().collect();
    let consent = medme_share::share::ShareConsent {
        utc_ts: "2026-07-28T00:00:00Z".into(),
        consent_text_version: "demo".into(),
        signature_png_base64: None,
        method: "press_hold".into(),
        session_id: "demo-session".into(),
    };

    let (blob, key_b64, n) = medme_share::share::build_claim_blob(
        &vault,
        15, // 与瞬时云 TTL 一致
        &medme_share::render_dicom_png_in_process,
        consent,
        &confirmed,
    )
    .unwrap();

    // 对象 id:不透明、不可枚举。生产由上传端生成,这里用同样的形状。
    let mut id_bytes = [0u8; 12];
    getrandom::fill(&mut id_bytes).unwrap();
    let id = base64::Engine::encode(&base64::engine::general_purpose::URL_SAFE_NO_PAD, id_bytes);

    std::fs::create_dir_all(out_dir.join("c")).unwrap();
    std::fs::write(out_dir.join("c").join(&id), &blob).unwrap();

    // 查看器副本:把 CLAIM_BASE 与 CSP 的 connect-src 一起指向同源,好在本地实跑。
    // 改脚本会让 CSP 锁死的 sha256 失配,故连脚本哈希一并重算 —— 与生产同一套约束。
    let viewer = include_str!("../../../web/hosted-viewer/index.html");
    let viewer = viewer
        .replace("https://medme-claim.oss-cn-hangzhou.aliyuncs.com/c/", "/c/")
        .replace(
            "connect-src https://medme-claim.oss-cn-hangzhou.aliyuncs.com",
            "connect-src 'self'",
        );
    let viewer = rehash_csp(&viewer);
    std::fs::write(out_dir.join("index.html"), &viewer).unwrap();

    let fragment = format!("c1.{id}.{key_b64}");
    std::fs::write(out_dir.join("fragment.txt"), &fragment).unwrap();
    println!("密文 {} KB,{n} 份记录", blob.len() / 1024);
    println!("认领:{}/index.html#{fragment}", out_dir.display());

    // ── 二维码:和认领用的是**同一份密文**,只是入口不同(医生看,不是病人存)──
    let qr_fragment = format!("q2.{id}.{key_b64}");
    std::fs::write(out_dir.join("qr_fragment.txt"), &qr_fragment).unwrap();
    println!(
        "二维码内容 {} 字符(扫完直接是完整病历含原件)",
        qr_fragment.len()
    );
    println!("扫码后:{}/index.html#{qr_fragment}", out_dir.display());
}

/// 重算两段内联脚本的 sha256 并替换进 CSP —— 与 `web/hosted-viewer/index.html` 头部
/// 注释里那段 python 等价。本地副本改了脚本内容(CLAIM_BASE),不重算就整页不执行。
fn rehash_csp(html: &str) -> String {
    use sha2::{Digest, Sha256};
    let open = "<script>";
    let close = "</script>";
    let mut hashes = Vec::new();
    let mut i = 0;
    while let Some(a) = html[i..].find(open) {
        let start = i + a + open.len();
        let Some(b) = html[start..].find(close) else {
            break;
        };
        let end = start + b;
        let digest = Sha256::digest(&html.as_bytes()[start..end]);
        hashes.push(format!(
            "'sha256-{}'",
            base64::Engine::encode(&base64::engine::general_purpose::STANDARD, digest)
        ));
        i = end;
    }
    // 首屏防闪脚本(head 里那段)、内联 dicom-parser、查看器逻辑 —— 三段。
    assert_eq!(hashes.len(), 3, "查看器应恰有三段内联脚本");

    // 替换 script-src 后面直到分号的整段。**必须先定位到 CSP meta 标签**:头部维护
    // 注释里也出现「script-src」字样,直接 find 会改到注释上,CSP 原封不动 —— 于是
    // 整段脚本被浏览器拦下、页面一片空白(踩过)。
    let meta = html
        .find("http-equiv=\"Content-Security-Policy\"")
        .expect("找不到 CSP meta 标签");
    let key = "script-src ";
    let s = meta + html[meta..].find(key).expect("CSP 缺 script-src") + key.len();
    let e = s + html[s..].find(';').expect("script-src 未以分号收尾");
    format!("{}{}{}", &html[..s], hashes.join(" "), &html[e..])
}
