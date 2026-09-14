# Task 19 报告(fix/sim-ux,base f0efabf)

## 逐条结果

1. **解锁转圈**(阻塞项 2):代码读下来 `_asyncButton`/`_kdfWaitHint`/两个出口的
   disabled-not-hidden 写法其实已经对——加了一条回归测试锁死这个契约(转圈时提示语
   在、两个出口按钮仍在只是 disabled)。冒烟报告里"转圈没画出来、出口消失"更像是
   debug 构建下 Argon2(m_kib=65536,2-3 分钟)期间真机/模拟器的渲染节流或 CPU 争用,
   不是 widget 树的逻辑 bug——这块我没法在不碰 Rust 的前提下继续深挖,标记为**遗留
   关注点**,不是本次改的代码。

2. **登录后死路**(友好度 #4):根因确认——`pendingCloudEnable` 只在三处既有触发点
   排空(导入 debounce / 回前台 / 冷启动补齐,`sync_engine.dart`),登录/解锁那一刻
   本身不触发,所以要等到首次导入才自动跑完注册。修法:给 `AccountScreen` 加测试
   注入点 `onReadyCloudSync`(同 `backup_status_line.dart` 的 `retry` 套路),
   `_enterReady()` 里顺手调一次,4 个生产构造点(`main.dart` ×2、
   `settings_screen.dart`、`backup_status_line.dart`)接上真实的
   `sync_engine.runBackgroundSync`。默认 null,不影响任何既有 widget 测试(它们都没
   注入这个参数)。跑完 `setState` 刷新这一屏。

3. **横幅重复**(友好度 #5):横幅原来逐字复用云同步小节的 `_cloudDefaultCopy`。改成
   独立短句「登录后病历会自动加密备份到云端;下面可以按成员关掉。」;小节说明原样
   保留三件事的完整版本。

4. **云抽取空结果无提示**(友好度 #2,UI 侧):**没有改代码,按брief的退路直接停下
   报告**——查过 `DocumentSummaryDto`/`DocumentDetailDto`(FRB dto.dart)以及
   `vault_projections.rs` 内部的 `ProjectionDoc.extraction_json`,后者是私有结构体,
   没有任何字段把"这份文档云端抽取出的 labs/meds/diagnoses 数量"暴露给 Dart。文档
   列表行读到的 `doc_type` 是 OCR/正则解析出来的,和云抽取本身是否落了空结果是两件
   独立的事,没法在现有投影上可靠地区分"没跑过"和"跑了但空"。这确实需要新的投影
   字段 + FRB 重新生成,按 brief 的指示不动 Rust,停在这里报告。

5. **CLAUDE.md 过期行 + Podfile.lock**:已修正第 33 行(方向从 arm64 改成
   x86_64、原因从 ML Kit 改成 PP-OCRv5/ONNX Runtime);`pod install` 产生的
   `Podfile.lock`(新增 flutter_secure_storage、sign_in_with_apple)单独一个 commit。

## 测试

`flutter analyze`:无问题。
`flutter test`(全量,foreground):735 个测试全部通过(新增 5 个:1 条解锁转圈
回归、3 条 `onReadyCloudSync` 触发、2 条横幅独立短句)。

## 遗留关注点(未改代码)

- 阻塞项 2(解锁转圈几分钟无反馈的真实体验)按上面第 1 条,怀疑是 debug 构建下
  Argon2 的 CPU 争用/渲染节流,而非 widget 逻辑;需要真机 release 复测才能下结论,
  这次没有改动能验证的代码路径。
- 友好度 #2(云端整理空结果)需要新投影字段 + FRB regen,按要求没有动 Rust。
