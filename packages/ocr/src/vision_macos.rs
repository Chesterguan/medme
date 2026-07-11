//! macOS on-device OCR via Apple **Vision** (`VNRecognizeTextRequest`) —
//! offline, no model download, strong Chinese. PRIMARY recognizer on the macOS
//! desktop build; `recognize` falls back to oar-ocr / PP-OCRv5 if Vision yields
//! nothing or errors. Mirrors the proven iOS `OcrVision.swift`, but pure Rust
//! via `objc2` so the desktop crate needs no Swift toolchain / link wiring.

use crate::OcrOutcome;
use anyhow::{anyhow, Context, Result};
use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2::AnyThread;
use objc2_core_foundation::{CFData, CFRetained};
use objc2_core_graphics::{
    CGBitmapInfo, CGColorRenderingIntent, CGColorSpace, CGDataProvider, CGImage, CGImageAlphaInfo,
};
use objc2_foundation::{NSArray, NSDictionary, NSString};
use objc2_vision::{
    VNImageOption, VNImageRequestHandler, VNRecognizeTextRequest, VNRequest,
    VNRequestTextRecognitionLevel,
};

/// Recognize text in already-decoded RGBA8 pixels (tightly packed) via Apple
/// Vision. Returns joined lines + mean observation confidence (0..1).
pub fn recognize_rgba(width: u32, height: u32, rgba: &[u8]) -> Result<OcrOutcome> {
    let cg = make_cgimage(width, height, rgba)?;
    // SAFETY: standard Vision usage — build a text request, run it synchronously
    // on the image, read observations. objc2 ref-counts all objects.
    unsafe {
        let request = VNRecognizeTextRequest::new();
        request.setRecognitionLevel(VNRequestTextRecognitionLevel::Accurate);
        // Simplified + Traditional Chinese + English (labels/units often EN).
        let langs = NSArray::from_retained_slice(&[
            NSString::from_str("zh-Hans"),
            NSString::from_str("zh-Hant"),
            NSString::from_str("en-US"),
        ]);
        request.setRecognitionLanguages(&langs);
        request.setUsesLanguageCorrection(true);

        let options = NSDictionary::<VNImageOption, AnyObject>::new();
        let handler = VNImageRequestHandler::initWithCGImage_options(
            VNImageRequestHandler::alloc(),
            &cg,
            &options,
        );

        // VNRecognizeTextRequest is a subclass of VNRequest; performRequests
        // wants an NSArray<VNRequest>.
        let req: Retained<VNRequest> = Retained::cast_unchecked(request.clone());
        let requests = NSArray::from_retained_slice(&[req]);
        handler
            .performRequests_error(&requests)
            .map_err(|e| anyhow!("Vision performRequests failed: {e:?}"))?;

        let mut lines: Vec<String> = Vec::new();
        let mut conf_sum: f32 = 0.0;
        let mut conf_n: u32 = 0;
        if let Some(results) = request.results() {
            for obs in results.iter() {
                let candidates = obs.topCandidates(1);
                if let Some(text) = candidates.firstObject() {
                    let s = text.string().to_string();
                    if !s.trim().is_empty() {
                        lines.push(s);
                        conf_sum += text.confidence();
                        conf_n += 1;
                    }
                }
            }
        }
        Ok(OcrOutcome {
            text: lines.join("\n"),
            confidence: if conf_n > 0 {
                conf_sum / conf_n as f32
            } else {
                0.0
            },
        })
    }
}

/// Build a CGImage from tightly-packed RGBA8 pixels (bytes_per_row = width*4).
/// CFData copies the bytes, so the borrowed slice need not outlive the call.
fn make_cgimage(width: u32, height: u32, rgba: &[u8]) -> Result<CFRetained<CGImage>> {
    let expected = width as usize * height as usize * 4;
    if rgba.len() < expected {
        return Err(anyhow!(
            "rgba buffer too small: {} < {expected}",
            rgba.len()
        ));
    }
    // SAFETY: CFDataCreate copies `len` bytes from a valid pointer; the rest is
    // CoreGraphics object construction from that buffer.
    unsafe {
        let data = CFData::new(None, rgba.as_ptr(), expected as isize)
            .context("CFDataCreate returned null")?;
        let provider =
            CGDataProvider::with_cf_data(Some(&data)).context("CGDataProvider from CFData")?;
        let space = CGColorSpace::new_device_rgb().context("CGColorSpace device RGB")?;
        // 8 bits/component, 32 bits/pixel, non-premultiplied alpha last (RGBA).
        let bitmap = CGBitmapInfo(CGImageAlphaInfo::Last.0);
        CGImage::new(
            width as usize,
            height as usize,
            8,
            32,
            width as usize * 4,
            Some(&space),
            bitmap,
            Some(&provider),
            std::ptr::null(),
            false,
            CGColorRenderingIntent::RenderingIntentDefault,
        )
        .context("CGImage::new returned null")
    }
}
