# MedMe · 给 AI agent 的项目指针

MedMe(医我):**on-device、E2E 加密**的个人病历保险箱。导入照片/PDF → OCR → 分类 → 结构化抽取 → 医生查看器 summary → 加密分享。桌面 Tauri + 移动 Flutter,复用 Rust core。

## Session 开头:先重建上下文(别凭记忆)
1. **读 `docs/ADR/`**(架构决策,Nygard 格式;ADR 不可变,新决策加新号 supersede 旧号)。
2. **读 `docs/log/` 最新几条**(工程日志:讨论/测试数字/发现;精炼+链接)。
3. **按任务 grep `docs/ADR` + `docs/log`** 取相关切片(检索,不全读)。
4. 我的跨会话记忆在 `.claude/projects/*/memory/`(MEMORY.md 索引)。

**技术(设计/架构/测试/决策)→ git(ADR + log);商业/roadmap/产品 → Notion(除非用户关心)。** 公开 build-in-public blog 从 `docs/log/` 提炼(见最新 log)。

## 易忘、易记混的事实(读代码为准)
- **OCR 分两套,别混**:
  - **移动端(iOS + Android)统一走 PP-OCRv5** —— 模型编译进二进制,经 FRB `recognize_image_pp`,见 `ocr_bridge.dart:25`。iOS 在喂 PP 之前多一步 Apple Vision 的**画面拉正**(只处理画面、不识别);Android 的「拍照」用系统文档扫描器(GMS 提供)。**ML Kit 中文识别那条回退路径已随依赖删除**(质量不够)。见 [ADR 0006](docs/ADR/0006-ios-ocr-pp-ocrv5.md) 与 [ADR 0007](docs/ADR/0007-android-doc-scan-degms-and-geometry.md)。
  - **桌面**才是各平台原生:mac=Apple Vision / Win=Windows.Media.Ocr / Linux=PP-OCRv5。见 [ADR 0005](docs/ADR/0005-ocr-per-platform-native.md)(其中「移动 iOS=Vision / Android=ML Kit」两行**已被 ADR 0006/0007 supersede**)。
  - ⚠️ 这一条曾长期写错(写成移动端=Vision/ML Kit),并直接导致隐私政策里对外声明了错误的处理技术。**以此处为准,拿不准读 `ocr_bridge.dart`。**
- **抽取当前是正则**(`parser::assemble_summary`,分享时跑);MedGemma 只探索过、**0 集成**(#150/#157)。
- 存储是**事件溯源**(core-model:append_event + materialize + CAS);vault 格式须与桌面逐字节兼容——加事件类型 = 动格式,慎。
- 移动端 build 纪律见 `apps/mobile_flutter/CLAUDE.md`(不日常跑 release/全 ABI)。

## 工作纪律
- 提方案/结论前**先读代码**,别猜、别拿没验证的当事实、别在「好/不好」间摇摆(见 memory `verify-before-asserting`)。
- 性能测试用 `--release`。医疗数据:只输出原文逐字内容,逐字子串校验挡幻觉。

### 四条硬规矩(会话代价换来的,别再犯)

1. **不许自己发明约束。** 用户没提的限制(体积、性能、兼容性、"手机上会不会慢")**不构成拒绝或缩水的理由**。可以**说出来**供他判断,但不能拿它替他做决定、更不能反复拿它挡事。
   - 触发词自检:说出「但是 / 不过 / 考虑到」后面跟着一个用户没提过的限制 —— 停,改成一句提示,然后**按他说的做**。
   - 那次的真实代价:用户要网页版 demo,我拿"手机加载慢"砍了三轮数据,被连续纠正三次。

2. **先找现成的,别造。** 要数据先翻 `examples/demo-dataset/`、`apps/desktop/src-tauri/demo-data/`(张建国全套真实示例);要结论先翻 `docs/ADR`、`docs/log`、PR body。
   - **凡是"演示/示例"数据,一律走生产代码路径产出**(如 `build_encrypted_share`),不手写 —— 手写的必然和生产结构不一致,而且是编的。

3. **对外产出必须独立核查,不许自审。** blog、公开页、给医生看的东西,一律派独立 subagent 逐条核到 `file:line`。
   - 那次三轮核查抓出 5 条硬错误,**包括我"修正"时新引入的错误**。自己查一定漏。

4. **改了「数据往哪走」,必须同步隐私政策。** 只要动到*数据会不会离开手机 / 去哪 / 存多久 / 谁能解密*,就去看一眼 `gh-pages` 分支的 `privacy.html`(worktree 在 `../Medme-ghpages`)。
   - 网站与代码是**两棵没有共同祖先的独立历史**,`main` 里根本没有政策的副本 —— 改代码时看不见它,评审也评审不到,它只会静静地过期。
   - 2026-07-30 的真实代价:代拍从「当场给加密文件」改成「发认领链接上云」,政策里还写着「**这个过程不经过我们的服务器**」;同一份文件里还把 iOS 的定位声明归因于「文字识别依赖库」(实际是相册选图组件)。两条都是对外说了不实的话,直到用户让我核才发现。
   - `gh-pages` 是**推上去即上线**,没有 merge 这一步;改完自己 `curl` 一下线上核实。

**不确定就问,别猜着做。** 问一句的成本远低于返工三轮。
