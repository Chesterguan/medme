//! 平台无关的**分享 + 导出**核心逻辑,从桌面端 Tauri 层抽出,供桌面与未来
//! 移动端(Tauri v2 mobile,同一 Rust 核)复用。
//!
//! 两个模块都是**纯函数**:输入一个 [`core_model::Vault`] 引用,输出 HTML 字符串
//! (与记录数 / 口令),不触碰 Tauri、不弹文件对话框、不决定落盘位置 —— 调用方
//! (桌面/移动命令层)负责收集 Vault、拿到返回值再落盘。
//!
//! - [`export`]:整条时间线渲染成自包含 HTML(浏览器「打印 / 另存为 PDF」)。
//! - [`share`]:全部病历打包成**自包含加密 HTML**(AES-256-GCM + 内联查看器)。

pub mod export;
pub mod share;

/// 注入式 DICOM→PNG 渲染器:给定一份 DICOM 实例的原始字节,返回其锚点切片的 PNG;
/// 无法渲染(不支持的压缩 / 解码失败)时返回 `None`,构建器随即降级为一行文字说明
/// —— 与本就存在的降级行为逐字一致。
///
/// 为何**注入**而不写死成 [`dicom::render_png`]:GHSA-24px。桌面工作区构建里,Cargo
/// 特性合并会为共享的 `dicom` 依赖打开 C/C++ 的 JPEG2000/JPEG-LS 解码器(`codecs`);
/// 于是在**主进程**里解码攻击者提供的压缩像素,就是一处内存破坏型 RCE 面(正是 #44
/// 为「查看」路径关闭的那一处)。因此桌面改为注入一个**在隔离子进程里解码**的渲染器
/// (见 `dicom_subprocess`),share 包在桌面上自身绝不再调用进程内的编解码器。移动端
/// Android 构建把 `codecs` 关掉,故 [`render_dicom_png_in_process`] 在那里是安全的。
pub type DicomPngRenderer<'a> = &'a dyn Fn(&[u8]) -> Option<Vec<u8>>;

/// 进程内 DICOM→PNG 渲染器(经链接进来的 `dicom` 直接解码)。仅在 `dicom` **不含**
/// C/C++ `codecs` 特性(移动端)或输入可信(测试)时,才可作为 [`DicomPngRenderer`]
/// 传入。桌面**禁止**使用它 —— 见 [`DicomPngRenderer`](GHSA-24px)—— 而应注入
/// 子进程隔离的渲染器。
pub fn render_dicom_png_in_process(dcm_bytes: &[u8]) -> Option<Vec<u8>> {
    dicom::render_png(dcm_bytes).ok()
}
