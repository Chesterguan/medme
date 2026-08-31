//! 多张单页照片合成一份多页 PDF 的字节级实现(流派 A —— 见 `lib.rs` 里
//! `merge_documents_into_pdf` 的文档注释,那才是 Vault 编排入口)。
//!
//! 本模块只做一件事:`Vec<照片字节>` -> `PDF 字节`,不碰 `Vault`/CAS/事件 ——
//! 纯函数,方便脱离 Vault 单独单测,也让 `merge_documents_into_pdf` 的编排逻辑
//! 保持简短(校验 + 组装 + 落库三段,不夹杂 PDF 内部结构)。
//!
//! 手搭 PDF 对象树的手法与 `lib.rs` 测试区已有的
//! `build_two_page_pdf_second_page_blank`/`build_two_page_pdf_both_pages_have_text`
//! 一致(`lopdf::Document` + `dictionary!` + `Stream`),只是这里多加了图像
//! XObject(那两个测试 helper 特意避开了图片,注释写明「保持 pipeline 不依赖
//! image/JPEG」——现在为了合并功能这条依赖已经加上,见 `Cargo.toml`)。

use anyhow::{Context, Result};
use image::codecs::jpeg::JpegEncoder;
use lopdf::content::{Content, Operation};
use lopdf::{dictionary, Document as LoDocument, Object, Stream};

/// JPEG 重编码质量。85 是「肉眼看不出压缩痕迹、体积可控」的常见经验值——化验单
/// 以文字为主,不需要摄影级的 95+;`ocr::recognize_pdf_mixed` 本来就是从真实扫描
/// PDF 里质量通常更低的 DCTDecode 图像识别文字,这个质量级别对 OCR 不构成新障碍。
const JPEG_QUALITY: u8 = 85;

/// 单页在 PDF 坐标系里的最长边上限(pt,即 1/72 英寸)。手机照片常见 3000×4000
/// 像素,直接拿像素数当 PDF 单位会做出一份物理尺寸 40+ 英寸的「页面」——PDF 格式
/// 本身能装下,但没有意义。缩到 1600pt(约 22 英寸@72dpi,屏幕阅读绰绰有余)是
/// 够用又不夸张的上限;缩放只改 `MediaBox` 与内容流的 `cm` 矩阵,**不重采样嵌入的
/// 图像本身**——JPEG 里仍是照片的原生像素,清晰度不受这个常量影响。
const MAX_PAGE_POINTS: f64 = 1600.0;

/// 把多张照片的原始字节合成一份多页 PDF——每张照片一页,整页铺满(`cm` 矩阵缩放
/// + `Do` 画满单位正方形),用 `/DCTDecode`(JPEG)编码嵌入图像 XObject。
///
/// **为什么统一转 JPEG 重编码,而不是原样嵌入原始字节**:输入可能是 PNG——PDF
/// 图像 XObject 不能直接塞 PNG 的 zlib 流(PNG 每行前面还有一个 filter 字节,
/// 得走 `/FlateDecode` + `/Predictor` 或先转码,不是简单套个 Filter 名字就行);
/// TIFF 同理更复杂。统一先解码、再用 `JpegEncoder` 重新编码,换来的是单一、简单、
/// 而且 `ocr::recognize_pdf_mixed`(内部 `extract_dct_images`)已经支持读取的格式
/// —— 合并出的 PDF 走的是与桌面/CLI「扫描版 PDF」完全同一条识别代码路径,merge
/// 这一侧零新增 OCR 代码。
///
/// 代价:重编码是有损的(`JPEG_QUALITY` = 85,肉眼无感);原始像素只在 CAS 里
/// **各自独立的原始照片字节**上完整保留——本函数不删除、不覆盖任何输入,合成的
/// PDF 是全新的一份 CAS 对象(见 `lib.rs::merge_documents_into_pdf` 的
/// 「Raw Never Dies」说明)。
///
/// 不支持的输入(如 HEIC 字节混进来、或图片已损坏到 `image` 解不出来)直接报错并
/// 点名第几张——不静默跳过某一页(那会做出一份缺页却自称完整的 PDF,复现的正是
/// `pipeline::ingest_pdf`/`ingest_image` 修过的「静默丢页」缺陷)。
pub(crate) fn build_pdf_from_photos(photos: &[Vec<u8>]) -> Result<Vec<u8>> {
    anyhow::ensure!(!photos.is_empty(), "没有可合并的照片");

    let mut doc = LoDocument::with_version("1.5");
    let pages_id = doc.new_object_id();
    let mut kids = Vec::with_capacity(photos.len());

    for (idx, bytes) in photos.iter().enumerate() {
        let page_no = idx + 1;
        let img = image::load_from_memory(bytes)
            .with_context(|| format!("第 {page_no} 张照片无法解码(格式不支持或已损坏)"))?;
        let rgb = img.to_rgb8();
        let (px_w, px_h) = rgb.dimensions();
        // `image::load_from_memory` 成功解码理论上不会给出 0 边长,但除零(下面的
        // `px_w.max(px_h)` 当分母)不能赌"理论上";守住比排查一次 panic 便宜。
        anyhow::ensure!(px_w > 0 && px_h > 0, "第 {page_no} 张照片尺寸异常(0 边长)");

        let mut jpeg_bytes = Vec::new();
        JpegEncoder::new_with_quality(&mut jpeg_bytes, JPEG_QUALITY)
            .encode_image(&rgb)
            .with_context(|| format!("第 {page_no} 张照片重编码为 JPEG 失败"))?;

        let scale = (MAX_PAGE_POINTS / (px_w.max(px_h) as f64)).min(1.0);
        let page_w = px_w as f64 * scale;
        let page_h = px_h as f64 * scale;

        let image_dict = dictionary! {
            "Type" => "XObject",
            "Subtype" => "Image",
            "Width" => px_w as i64,
            "Height" => px_h as i64,
            "ColorSpace" => "DeviceRGB",
            "BitsPerComponent" => 8,
            "Filter" => "DCTDecode",
        };
        // `with_compression(false)`:字典已经声明 `/Filter /DCTDecode`,内容本身
        // 就是 JPEG 字节——绝不能再让 lopdf 套一层 Flate(那样会产出「Filter 说是
        // DCTDecode、字节却是 zlib」的坏 PDF)。`Stream::new` 默认 `allows_compression
        // = true`,但只有显式调用 `compress()` 才会真的压缩,这里本就不会调用它;
        // 显式关掉是把这条不变量写进类型,而不是依赖"调用方没手滑调 compress()"。
        let image_id = doc.add_object(Stream::new(image_dict, jpeg_bytes).with_compression(false));

        let content = Content {
            operations: vec![
                Operation::new("q", vec![]),
                Operation::new(
                    "cm",
                    vec![
                        page_w.into(),
                        0.into(),
                        0.into(),
                        page_h.into(),
                        0.into(),
                        0.into(),
                    ],
                ),
                Operation::new("Do", vec!["Im0".into()]),
                Operation::new("Q", vec![]),
            ],
        };
        let content_id = doc.add_object(Stream::new(
            dictionary! {},
            content.encode().context("编码 PDF 页内容流失败")?,
        ));
        let resources_id = doc.add_object(dictionary! {
            "XObject" => dictionary! { "Im0" => image_id },
        });
        let page_id = doc.add_object(dictionary! {
            "Type" => "Page",
            "Parent" => pages_id,
            "Contents" => content_id,
            "Resources" => resources_id,
            "MediaBox" => vec![0.into(), 0.into(), page_w.into(), page_h.into()],
        });
        kids.push(page_id.into());
    }

    let count = kids.len() as i64;
    doc.objects.insert(
        pages_id,
        Object::Dictionary(dictionary! {
            "Type" => "Pages",
            "Kids" => kids,
            "Count" => count,
        }),
    );
    let catalog_id = doc.add_object(dictionary! {
        "Type" => "Catalog",
        "Pages" => pages_id,
    });
    doc.trailer.set("Root", catalog_id);

    let mut bytes = Vec::new();
    doc.save_to(&mut bytes).context("保存合成 PDF 失败")?;
    Ok(bytes)
}

/// 造一张纯色的最小合法 JPEG 照片字节(测试专用——不依赖真实相机文件)。
/// `pub(crate)`(不是 `#[cfg(test)] mod tests` 内部私有):`lib.rs` 里
/// `merge_documents_into_pdf` 的编排测试也要造假照片喂进 `Vault`,两边共用同一个
/// 造图 helper,不重复写一份。
#[cfg(test)]
pub(crate) fn fake_photo(w: u32, h: u32) -> Vec<u8> {
    let img = image::RgbImage::from_pixel(w, h, image::Rgb([200, 40, 40]));
    let mut bytes = Vec::new();
    JpegEncoder::new_with_quality(&mut bytes, JPEG_QUALITY)
        .encode_image(&img)
        .unwrap();
    bytes
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn merges_n_photos_into_n_page_pdf_readable_by_lopdf() {
        let photos = vec![
            fake_photo(100, 140),
            fake_photo(120, 90),
            fake_photo(80, 80),
        ];
        let pdf_bytes = build_pdf_from_photos(&photos).unwrap();

        // 生成的字节本身必须是 lopdf 能读回来的合法 PDF——这是后续
        // `ocr::recognize_pdf_mixed` 能不能重新识别的前提。
        let doc = LoDocument::load_mem(&pdf_bytes).expect("合成的 PDF 必须能被 lopdf 读回");
        assert_eq!(doc.get_pages().len(), 3, "3 张照片应合成 3 页");
    }

    #[test]
    fn empty_input_is_rejected_not_a_zero_page_pdf() {
        let err = build_pdf_from_photos(&[]).unwrap_err();
        assert!(err.to_string().contains("没有可合并的照片"));
    }

    #[test]
    fn undecodable_photo_bytes_error_out_naming_the_page() {
        // 第 2 张是垃圾字节(模拟 HEIC 或损坏文件混进来的情况)——必须报错并点名
        // 第几张,不能静默跳过做出一份缺页的 PDF。
        let photos = vec![fake_photo(50, 50), b"not a real image".to_vec()];
        let err = build_pdf_from_photos(&photos).unwrap_err();
        assert!(
            err.to_string().contains("第 2 张"),
            "错误信息应点名第几张解码失败,实际:{err}"
        );
    }
}
