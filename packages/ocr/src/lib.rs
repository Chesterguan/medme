//! OCR backend for MedMe: recognizes text in image bytes (png/jpg/tiff) via
//! `oar-ocr` (PP-OCRv5, ONNX Runtime). Models are auto-downloaded from
//! ModelScope into `$OAR_HOME` (default `~/.oar`) on first use, SHA-256
//! verified, and cached for subsequent runs.

use anyhow::{Context, Result};
use oar_ocr::oarocr::{OAROCR, OAROCRBuilder};
use oar_ocr::utils::dynamic_to_rgb;
use std::sync::OnceLock;

static PIPELINE: OnceLock<OAROCR> = OnceLock::new();

fn pipeline() -> Result<&'static OAROCR> {
    if let Some(p) = PIPELINE.get() {
        return Ok(p);
    }
    let built = OAROCRBuilder::new(
        "pp-ocrv5_mobile_det.onnx",
        "pp-ocrv5_mobile_rec.onnx",
        "ppocrv5_dict.txt",
    )
    .build()
    .map_err(|e| anyhow::anyhow!("failed to build OAROCR pipeline: {e}"))?;
    Ok(PIPELINE.get_or_init(|| built))
}

/// Recognize text in image bytes (png/jpg/tiff/...). Returns recognized text
/// lines joined with "\n". Lazily builds the OCR pipeline on first call
/// (models auto-download from ModelScope on first ever run on this machine).
pub fn recognize(image_bytes: &[u8]) -> Result<String> {
    let ocr = pipeline()?;
    let dynamic = image::load_from_memory(image_bytes).context("ocr::recognize: decode image")?;
    let image = dynamic_to_rgb(dynamic);
    let results = ocr
        .predict(vec![image])
        .map_err(|e| anyhow::anyhow!("OCR prediction failed: {e}"))?;
    let mut lines = Vec::new();
    if let Some(result) = results.into_iter().next() {
        for region in result.text_regions {
            if let Some(text) = region.text {
                if !text.trim().is_empty() {
                    lines.push(text);
                }
            }
        }
    }
    Ok(lines.join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Requires network access to ModelScope on first run (models are cached
    /// afterward in $OAR_HOME). Run explicitly with:
    ///   cargo test -p ocr -- --ignored
    #[test]
    #[ignore]
    fn recognizes_cjk_test_image() {
        let bytes = std::fs::read("/tmp/ocr_test.png")
            .expect("generate /tmp/ocr_test.png first (see feat-ocr-report.md)");
        let text = recognize(&bytes).expect("OCR should succeed");
        assert!(
            text.contains("Creatinine") || text.contains("肌酐"),
            "unexpected OCR text: {text}"
        );
    }
}
