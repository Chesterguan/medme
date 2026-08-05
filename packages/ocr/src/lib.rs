//! OCR backend for MedMe: recognizes text in image bytes (png/jpg/tiff) via
//! `oar-ocr` (PP-OCRv5, ONNX Runtime). Models are auto-downloaded from
//! ModelScope into `$OAR_HOME` (default `~/.oar`) on first use, SHA-256
//! verified, and cached for subsequent runs.
//!
//! Also handles scanned/image-only PDFs (no text layer) via `recognize_pdf`:
//! it pulls page image XObjects out of the PDF with `lopdf` and OCRs each one.

use anyhow::{Context, Result};
use image::{DynamicImage, GenericImageView, GrayImage, ImageDecoder, Luma};
use imageproc::filter::gaussian_blur_f32;
use imageproc::geometric_transformations::{rotate_about_center, Border, Interpolation};
use lopdf::{Document, Object};
/// macOS on-device OCR via Apple Vision — primary recognizer on the desktop
/// build (oar-ocr is the fallback). See the module for the rationale (#41).
#[cfg(target_os = "macos")]
mod vision_macos;
/// Windows on-device OCR via Windows.Media.Ocr — primary on the Windows build
/// (oar-ocr is the fallback). See the module (#41).
#[cfg(target_os = "windows")]
mod windows_ocr;
#[cfg(feature = "engine")]
use oar_ocr::oarocr::{OAROCRBuilder, OAROCR};
#[cfg(feature = "engine")]
use oar_ocr::utils::dynamic_to_rgb;
#[cfg(feature = "engine")]
use std::path::PathBuf;
#[cfg(feature = "engine")]
use std::sync::OnceLock;

#[cfg(feature = "engine")]
static PIPELINE: OnceLock<OAROCR> = OnceLock::new();

/// Optional override for where the three PP-OCRv5 model files live. When unset
/// -- which is every build we currently ship -- the builder is handed the bare
/// file names, which the `auto-download` feature resolves out of `$OAR_HOME`
/// (`~/.oar`), fetching them from ModelScope on first use. When set via
/// [`set_model_dir`], the builder gets absolute, on-disk paths instead, for
/// packaging the models alongside the binary with `auto-download` off.
#[cfg(feature = "engine")]
static MODEL_DIR: OnceLock<PathBuf> = OnceLock::new();

/// Point the OCR engine at a directory holding the three PP-OCRv5 model files
/// (`pp-ocrv5_mobile_det.onnx`, `pp-ocrv5_mobile_rec.onnx`, `ppocrv5_dict.txt`).
///
/// For packaging the models next to the binary instead of auto-downloading
/// them. In production, has no callers -- mobile does not use this crate (ADR
/// 0005), and desktop/CLI auto-download. **Test-branch exception:**
/// `feat/ios-pp-ocr-test`'s `apps/mobile_flutter/rust/src/api/vault.rs`
/// (`ensure_pp_models_ready`) calls this to point at models it writes out of
/// its own `include_bytes!`-embedded copies -- see that function for why (no
/// writable `$OAR_HOME` in the iOS sandbox). Must be called before the first
/// `recognize`/`recognize_pdf` call (the pipeline is built lazily on first use
/// and cached). Idempotent: the first call wins; later calls are ignored.
#[cfg(feature = "engine")]
pub fn set_model_dir(dir: PathBuf) {
    let _ = MODEL_DIR.set(dir);
}

/// Result of an OCR recognition call: the recognized text plus a confidence
/// score (mean of the recognized text lines' per-line confidences, `0..1`;
/// `0.0` when no lines were recognized).
/// Which OCR engine actually produced an [`OcrOutcome`]. Lets callers (the
/// ingest pipeline) record accurate provenance instead of hardcoding one
/// engine — on macOS/Windows the primary recognizer is Apple Vision /
/// Windows.Media.Ocr, not the ONNX fallback the metadata used to always claim.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OcrBackend {
    /// Apple Vision (`VNRecognizeTextRequest`) — macOS on-device.
    AppleVision,
    /// Windows.Media.Ocr (WinRT) — Windows on-device.
    WindowsOcr,
    /// oar-ocr / PP-OCRv5 ONNX engine (Linux, and the macOS/Windows fallback).
    Onnx,
}

#[derive(Debug, Clone, PartialEq)]
pub struct OcrOutcome {
    pub text: String,
    pub confidence: f32,
    /// The engine that produced `text` (provenance for the vault's audit trail).
    pub backend: OcrBackend,
}

/// Mean of `Some` confidences, or `0.0` if there are none. Pure float helper
/// (no `oar-ocr` types involved), used by both `recognize` (engine-gated)
/// and `recognize_pdf` (not gated -- it just calls `recognize` per page).
fn mean_confidence(confidences: &[f32]) -> f32 {
    if confidences.is_empty() {
        0.0
    } else {
        confidences.iter().sum::<f32>() / confidences.len() as f32
    }
}

#[cfg(feature = "engine")]
fn pipeline() -> Result<&'static OAROCR> {
    if let Some(p) = PIPELINE.get() {
        return Ok(p);
    }
    // With a MODEL_DIR set, hand the builder absolute paths to packaged models
    // (for builds with `auto-download` off, where bare names wouldn't resolve).
    // Without it -- every build we ship today -- the bare names go through
    // `auto-download`'s `$OAR_HOME` resolution unchanged.
    // NOTE: page orientation (0/90/180/270) is handled geometrically in
    // `predict_lines` (see `orient_upright`), NOT by oar-ocr's doc-ori ONNX model.
    // The doc-ori model classified correctly on desktop but returned 0° (no
    // rotation) under Android's onnxruntime for the same model+input, AND it runs
    // per-band inside `predict` (wrong granularity for a whole-page decision). The
    // geometric approach uses the det boxes we already compute — a sideways page's
    // text lines come back taller-than-wide — so it's deterministic, cross-platform,
    // and free of that ort quirk. See ADR 0007.
    let (det, rec, dict) = match MODEL_DIR.get() {
        Some(dir) => (
            dir.join("pp-ocrv5_mobile_det.onnx"),
            dir.join("pp-ocrv5_mobile_rec.onnx"),
            dir.join("ppocrv5_dict.txt"),
        ),
        None => (
            PathBuf::from("pp-ocrv5_mobile_det.onnx"),
            PathBuf::from("pp-ocrv5_mobile_rec.onnx"),
            PathBuf::from("ppocrv5_dict.txt"),
        ),
    };
    let built = OAROCRBuilder::new(det, rec, dict)
        .build()
        .map_err(|e| anyhow::anyhow!("failed to build OAROCR pipeline: {e}"))?;
    Ok(PIPELINE.get_or_init(|| built))
}

/// Upper bound on the pixel buffer a decoded input image may allocate. A tiny
/// crafted file can declare enormous dimensions in its header (a "pixel flood"):
/// left unbounded, `image` allocates the full raw-pixel buffer, and `preprocess`
/// then allocates several more full-resolution buffers (grayscale + f32 blur
/// intermediates) on top — OOM from a few hundred bytes of input. We decode with
/// explicit [`image::Limits`] so such inputs return `Err` instead. 512 MiB is far
/// above any real phone photo / document scan yet bounds the worst case.
#[cfg_attr(not(feature = "engine"), allow(dead_code))]
const MAX_IMAGE_ALLOC_BYTES: u64 = 512 * 1024 * 1024;
/// Hard ceiling on either image dimension. The alloc cap above already rejects
/// most floods, but a 1-byte-per-pixel grayscale image can declare very large
/// dimensions while staying just under it; this bounds each axis explicitly.
#[cfg_attr(not(feature = "engine"), allow(dead_code))]
const MAX_IMAGE_DIM: u32 = 20_000;

/// Working-resolution ceiling for [`preprocess`]. `decode_image_bounded` accepts
/// images up to [`MAX_IMAGE_DIM`] (20000px), but `preprocess`'s illumination
/// flattening allocates several full-resolution `f32` buffers (grayscale + blur
/// intermediates), so a ~19000px image — legal under the decode cap — balloons
/// to multiple gigabytes transiently, worst on low-RAM mobile. OCR gains nothing
/// from resolution beyond a normal scan, so we downscale (preserving aspect) to
/// this bound before those amplifying passes. A typical A4 scan at 300dpi
/// (~2500px) is already well under this and is left untouched.
const OCR_MAX_WORKING_DIM: u32 = 4_000;

/// Decode image bytes (png/jpg/tiff/...) into a [`DynamicImage`] under explicit
/// allocation + dimension limits, so a small file declaring huge dimensions
/// errors cleanly rather than driving a multi-gigabyte allocation. Behaves
/// identically to `image::load_from_memory` for normally-sized inputs.
#[cfg_attr(not(feature = "engine"), allow(dead_code))]
fn decode_image_bounded(image_bytes: &[u8]) -> Result<DynamicImage> {
    let mut limits = image::Limits::default();
    limits.max_alloc = Some(MAX_IMAGE_ALLOC_BYTES);
    limits.max_image_width = Some(MAX_IMAGE_DIM);
    limits.max_image_height = Some(MAX_IMAGE_DIM);

    let mut reader = image::ImageReader::new(std::io::Cursor::new(image_bytes))
        .with_guessed_format()
        .context("ocr: guess image format")?;
    reader.limits(limits);
    // 应用 EXIF 方向:相册/相机胶卷里的照片常带旋转标记(竖拍存成横向像素 + 一个
    // 「顺时针转 90°」的 EXIF 标记),`image` 默认**不**应用它。不修正就会把照片当
    // 横躺的像素解码 → PP 识别横躺的字 → 乱码。相机文档扫描器输出的是已摆正的图,
    // 无此标记,不受影响;无 EXIF / 拿不到方向的普通扫描件按「不变换」处理,同样不变。
    let mut decoder = reader.into_decoder().context("ocr: build decoder")?;
    let orientation = decoder
        .orientation()
        .unwrap_or(image::metadata::Orientation::NoTransforms);
    let mut img = DynamicImage::from_decoder(decoder).context("ocr: decode image within limits")?;
    img.apply_orientation(orientation);
    Ok(img)
}

/// Downscale `img` (preserving aspect ratio) so neither dimension exceeds
/// [`OCR_MAX_WORKING_DIM`], returning it unchanged when it already fits. This
/// caps the transient `f32` buffers `preprocess` allocates on very large
/// inputs; OCR quality on normal-resolution scans is unaffected since they are
/// already under the limit.
fn downscale_to_working_dim(img: DynamicImage) -> DynamicImage {
    let (w, h) = img.dimensions();
    if w <= OCR_MAX_WORKING_DIM && h <= OCR_MAX_WORKING_DIM {
        return img;
    }
    let scale = OCR_MAX_WORKING_DIM as f32 / w.max(h) as f32;
    let nw = ((w as f32 * scale).round() as u32).max(1);
    let nh = ((h as f32 * scale).round() as u32).max(1);
    // `resize` preserves aspect and fits within the box; Triangle matches the
    // filter already used for the skew-search downscale below.
    img.resize(nw, nh, image::imageops::FilterType::Triangle)
}

/// Mild image preprocessing to bring messy phone photos of paper reports
/// closer to scan quality before OCR: grayscale, de-shadow / illumination
/// flattening, contrast stretch, and (only if a clear skew is detected) a
/// small deskew rotation. Deliberately conservative -- an already-clean scan
/// should come out looking essentially the same, just grayscale.
///
/// Never panics and never fails: any internal issue (degenerate input,
/// unreliable skew estimate, etc.) causes that step to be skipped, and if
/// something still goes wrong the original image is returned unchanged.
pub fn preprocess(img: DynamicImage) -> DynamicImage {
    let (w, h) = img.dimensions();
    // Too small for the blur radii / rotation search below to mean anything;
    // just pass it through rather than risk degrading a tiny image.
    if w < 16 || h < 16 {
        return img;
    }

    // Bound the working resolution before the amplifying f32 passes below
    // (`flatten_illumination` / `gaussian_blur_f32`). Normal-resolution scans
    // are under the limit and pass through untouched. See [`OCR_MAX_WORKING_DIM`].
    let img = downscale_to_working_dim(img);

    let gray = img.to_luma8();
    let flattened = flatten_illumination(&gray);
    let stretched = stretch_contrast(&flattened);
    let result = match estimate_skew_deg(&stretched) {
        Some(angle) if angle.abs() >= 0.5 && angle.is_finite() => deskew(&stretched, angle),
        _ => stretched,
    };
    DynamicImage::ImageLuma8(result)
}

/// De-shadows / normalizes uneven lighting by dividing the image by a
/// heavily-blurred copy of itself (an estimate of the local background),
/// then rescaling. Because the blur radius is much larger than a character
/// stroke, this flattens slow-varying shadows/gradients while leaving
/// fine (text-scale) detail intact.
fn flatten_illumination(gray: &GrayImage) -> GrayImage {
    let (w, h) = gray.dimensions();
    // Scale the blur radius to image size (clamped to a sane range) so this
    // behaves similarly on both small crops and large phone photos.
    let sigma = (w.min(h) as f32 / 8.0).clamp(8.0, 60.0);
    let background = gaussian_blur_f32(gray, sigma);

    let mut out = GrayImage::new(w, h);
    for ((src, bg), dst) in gray.pixels().zip(background.pixels()).zip(out.pixels_mut()) {
        let fg = src.0[0] as f32;
        let bg_v = (bg.0[0] as f32).max(1.0); // guard against div-by-zero
                                              // Rescale so a pixel matching the local background lands around
                                              // 200 (near-white, but with headroom so it isn't blown out before
                                              // the contrast-stretch step restores full range).
        let normalized = (fg / bg_v) * 200.0;
        dst.0[0] = normalized.clamp(0.0, 255.0) as u8;
    }
    out
}

/// Linearly stretches the image's intensity range to fill 0..=255. A no-op
/// on already-flat/blank images (nothing to stretch) or already-full-range
/// images.
fn stretch_contrast(gray: &GrayImage) -> GrayImage {
    let (mut lo, mut hi) = (u8::MAX, u8::MIN);
    for p in gray.pixels() {
        let v = p.0[0];
        lo = lo.min(v);
        hi = hi.max(v);
    }
    if hi <= lo {
        return gray.clone();
    }
    let (w, h) = gray.dimensions();
    let lo_f = lo as f32;
    let scale = 255.0 / (hi as f32 - lo_f);
    let mut out = GrayImage::new(w, h);
    for (src, dst) in gray.pixels().zip(out.pixels_mut()) {
        let v = ((src.0[0] as f32 - lo_f) * scale).clamp(0.0, 255.0);
        dst.0[0] = v as u8;
    }
    out
}

/// Estimates the dominant text skew angle in degrees via a projection
/// profile search: for each candidate angle in a small range, rotate and
/// score by the variance of per-row pixel-intensity sums (horizontal text
/// lines produce high-contrast rows/gaps, which maximizes this variance
/// when the rotation is correct). Returns `None` when the image is too
/// small to search reliably.
///
/// The search runs on a downscaled copy since the skew angle is a global
/// property of the page and doesn't need full resolution -- this keeps the
/// O(angles x pixels) search fast even on multi-megapixel phone photos.
fn estimate_skew_deg(gray: &GrayImage) -> Option<f32> {
    let (w, h) = gray.dimensions();
    if w < 16 || h < 16 {
        return None;
    }

    let longest = w.max(h) as f32;
    let scale = 300.0 / longest;
    let small = if scale < 1.0 {
        let sw = ((w as f32 * scale).round() as u32).max(1);
        let sh = ((h as f32 * scale).round() as u32).max(1);
        image::imageops::resize(gray, sw, sh, image::imageops::FilterType::Triangle)
    } else {
        gray.clone()
    };

    const ANGLE_RANGE_DEG: f32 = 10.0;
    const ANGLE_STEP_DEG: f32 = 0.5;

    let mut best_angle = 0.0f32;
    let mut best_score = f32::MIN;
    let mut found = false;

    let mut angle_deg = -ANGLE_RANGE_DEG;
    while angle_deg <= ANGLE_RANGE_DEG {
        let rotated = rotate_about_center(
            &small,
            angle_deg.to_radians(),
            Interpolation::Nearest,
            Border::Constant(Luma([255])),
        );
        let score = row_sum_variance(&rotated);
        if score.is_finite() && score > best_score {
            best_score = score;
            best_angle = angle_deg;
            found = true;
        }
        angle_deg += ANGLE_STEP_DEG;
    }

    if !found || !best_score.is_finite() {
        return None;
    }
    Some(best_angle)
}

/// Variance of per-row summed pixel intensities -- high when rows alternate
/// between "mostly text" and "mostly gap", which is the signature of
/// correctly-oriented horizontal text.
fn row_sum_variance(img: &GrayImage) -> f32 {
    let (w, h) = img.dimensions();
    if w == 0 || h == 0 {
        return 0.0;
    }
    let sums: Vec<f64> = (0..h)
        .map(|y| (0..w).map(|x| img.get_pixel(x, y).0[0] as f64).sum::<f64>())
        .collect();
    let mean = sums.iter().sum::<f64>() / sums.len() as f64;
    let variance = sums.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / sums.len() as f64;
    variance as f32
}

/// Rotates the image clockwise by `angle_deg` about its center, filling
/// exposed corners with white (matching a paper background) rather than
/// black.
fn deskew(gray: &GrayImage, angle_deg: f32) -> GrayImage {
    rotate_about_center(
        gray,
        angle_deg.to_radians(),
        Interpolation::Bilinear,
        Border::Constant(Luma([255])),
    )
}

/// Vertical banding for tall images. PP-OCRv5's detector rescales each input so
/// its longer side is at most ~960px (`limit_side_len` default in oar-ocr) before
/// it looks for text lines. A tall screenshot (long side 2000+) therefore gets
/// shrunk >2x, and its dense small text drops below the detector's resolution —
/// whole sections (e.g. a report's 「诊断及建议」body) go undetected while larger
/// headings survive. Rather than tune that budget to a magic number (which just
/// moves the cliff to a taller image), we split tall pages into bands short
/// enough that the detector's rescale stays mild, so small text survives
/// regardless of total page height — add a band, not a bigger guess.
///
/// `TILE_CORE_H` is the height each band *owns*; `TILE_OVERLAP` is how far a band
/// physically extends past its core on each inner side, so a text line straddling
/// a core boundary is still captured whole by the band that owns its center.
/// Both are OCR-quality knobs (smaller core = milder rescale = better recall on
/// dense text, at more predict passes); tune on real tall reports.
#[cfg(feature = "engine")]
const TILE_CORE_H: u32 = 1100;
#[cfg(feature = "engine")]
const TILE_OVERLAP: u32 = 120;

/// One recognized text line in full-image pixel coordinates (origin top-left),
/// engine-neutral so the banding/merge logic below doesn't depend on oar-ocr's
/// box type. `bottom - top` is the line height [`LayoutLine`] wants.
#[cfg(feature = "engine")]
struct OcrLine {
    text: String,
    confidence: Option<f32>,
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,
}

/// A band owns a recognized line iff the line's vertical center falls in the
/// band's core range `[core_top, core_bot)` — the last band owns everything down
/// to the image bottom. Cores tile the page with no gaps and no overlap, so each
/// line is emitted by exactly one band even though physical bands overlap. Pure
/// (no engine) so the dedup rule is unit-testable on its own.
#[cfg(feature = "engine")]
fn band_owns(center_y: f32, core_top: f32, core_bot: f32, is_last: bool) -> bool {
    center_y >= core_top && (center_y < core_bot || is_last)
}

/// Maps one band's [`oar_ocr::oarocr::TextRegion`]s into full-image [`OcrLine`]s,
/// offsetting y by the band's top and (when `core` is set) dropping lines this
/// band doesn't own so overlap regions aren't emitted twice.
#[cfg(feature = "engine")]
fn push_band_lines(
    regions: Vec<oar_ocr::oarocr::TextRegion>,
    y_off: f32,
    core: Option<(f32, f32, bool)>,
    out: &mut Vec<OcrLine>,
) {
    for region in regions {
        let Some(text) = region.text else { continue };
        if text.trim().is_empty() {
            continue;
        }
        let bb = &region.bounding_box;
        let top = bb.y_min() + y_off;
        let bottom = bb.y_max() + y_off;
        if let Some((core_top, core_bot, is_last)) = core {
            if !band_owns((top + bottom) * 0.5, core_top, core_bot, is_last) {
                continue;
            }
        }
        out.push(OcrLine {
            text: text.to_string(),
            confidence: region.confidence,
            left: bb.x_min(),
            top,
            right: bb.x_max(),
            bottom,
        });
    }
}

/// Decode + preprocess the image once, then run detection+recognition and return
/// the recognized lines in full-image coordinates. Short images
/// (`height <= TILE_CORE_H`) run as a single `predict` over the whole frame —
/// byte-identical to the pre-banding path, so existing Linux desktop/CLI and
/// macOS/Windows fallback output can't regress. Taller images are recognized in
/// overlapping vertical bands (see [`TILE_CORE_H`]) and merged. Lines come back
/// in band order (top-to-bottom); within a band the detector's own order is
/// preserved. Shared by [`recognize_engine`] (joins with "\n") and
/// [`recognize_engine_layout`] (rebuilds table columns from the boxes).
#[cfg(feature = "engine")]
fn predict_lines_core(dynamic: &DynamicImage) -> Result<Vec<OcrLine>> {
    let ocr = pipeline()?;
    let (w, h) = (dynamic.width(), dynamic.height());
    let mut out: Vec<OcrLine> = Vec::new();

    let predict_band = |img: image::RgbImage| -> Result<Vec<oar_ocr::oarocr::TextRegion>> {
        Ok(ocr
            .predict(vec![img])
            .map_err(|e| anyhow::anyhow!("OCR prediction failed: {e}"))?
            .into_iter()
            .next()
            .map(|r| r.text_regions)
            .unwrap_or_default())
    };

    // Short image: single pass over the whole frame (no crop, no dedup) — this
    // path must stay byte-identical to the pre-banding behavior.
    if h <= TILE_CORE_H {
        let regions = predict_band(dynamic_to_rgb(dynamic.clone()))?;
        push_band_lines(regions, 0.0, None, &mut out);
        return Ok(out);
    }

    // Tall image: recognize in overlapping vertical bands so the detector's
    // internal rescale stays mild and dense small text survives.
    let n_bands = h.div_ceil(TILE_CORE_H);
    for i in 0..n_bands {
        let core_top = i * TILE_CORE_H;
        let core_bot = ((i + 1) * TILE_CORE_H).min(h);
        let is_last = i + 1 == n_bands;
        // Physical band extends past its core by TILE_OVERLAP on each inner side.
        let band_top = if i == 0 { 0 } else { core_top - TILE_OVERLAP };
        let band_bot = if is_last {
            h
        } else {
            (core_bot + TILE_OVERLAP).min(h)
        };
        let band = dynamic.crop_imm(0, band_top, w, band_bot - band_top);
        let regions = predict_band(dynamic_to_rgb(band))?;
        push_band_lines(
            regions,
            band_top as f32,
            Some((core_top as f32, core_bot as f32, is_last)),
            &mut out,
        );
    }
    Ok(out)
}

/// A line's box counts as "tall" (rotated text) when its height exceeds its width
/// by this factor.
#[cfg(feature = "engine")]
const ORIENT_TALL_RATIO: f32 = 1.3;
/// If more than this fraction of a page's lines are "tall", treat the page as
/// sideways (rotated 90°/270°) and try to upright it.
#[cfg(feature = "engine")]
const ORIENT_TALL_THRESHOLD: f32 = 0.5;
/// Minimum in-plane skew (degrees) worth a deskew + re-OCR pass. Below this the
/// tilt doesn't meaningfully hurt row grouping and isn't worth the resample.
#[cfg(feature = "engine")]
const ORIENT_MIN_DESKEW_DEG: f32 = 1.0;

/// Fraction of non-empty lines whose detection box is taller than wide (by
/// [`ORIENT_TALL_RATIO`]). Near 0 for an upright document (text lines are wide and
/// short); high for a 90°/270°-rotated page (each line becomes a tall narrow
/// strip). Empty input → 0.
#[cfg(feature = "engine")]
fn tall_fraction(lines: &[OcrLine]) -> f32 {
    let considered = lines.iter().filter(|l| !l.text.trim().is_empty()).count();
    if considered == 0 {
        return 0.0;
    }
    let tall = lines
        .iter()
        .filter(|l| !l.text.trim().is_empty())
        .filter(|l| {
            let lw = (l.right - l.left).max(1.0);
            let lh = (l.bottom - l.top).max(1.0);
            lh > ORIENT_TALL_RATIO * lw
        })
        .count();
    tall as f32 / considered as f32
}

/// Mean recognition confidence over a page's non-empty lines (0 if none). Higher
/// when the page reads cleanly (upright) than when it's garbage (upside-down) —
/// the discriminator [`predict_lines`] uses to pick between the two 90° rotations.
#[cfg(feature = "engine")]
fn mean_line_confidence(lines: &[OcrLine]) -> f32 {
    let confs: Vec<f32> = lines
        .iter()
        .filter(|l| !l.text.trim().is_empty())
        .filter_map(|l| l.confidence)
        .collect();
    mean_confidence(&confs)
}

/// Decode + preprocess, then recognize with automatic **page-orientation
/// correction done geometrically** (no doc-orientation ONNX model — see
/// [`pipeline`] for why). Most text lines in an upright document are wider than
/// tall; a 90°/270°-rotated page makes them taller than wide. So: OCR once; if the
/// lines come back predominantly tall (page is sideways), OCR the image rotated
/// 90° and 270° too and keep whichever orientation yields the most horizontal
/// lines (lowest [`tall_fraction`]). Deterministic and cross-platform (reuses the
/// det model, which works everywhere). Upright pages — the common case — pay only
/// one cheap tall-fraction check and never re-OCR. Returned line coordinates are
/// in the chosen (uprighted) frame, which is all [`rebuild_layout_text`] and the
/// "\n"-join need. Shared by [`recognize_engine`] and [`recognize_engine_layout`].
#[cfg(feature = "engine")]
fn predict_lines(image_bytes: &[u8]) -> Result<Vec<OcrLine>> {
    let dynamic = decode_image_bounded(image_bytes).context("ocr::recognize: decode image")?;
    let dynamic = preprocess(dynamic);

    // 1) Orientation. OCR once; if the page reads sideways (predominantly tall line
    //    boxes), OCR the 90°/270° rotations too and keep the upright one (horizontal
    //    + highest recognition confidence — upright reads cleanly, upside-down is
    //    garbage). We track the winning *image*, not just its lines, so the deskew
    //    step below runs on the correctly-oriented frame. Upright pages (the common
    //    case) skip the rotations entirely.
    let lines0 = predict_lines_core(&dynamic)?;
    let mut best_img = dynamic;
    let mut best_lines = lines0;
    let mut best_conf = mean_line_confidence(&best_lines);
    if tall_fraction(&best_lines) > ORIENT_TALL_THRESHOLD {
        for rotated in [
            DynamicImage::ImageRgba8(image::imageops::rotate90(&best_img)),
            DynamicImage::ImageRgba8(image::imageops::rotate270(&best_img)),
        ] {
            if let Ok(cand) = predict_lines_core(&rotated) {
                let cc = mean_line_confidence(&cand);
                if tall_fraction(&cand) <= ORIENT_TALL_THRESHOLD && cc > best_conf {
                    best_conf = cc;
                    best_lines = cand;
                    best_img = rotated;
                }
            }
        }
    }

    // 2) Deskew (in-plane tilt). A tilted photo leaves text rows slanted even once
    //    upright; the detector then merges/mis-groups cells (the "mashed, hard to
    //    read" layout). If the chosen upright image has a meaningful in-plane skew,
    //    rotate it flat (reusing the projection-profile [`estimate_skew_deg`] +
    //    [`deskew`] already used in [`preprocess`]) and re-OCR so rows come back
    //    horizontal. `preprocess` already deskewed upright inputs, so this only fires
    //    for pages that were *rotated first* (their skew survives the rotation).
    //    **Failure-safe**: accept the deskewed result only if it kept ~all its lines
    //    and didn't make the page look more sideways — otherwise keep the pre-deskew
    //    result. A bad warp is worse than none.
    let gray = best_img.to_luma8();
    if let Some(angle) = estimate_skew_deg(&gray) {
        if angle.is_finite() && angle.abs() >= ORIENT_MIN_DESKEW_DEG {
            let deskewed = DynamicImage::ImageLuma8(deskew(&gray, angle));
            if let Ok(dl) = predict_lines_core(&deskewed) {
                let kept_lines = dl.len() * 10 >= best_lines.len() * 8;
                let not_worse = tall_fraction(&dl) <= tall_fraction(&best_lines) + 0.05;
                if kept_lines && not_worse {
                    return Ok(dl);
                }
            }
        }
    }
    Ok(best_lines)
}

/// Recognize text in image bytes (png/jpg/tiff/...). Returns recognized text
/// lines joined with "\n", plus a confidence score (mean of the recognized
/// lines' per-line confidences; `0.0` if no lines were recognized). Lazily
/// builds the OCR pipeline on first call (models auto-download from
/// ModelScope on first ever run on this machine).
#[cfg(feature = "engine")]
fn recognize_engine(image_bytes: &[u8]) -> Result<OcrOutcome> {
    let mut lines = Vec::new();
    let mut confidences = Vec::new();
    // predict_lines already drops empty text and returns lines in reading order
    // (top-to-bottom across bands), so a plain "\n" join matches the old output.
    for line in predict_lines(image_bytes)? {
        if let Some(c) = line.confidence {
            confidences.push(c);
        }
        lines.push(line.text);
    }
    Ok(OcrOutcome {
        text: lines.join("\n"),
        confidence: mean_confidence(&confidences),
        backend: OcrBackend::Onnx,
    })
}

/// Same recognition as [`recognize_engine`], but the returned text has table
/// columns reconstructed from each line's detection box instead of being a
/// flat "\n"-joined dump. **Mobile iOS PP-OCRv5 test path only**
/// (feat/ios-pp-ocr-test) — every other caller keeps using [`recognize_engine`]
/// unchanged, so this cannot regress Linux/macOS/Windows output.
///
/// Mirrors the algorithm the Android path already runs in Dart
/// (`apps/mobile_flutter/lib/ocr_bridge.dart::_rebuildLayoutText`, added to fix
/// lab-report tables collapsing into a flat dump when ML Kit splits one visual
/// row into several `TextLine`s): group detection boxes into visual rows by y,
/// then within a row map each box's x position to a character column and pad
/// with spaces. PP-OCRv5's detector already produces one box per text *line*
/// (not per character or per block), the same granularity ML Kit's
/// `TextLine.boundingBox` is at, so [`rebuild_layout_text`] ports directly.
#[cfg(feature = "engine")]
pub fn recognize_engine_layout(image_bytes: &[u8]) -> Result<OcrOutcome> {
    let mut confidences = Vec::new();
    let mut layout_lines = Vec::new();
    for line in predict_lines(image_bytes)? {
        if let Some(c) = line.confidence {
            confidences.push(c);
        }
        layout_lines.push(LayoutLine {
            text: line.text,
            left: line.left,
            top: line.top,
            right: line.right,
            height: line.bottom - line.top,
        });
    }
    Ok(OcrOutcome {
        text: rebuild_layout_text(&layout_lines),
        confidence: mean_confidence(&confidences),
        backend: OcrBackend::Onnx,
    })
}

/// A recognized text line's content plus its on-page geometry (pixel
/// coordinates, origin top-left) — engine-agnostic, so [`rebuild_layout_text`]
/// doesn't depend on any one OCR crate's box type. `top`/`left`/`right` are the
/// line's bounding box edges; `height` is `bottom - top` (kept as a field
/// rather than derived, matching the ML Kit `Rect` this ports from).
#[derive(Debug, Clone, PartialEq)]
pub struct LayoutLine {
    pub text: String,
    pub left: f32,
    pub top: f32,
    pub right: f32,
    pub height: f32,
}

/// Layout-reconstruction constants — kept numerically identical to
/// `ocr_bridge.dart`'s `_ocrTargetColumnWidth` / `_ocrRowYToleranceRatio` /
/// `_ocrBlockGapRatio` so the two engines' table output lines up the same way.
const LAYOUT_TARGET_COLUMN_WIDTH: usize = 90;
const LAYOUT_ROW_Y_TOLERANCE_RATIO: f32 = 0.6;
const LAYOUT_BLOCK_GAP_RATIO: f32 = 1.6;

/// A side-by-side dual-table page (e.g. a lab report with 22 items laid out
/// as two 11-item columns) needs at least this many visual rows agreeing on
/// the same gutter position before we believe it, so a single coincidental
/// gap (a demographics line like "科室：肺病科    床号：16" happens to have a
/// wide space at roughly the same x as the real gutter) can't manufacture a
/// split on its own.
const DUAL_COLUMN_MIN_SUPPORT_ROWS: usize = 4;
/// ...and that support must also be a healthy fraction of every row on the
/// page that even has >=2 boxes (not just an absolute count), so a handful
/// of stray multi-box rows scattered through an otherwise prose-only page
/// can't reach the floor above by sheer page length.
const DUAL_COLUMN_MIN_SUPPORT_FRACTION: f32 = 0.34;
// There is deliberately no "how close must two rows' gaps be to count as the
// same seam" constant here any more. The previous implementation had one --
// gaps had to cluster within 2% of `content_span` and the reported band was
// the *intersection* of every contributing row's gap -- and it never found a
// real lab report's gutter: see `find_dual_column_band` for why that
// calibration describes a geometry that does not occur in practice.

/// Reconstructs page layout from per-line detection boxes: lines are grouped
/// into visual rows by y-coordinate (within a tolerance relative to line
/// height); a row with a single line is emitted as-is (prose); a row with
/// multiple lines (a table row split into per-cell detections) has each
/// line's x position mapped to a character column and space-padded to align.
/// Rows separated by a much larger vertical gap than the surrounding line
/// height get a blank line between them (paragraph/table boundary).
///
/// A page can also be laid out as **two side-by-side tables** (a lab report
/// splitting its item list into a left and a right half to save vertical
/// space) — in detection-box terms, that's a visual row whose boxes actually
/// belong to *two* unrelated records, with a stable vertical whitespace band
/// (a "gutter") running down most of the page between them. Left unhandled,
/// each such row gets joined into a single flat line carrying both records,
/// and every downstream consumer that assumes "one row = one record" (the
/// regex-based lab-value extractor, table rendering, ...) silently drops the
/// second half. [`find_dual_column_band`] looks for that recurring gutter
/// across the whole page first (conservatively — see its doc), and only if
/// one is found does [`split_row_at_gutter`] break individual qualifying rows
/// into their left/right halves before column alignment.
///
/// Direct port of `ocr_bridge.dart::_rebuildLayoutText`/`_buildRowText` (see
/// that file for the original rationale) — kept as a free function here so it
/// can be unit-tested without the OCR engine and reused by any future
/// box-producing recognizer, not just PP-OCRv5.
#[cfg_attr(not(feature = "engine"), allow(dead_code))]
pub fn rebuild_layout_text(lines: &[LayoutLine]) -> String {
    // Each line's text is corrected in isolation (see
    // `normalize_ocr_decimal_comma`) before anything else touches it, so both
    // the single-box "prose" fast path in `build_row_text` and the multi-box
    // column-aligned path see the same fixed-up text.
    let owned: Vec<LayoutLine> = lines
        .iter()
        .filter(|l| !l.text.trim().is_empty())
        .map(|l| LayoutLine {
            text: normalize_ocr_decimal_comma(&l.text),
            ..(*l).clone()
        })
        .collect();
    let mut lines: Vec<&LayoutLine> = owned.iter().collect();
    if lines.is_empty() {
        return String::new();
    }
    // Reading order: top-to-bottom, then left-to-right.
    lines.sort_by(|a, b| {
        a.top
            .partial_cmp(&b.top)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(
                a.left
                    .partial_cmp(&b.left)
                    .unwrap_or(std::cmp::Ordering::Equal),
            )
    });

    // 1) Group lines into visual rows by y (tolerance = a fraction of line height).
    let mut rows: Vec<Vec<&LayoutLine>> = Vec::new();
    for line in lines.iter().copied() {
        if let Some(last_row) = rows.last() {
            let ref_top = last_row[0].top;
            let tol = LAYOUT_ROW_Y_TOLERANCE_RATIO * line.height.max(last_row[0].height);
            if (line.top - ref_top).abs() <= tol {
                rows.last_mut().unwrap().push(line);
                continue;
            }
        }
        rows.push(vec![line]);
    }

    // 2) Content bounding box (not full image width) as the column-coordinate
    //    reference, same reasoning as the Dart port: avoids background margin
    //    compressing column resolution.
    let content_left = lines.iter().map(|l| l.left).fold(f32::INFINITY, f32::min);
    let content_right = lines
        .iter()
        .map(|l| l.right)
        .fold(f32::NEG_INFINITY, f32::max);
    let content_span = content_right - content_left;

    // 2b) Can a cell's *content* be trusted to say which record it belongs to?
    //     Only on a page whose text lines run level. Photographed reports are
    //     often tilted, and step 1 groups boxes into rows by raw `top`, so once
    //     the tilt carries a line further than the very tolerance that grouping
    //     uses, one visual row silently mixes cells from neighbouring records
    //     — the item name from one row, the reference range from the next.
    //     Reasoning about such a row's cells is then unsound, so
    //     `find_dual_column_band` is told not to.
    let median_height = median_line_height(&lines);
    let tilt_drift = estimate_tilt(&lines, median_height).abs() * content_span;
    let trust_cell_content = tilt_drift <= LAYOUT_ROW_Y_TOLERANCE_RATIO * median_height;

    // 2c) Does this page have a two-table-side-by-side layout? Detected once
    //     over all rows (not per-row) — see `find_dual_column_band` doc.
    let dual_column_band = find_dual_column_band(&rows, content_span, trust_cell_content);

    // 3) Emit each visual row; insert a blank line where the vertical gap to
    //    the previous row is much larger than the line height (block break).
    //    A row that straddles the detected gutter with enough boxes on each
    //    side is emitted as two lines (left record, right record) instead of
    //    one flattened line.
    let mut out_lines: Vec<String> = Vec::new();
    let mut prev_top: Option<f32> = None;
    let mut prev_height: Option<f32> = None;
    for row in &rows {
        let row_top = row.iter().map(|l| l.top).fold(f32::INFINITY, f32::min);
        let row_height = row
            .iter()
            .map(|l| l.height)
            .fold(f32::NEG_INFINITY, f32::max);
        if let Some(pt) = prev_top {
            let ref_height = prev_height.unwrap_or(row_height);
            if ref_height > 0.0 && row_top - pt > LAYOUT_BLOCK_GAP_RATIO * ref_height {
                out_lines.push(String::new());
            }
        }
        match dual_column_band.and_then(|(gl, gr)| split_row_at_gutter(row, gl, gr)) {
            Some((left, right)) => {
                out_lines.push(build_row_text(&left, content_left, content_span));
                out_lines.push(build_row_text(&right, content_left, content_span));
            }
            None => out_lines.push(build_row_text(row, content_left, content_span)),
        }
        prev_top = Some(row_top);
        prev_height = Some(row_height);
    }
    out_lines.join("\n")
}

/// Corrects a specific, narrow OCR misread: a printed decimal point recognized
/// as a comma. On a compressed or low-resolution photo the two glyphs are
/// nearly indistinguishable, and PP-OCRv5 occasionally reads "3.50~10.00" as
/// "3,50~10.00". Every lab report this reconstructs uses a period as its
/// decimal separator throughout (`4.00~10.00`, `1.80~6.40`, ... — never a
/// thousands-grouping comma on a lab value), so a comma directly between two
/// ASCII digits, with nothing else around it, is unambiguously that misread
/// rather than a second, different number format. Left uncorrected it feeds
/// the downstream extractor a malformed range: `3,50~10.00` parses as
/// low=`50`, high=`10` — `low > high`, and a confidently wrong reference band
/// is worse than the extractor dropping the value outright.
///
/// Deliberately narrow: it only ever rewrites a comma that has an ASCII digit
/// immediately on both sides, so prose punctuation (including full-width `，`)
/// and any comma next to whitespace or a CJK character is untouched.
fn normalize_ocr_decimal_comma(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    chars
        .iter()
        .enumerate()
        .map(|(i, &c)| {
            let misread_decimal_point = c == ','
                && i > 0
                && chars[i - 1].is_ascii_digit()
                && chars.get(i + 1).is_some_and(char::is_ascii_digit);
            if misread_decimal_point {
                '.'
            } else {
                c
            }
        })
        .collect()
}

/// How far either side of level [`estimate_tilt`] searches, and how finely.
/// These bound the search, they don't calibrate the decision — the threshold
/// the tilt is compared against is [`LAYOUT_ROW_Y_TOLERANCE_RATIO`], the same
/// tolerance row grouping already uses. 0.25 is ~14 degrees, well past what a
/// legible hand-held photo of a report survives.
const TILT_SEARCH_LIMIT: f32 = 0.25;
const TILT_SEARCH_STEP: f32 = 0.002;

/// Median detection-box height — the page's line height, used as the unit
/// tilt is judged in. Median rather than mean so a banner or a stamp doesn't
/// drag it.
fn median_line_height(lines: &[&LayoutLine]) -> f32 {
    let mut heights: Vec<f32> = lines.iter().map(|l| l.height).collect();
    heights.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    heights.get(heights.len() / 2).copied().unwrap_or(0.0)
}

/// Estimates the page's tilt as the slope (dy/dx) whose horizontal projection
/// of the detection boxes is most sharply peaked. This is the textbook skew
/// estimate: at the true tilt every text line's boxes land in one bin, so the
/// profile is a comb of tall spikes; away from it neighbouring lines smear
/// into each other and flatten it. Sum of squared bin mass scores that
/// peakiness, and boxes are weighted by width so a long line of body text
/// counts for more than a stray tick mark.
fn estimate_tilt(lines: &[&LayoutLine], median_height: f32) -> f32 {
    if median_height <= 0.0 || lines.is_empty() {
        return 0.0;
    }
    let bin = (median_height / 4.0).max(1.0);
    let mut best = (0.0f32, f32::NEG_INFINITY);
    let mut slope = -TILT_SEARCH_LIMIT;
    while slope <= TILT_SEARCH_LIMIT {
        let mut hist: std::collections::HashMap<i64, f32> = std::collections::HashMap::new();
        for line in lines {
            let x_centre = (line.left + line.right) / 2.0;
            let key = ((line.top - slope * x_centre) / bin).floor() as i64;
            *hist.entry(key).or_insert(0.0) += line.right - line.left;
        }
        let peakiness: f32 = hist.values().map(|mass| mass * mass).sum();
        if peakiness > best.1 {
            best = (slope, peakiness);
        }
        slope += TILT_SEARCH_STEP;
    }
    best.0
}

/// One candidate row's horizontal occupancy, as [`find_dual_column_band`]'s
/// projection profile consumes it: the row's own extent (leftmost box edge to
/// rightmost) plus every box interval within it.
struct RowSpans {
    extent: (f32, f32),
    boxes: Vec<(f32, f32)>,
}

impl RowSpans {
    /// Does this row leave the column at `x` blank? Only true *strictly
    /// inside* the row's own extent: the whitespace past a short row's last
    /// box is the page margin, not a gutter, and letting it vote would let a
    /// page of ragged-right prose manufacture a seam out of its own margin.
    fn is_blank_at(&self, x: f32) -> bool {
        x > self.extent.0 && x < self.extent.1 && !self.boxes.iter().any(|(l, r)| x > *l && x < *r)
    }
}

/// Looks for a vertical whitespace band that recurs at (roughly) the same
/// x-position across many of the page's visual rows — the seam between a
/// left table and a right table on a side-by-side dual-table page. Returns
/// `(band_left, band_right)` in the same pixel coordinates as `LayoutLine`,
/// or `None` if no such band clears the conservative bar below.
///
/// Why this can't just take "the widest gap in each row": within a single
/// table half, the gap before a fixed-x column (e.g. a right-aligned label
/// column followed by a result column that always starts at the same x) is
/// often *wider* than the actual left/right seam, because label lengths
/// vary but the seam itself is a fixed, narrow band of unused page margin.
/// So instead this collects *every* adjacent-box gap on *every* multi-box
/// row, clusters them by x-position, and picks the cluster that (a) is
/// backed by enough distinct rows to rule out coincidence, and (b) — among
/// clusters that clear that bar — has the largest gap width, since the real
/// seam is the one whitespace band wide enough to separate two independent
/// tables, whereas same-support internal-column gaps (e.g. value -> its
/// reference range) tend to be narrow.
///
/// Conservative by construction: a prose page (one detection box per visual
/// row) has zero multi-box rows, so this returns `None` immediately — see
/// `rebuild_layout_text_single_line_per_row_passes_through` and
/// `rebuild_layout_text_dual_column_leaves_single_column_page_untouched`.
///
/// # Why this is a projection profile and not a clustering of per-row gaps
///
/// The original implementation collected each row's adjacent-box gaps,
/// clustered them by midpoint within a fixed 2%-of-content-width tolerance,
/// and reported the *intersection* of every contributing row's gap. On real
/// lab photos it never fired once. Both halves of that calibration assume the
/// left table's right edge is essentially constant down the page, and it
/// simply isn't: item names differ in length (`1白细胞计数` vs
/// `5嗜酸性粒细胞计数`) and the recognizer frequently glues a value onto the
/// name (`5嗜酸性粒细胞计数0.17`), so the left half's right edge swings far
/// wider than 2% — which both scatters the gaps across several clusters and
/// collapses the intersection to nothing (`width <= 0.0`, cluster discarded).
/// One row with an unusually wide left half could veto the whole page.
///
/// So instead of asking "do the rows' gaps agree closely enough", this asks
/// the question document layout analysis normally asks: **for each x, how
/// many rows leave that column blank?** That profile's high plateau *is* the
/// gutter, and its edges fall out of the data — there is no tolerance
/// constant to calibrate, so a ragged left edge costs support only at the x
/// values it actually reaches, instead of invalidating the seam entirely.
/// The band is then the widest run of x that clears the same support bar the
/// old code used ([`DUAL_COLUMN_MIN_SUPPORT_ROWS`] /
/// [`DUAL_COLUMN_MIN_SUPPORT_FRACTION`], both unchanged), and what's returned
/// is that run's best-supported core, so the midpoint `split_row_at_gutter`
/// tests sits where the most rows are blank.
///
/// Dropping the intersection loses the old guarantee that every voting row's
/// gap contains the returned midpoint — deliberately. That guarantee was
/// never needed: [`split_row_at_gutter`] re-checks each row on its own and
/// returns `None` for any row that doesn't straddle the seam, which is
/// already the correct per-row degradation (that row is emitted unsplit).
/// Requiring it up front only let one narrow row suppress the entire page.
fn find_dual_column_band(
    rows: &[Vec<&LayoutLine>],
    content_span: f32,
    trust_cell_content: bool,
) -> Option<(f32, f32)> {
    if content_span <= 0.0 {
        return None;
    }
    let candidate_rows: Vec<&Vec<&LayoutLine>> = rows.iter().filter(|r| r.len() >= 2).collect();
    if candidate_rows.len() < DUAL_COLUMN_MIN_SUPPORT_ROWS {
        return None;
    }

    let spans: Vec<RowSpans> = candidate_rows
        .iter()
        .map(|row| RowSpans {
            extent: (
                row.iter().map(|l| l.left).fold(f32::INFINITY, f32::min),
                row.iter()
                    .map(|l| l.right)
                    .fold(f32::NEG_INFINITY, f32::max),
            ),
            boxes: row.iter().map(|l| (l.left, l.right)).collect(),
        })
        .collect();

    // The profile can only change value at a box edge, so it is piecewise
    // constant between consecutive edges. Sweeping the sorted edges evaluates
    // it exactly, with no bin count / resolution constant to pick.
    let mut edges: Vec<f32> = spans
        .iter()
        .flat_map(|s| s.boxes.iter().flat_map(|(l, r)| [*l, *r]))
        .collect();
    edges.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    edges.dedup();
    if edges.len() < 2 {
        return None;
    }

    // Same bar as before: an absolute row floor *and* a healthy fraction of
    // the page's multi-box rows.
    let min_support = DUAL_COLUMN_MIN_SUPPORT_ROWS
        .max((DUAL_COLUMN_MIN_SUPPORT_FRACTION * candidate_rows.len() as f32).ceil() as usize);

    // (left, right, how many rows are blank across this whole slice)
    let cells: Vec<(f32, f32, usize)> = edges
        .windows(2)
        .map(|w| {
            let mid = (w[0] + w[1]) / 2.0;
            let support = spans.iter().filter(|s| s.is_blank_at(mid)).count();
            (w[0], w[1], support)
        })
        .collect();

    let mut candidates: Vec<(f32, f32, f32)> = Vec::new(); // (core width, left, right)
    let mut i = 0;
    while i < cells.len() {
        if cells[i].2 < min_support {
            i += 1;
            continue;
        }
        let start = i;
        while i < cells.len() && cells[i].2 >= min_support {
            i += 1;
        }
        // Within this qualifying run, keep the widest stretch at the run's
        // peak support: the sub-band the largest number of rows agree is
        // blank, so the midpoint handed to `split_row_at_gutter` is the one
        // most rows can actually act on. Ranking candidate seams by that
        // core's width preserves the previous policy of preferring the
        // widest band -- an internal column gap (value -> its reference
        // range) is narrow, whereas the seam between two independent tables
        // is the one whitespace band wide enough to separate them.
        let run = &cells[start..i];
        let peak = run.iter().map(|c| c.2).max().unwrap_or(0);
        let mut core: Option<(f32, f32)> = None;
        let mut j = 0;
        while j < run.len() {
            if run[j].2 != peak {
                j += 1;
                continue;
            }
            let s = j;
            while j < run.len() && run[j].2 == peak {
                j += 1;
            }
            let (l, r) = (run[s].0, run[j - 1].1);
            if core.is_none_or(|(cl, cr)| r - l > cr - cl) {
                core = Some((l, r));
            }
        }
        if let Some((l, r)) = core {
            candidates.push((r - l, l, r));
        }
    }

    // Geometry alone cannot finish the job: a single-column 4-field table
    // ("Hemoglobin | 12 | 11.0-16.0 | g/dL", every row identical) projects
    // exactly the same profile as two side-by-side 2-field tables -- a clean,
    // fully-supported whitespace band with two boxes either side, widest in
    // the middle. Splitting there would tear one record in half, which is
    // strictly worse than leaving two records joined, so the widest band is
    // only *proposed* here; each candidate must then show it behaves like a
    // seam before it is believed.
    //
    // The tell is what starts the right-hand half. A record begins with an
    // item *name*; the cell after a mere column break begins with the value,
    // range or unit that belongs to the record still in progress on the left.
    // So a candidate is accepted only if it actually splits enough rows and
    // most of those right halves open with something name-like.
    candidates.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
    for (_, l, r) in candidates {
        let (mut splits, mut name_heads, mut value_heads) = (0usize, 0usize, 0usize);
        for row in &candidate_rows {
            if let Some((_, right)) = split_row_at_gutter(row, l, r) {
                splits += 1;
                // `split_row_at_gutter` returns the right half sorted by
                // `left`, so `right[0]` is the cell the record would open on.
                if looks_like_measurement(&right[0].text) {
                    value_heads += 1;
                } else {
                    name_heads += 1;
                }
            }
        }
        // On a tilted page the head cell may simply belong to a different
        // record than the rest of its half, so the name-vs-measurement test
        // means nothing and is skipped. Skipping it splits more eagerly, which
        // is the safe direction downstream: an over-split row leaves a value
        // stranded without a reference range and the extractor drops it,
        // whereas leaving the row joined hands that value the *neighbouring*
        // record's range and produces a confidently wrong result.
        if splits >= DUAL_COLUMN_MIN_SUPPORT_ROWS
            && (!trust_cell_content || name_heads > value_heads)
        {
            return Some((l, r));
        }
    }
    None
}

/// Does this cell read as a measurement — a figure, a range, a unit — rather
/// than the start of a new record? Used by [`find_dual_column_band`] to reject
/// a single-column table's internal column break, which is geometrically
/// indistinguishable from a real dual-table seam, so only the content of the
/// cell the right-hand record would open on can tell them apart.
///
/// Three shapes count as a measurement, all of them things that continue the
/// record already in progress rather than starting a new one:
///   * no letters at all (`char::is_alphabetic` covers CJK item names as well
///     as Latin ones) — `11.0 - 16.0`, `120~160`, `3.86`;
///   * a solidus anywhere — `mmol/L`, `g/dL`, `10^9/L` are units, and a unit
///     never opens a record;
///   * a leading comparison — `<5.20`, `>1.04` is a reference bound.
///
/// Erring toward "measurement" is the safe direction: it can only suppress a
/// split (two records left on one line, which the extractor already survives),
/// never manufacture one that tears a record in half. The known cost is a
/// Chinese item name that genuinely contains a solidus, e.g. `A/G比值` — a
/// page whose right-hand column starts with one of those simply won't split.
fn looks_like_measurement(text: &str) -> bool {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return false;
    }
    !trimmed.chars().any(char::is_alphabetic)
        || trimmed.contains('/')
        || trimmed.starts_with('<')
        || trimmed.starts_with('>')
}

/// If `row` has a genuine left/right split at the gutter `[gutter_left,
/// gutter_right]` — a gap between two of its boxes containing the gutter's
/// midpoint, with at least 2 boxes on each side — returns the row split into
/// its left and right halves. Requiring >=2 boxes per side (not just >=1)
/// is what keeps this from splitting e.g. a demographics row's incidental
/// "label: value    label: value" gap into two 1-box halves: such a row
/// still contributes to `find_dual_column_band`'s vote count (harmless —
/// real dual-table rows vastly outnumber it there) but never actually gets
/// split. Returns `None` (row emitted unchanged) if no gap contains the
/// gutter midpoint at all — the case for a full-width title/header/footer
/// line, where a single box spans straight across the gutter position.
fn split_row_at_gutter<'a>(
    row: &[&'a LayoutLine],
    gutter_left: f32,
    gutter_right: f32,
) -> Option<(Vec<&'a LayoutLine>, Vec<&'a LayoutLine>)> {
    if row.len() < 4 {
        return None;
    }
    let mut sorted: Vec<&LayoutLine> = row.to_vec();
    sorted.sort_by(|a, b| {
        a.left
            .partial_cmp(&b.left)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    let gutter_mid = (gutter_left + gutter_right) / 2.0;
    for i in 0..sorted.len() - 1 {
        if sorted[i].right <= gutter_mid && gutter_mid <= sorted[i + 1].left {
            let left = sorted[..=i].to_vec();
            let right = sorted[i + 1..].to_vec();
            return if left.len() >= 2 && right.len() >= 2 {
                Some((left, right))
            } else {
                None
            };
        }
    }
    None
}

/// Joins one visual row's lines into a single line of text. A single-line row
/// (prose) is returned as-is; a multi-line row (one table row split into
/// several detections) has each line after the first padded with spaces so
/// its start lands at the target character column derived from its `left`
/// position within `content_span` — at least 2 spaces, matching the viewer's
/// `splitCells` "2+ consecutive spaces = column break" rule.
#[cfg_attr(not(feature = "engine"), allow(dead_code))]
fn build_row_text(row: &[&LayoutLine], content_left: f32, content_span: f32) -> String {
    if row.len() <= 1 || content_span <= 0.0001 {
        return row
            .iter()
            .map(|l| l.text.as_str())
            .collect::<Vec<_>>()
            .join(" ");
    }
    let mut sorted = row.to_vec();
    sorted.sort_by(|a, b| {
        a.left
            .partial_cmp(&b.left)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    let mut buf = String::new();
    let mut buf_len = 0usize; // char count, not byte length (CJK-safe)
    for line in sorted {
        if buf.is_empty() {
            buf.push_str(&line.text);
            buf_len = line.text.chars().count();
            continue;
        }
        let col = (((line.left - content_left) / content_span) * LAYOUT_TARGET_COLUMN_WIDTH as f32)
            .round() as i64;
        let target_len = col.max(buf_len as i64 + 2).max(0) as usize;
        let pad = target_len.saturating_sub(buf_len);
        buf.push_str(&" ".repeat(pad));
        buf.push_str(&line.text);
        buf_len += pad + line.text.chars().count();
    }
    buf
}

/// macOS: hand the raw bytes to Apple Vision, which decodes them via ImageIO
/// (handles HEIC/HEIF iPhone photos + every Apple format, unlike the Rust
/// `image` crate) and recognizes the text.
#[cfg(target_os = "macos")]
fn recognize_vision(image_bytes: &[u8]) -> Result<OcrOutcome> {
    vision_macos::recognize_bytes(image_bytes)
}

/// Recognize text in image bytes. **macOS**: Apple Vision is the primary
/// recognizer (offline, strong Chinese, #41); if it errors or finds no text,
/// fall back to the oar-ocr / PP-OCRv5 engine. **Other platforms**: the engine
/// (or a stub error when the engine isn't linked in, e.g. a no-`engine` build).
#[cfg(target_os = "macos")]
pub fn recognize(image_bytes: &[u8]) -> Result<OcrOutcome> {
    match recognize_vision(image_bytes) {
        Ok(outcome) if !outcome.text.trim().is_empty() => return Ok(outcome),
        Ok(_) => {} // Vision ran but found nothing — try the engine.
        Err(e) => eprintln!("[ocr] Apple Vision failed, falling back to engine: {e:#}"),
    }
    #[cfg(feature = "engine")]
    {
        recognize_engine(image_bytes)
    }
    #[cfg(not(feature = "engine"))]
    {
        Ok(OcrOutcome {
            text: String::new(),
            confidence: 0.0,
            backend: OcrBackend::AppleVision,
        })
    }
}

/// Windows: Windows.Media.Ocr is the primary recognizer (offline, on-device,
/// #41); if it errors or finds no text, fall back to the oar-ocr / PP-OCRv5
/// engine.
#[cfg(target_os = "windows")]
pub fn recognize(image_bytes: &[u8]) -> Result<OcrOutcome> {
    match windows_ocr::recognize_bytes(image_bytes) {
        Ok(outcome) if !outcome.text.trim().is_empty() => return Ok(outcome),
        Ok(_) => {} // ran but found nothing — try the engine.
        Err(e) => eprintln!("[ocr] Windows.Media.Ocr failed, falling back to engine: {e:#}"),
    }
    #[cfg(feature = "engine")]
    {
        recognize_engine(image_bytes)
    }
    #[cfg(not(feature = "engine"))]
    {
        Ok(OcrOutcome {
            text: String::new(),
            confidence: 0.0,
            backend: OcrBackend::WindowsOcr,
        })
    }
}

#[cfg(all(
    not(target_os = "macos"),
    not(target_os = "windows"),
    feature = "engine"
))]
pub fn recognize(image_bytes: &[u8]) -> Result<OcrOutcome> {
    recognize_engine(image_bytes)
}

/// No-`engine`, non-native stub: nothing to recognize with. Callers treat OCR
/// failure as non-fatal (store the file without extracted text).
#[cfg(all(
    not(target_os = "macos"),
    not(target_os = "windows"),
    not(feature = "engine")
))]
pub fn recognize(_image_bytes: &[u8]) -> Result<OcrOutcome> {
    anyhow::bail!("ocr::recognize: OCR engine not available on this platform")
}

/// OCR a PDF that has no text layer: extract each page's embedded image
/// (JPEG / `DCTDecode` XObjects -- the common encoding for App-exported
/// "image PDF" scans, e.g. Photos.app "Save as PDF" or Pillow-based
/// exporters) and OCR it via [`recognize`], joining page texts with "\n".
///
/// Only `DCTDecode`-encoded image XObjects are decoded: the stream bytes for
/// that filter are the raw JPEG, so no image-specific reconstruction is
/// needed. Other embedded-image encodings (`CCITTFaxDecode` fax scans,
/// `JPXDecode` JPEG2000, raw/Flate-encoded raster samples that would need
/// colorspace + bit-depth reconstruction) are not supported and are skipped
/// page-by-page rather than failing the whole document.
///
/// Returns an error if the PDF can't be parsed, or if no page yields any
/// non-empty OCR text. Confidence is the mean of all pages' line confidences.
/// Upper bound on how many embedded page images a single PDF will be OCR'd.
/// Each image runs a full decode + [`preprocess`] + ONNX inference — seconds of
/// CPU and hundreds of MB transiently — so a small crafted PDF declaring
/// thousands of pages/images could pin CPU and memory for minutes (a DoS). We
/// OCR at most this many and stop; anything beyond is reported as skipped rather
/// than silently dropped. 50 comfortably covers real multi-page reports.
const MAX_OCR_PAGE_IMAGES: usize = 50;

/// OCR each image in `images` via `recognize_one`, but run the (expensive)
/// recognizer on at most [`MAX_OCR_PAGE_IMAGES`] of them. Returns the collected
/// per-page texts, their confidences, and the count of images that were NOT
/// OCR'd because the cap was reached.
///
/// The iterator is consumed lazily one image at a time (each is dropped
/// immediately once past the cap), so both the OCR work and the peak memory
/// stay bounded regardless of how many images the document declares. Kept
/// separate from [`recognize_pdf`] so the cap is unit-testable without a real
/// multi-image PDF or the OCR engine.
fn ocr_page_images<I, F>(images: I, mut recognize_one: F) -> (Vec<String>, Vec<f32>, usize)
where
    I: IntoIterator<Item = Vec<u8>>,
    F: FnMut(&[u8]) -> Result<OcrOutcome>,
{
    let mut page_texts = Vec::new();
    let mut page_confidences = Vec::new();
    let mut processed = 0usize;
    let mut skipped = 0usize;
    for image_bytes in images {
        if processed >= MAX_OCR_PAGE_IMAGES {
            // Past the cap: don't run OCR, just tally so we can report honestly.
            skipped += 1;
            continue;
        }
        processed += 1;
        match recognize_one(&image_bytes) {
            Ok(outcome) if !outcome.text.trim().is_empty() => {
                page_confidences.push(outcome.confidence);
                page_texts.push(outcome.text);
            }
            Ok(_) => {}
            Err(e) => {
                // One image failing OCR shouldn't sink the other pages.
                eprintln!("recognize_pdf: OCR failed for one page image: {e:#}");
            }
        }
    }
    (page_texts, page_confidences, skipped)
}

pub fn recognize_pdf(pdf_bytes: &[u8]) -> Result<OcrOutcome> {
    let doc = Document::load_mem(pdf_bytes).context("recognize_pdf: parse PDF")?;
    // Lazily stream every page's DCTDecode images; the cap is enforced (and
    // peak memory bounded) inside `ocr_page_images`.
    let images = doc
        .get_pages()
        .into_values()
        .flat_map(|page_id| extract_dct_images(&doc, page_id));
    let (page_texts, page_confidences, skipped) = ocr_page_images(images, recognize);
    if skipped > 0 {
        // No silent truncation: make it visible that we stopped early on purpose.
        eprintln!(
            "recognize_pdf: OCR capped at {MAX_OCR_PAGE_IMAGES} page images to bound work; \
             {skipped} additional embedded image(s) were NOT OCR'd"
        );
    }
    if page_texts.is_empty() {
        anyhow::bail!("recognize_pdf: no OCR-able (DCTDecode) page images found in PDF");
    }
    Ok(OcrOutcome {
        text: page_texts.join("\n"),
        confidence: mean_confidence(&page_confidences),
        // Page images went through `recognize`, whose primary engine is
        // platform-fixed; label with that platform's engine.
        backend: pdf_ocr_backend(),
    })
}

/// The primary OCR engine `recognize` uses on this platform — used to label
/// [`recognize_pdf`]'s aggregate outcome (its page images all go through
/// `recognize`).
#[inline]
fn pdf_ocr_backend() -> OcrBackend {
    #[cfg(target_os = "macos")]
    {
        OcrBackend::AppleVision
    }
    #[cfg(target_os = "windows")]
    {
        OcrBackend::WindowsOcr
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        OcrBackend::Onnx
    }
}

/// Collect raw JPEG bytes for every `DCTDecode` image XObject directly
/// referenced by a page's `/Resources /XObject` dict. Does not recurse into
/// Form XObjects.
fn extract_dct_images(doc: &Document, page_id: lopdf::ObjectId) -> Vec<Vec<u8>> {
    let mut out = Vec::new();
    let resources = match doc.get_page_resources(page_id) {
        Ok((Some(dict), _)) => dict,
        _ => return out,
    };
    let xobjects = match resources.get(b"XObject").and_then(Object::as_dict) {
        Ok(d) => d.clone(),
        Err(_) => return out,
    };
    for (_name, obj_ref) in xobjects.iter() {
        let Object::Reference(oid) = obj_ref else {
            continue;
        };
        let Ok(Object::Stream(stream)) = doc.get_object(*oid) else {
            continue;
        };
        let is_image =
            stream.dict.get(b"Subtype").and_then(Object::as_name).ok() == Some(b"Image".as_slice());
        if !is_image {
            continue;
        }
        let filters = stream.filters().unwrap_or_default();
        if filters.len() == 1 && filters[0] == b"DCTDecode" {
            out.push(stream.content.clone());
        }
        // Other filters not handled -- see doc comment on recognize_pdf.
    }
    out
}

/// Per-page threshold below which a page's own extracted text is treated as
/// "no usable text layer" for [`recognize_pdf_mixed`]. Same value `pipeline`
/// used to apply to the *whole document's* concatenated text -- the bug this
/// module fixes is exactly that whole-document application: a text-rich page
/// 1 (e.g. a printed discharge summary) pushes the concatenated length past
/// this threshold even when every later page is a scanned image with no text
/// layer at all, so those pages never got OCR'd and their content silently
/// never made it into the document.
pub const MIN_TEXT_LAYER_LEN: usize = 20;

/// How one page of a [`recognize_pdf_mixed`] call was resolved.
#[derive(Debug, Clone, PartialEq)]
pub enum PdfPageText {
    /// The page's own embedded text layer had enough text to use as-is.
    TextLayer(String),
    /// The text layer was missing/too short; OCR on the page's embedded
    /// DCTDecode image(s) recovered text instead.
    Ocr {
        text: String,
        confidence: f32,
        backend: OcrBackend,
    },
    /// Neither a usable text layer nor OCR produced anything for this page:
    /// no embedded DCTDecode image to OCR, OCR ran and found nothing, every
    /// image on the page failed to OCR, or the page was past
    /// [`MAX_OCR_PAGE_IMAGES`] and never attempted. Callers MUST surface
    /// pages in this state to the user -- silently dropping them is the bug
    /// `recognize_pdf_mixed` exists to fix, and reproducing it one layer up
    /// (e.g. by joining only the recognized pages and reporting success) just
    /// moves the same defect.
    Unrecognized,
}

/// One page's outcome from [`recognize_pdf_mixed`]. `page_no` is 1-based,
/// matching `lopdf`/`pdf-extract`'s own page numbering.
#[derive(Debug, Clone, PartialEq)]
pub struct PdfPage {
    pub page_no: i32,
    pub result: PdfPageText,
}

/// Outcome of a whole-document mixed-PDF recognition pass: one entry per
/// page, in order. `pages.len()` is therefore an accurate page count --
/// unlike `parser::extract`'s old form-feed-counting heuristic, which always
/// undercounted: `pdf-extract`'s `PlainTextOutput::end_page` never actually
/// writes `\x0c` between pages, so that heuristic's `+= 1` on match count
/// never fired and every PDF reported `page_count == 1` regardless of its
/// real length.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct MixedPdfOutcome {
    pub pages: Vec<PdfPage>,
}

impl MixedPdfOutcome {
    pub fn page_count(&self) -> i32 {
        self.pages.len() as i32
    }

    /// 1-based page numbers that ended up [`PdfPageText::Unrecognized`] --
    /// exactly the set a caller must not stay silent about.
    pub fn unrecognized_pages(&self) -> Vec<i32> {
        self.pages
            .iter()
            .filter(|p| matches!(p.result, PdfPageText::Unrecognized))
            .map(|p| p.page_no)
            .collect()
    }

    /// All recognized text (text-layer + OCR'd pages), joined in page order.
    /// Unrecognized pages contribute nothing to this string -- callers that
    /// need to know about them use [`unrecognized_pages`](Self::unrecognized_pages).
    pub fn text(&self) -> String {
        self.pages
            .iter()
            .filter_map(|p| match &p.result {
                PdfPageText::TextLayer(t) => Some(t.as_str()),
                PdfPageText::Ocr { text, .. } => Some(text.as_str()),
                PdfPageText::Unrecognized => None,
            })
            .collect::<Vec<_>>()
            .join("\n")
    }
}

/// Resolve one page that has no usable text layer: OCR its embedded
/// DCTDecode image(s) if the per-document OCR budget allows, otherwise
/// report [`PdfPageText::Unrecognized`] rather than silently skip it.
/// `ocr_budget` is shared (decremented) across the whole document -- see
/// [`build_mixed_pages`].
fn resolve_page_via_ocr<F>(
    images: Vec<Vec<u8>>,
    ocr_budget: &mut usize,
    recognize_one: &mut F,
) -> PdfPageText
where
    F: FnMut(&[u8]) -> Result<OcrOutcome>,
{
    if images.is_empty() {
        return PdfPageText::Unrecognized;
    }
    if *ocr_budget == 0 {
        // Past the cap: don't run the (expensive) recognizer, but this page
        // is explicitly "not attempted", not "checked and empty" -- both
        // collapse to `Unrecognized` so the caller reports it either way.
        return PdfPageText::Unrecognized;
    }
    *ocr_budget -= 1;
    let mut texts = Vec::new();
    let mut confidences = Vec::new();
    let mut backend = None;
    for image_bytes in images {
        match recognize_one(&image_bytes) {
            Ok(outcome) if !outcome.text.trim().is_empty() => {
                backend = Some(outcome.backend);
                confidences.push(outcome.confidence);
                texts.push(outcome.text);
            }
            Ok(_) => {} // ran, found nothing on this image -- other images on the page may still hit.
            Err(e) => {
                // One image failing OCR shouldn't sink the rest of the page's images.
                eprintln!("recognize_pdf_mixed: OCR failed for one page image: {e:#}");
            }
        }
    }
    match backend {
        Some(backend) if !texts.is_empty() => PdfPageText::Ocr {
            text: texts.join("\n"),
            confidence: mean_confidence(&confidences),
            backend,
        },
        _ => PdfPageText::Unrecognized,
    }
}

/// Pure decision core of [`recognize_pdf_mixed`]: given each page's own
/// extracted text-layer text and its embedded DCTDecode image bytes (if
/// any), decide per page whether the text layer is usable and, for pages
/// that need it, run `recognize_one` (capped at [`MAX_OCR_PAGE_IMAGES`]
/// pages actually OCR'd -- same DoS bound `recognize_pdf` already enforces,
/// just counted per page instead of per image since real scanned PDFs are
/// overwhelmingly one image per page). Kept separate from
/// `recognize_pdf_mixed` so the actual fix -- per-page instead of
/// whole-document text-layer detection -- is unit-testable without a real
/// multi-page PDF or the OCR engine (mirrors [`ocr_page_images`]'s reason
/// for existing).
fn build_mixed_pages<F>(
    page_texts: Vec<String>,
    mut page_images: Vec<Vec<Vec<u8>>>,
    mut recognize_one: F,
) -> Vec<PdfPage>
where
    F: FnMut(&[u8]) -> Result<OcrOutcome>,
{
    let mut ocr_budget = MAX_OCR_PAGE_IMAGES;
    page_texts
        .into_iter()
        .enumerate()
        .map(|(idx, text)| {
            let page_no = idx as i32 + 1;
            if text.trim().chars().count() >= MIN_TEXT_LAYER_LEN {
                return PdfPage {
                    page_no,
                    result: PdfPageText::TextLayer(text),
                };
            }
            let images = page_images
                .get_mut(idx)
                .map(std::mem::take)
                .unwrap_or_default();
            let result = resolve_page_via_ocr(images, &mut ocr_budget, &mut recognize_one);
            PdfPage { page_no, result }
        })
        .collect()
}

/// OCR a PDF that mixes real text-layer pages with scanned/image-only pages
/// (e.g. a discharge summary whose first page was printed and whose later
/// pages are appended lab-report scans), one page at a time -- so a
/// text-rich first page can no longer cause every later scanned page to be
/// silently skipped. See [`MIN_TEXT_LAYER_LEN`]'s doc comment for the bug
/// this replaces.
///
/// Returns one [`PdfPage`] per page, in order. `pipeline::ingest` uses
/// [`MixedPdfOutcome::text`] for what gets stored and
/// [`MixedPdfOutcome::unrecognized_pages`] for what it MUST tell the caller
/// was not captured -- never silently drop that list.
pub fn recognize_pdf_mixed(pdf_bytes: &[u8]) -> Result<MixedPdfOutcome> {
    let doc = Document::load_mem(pdf_bytes).context("recognize_pdf_mixed: parse PDF")?;
    let page_ids: Vec<lopdf::ObjectId> = doc.get_pages().into_values().collect();
    let mut page_texts = pdf_extract::extract_text_from_mem_by_pages(pdf_bytes)
        .map_err(|e| anyhow::anyhow!("recognize_pdf_mixed: extract per-page text layer: {e}"))?;
    // `pdf-extract` and `lopdf` both derive page order by walking the same page
    // tree (`Document::get_pages`), so these line up 1:1 for any PDF that parses
    // at all. Guard the lengths anyway rather than assume it, so a PDF where
    // they somehow disagree degrades to "treat the extra/missing pages as no
    // text layer" (still OCR-attempted) instead of a panic or a silent
    // misalignment that mislabels every later page.
    page_texts.resize(page_ids.len(), String::new());
    let page_images: Vec<Vec<Vec<u8>>> = page_ids
        .iter()
        .map(|&page_id| extract_dct_images(&doc, page_id))
        .collect();
    let pages = build_mixed_pages(page_texts, page_images, recognize);
    Ok(MixedPdfOutcome { pages })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The banding dedup rule must tile the page with no gaps and no double-counts:
    /// every vertical position is owned by exactly one band's core. Cores here are
    /// [0,1100), [1100,2200), [2200, end] with the last band open-ended.
    #[cfg(feature = "engine")]
    #[test]
    fn band_owns_tiles_page_without_gaps_or_overlap() {
        let cores = [
            (0.0, 1100.0, false),
            (1100.0, 2200.0, false),
            (2200.0, 3000.0, true),
        ];
        // A line's center is owned by exactly one band, across the whole page and
        // past the last core (a line hanging below 3000 still belongs to the last).
        for center in [0.0, 549.0, 1099.9, 1100.0, 2199.9, 2200.0, 2999.0, 3200.0] {
            let owners = cores
                .iter()
                .filter(|(t, b, last)| band_owns(center, *t, *b, *last))
                .count();
            assert_eq!(
                owners, 1,
                "center {center} should be owned by exactly one band"
            );
        }
        // Seam is half-open: 1100.0 goes to the upper band, not the lower one.
        assert!(!band_owns(1100.0, 0.0, 1100.0, false));
        assert!(band_owns(1100.0, 1100.0, 2200.0, false));
    }

    /// Empirical before/after of the banding fix. Stacks a real dense lab-report
    /// photo 2x vertically into a 960x2560 tall page — long side 2560, which the
    /// PP detector rescales to ~960 (0.375x), the same severe shrink that made a
    /// tall screenshot lose its dense small text. Compares RAW detection counts
    /// (like-for-like): single whole-image predict vs the new banded path.
    /// Banding keeps each half near-native, so it should detect materially more
    /// lines. `#[ignore]` (needs models + the demo asset): run with
    /// `cargo test -p ocr --features engine -- --ignored --nocapture banding_recovers`.
    /// Orientation fix: OCR a 90°-rotated real report photo (血常规报告1.jpg — the
    /// original is physically sideways). With the doc-ori model wired into the
    /// pipeline, oar-ocr rotates it upright before detection, so the layout text
    /// comes out in readable horizontal rows instead of vertical columns. Prints
    /// the text to eyeball. `#[ignore]` (needs models + asset):
    /// `cargo test -p ocr --features engine -- --ignored --nocapture orientation_uprights`.
    /// Replicates the MOBILE condition: explicit model dir (like
    /// `ensure_pp_models_ready` + `set_model_dir`) + auto-download OFF. If this
    /// leaves the 90° report vertical while the auto-download variant uprights it,
    /// the bug is in how the orientation model is loaded via explicit path (not
    /// Android-specific). Run: `cargo test -p ocr --no-default-features
    /// --features engine -- --ignored --nocapture orientation_explicit_path`.
    /// Diagnostic: dump each recognized line's box (top/left/right/height) + text
    /// for a real report, to see WHY the rendered layout is jumbled — is it skew
    /// (rows slanted → y-grouping mis-groups), 2-column interleaving, or both?
    /// `cargo test -p ocr --features engine -- --ignored --nocapture dump_boxes`.
    #[cfg(feature = "engine")]
    #[test]
    #[ignore]
    fn dump_boxes_for_layout_diagnosis() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../examples/demo-dataset/real/血常规报告1.jpg"
        );
        let bytes = std::fs::read(path).expect("photo present");
        // predict_lines already applies geometric orientation, so boxes are in the
        // uprighted frame — the same frame rebuild_layout_text groups.
        let mut lines = predict_lines(&bytes).expect("ocr");
        lines.sort_by(|a, b| a.top.partial_cmp(&b.top).unwrap());
        eprintln!("total lines = {}", lines.len());
        for l in &lines {
            eprintln!(
                "top={:6.0} left={:6.0} right={:6.0} h={:4.0} w={:4.0} | {}",
                l.top,
                l.left,
                l.right,
                l.bottom - l.top,
                l.right - l.left,
                l.text.chars().take(24).collect::<String>()
            );
        }
    }

    #[cfg(feature = "engine")]
    #[test]
    #[ignore]
    fn orientation_explicit_path_like_mobile() {
        let oar = format!("{}/.oar", std::env::var("HOME").unwrap());
        set_model_dir(std::path::PathBuf::from(&oar));
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../examples/demo-dataset/real/血常规报告1.jpg"
        );
        let bytes = std::fs::read(path).expect("demo report photo present");
        let out = recognize_engine_layout(&bytes).expect("OCR");
        eprintln!("----- 显式路径(模拟手机)识别文本 -----\n{}", out.text);
    }

    #[cfg(feature = "engine")]
    #[test]
    #[ignore]
    fn orientation_uprights_sideways_report() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../examples/demo-dataset/real/血常规报告1.jpg"
        );
        let bytes = std::fs::read(path).expect("demo report photo present");
        let out = recognize_engine_layout(&bytes).expect("OCR");
        eprintln!(
            "----- 血常规报告1(原件 90° 躺倒)识别文本 -----\n{}",
            out.text
        );
        assert!(
            out.text.contains("白细胞") || out.text.contains("红细胞"),
            "expected lab terms, got: {}",
            out.text
        );
    }

    #[cfg(feature = "engine")]
    #[test]
    #[ignore]
    fn banding_recovers_more_lines_than_single_pass() {
        use std::io::Cursor;
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../examples/demo-dataset/real/血常规报告1.jpg"
        );
        let bytes = std::fs::read(path).expect("demo report photo present");

        // Build the tall synthetic page: the report stacked on itself.
        let base = decode_image_bounded(&bytes).expect("decode").to_rgb8();
        let (w, h) = base.dimensions();
        let mut tall = image::RgbImage::new(w, h * 2);
        image::imageops::replace(&mut tall, &base, 0, 0);
        image::imageops::replace(&mut tall, &base, 0, h as i64);
        let mut tall_png = Vec::new();
        image::DynamicImage::ImageRgb8(tall)
            .write_to(&mut Cursor::new(&mut tall_png), image::ImageFormat::Png)
            .expect("encode tall png");

        let nonempty = |regions: &[oar_ocr::oarocr::TextRegion]| {
            regions
                .iter()
                .filter(|r| {
                    r.text
                        .as_ref()
                        .map(|t| !t.trim().is_empty())
                        .unwrap_or(false)
                })
                .count()
        };

        // Old behavior: single whole-image predict on the 2560-tall page.
        let ocr = pipeline().expect("pipeline");
        let dynamic = preprocess(decode_image_bounded(&tall_png).expect("decode tall"));
        let single = ocr
            .predict(vec![dynamic_to_rgb(dynamic)])
            .expect("single predict")
            .into_iter()
            .next()
            .map(|r| r.text_regions)
            .unwrap_or_default();
        let single_raw = nonempty(&single);

        // New behavior: banded path — count raw lines it keeps after dedup.
        let banded_raw = predict_lines(&tall_png).expect("banded predict").len();

        eprintln!("tall page 960x2560 — single-pass raw lines = {single_raw}");
        eprintln!("tall page 960x2560 — banded      raw lines = {banded_raw}");
        assert!(
            banded_raw > single_raw,
            "banding should recover more lines on a tall page: single={single_raw} banded={banded_raw}"
        );
    }

    /// Minimal IEEE CRC-32 (used to forge a valid PNG IHDR chunk below).
    fn crc32(bytes: &[u8]) -> u32 {
        let mut crc: u32 = 0xFFFF_FFFF;
        for &b in bytes {
            crc ^= b as u32;
            for _ in 0..8 {
                let mask = (crc & 1).wrapping_neg();
                crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
            }
        }
        !crc
    }

    /// Builds a byte-tiny but structurally-valid PNG whose IHDR declares
    /// `w`x`h` RGB pixels. The image decoder reads these dimensions from the
    /// header and would allocate `w*h*3` bytes for the raw buffer — this is the
    /// classic "pixel flood": a few dozen bytes of input demanding gigabytes.
    fn png_with_declared_dimensions(w: u32, h: u32) -> Vec<u8> {
        let mut out = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
        let mut ihdr = Vec::new();
        ihdr.extend_from_slice(b"IHDR");
        ihdr.extend_from_slice(&w.to_be_bytes());
        ihdr.extend_from_slice(&h.to_be_bytes());
        ihdr.extend_from_slice(&[8, 2, 0, 0, 0]); // 8-bit, color type 2 (RGB)
        out.extend_from_slice(&13u32.to_be_bytes()); // IHDR data length
        out.extend_from_slice(&ihdr);
        out.extend_from_slice(&crc32(&ihdr).to_be_bytes());
        // A single empty IDAT + IEND so the stream is well-formed up to the point
        // the size check fires (it fires before any IDAT is read).
        out.extend_from_slice(&0u32.to_be_bytes());
        out.extend_from_slice(b"IDAT");
        out.extend_from_slice(&crc32(b"IDAT").to_be_bytes());
        out.extend_from_slice(&0u32.to_be_bytes());
        out.extend_from_slice(b"IEND");
        out.extend_from_slice(&crc32(b"IEND").to_be_bytes());
        out
    }

    #[test]
    fn decode_rejects_pixel_flood_instead_of_ooming() {
        // ~46000 x 46000 x 3 = ~6.3 GB demanded from ~50 bytes of input. With the
        // bounded decoder this returns Err; unbounded, it would try to allocate
        // gigabytes (OOM) before `preprocess` ever ran.
        let bomb = png_with_declared_dimensions(46_000, 46_000);
        assert!(bomb.len() < 128, "the bomb file itself is tiny");
        let err = decode_image_bounded(&bomb).expect_err("pixel flood must be rejected");
        // "Memory limit exceeded" / "Image size exceeds limit" — proves the IHDR
        // parsed and the *size* guard fired (not a CRC/format rejection).
        let msg = format!("{err:#}");
        assert!(
            msg.contains("limit"),
            "expected a decode-limit error, got: {msg}"
        );
    }

    #[test]
    fn decode_accepts_normal_image() {
        // A small, real image decodes identically to before (behavior preserved).
        let img = DynamicImage::ImageLuma8(GrayImage::from_pixel(64, 48, Luma([200])));
        let mut png = std::io::Cursor::new(Vec::new());
        img.write_to(&mut png, image::ImageFormat::Png)
            .expect("encode png");
        let decoded = decode_image_bounded(png.get_ref()).expect("normal image decodes");
        assert_eq!(decoded.dimensions(), (64, 48));
    }

    #[test]
    fn mean_confidence_of_empty_is_zero() {
        assert_eq!(mean_confidence(&[]), 0.0);
    }

    #[test]
    fn mean_confidence_averages_values() {
        assert_eq!(
            mean_confidence(&[0.8, 0.6, 1.0]),
            (0.8 + 0.6 + 1.0f32) / 3.0
        );
    }

    /// Builds a synthetic "document" image: a white background with evenly
    /// spaced horizontal black bars (standing in for text lines), plus a
    /// left-to-right lighting gradient (standing in for an uneven-shadow
    /// phone photo).
    fn synthetic_document(w: u32, h: u32) -> GrayImage {
        GrayImage::from_fn(w, h, |x, y| {
            let is_bar = (y % 12) < 3;
            let base: f32 = if is_bar { 40.0 } else { 235.0 };
            // Shadow gradient: darker on the left, brighter on the right.
            let shadow = 0.55 + 0.45 * (x as f32 / w.max(1) as f32);
            Luma([(base * shadow).clamp(0.0, 255.0) as u8])
        })
    }

    #[test]
    fn preprocess_handles_tiny_image_without_panicking() {
        let img = DynamicImage::ImageLuma8(GrayImage::from_pixel(4, 4, Luma([128])));
        let out = preprocess(img.clone());
        // Below the size floor: passed through unchanged.
        assert_eq!(out.dimensions(), img.dimensions());
    }

    #[test]
    fn preprocess_of_synthetic_photo_is_same_size_and_finite() {
        let doc = synthetic_document(160, 120);
        let img = DynamicImage::ImageLuma8(doc);
        let out = preprocess(img.clone());
        assert_eq!(out.dimensions(), img.dimensions());
        // Every output pixel is a valid, non-degenerate u8 (implicitly true
        // for GrayImage) -- just make sure we actually got real content out,
        // not an all-zero or all-saturated image.
        let gray = out.to_luma8();
        let (mut lo, mut hi) = (255u8, 0u8);
        for p in gray.pixels() {
            lo = lo.min(p.0[0]);
            hi = hi.max(p.0[0]);
        }
        assert!(hi > lo, "expected some contrast in preprocessed output");
    }

    #[test]
    fn preprocess_on_uniform_image_does_not_panic() {
        // A blank/solid-color "page": no text, no gradient. Should pass
        // through the pipeline safely (contrast stretch is a no-op here).
        let img = DynamicImage::ImageLuma8(GrayImage::from_pixel(200, 150, Luma([255])));
        let out = preprocess(img.clone());
        assert_eq!(out.dimensions(), img.dimensions());
    }

    #[test]
    fn flatten_illumination_reduces_shadow_gradient() {
        let doc = synthetic_document(160, 120);
        let flattened = flatten_illumination(&doc);
        // Compare mean brightness of the "background" (non-bar) rows on the
        // dark (left) side vs the bright (right) side before and after.
        let side_means = |img: &GrayImage| -> (f64, f64) {
            let (w, h) = img.dimensions();
            let mut left = (0u64, 0u64);
            let mut right = (0u64, 0u64);
            for y in 0..h {
                if (y % 12) < 3 {
                    continue; // skip bar rows, only look at background
                }
                for x in 0..w {
                    let v = img.get_pixel(x, y).0[0] as u64;
                    if x < w / 2 {
                        left.0 += v;
                        left.1 += 1;
                    } else {
                        right.0 += v;
                        right.1 += 1;
                    }
                }
            }
            (
                left.0 as f64 / left.1.max(1) as f64,
                right.0 as f64 / right.1.max(1) as f64,
            )
        };
        let (before_left, before_right) = side_means(&doc);
        let (after_left, after_right) = side_means(&flattened);
        let before_gap = (before_right - before_left).abs();
        let after_gap = (after_right - after_left).abs();
        assert!(
            after_gap < before_gap,
            "expected shadow gradient to shrink: before={before_gap}, after={after_gap}"
        );
    }

    #[test]
    fn stretch_contrast_expands_narrow_range_to_full() {
        // A low-contrast image using only the middle of the range.
        let img = GrayImage::from_fn(50, 50, |x, _y| Luma([if x < 25 { 100u8 } else { 140u8 }]));
        let out = stretch_contrast(&img);
        let (mut lo, mut hi) = (255u8, 0u8);
        for p in out.pixels() {
            lo = lo.min(p.0[0]);
            hi = hi.max(p.0[0]);
        }
        assert_eq!(lo, 0);
        assert_eq!(hi, 255);
    }

    #[test]
    fn stretch_contrast_is_noop_on_flat_image() {
        let img = GrayImage::from_pixel(30, 30, Luma([77]));
        let out = stretch_contrast(&img);
        assert!(out.pixels().all(|p| p.0[0] == 77));
    }

    #[test]
    fn estimate_skew_deg_none_on_tiny_image() {
        let img = GrayImage::from_pixel(8, 8, Luma([255]));
        assert_eq!(estimate_skew_deg(&img), None);
    }

    #[test]
    fn deskew_of_rotated_synthetic_recovers_near_zero_residual_skew() {
        let doc = synthetic_document(240, 180);
        let skew_deg = 5.0f32;
        let skewed = rotate_about_center(
            &doc,
            skew_deg.to_radians(),
            Interpolation::Bilinear,
            Border::Constant(Luma([255])),
        );

        let estimated = estimate_skew_deg(&skewed).expect("should find a skew estimate");
        assert!(estimated.is_finite());

        let corrected = deskew(&skewed, estimated);
        assert_eq!(corrected.dimensions(), skewed.dimensions());

        // Residual skew after correction should be small: re-estimating on
        // the corrected image should find an angle close to 0.
        let residual = estimate_skew_deg(&corrected).unwrap_or(0.0);
        assert!(
            residual.abs() <= 1.5,
            "expected small residual skew after deskew, got {residual} (estimated correction was {estimated})"
        );
    }

    #[test]
    fn estimate_skew_deg_on_unskewed_image_is_near_zero() {
        let doc = synthetic_document(240, 180);
        let angle = estimate_skew_deg(&doc).unwrap_or(0.0);
        assert!(
            angle.abs() <= 1.0,
            "expected near-zero skew estimate for unrotated image, got {angle}"
        );
    }

    #[test]
    fn ocr_page_images_caps_expensive_work_and_reports_skips() {
        // More images than the cap: the recognizer (the expensive part) must run
        // at most MAX_OCR_PAGE_IMAGES times, and the remainder must be reported
        // as skipped -- not silently dropped.
        let extra = 7;
        let total = MAX_OCR_PAGE_IMAGES + extra;
        let images: Vec<Vec<u8>> = (0..total).map(|i| vec![i as u8]).collect();
        let mut calls = 0usize;
        let (texts, confs, skipped) = ocr_page_images(images, |_bytes| {
            calls += 1;
            Ok(OcrOutcome {
                text: "line".to_string(),
                confidence: 1.0,
                backend: OcrBackend::Onnx,
            })
        });
        assert_eq!(
            calls, MAX_OCR_PAGE_IMAGES,
            "OCR must run on at most the cap-many images"
        );
        assert_eq!(texts.len(), MAX_OCR_PAGE_IMAGES);
        assert_eq!(confs.len(), MAX_OCR_PAGE_IMAGES);
        assert_eq!(
            skipped, extra,
            "images beyond the cap must be reported as skipped"
        );
    }

    #[test]
    fn ocr_page_images_under_cap_processes_all_with_no_skips() {
        // A normal document (few images) is unaffected: everything is OCR'd and
        // nothing is reported as skipped.
        let images: Vec<Vec<u8>> = (0..3).map(|_| vec![0u8]).collect();
        let mut calls = 0usize;
        let (texts, _confs, skipped) = ocr_page_images(images, |_bytes| {
            calls += 1;
            Ok(OcrOutcome {
                text: "ok".to_string(),
                confidence: 0.5,
                backend: OcrBackend::Onnx,
            })
        });
        assert_eq!(calls, 3);
        assert_eq!(texts.len(), 3);
        assert_eq!(skipped, 0);
    }

    /// The mixed-PDF bug, reproduced without a real PDF or OCR engine: a
    /// text-rich page 1 (e.g. a printed report header) must not stop a later
    /// image-only page from being OCR'd. Before `build_mixed_pages` existed,
    /// `pipeline::ingest` checked `MIN_TEXT_LAYER_LEN` against the
    /// *concatenation* of all pages -- page 1 alone cleared it, so page 2's
    /// image was never even looked at.
    #[test]
    fn build_mixed_pages_ocrs_image_only_pages_even_after_a_text_rich_page() {
        let page_texts = vec![
            "本页为出院小结正文,内容足够长,超过最小文本层阈值。".to_string(),
            String::new(), // scanned page: pdf-extract finds nothing
        ];
        let page_images = vec![
            vec![],             // page 1: no embedded image, doesn't matter
            vec![vec![0xFFu8]], // page 2: one (fake) DCTDecode image
        ];
        let mut calls = 0usize;
        let pages = build_mixed_pages(page_texts, page_images, |_bytes| {
            calls += 1;
            Ok(OcrOutcome {
                text: "化验结果:肌酐 120".to_string(),
                confidence: 0.9,
                backend: OcrBackend::Onnx,
            })
        });
        assert_eq!(calls, 1, "only the image-only page should trigger OCR");
        assert_eq!(pages.len(), 2);
        assert!(matches!(pages[0].result, PdfPageText::TextLayer(_)));
        assert_eq!(pages[0].page_no, 1);
        match &pages[1].result {
            PdfPageText::Ocr { text, .. } => assert!(text.contains("肌酐")),
            other => panic!("expected page 2 to be OCR'd, got {other:?}"),
        }
        assert_eq!(pages[1].page_no, 2);

        let outcome = MixedPdfOutcome { pages };
        assert_eq!(
            outcome.page_count(),
            2,
            "page count must reflect both pages"
        );
        assert!(outcome.unrecognized_pages().is_empty());
        assert!(
            outcome.text().contains("肌酐"),
            "OCR'd page text must make it into the document"
        );
    }

    /// A page with no text layer AND no OCR-able image (blank scan artifact,
    /// or an image encoding `extract_dct_images` doesn't handle) must come
    /// back `Unrecognized` -- not silently absent from the page list, and not
    /// papered over as if it were successfully processed. This is the crux of
    /// the "no silent data loss" requirement: we may not always be able to
    /// recover a page's content, but we must always be able to say so.
    #[test]
    fn build_mixed_pages_reports_unrecognized_when_nothing_to_ocr() {
        let page_texts = vec![
            "够长的第一页文本内容超过阈值二十个字符没问题".to_string(),
            String::new(),
        ];
        let page_images = vec![vec![], vec![]]; // neither page has an image
        let pages = build_mixed_pages(page_texts, page_images, |_bytes| {
            panic!("recognize_one should never be called: page 2 has no image")
        });
        assert_eq!(pages.len(), 2);
        assert_eq!(pages[1].result, PdfPageText::Unrecognized);

        let outcome = MixedPdfOutcome { pages };
        assert_eq!(outcome.unrecognized_pages(), vec![2]);
        assert!(
            !outcome.text().contains("Unrecognized"),
            "unrecognized pages must contribute no fabricated text"
        );
    }

    /// The per-document OCR budget (same DoS bound as `ocr_page_images`, now
    /// counted per page) must still cap expensive work on a document with
    /// many image-only pages, and every page past the cap must come back
    /// `Unrecognized` -- "capped" is a form of "not processed" and must be
    /// just as visible as any other reason a page didn't get text.
    #[test]
    fn build_mixed_pages_caps_ocr_work_and_marks_the_rest_unrecognized() {
        let extra = 3;
        let total = MAX_OCR_PAGE_IMAGES + extra;
        let page_texts = vec![String::new(); total];
        let page_images = vec![vec![vec![0u8]]; total];
        let mut calls = 0usize;
        let pages = build_mixed_pages(page_texts, page_images, |_bytes| {
            calls += 1;
            Ok(OcrOutcome {
                text: "text".to_string(),
                confidence: 1.0,
                backend: OcrBackend::Onnx,
            })
        });
        assert_eq!(
            calls, MAX_OCR_PAGE_IMAGES,
            "OCR must run on at most the cap-many pages"
        );
        let outcome = MixedPdfOutcome { pages };
        assert_eq!(
            outcome.unrecognized_pages().len(),
            extra,
            "pages past the cap must be reported, not silently dropped"
        );
    }

    /// End-to-end wiring check with a real (hand-built) PDF: page 1 has an
    /// actual Helvetica text layer, page 2 is blank (no content stream, no
    /// image) -- confirms `lopdf`'s page order and `pdf-extract`'s per-page
    /// order line up 1:1 on a real document, and that a page with truly
    /// nothing recoverable comes back `Unrecognized` rather than panicking or
    /// silently vanishing from the page list. Doesn't touch the OCR engine
    /// (page 2 has no image, so `recognize` is never invoked), so this test
    /// behaves the same with or without the `engine` feature.
    #[test]
    fn recognize_pdf_mixed_reads_real_two_page_pdf_in_order() {
        use lopdf::content::{Content, Operation};
        use lopdf::{dictionary, Stream};

        let mut doc = Document::with_version("1.5");
        let pages_id = doc.new_object_id();

        let font_id = doc.add_object(dictionary! {
            "Type" => "Font",
            "Subtype" => "Type1",
            "BaseFont" => "Helvetica",
        });
        let resources_id = doc.add_object(dictionary! {
            "Font" => dictionary! { "F1" => font_id },
        });
        let content = Content {
            operations: vec![
                Operation::new("BT", vec![]),
                Operation::new("Tf", vec!["F1".into(), 12.into()]),
                Operation::new("Td", vec![20.into(), 700.into()]),
                Operation::new(
                    "Tj",
                    vec![Object::string_literal(
                        "Discharge summary page one printed text",
                    )],
                ),
                Operation::new("ET", vec![]),
            ],
        };
        let content_id = doc.add_object(Stream::new(
            dictionary! {},
            content.encode().expect("encode content stream"),
        ));
        let page1_id = doc.add_object(dictionary! {
            "Type" => "Page",
            "Parent" => pages_id,
            "Contents" => content_id,
            "Resources" => resources_id,
        });
        // Page 2: blank -- no Contents, no image. Nothing recoverable.
        let page2_id = doc.add_object(dictionary! {
            "Type" => "Page",
            "Parent" => pages_id,
        });

        doc.objects.insert(
            pages_id,
            Object::Dictionary(dictionary! {
                "Type" => "Pages",
                "Kids" => vec![page1_id.into(), page2_id.into()],
                "Count" => 2,
                "MediaBox" => vec![0.into(), 0.into(), 612.into(), 792.into()],
            }),
        );
        let catalog_id = doc.add_object(dictionary! {
            "Type" => "Catalog",
            "Pages" => pages_id,
        });
        doc.trailer.set("Root", catalog_id);

        let mut bytes = Vec::new();
        doc.save_to(&mut bytes).expect("save PDF");

        let outcome =
            recognize_pdf_mixed(&bytes).expect("recognize_pdf_mixed should parse this PDF");
        assert_eq!(outcome.page_count(), 2);
        match &outcome.pages[0].result {
            PdfPageText::TextLayer(t) => {
                assert!(
                    t.contains("Discharge summary"),
                    "unexpected page 1 text: {t}"
                )
            }
            other => panic!("expected page 1 text layer, got {other:?}"),
        }
        assert_eq!(outcome.pages[0].page_no, 1);
        assert_eq!(outcome.pages[1].result, PdfPageText::Unrecognized);
        assert_eq!(outcome.pages[1].page_no, 2);
        assert_eq!(outcome.unrecognized_pages(), vec![2]);
    }

    #[test]
    fn downscale_shrinks_oversized_image_preserving_aspect() {
        // An 8000x4000 image (legal under the 20000px decode cap) is brought
        // under the working limit before the amplifying f32 passes run.
        let img = DynamicImage::ImageLuma8(GrayImage::from_pixel(8000, 4000, Luma([128])));
        let out = downscale_to_working_dim(img);
        let (w, h) = out.dimensions();
        assert!(
            w <= OCR_MAX_WORKING_DIM && h <= OCR_MAX_WORKING_DIM,
            "expected both dims <= {OCR_MAX_WORKING_DIM}, got {w}x{h}"
        );
        assert_eq!(w, OCR_MAX_WORKING_DIM, "longest axis should hit the limit");
        // 2:1 aspect ratio preserved.
        assert!(
            (w as f32 / h as f32 - 2.0).abs() < 0.05,
            "aspect ratio should be preserved, got {w}x{h}"
        );
    }

    #[test]
    fn downscale_leaves_normal_scan_untouched() {
        // A typical A4 scan at 300dpi (~2480x3508) is under the limit and must
        // be returned with identical dimensions (behavior preserved).
        let img = DynamicImage::ImageLuma8(GrayImage::from_pixel(2480, 3508, Luma([128])));
        let out = downscale_to_working_dim(img);
        assert_eq!(out.dimensions(), (2480, 3508));
    }

    #[test]
    fn preprocess_downscales_oversized_input_below_working_dim() {
        // End-to-end through preprocess: an oversized input comes out bounded to
        // the working dimension (so the f32 buffers never see full resolution).
        let big = DynamicImage::ImageLuma8(GrayImage::from_pixel(
            OCR_MAX_WORKING_DIM + 2000,
            120,
            Luma([200]),
        ));
        let out = preprocess(big);
        let (w, h) = out.dimensions();
        assert!(
            w <= OCR_MAX_WORKING_DIM && h <= OCR_MAX_WORKING_DIM,
            "preprocess output should be bounded, got {w}x{h}"
        );
    }

    /// Requires network access to ModelScope on first run (models are cached
    /// afterward in $OAR_HOME). Run explicitly with:
    ///   cargo test -p ocr -- --ignored
    #[test]
    #[ignore]
    fn recognizes_cjk_test_image() {
        let bytes = std::fs::read("/tmp/ocr_test.png")
            .expect("generate /tmp/ocr_test.png first (see feat-ocr-report.md)");
        let outcome = recognize(&bytes).expect("OCR should succeed");
        assert!(
            outcome.text.contains("Creatinine") || outcome.text.contains("肌酐"),
            "unexpected OCR text: {}",
            outcome.text
        );
        assert!(
            outcome.confidence > 0.0,
            "expected non-zero confidence, got {}",
            outcome.confidence
        );
    }

    /// Requires network access to ModelScope on first run (models are cached
    /// afterward in $OAR_HOME). Run explicitly with:
    ///   cargo test -p ocr -- --ignored
    #[test]
    #[ignore]
    fn recognizes_scanned_image_pdf() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../examples/demo-dataset/photos/2026-03-15_检验报告_扫描图PDF.pdf"
        );
        let bytes = std::fs::read(path).expect("demo scanned PDF present");
        let outcome = recognize_pdf(&bytes).expect("recognize_pdf should succeed");
        assert!(
            outcome.text.contains("肌酐") || outcome.text.contains("Creatinine"),
            "unexpected OCR text: {}",
            outcome.text
        );
        assert!(
            outcome.text.contains("2026-03-15"),
            "expected date in OCR text: {}",
            outcome.text
        );
        assert!(
            outcome.confidence > 0.0,
            "expected non-zero confidence, got {}",
            outcome.confidence
        );
    }

    fn ll(text: &str, left: f32, top: f32, right: f32, height: f32) -> LayoutLine {
        LayoutLine {
            text: text.to_string(),
            left,
            top,
            right,
            height,
        }
    }

    #[test]
    fn rebuild_layout_text_of_empty_is_empty() {
        assert_eq!(rebuild_layout_text(&[]), "");
    }

    #[test]
    fn rebuild_layout_text_single_line_per_row_passes_through() {
        // Prose: one detection box per visual row -> lines emitted unchanged,
        // in top-to-bottom order, no padding introduced.
        let lines = vec![
            ll("第二行", 10.0, 40.0, 100.0, 20.0),
            ll("第一行", 10.0, 10.0, 100.0, 20.0),
        ];
        assert_eq!(rebuild_layout_text(&lines), "第一行\n第二行");
    }

    #[test]
    fn rebuild_layout_text_aligns_multi_box_row_into_columns() {
        // A lab-report row split into 3 detections at increasing x — must be
        // joined into one line with >=2 spaces between fields (splitCells rule).
        let lines = vec![
            ll("肌酐", 0.0, 100.0, 40.0, 20.0),
            ll("88", 200.0, 102.0, 230.0, 20.0),
            ll("umol/L", 400.0, 101.0, 480.0, 20.0),
        ];
        let out = rebuild_layout_text(&lines);
        assert_eq!(out.lines().count(), 1, "one visual row -> one output line");
        assert!(out.starts_with("肌酐"));
        // Every field after the first must be separated by >=2 spaces.
        for part in ["88", "umol/L"] {
            let idx = out.find(part).expect("field present");
            let gap = out[..idx].chars().rev().take_while(|c| *c == ' ').count();
            assert!(
                gap >= 2,
                "expected >=2 space gap before {part:?}, got {gap} in {out:?}"
            );
        }
    }

    #[test]
    fn normalize_ocr_decimal_comma_rewrites_digit_flanked_comma() {
        // The reproduction this exists for: PP-OCRv5 misreading the decimal
        // point in "3.50~10.00" as a comma on a compressed real photo. Left
        // alone, the extractor parses "3,50~10.00" as low=50, high=10 --
        // `low > high`, a malformed range reported with full confidence.
        assert_eq!(
            normalize_ocr_decimal_comma("10嗜酸性粒细胞百分4.40  +  3,50~10.00 %"),
            "10嗜酸性粒细胞百分4.40  +  3.50~10.00 %"
        );
    }

    #[test]
    fn normalize_ocr_decimal_comma_leaves_non_digit_flanked_commas_alone() {
        // Only a comma with an ASCII digit on *both* sides is a plausible
        // misread decimal point. Prose punctuation (including the full-width
        // CJK comma) and a comma next to whitespace must pass through as-is.
        for text in ["项目, 结果", "备注：正常，无需复查", "12, 34", "12 ,34"] {
            assert_eq!(normalize_ocr_decimal_comma(text), text);
        }
    }

    #[test]
    fn rebuild_layout_text_fixes_decimal_comma_before_extraction() {
        // End-to-end through `rebuild_layout_text`: a single mis-OCR'd box
        // must come out with its decimal point restored, not just the
        // isolated helper.
        let lines = vec![ll("3,50~10.00", 0.0, 0.0, 100.0, 20.0)];
        assert_eq!(rebuild_layout_text(&lines), "3.50~10.00");
    }

    #[test]
    fn rebuild_layout_text_inserts_blank_line_at_large_vertical_gap() {
        // Second row's top is far below the first row's line height -> treated
        // as a block/table boundary, blank line inserted between them.
        let lines = vec![
            ll("段落一", 0.0, 0.0, 100.0, 20.0),
            ll("段落二", 0.0, 200.0, 100.0, 20.0),
        ];
        let out = rebuild_layout_text(&lines);
        assert_eq!(out, "段落一\n\n段落二");
    }

    #[test]
    fn rebuild_layout_text_groups_close_y_into_same_row() {
        // Two boxes with nearly identical `top` (within tolerance) count as
        // the same visual row even though they were pushed in arbitrary order.
        let lines = vec![
            ll("B", 300.0, 12.0, 340.0, 20.0),
            ll("A", 0.0, 10.0, 40.0, 20.0),
        ];
        let out = rebuild_layout_text(&lines);
        assert_eq!(
            out.lines().count(),
            1,
            "close-y boxes must merge into one row"
        );
    }

    /// Builds one synthetic dual-table row: a left record (serial + value at
    /// fixed x) and, past a wide fixed gutter, a right record (serial +
    /// value at fixed x) -- the same shape as a lab report that splits its
    /// item list into a left half and a right half to save vertical space
    /// (see the real 22-item repro this was written against, #ocr build 46).
    fn dual_row(
        top: f32,
        serial_l: &str,
        val_l: &str,
        serial_r: &str,
        val_r: &str,
    ) -> Vec<LayoutLine> {
        vec![
            ll(serial_l, 0.0, top, 20.0, 20.0),
            ll(val_l, 100.0, top, 160.0, 20.0),
            // Gutter: a wide, fixed (160 -> 400) gap present on every row --
            // clearly wider than either side's own internal serial->value
            // gap (80px), so it wins cluster selection on width.
            ll(serial_r, 400.0, top, 420.0, 20.0),
            ll(val_r, 500.0, top, 560.0, 20.0),
        ]
    }

    #[test]
    fn rebuild_layout_text_splits_dual_column_table_rows() {
        // 5 rows sharing the same left/right column anchors -- enough
        // support (>= DUAL_COLUMN_MIN_SUPPORT_ROWS) for the recurring
        // 160->400 gutter to be recognized, so each row's left and right
        // records land on their own line instead of one flattened line
        // carrying both (the bug: parser::extract_labs only sees "one
        // record per line", so the right half was silently dropped).
        let mut lines = Vec::new();
        for i in 0..5 {
            let top = i as f32 * 25.0;
            lines.extend(dual_row(
                top,
                &format!("{i}L"),
                &format!("valL{i}"),
                &format!("{i}R"),
                &format!("valR{i}"),
            ));
        }
        let out = rebuild_layout_text(&lines);
        let out_lines: Vec<&str> = out.lines().collect();
        assert_eq!(
            out_lines.len(),
            10,
            "5 dual-record rows must become 10 single-record lines, got: {out:?}"
        );
        for (i, line) in out_lines.iter().enumerate() {
            if i % 2 == 0 {
                let row = i / 2;
                assert!(line.contains(&format!("{row}L")) && line.contains(&format!("valL{row}")));
                assert!(
                    !line.contains(&format!("{row}R")),
                    "left half must not carry the right record's fields: {line:?}"
                );
            } else {
                let row = i / 2;
                assert!(line.contains(&format!("{row}R")) && line.contains(&format!("valR{row}")));
                assert!(
                    !line.contains(&format!("valL{row}")),
                    "right half must not carry the left record's fields: {line:?}"
                );
            }
        }
    }

    #[test]
    fn rebuild_layout_text_dual_column_leaves_single_column_page_untouched() {
        // Only 2 rows share the coincidental left/right gap -- below
        // DUAL_COLUMN_MIN_SUPPORT_ROWS (4), same as e.g. a demographics
        // line ("科室：肺病科    床号：16") landing near the real gutter's x
        // by chance on an otherwise single-column page. Must NOT be treated
        // as a dual-table page: every row stays a single flattened line,
        // byte-for-byte the same as `rebuild_layout_text` produced before
        // dual-column detection existed.
        let mut lines = Vec::new();
        lines.extend(dual_row(0.0, "0L", "valL0", "0R", "valR0"));
        lines.extend(dual_row(25.0, "1L", "valL1", "1R", "valR1"));
        // Plain single-box prose rows right after, as on a real page (kept
        // close enough vertically to stay in the same block -- no blank
        // line from the unrelated large-vertical-gap rule).
        lines.push(ll("这是一段普通正文", 0.0, 50.0, 300.0, 20.0));
        lines.push(ll("第二段正文内容", 0.0, 75.0, 300.0, 20.0));

        let out = rebuild_layout_text(&lines);
        let out_lines: Vec<&str> = out.lines().collect();
        // 2 rows (still joined, not split) + 2 prose lines = 4 lines total.
        assert_eq!(
            out_lines.len(),
            4,
            "below the support floor, rows must stay unsplit: {out:?}"
        );
        assert!(out_lines[0].contains("0L") && out_lines[0].contains("0R"));
        assert!(out_lines[1].contains("1L") && out_lines[1].contains("1R"));
    }

    #[test]
    fn rebuild_layout_text_dual_column_does_not_split_full_width_row() {
        // A genuine dual-table page (5 rows, same shape as the "splits"
        // test above) also contains one full-width row -- a title/banner
        // whose single wide box happens to straddle the detected gutter's
        // x-range, the same shape as "涟水县中医院检验报告单" spanning across
        // where the lab table's gutter sits a few rows below. It must be
        // emitted unchanged: no gap in that row contains the gutter's
        // midpoint (a box covers that whole span), so there's nothing to
        // split on -- title/header/footer rows survive verbatim.
        let mut lines = Vec::new();
        lines.extend(dual_row(0.0, "0L", "valL0", "0R", "valR0"));
        lines.extend(dual_row(25.0, "1L", "valL1", "1R", "valR1"));
        lines.extend(dual_row(50.0, "2L", "valL2", "2R", "valR2"));
        lines.extend(dual_row(75.0, "3L", "valL3", "3R", "valR3"));
        // Banner row: 4 boxes (same box count as a data row) but the 2nd
        // box straddles the gutter (160..400) instead of leaving it free.
        lines.push(ll("边A", 0.0, 100.0, 30.0, 20.0));
        lines.push(ll("标题横跨整行", 50.0, 100.0, 450.0, 20.0));
        lines.push(ll("边C", 470.0, 100.0, 510.0, 20.0));
        lines.push(ll("边D", 520.0, 100.0, 560.0, 20.0));

        let out = rebuild_layout_text(&lines);
        let out_lines: Vec<&str> = out.lines().collect();
        // 4 dual-record rows -> 8 lines, + the banner row unsplit -> 1 line.
        assert_eq!(
            out_lines.len(),
            9,
            "banner row must stay a single unsplit line: {out:?}"
        );
        let banner_line = out_lines
            .iter()
            .find(|l| l.contains("标题横跨整行"))
            .expect("banner text present");
        assert!(
            banner_line.contains("边A")
                && banner_line.contains("边C")
                && banner_line.contains("边D")
        );
    }

    #[test]
    fn estimate_tilt_recovers_known_page_rotation() {
        // Lay a level page out, then rotate it: every box's top gains
        // `slope * x_centre`. The projection profile is sharpest at exactly
        // that slope, so the estimate must find it back.
        let slope = 0.10_f32;
        let mut owned = Vec::new();
        for row in 0..10 {
            for col in 0..5 {
                let left = col as f32 * 200.0;
                let right = left + 150.0;
                let x_centre = (left + right) / 2.0;
                let top = row as f32 * 40.0 + slope * x_centre;
                owned.push(ll("x", left, top, right, 20.0));
            }
        }
        let refs: Vec<&LayoutLine> = owned.iter().collect();
        let estimated = estimate_tilt(&refs, median_line_height(&refs));
        assert!(
            (estimated - slope).abs() <= 2.0 * TILT_SEARCH_STEP,
            "expected tilt ~{slope}, got {estimated}"
        );

        // ...and a level page must read as level, or every page would be
        // treated as untrustworthy.
        let mut level = Vec::new();
        for row in 0..10 {
            for col in 0..5 {
                let left = col as f32 * 200.0;
                level.push(ll("x", left, row as f32 * 40.0, left + 150.0, 20.0));
            }
        }
        let level_refs: Vec<&LayoutLine> = level.iter().collect();
        let flat = estimate_tilt(&level_refs, median_line_height(&level_refs));
        assert!(
            flat.abs() <= 2.0 * TILT_SEARCH_STEP,
            "level page read as {flat}"
        );
    }

    #[test]
    fn rebuild_layout_text_dual_column_splits_despite_ragged_left_edge() {
        // The bug this rewrite exists for. Every row here is a genuine
        // two-record row, but the left half's right edge moves around by ~70px
        // between rows -- exactly what real lab photos do, because item names
        // differ in length and the recognizer often glues the value onto the
        // name (`5嗜酸性粒细胞计数0.17`). The previous detector demanded the
        // rows' gaps cluster within 2% of the content width *and* that all of
        // them overlap, so a page like this scattered into several clusters
        // whose intersections were empty, and it split nothing at all.
        let names = [
            "1白细胞计数",
            "2中性粒细胞计数",
            "3淋巴细胞计数",
            "4单核细胞计数",
            "5嗜酸性粒细胞计数0.17",
            "6嗜碱性粒细胞计数0.04",
        ];
        let right_names = [
            "14红细胞压积",
            "15红细胞平均体积",
            "16平均血红蛋白",
            "17平均血红蛋白浓度",
            "18红细胞分布宽度",
            "19血小板计数",
        ];
        // Ragged: the left half ends anywhere in 430..=500.
        let left_edges = [430.0, 470.0, 445.0, 455.0, 500.0, 495.0];
        let mut lines = Vec::new();
        for i in 0..6 {
            let top = i as f32 * 40.0;
            let edge: f32 = left_edges[i];
            lines.push(ll(names[i], 40.0, top, edge - 120.0, 24.0));
            lines.push(ll("4.00~10.00", edge - 110.0, top, edge, 24.0));
            // Right half starts at a stable x, as the second table does.
            lines.push(ll(right_names[i], 560.0, top, 700.0, 24.0));
            lines.push(ll("39.2", 720.0, top, 780.0, 24.0));
            lines.push(ll("42.0~49.0", 800.0, top, 920.0, 24.0));
        }

        let out = rebuild_layout_text(&lines);
        for (i, right) in right_names.iter().enumerate() {
            let offender = out
                .lines()
                .find(|l| l.contains(names[i]) && l.contains(right));
            assert!(
                offender.is_none(),
                "left record {:?} and right record {right:?} must not share a line, got {offender:?}",
                names[i]
            );
        }
    }

    #[test]
    fn rebuild_layout_text_dual_column_keeps_single_table_record_whole() {
        // A single-column 4-field table -- name | result | range | unit, every
        // row on the same four x anchors. Geometrically this is *identical* to
        // two side-by-side 2-field tables: a clean, fully-supported whitespace
        // band with two boxes either side, widest in the middle. Only the
        // content says otherwise: each candidate seam's right half would open
        // on a value (`12`), a range (`11.0 - 16.0`) or a unit (`g/dL`), never
        // on an item name, so none of them is a record boundary. Splitting one
        // would tear a record in half and leave the extractor a value with no
        // name -- strictly worse than leaving two records on one line.
        // Regression fixture: the real `GNU_Health_lab_report_sample.png`.
        let rows = [
            ("Hemoglobin", "12", "11.0 - 16.0", "g/dL"),
            ("RBC", "3.3", "3.5-5.50", "10^6/uL"),
            ("HCT", "36", "37.0-50.0", "%"),
            ("MCV", "83", "82-95", "fL"),
            ("MCH", "28", "27-31", "pg"),
            ("WBC", "6.7", "4.5-11", "10^3/uL"),
        ];
        let mut lines = Vec::new();
        for (i, (name, result, range, unit)) in rows.iter().enumerate() {
            let top = i as f32 * 30.0;
            lines.push(ll(name, 0.0, top, 100.0, 20.0));
            lines.push(ll(result, 200.0, top, 230.0, 20.0));
            lines.push(ll(range, 300.0, top, 380.0, 20.0));
            lines.push(ll(unit, 450.0, top, 500.0, 20.0));
        }

        let out = rebuild_layout_text(&lines);
        assert_eq!(
            out.lines().count(),
            rows.len(),
            "single-column table must stay one line per record: {out:?}"
        );
        for (name, result, range, unit) in rows {
            let line = out
                .lines()
                .find(|l| l.contains(name))
                .unwrap_or_else(|| panic!("record {name:?} present in {out:?}"));
            assert!(
                line.contains(result) && line.contains(range) && line.contains(unit),
                "record {name:?} must keep its value, range and unit on one line, got {line:?}"
            );
        }
    }
}
