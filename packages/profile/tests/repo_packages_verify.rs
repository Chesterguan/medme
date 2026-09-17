//! 仓库里每一个 `skills/<id>/<ver>.json` 都必须能用**编进二进制的生产公钥**验过签。
//!
//! 这条测试是签名这件事的唯一自动化保障:没有它,谁手改了一个字节、或者拿错
//! 私钥重签,都要等到真机上「包加载不出来」才发现。
use std::path::{Path, PathBuf};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..")
}

fn signed_packages() -> Vec<PathBuf> {
    let skills = repo_root().join("skills");
    let mut out = Vec::new();
    let Ok(ids) = std::fs::read_dir(&skills) else {
        return out;
    };
    for id in ids.flatten().filter(|e| e.path().is_dir()) {
        for f in std::fs::read_dir(id.path()).unwrap().flatten() {
            let p = f.path();
            let name = p.file_name().unwrap().to_string_lossy().to_string();
            if name.ends_with(".json") && !name.ends_with(".src.json") {
                out.push(p);
            }
        }
    }
    out
}

#[test]
fn every_signed_package_in_the_repo_verifies_with_the_production_key() {
    let pkgs = signed_packages();
    for p in &pkgs {
        let raw = std::fs::read_to_string(p).unwrap();
        profile::load_signed(&raw).unwrap_or_else(|e| panic!("{} 验签/加载失败:{e}", p.display()));
    }
    // 目录空也算过(C1 阶段还没有包内容),但一旦有文件就必须全过。
    eprintln!("verified {} signed package(s)", pkgs.len());
}

#[test]
fn index_json_lists_exactly_the_signed_packages_present() {
    let idx_path = repo_root().join("skills").join("index.json");
    let idx: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&idx_path).unwrap()).unwrap();
    let listed: Vec<(String, String)> = idx["skills"]
        .as_array()
        .expect("index.json 必须有 skills 数组")
        .iter()
        .map(|s| {
            (
                s["id"].as_str().unwrap().to_string(),
                s["version"].as_str().unwrap().to_string(),
            )
        })
        .collect();
    let mut on_disk: Vec<(String, String)> = signed_packages()
        .iter()
        .map(|p| {
            (
                p.parent()
                    .unwrap()
                    .file_name()
                    .unwrap()
                    .to_string_lossy()
                    .to_string(),
                p.file_stem().unwrap().to_string_lossy().to_string(),
            )
        })
        .collect();
    let mut listed_sorted = listed.clone();
    listed_sorted.sort();
    on_disk.sort();
    assert_eq!(listed_sorted, on_disk, "index.json 与 skills/ 目录不一致");
}

#[test]
fn the_production_public_key_is_not_the_placeholder() {
    assert_ne!(
        profile::SIGNING_PUBLIC_KEY_HEX,
        "0000000000000000000000000000000000000000000000000000000000000000",
        "还是 Task 1 的占位公钥 —— 用 scripts/sign_skill.py --pubkey 换成真的"
    );
}
