//! End-to-end round trip for the isolated DICOM decode subprocess (GHSA-24px).
//!
//! Custom harness (`harness = false`) so THIS test binary can play both roles:
//! when re-invoked with `--decode-dicom …` by the parent wrapper it runs the
//! decode child; otherwise it runs the assertions, which call the real parent
//! functions (`render_png` / `decode_frame_ipc`). Those spawn `current_exe()`
//! (this binary) with the hidden flag, so we exercise the genuine stdin→decode
//! →stdout path — the same code `commands::render_dicom` uses in production —
//! without having to build the full Tauri binary.
//!
//! A normal `libtest` harness can't do this: it would try to parse
//! `--decode-dicom` as a test filter and abort before our child code runs.

use std::path::Path;

fn sample(name: &str) -> Vec<u8> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../examples/demo-dataset/dicom")
        .join(name);
    std::fs::read(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

fn main() {
    // Child role: this same binary, re-spawned by the parent wrapper.
    let argv: Vec<String> = std::env::args().collect();
    if let Some(pos) = argv
        .iter()
        .position(|a| a == desktop_lib::dicom_subprocess::DECODE_FLAG)
    {
        std::process::exit(desktop_lib::dicom_subprocess::run_child(&argv[pos + 1..]));
    }

    // Parent/test role.
    valid_dicom_renders_to_png();
    valid_frame_decodes_to_ipc_bytes();
    valid_dicom_parses_meta();
    oom_bomb_is_rejected_before_spawn();
    child_decode_failure_degrades();
    bogus_bytes_degrade();
    println!("dicom_subprocess_roundtrip: all checks passed");
}

/// A valid uncompressed DICOM round-trips to a real PNG through the child.
fn valid_dicom_renders_to_png() {
    let png = desktop_lib::dicom_subprocess::render_png(&sample("CT_small.dcm"))
        .expect("valid DICOM should render via the subprocess");
    assert_eq!(
        &png[..8],
        b"\x89PNG\r\n\x1a\n",
        "child stdout must be a real PNG"
    );
}

/// The frame path round-trips the IPC buffer (header length + JSON + pixels).
fn valid_frame_decodes_to_ipc_bytes() {
    let wire = desktop_lib::dicom_subprocess::decode_frame_ipc(&sample("CT_small.dcm"), 0)
        .expect("valid frame should decode via the subprocess");
    let hlen = u32::from_le_bytes(wire[0..4].try_into().unwrap()) as usize;
    assert!(
        wire.len() > 4 + hlen,
        "IPC buffer must carry pixels after its header"
    );
}

/// 元数据解析也走子进程(按声明长度分配发生在解析期,畸形文件可诱导数 GB 分配)。
/// 合法文件必须原样拿到元数据 —— 隔离不能改变功能。
fn valid_dicom_parses_meta() {
    let meta = desktop_lib::dicom_subprocess::parse_meta(&sample("CT_small.dcm"))
        .expect("valid DICOM should parse via the subprocess");
    let in_process = dicom::parse_meta(&sample("CT_small.dcm")).expect("in-process parse");
    assert_eq!(meta, in_process, "隔离解析结果必须与进程内逐字段一致");
    assert_eq!(meta.modality.as_deref(), Some("CT"));
}

/// 声明长度远超文件本身的畸形文件:必须在**主进程 spawn 之前**就被浅扫拒绝,
/// 而不是进到解析里去分配数 GB(模糊测试发现的拒绝服务路径)。
fn oom_bomb_is_rejected_before_spawn() {
    // 128 字节前导 + "DICM" + 一个声明 4GB 长度的 OB 元素,文件本身只有几十字节。
    let mut bomb = vec![0u8; 128];
    bomb.extend_from_slice(b"DICM");
    bomb.extend_from_slice(&[0x02, 0x00, 0x00, 0x00]); // tag (0002,0000)
    bomb.extend_from_slice(b"OB");
    bomb.extend_from_slice(&[0x00, 0x00]); // reserved
    bomb.extend_from_slice(&0xFFFF_FF00u32.to_le_bytes()); // 声明 ~4GB
    let err = desktop_lib::dicom_subprocess::parse_meta(&bomb)
        .expect_err("声明长度超过文件本身必须被拒绝");
    assert!(err.contains("超过文件剩余"), "应由浅扫守卫拒绝,实际: {err}");
}

/// A valid header but an out-of-range frame index passes the parent's
/// pre-spawn bounds check, reaches the child, and makes it exit non-zero — the
/// parent must degrade (this is the "codec crash confined to child" path).
fn child_decode_failure_degrades() {
    let err = desktop_lib::dicom_subprocess::decode_frame_ipc(&sample("CT_small.dcm"), 9999)
        .expect_err("an undecodable request must degrade, not succeed");
    assert!(
        err.contains("已隔离"),
        "child non-zero exit should degrade, got: {err}"
    );
}

/// Non-DICOM bytes are rejected up front by the parent's header guard (they
/// never even reach the child) — still a graceful degrade.
fn bogus_bytes_degrade() {
    let err = desktop_lib::dicom_subprocess::render_png(b"definitely not a dicom file")
        .expect_err("bogus input must degrade, not succeed");
    assert!(!err.is_empty(), "degrade must carry an error message");
}
