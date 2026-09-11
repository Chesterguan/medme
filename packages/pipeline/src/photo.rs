//! 导入时压图(总纲横切 4):长边 2000px、JPEG q85。手机直拍 2~5 MB → ~400 KB,
//! OCR/LLM 识别不受影响,上云存储与流量降一个数量级。
//! 不留未压缩原图(创始人决定,2026-09-11)。HEIC/TIFF 多页/解不开的一律原样返回。
use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;
use image::GenericImageView;

pub const PHOTO_LONG_EDGE: u32 = 2000;
pub const PHOTO_JPEG_QUALITY: u8 = 85;

pub fn compress_photo(bytes: &[u8]) -> Vec<u8> {
    let Ok(fmt) = image::guess_format(bytes) else { return bytes.to_vec() };
    if !matches!(fmt, image::ImageFormat::Jpeg | image::ImageFormat::Png) {
        return bytes.to_vec();
    }
    let Ok(img) = image::load_from_memory(bytes) else { return bytes.to_vec() };
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
        let img = ImageBuffer::from_fn(4000, 3000, |x, y| Rgb([(x % 256) as u8, (y % 256) as u8, 7]));
        let mut out = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageRgb8(img).write_to(&mut out, image::ImageFormat::Jpeg).unwrap();
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
        image::DynamicImage::ImageRgb8(img).write_to(&mut out, image::ImageFormat::Png).unwrap();
        let small = out.into_inner();
        assert_eq!(compress_photo(&small), small);
    }
}
