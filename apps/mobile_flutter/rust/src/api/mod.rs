pub mod dto;
pub mod simple;
pub mod vault;
// 命名故意排在 `vault` 之后(字典序 "vault" < "vault_ephemeral"):FRB codegen 按
// api 符号全路径字典序给 wire 函数分配序号,这样新增本模块的函数只会在
// `frb_generated.*` 里追加在最后,不会导致 `vault` 模块里任何现有函数(尤其
// `recognize_image_pp`,iOS PP-OCR 路径)的序号往后挪——`git diff main` 对那部分
// 应为空,见 `apps/mobile_flutter/CLAUDE.md`「绝不能碰 OCR 路径」。
pub mod vault_ephemeral;
// 同一条纪律,但序号实际是按**函数名**分配的(见 `frb_generated.rs` 里 wire 函数的
// 排列:`…enable_icloud_sync` → `ephemeral_*` → `export_timeline_html`,跨模块混排;
// 上面这条注释靠 `ephemeral_` 这个共同前缀碰巧达到了同样效果)。本模块的三个函数
// 因此统一用 `view_` 前缀——排在现存最末的 `source_file_object_path` 之后,新增只会
// 追加在生成代码末尾,`recognize_image_pp` 的序号纹丝不动。
pub mod vault_projections;
