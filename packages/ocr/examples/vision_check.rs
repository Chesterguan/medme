// 验证 macOS Apple Vision OCR:读一张图 → ocr::recognize → 打印文字 + 置信度。
fn main() {
    let path = std::env::args()
        .nth(1)
        .expect("usage: vision_check <image>");
    let bytes = std::fs::read(&path).expect("read image");
    let t = std::time::Instant::now();
    let out = ocr::recognize(&bytes).expect("recognize");
    eprintln!(
        "[{}ms] confidence={:.3}",
        t.elapsed().as_millis(),
        out.confidence
    );
    println!("{}", out.text);
}
