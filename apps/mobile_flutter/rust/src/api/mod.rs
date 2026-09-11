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
// 本模块函数全部 `sync_` 前缀。**这条纪律真正钉住的只有一件事**:`sync_` 在
// 字典序上排在 `recognize_image_pp` 之后,所以它(以及字典序更早的一切)序号
// 不变——这是唯一的硬约束(见 `apps/mobile_flutter/CLAUDE.md`)。它**不能**
// 保证"新增不挪动任何既有函数的序号":序号是按全 crate**函数名**字典序分配
// 的(不是按模块/声明顺序,见上面 `vault_projections` 那条注释),`sync_` 排在
// `view_`(`vault_projections` 的三个函数)前面——新增这一批 `sync_*` 符号后,
// `view_*` 系列的序号确实整体往后挪了。这是可接受的(FRB 序号本来就只需要
// 一次生成内部自洽,不需要跨版本稳定),只是不要在这里重复"最末、不挪号"这个
// 已经被证伪的说法。
pub mod vault_sync;
