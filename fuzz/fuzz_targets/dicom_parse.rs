//! 攻击面最大的一处:DICOM 来自医院光盘、U 盘、别人发来的分享文件。
//! 只 fuzz 纯 Rust 的元数据解析与边界检查 —— 像素解码走 vendored C/C++ 编解码器
//! (OpenJPEG/CharLS),在移动端本就不编译、在桌面端被子进程隔离(GHSA-24px),
//! 交给 OSS-Fuzz 或单独的 target 更合适。
#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    // 目标不是「不报错」,而是**不 panic、不越界、不无限循环**。
    let _ = dicom::parse_meta(data);
    let _ = dicom::check_bounds(data);
});
