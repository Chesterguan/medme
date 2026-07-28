// 用手机端那条路径(PP-OCRv5 + 版面重建)跑一张图,复现移动端实际看到的文本。
// 桌面 macOS 默认走 Apple Vision,所以排查移动端问题必须显式走这个入口。
fn main() {
    let path = std::env::args().nth(1).expect("usage: pp_check <image>");
    let bytes = std::fs::read(&path).expect("read image");
    let t = std::time::Instant::now();
    let out = ocr::recognize_engine_layout(&bytes).expect("recognize");
    eprintln!(
        "[{}ms] confidence={:.3}",
        t.elapsed().as_millis(),
        out.confidence
    );
    println!("{}", out.text);
}
