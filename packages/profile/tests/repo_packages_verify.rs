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
    // `skills/` 被删/被改成文件时必须硬失败,不能让下面的 `read_dir` 静默吞成空表——
    // 那样 `every_signed_package_in_the_repo_verifies_with_the_production_key` 会空转变绿。
    assert!(skills.is_dir(), "skills/ 不见了:{}", skills.display());
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

/// 上一条只防「还是占位值」,不防「写错了」——63 个字符、含非 hex 字符、或者
/// 合法 hex 但不是一个能解压的 Ed25519 点,上一条测试都会放行,却会让每一个包在
/// 每一台设备上都加载失败。两条测试各防一类,缺一不可(实测:全 0/全 0xff 这两个
/// 「看起来像坏值」的 32 字节其实都能被 `from_bytes` 解压成合法点,所以这条测试
/// 本身也**不能**顶替上一条逐字节比对占位值的测试)。
#[test]
fn the_production_public_key_is_a_real_ed25519_point() {
    let h = profile::SIGNING_PUBLIC_KEY_HEX;
    assert_eq!(h.len(), 64, "公钥必须是 64 个 hex 字符");
    assert!(
        h.bytes().all(|b| b.is_ascii_hexdigit()),
        "公钥含非 hex 字符"
    );
    let mut k = [0u8; 32];
    for (i, c) in h.as_bytes().chunks(2).enumerate() {
        k[i] = u8::from_str_radix(std::str::from_utf8(c).unwrap(), 16).unwrap();
    }
    ed25519_dalek::VerifyingKey::from_bytes(&k).expect("常量不是合法 Ed25519 公钥");
}
