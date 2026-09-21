//! 导入时压图(总纲横切 4):长边 2000px、JPEG q85。手机直拍 2~5 MB → ~400 KB,
//! OCR/LLM 识别不受影响,上云存储与流量降一个数量级。
//! 不留未压缩原图(创始人决定,2026-09-11)。HEIC/TIFF 多页/解不开的一律原样返回。
use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;
use image::{DynamicImage, GenericImageView, ImageDecoder, ImageFormat, ImageResult};

pub const PHOTO_LONG_EDGE: u32 = 2000;
pub const PHOTO_JPEG_QUALITY: u8 = 85;

/// 解码并按 EXIF Orientation 摆正——`image` 默认**不**应用它,竖拍手机照片常存成
/// 横向像素 + 一个「顺时针转 90°」之类的标记,不摆正就压,压出来的图会歪着(原图
/// 交给桌面查看器/浏览器 `<img>` 时是摆正的,因为那些渲染器自己认 EXIF;压缩后
/// 的字节不再带 EXIF,歪了就再也摆不正)。与 `ocr::decode_image_bounded` 同一处理
/// (见 `packages/ocr/src/lib.rs`)。PNG 没有 EXIF 方向,`orientation()` 恒为
/// `None`,不受影响。
fn decode_with_orientation(bytes: &[u8], fmt: ImageFormat) -> ImageResult<DynamicImage> {
    let reader = image::ImageReader::with_format(std::io::Cursor::new(bytes), fmt);
    let mut decoder = reader.into_decoder()?;
    let orientation = decoder
        .orientation()
        .unwrap_or(image::metadata::Orientation::NoTransforms);
    let mut img = DynamicImage::from_decoder(decoder)?;
    img.apply_orientation(orientation);
    Ok(img)
}

pub fn compress_photo(bytes: &[u8]) -> Vec<u8> {
    let Ok(fmt) = image::guess_format(bytes) else {
        return bytes.to_vec();
    };
    if !matches!(fmt, image::ImageFormat::Jpeg | image::ImageFormat::Png) {
        return bytes.to_vec();
    }
    let Ok(img) = decode_with_orientation(bytes, fmt) else {
        return bytes.to_vec();
    };
    let (w, h) = img.dimensions();
    if w.max(h) <= PHOTO_LONG_EDGE {
        return bytes.to_vec();
    }
    let img = img.resize(PHOTO_LONG_EDGE, PHOTO_LONG_EDGE, FilterType::Triangle);
    let mut out = Vec::new();
    let mut enc = JpegEncoder::new_with_quality(&mut out, PHOTO_JPEG_QUALITY);
    match enc.encode_image(&img.to_rgb8()) {
        Ok(()) => out,
        Err(_) => bytes.to_vec(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{ImageBuffer, Rgb};

    fn big_jpeg() -> Vec<u8> {
        let img = ImageBuffer::from_fn(4000, 3000, |x, y| {
            Rgb([(x % 256) as u8, (y % 256) as u8, 7])
        });
        let mut out = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageRgb8(img)
            .write_to(&mut out, image::ImageFormat::Jpeg)
            .unwrap();
        out.into_inner()
    }

    #[test]
    fn large_photo_is_downscaled_to_2000_long_edge() {
        let out = compress_photo(&big_jpeg());
        let img = image::load_from_memory(&out).unwrap();
        assert_eq!(img.width().max(img.height()), 2000);
        assert_eq!(image::guess_format(&out).unwrap(), image::ImageFormat::Jpeg);
    }

    #[test]
    fn small_or_non_image_passes_through() {
        assert_eq!(compress_photo(b"not an image"), b"not an image");
        let img = ImageBuffer::from_fn(800, 600, |_, _| Rgb([1u8, 2, 3]));
        let mut out = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageRgb8(img)
            .write_to(&mut out, image::ImageFormat::Png)
            .unwrap();
        let small = out.into_inner();
        assert_eq!(compress_photo(&small), small);
    }

    /// 手写最小 EXIF TIFF IFD:只带一个 Orientation(0x0112, SHORT)标签。
    /// 足以让 `image` 的 JPEG 解码器读出方向,不需要完整 EXIF 结构。
    fn exif_orientation_bytes(orientation: u16) -> Vec<u8> {
        let mut v = Vec::new();
        v.extend_from_slice(b"II"); // little-endian
        v.extend_from_slice(&42u16.to_le_bytes());
        v.extend_from_slice(&8u32.to_le_bytes()); // IFD0 offset
        v.extend_from_slice(&1u16.to_le_bytes()); // 1 entry
        v.extend_from_slice(&0x0112u16.to_le_bytes()); // tag: Orientation
        v.extend_from_slice(&3u16.to_le_bytes()); // type: SHORT
        v.extend_from_slice(&1u32.to_le_bytes()); // count: 1
        let mut value_field = [0u8; 4];
        value_field[0..2].copy_from_slice(&orientation.to_le_bytes());
        v.extend_from_slice(&value_field);
        v.extend_from_slice(&0u32.to_le_bytes()); // next IFD offset: none
        v
    }

    /// 3000×2000(横向像素)+ 给定 EXIF Orientation 标签的 JPEG。
    fn landscape_jpeg_with_orientation(orientation: u16) -> Vec<u8> {
        use image::{ExtendedColorType, ImageEncoder};
        let img = ImageBuffer::from_fn(3000, 2000, |x, y| {
            Rgb([(x % 256) as u8, (y % 256) as u8, 7])
        });
        let mut out = Vec::new();
        let mut enc = JpegEncoder::new_with_quality(&mut out, 90);
        enc.set_exif_metadata(exif_orientation_bytes(orientation))
            .unwrap();
        enc.write_image(&img, 3000, 2000, ExtendedColorType::Rgb8)
            .unwrap();
        out
    }

    #[test]
    fn exif_orientation_6_rotates_before_downscale() {
        // Orientation=6(旋转 90° 顺时针摆正)：存的像素是横向 3000×2000,
        // 摆正后应变成竖向。不摆正就压缩,压出来的图会歪着。
        let out = compress_photo(&landscape_jpeg_with_orientation(6));
        let img = image::load_from_memory(&out).unwrap();
        assert!(
            img.height() > img.width(),
            "expected portrait output after applying orientation, got {}x{}",
            img.width(),
            img.height()
        );
        assert_eq!(img.width().max(img.height()), 2000);
    }

    #[test]
    fn exif_orientation_1_keeps_original_aspect() {
        // Orientation=1(不用变换)：像素怎么存就怎么显示,长边压到 2000 后
        // 仍是横向(不应被误摆正)。
        let out = compress_photo(&landscape_jpeg_with_orientation(1));
        let img = image::load_from_memory(&out).unwrap();
        assert!(
            img.width() > img.height(),
            "expected landscape output to keep its aspect, got {}x{}",
            img.width(),
            img.height()
        );
        assert_eq!(img.width().max(img.height()), 2000);
    }
}
