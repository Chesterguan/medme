pub mod dto;
pub mod simple;
pub mod vault;
// 命名故意排在 `vault` 之后(字典序 "vault" < "vault_ephemeral"):FRB codegen 按
// api 符号全路径字典序给 wire 函数分配序号,这样新增本模块的函数只会在
// `frb_generated.*` 里追加在最后,不会导致 `vault` 模块里任何现有函数(尤其
// `recognize_image_pp`,iOS PP-OCR 路径)的序号往后挪——`git diff main` 对那部分
// 应为空,见 `apps/mobile_flutter/CLAUDE.md`「绝不能碰 OCR 路径」。
pub mod vault_ephemeral;
