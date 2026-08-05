//! 诊断日志的最小封装——**Android 默认不捕获进程 stderr**,`eprintln!` 在真机
//! `adb logcat` 上永远看不到,连插着 USB 线盯日志的开发者都看不见。
//!
//! 2026-08 真机(华为 Mate 9)实测复现:「载入示例数据」有文件导入失败,logcat 全程
//! 零输出——不是没失败,是失败了也没地方看。grep 过 `rust/src/` 全部 4 处
//! `eprintln!` 诊断,统一改走这里的 [warn],不再是安卓上瞎的那一套。iOS 上
//! `eprintln!` 本就能被 Xcode / 终端捕获,不受影响,这里原样保留。
//!
//! **只报步骤 + 原因,不报病历内容**:调用方传入的字符串目前只含本地临时文件的
//! 路径(`ingest`/`load_demo_data` 落盘用的临时目录,不是病历文字/化验值本身),
//! 且只进本机日志通道(logcat/Xcode——需要物理连接设备才看得到,不出设备、不经
//! 埋点)。这与 `import_flow.dart` 里 `debugPrint` 的纪律一致:详情只给本机诊断
//! 看,离开设备的（`Analytics.track`)只留抽象原因码,不带任何文件路径或内容。

/// 进程启动时调一次(`api::simple::init_app`,`RustLib.init()` 会自动触发那个
/// `#[frb(init)]` 函数)。非安卓平台是空操作——`eprintln!` 不需要额外初始化。
pub fn init() {
    #[cfg(target_os = "android")]
    android_logger::init_once(
        android_logger::Config::default()
            .with_max_level(log::LevelFilter::Warn)
            .with_tag("medme"),
    );
}

/// 记一条警告级诊断:安卓经 `android_logger` 落 logcat(tag `medme`,`adb logcat
/// -s medme` 可过滤);其它平台走 `eprintln!`(原有行为不变)。
pub fn warn(msg: &str) {
    #[cfg(target_os = "android")]
    log::warn!("{msg}");
    #[cfg(not(target_os = "android"))]
    eprintln!("{msg}");
}
