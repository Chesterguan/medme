// 把一段 OCR 文本喂给抽取器,看化验项抽出来几条、值对不对——用于隔离
// 「OCR 认字」与「结构化抽取」两段。
fn main() {
    let path = std::env::args()
        .nth(1)
        .expect("usage: lab_check <text-file>");
    let text = std::fs::read_to_string(&path).expect("read");
    let labs = parser::extract_labs(&text);
    eprintln!("抽出化验项: {} 条", labs.len());
    for l in &labs {
        println!("{:?}", l);
    }
    let d = parser::extract_demographics(&text);
    eprintln!("姓名={:?} 性别={:?} 年龄={:?}", d.name, d.gender, d.age);
}
