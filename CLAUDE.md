# MedMe · 给 AI agent 的项目指针

MedMe(医我):**on-device、E2E 加密**的个人病历保险箱。导入照片/PDF → OCR → 分类 → 结构化抽取 → 医生查看器 summary → 加密分享。桌面 Tauri + 移动 Flutter,复用 Rust core。

## Session 开头:先重建上下文(别凭记忆)
1. **读 `docs/ADR/`**(架构决策,Nygard 格式;ADR 不可变,新决策加新号 supersede 旧号)。
2. **读 `docs/log/` 最新几条**(工程日志:讨论/测试数字/发现;精炼+链接)。
3. **按任务 grep `docs/ADR` + `docs/log`** 取相关切片(检索,不全读)。
4. 我的跨会话记忆在 `.claude/projects/*/memory/`(MEMORY.md 索引)。

**技术(设计/架构/测试/决策)→ git(ADR + log);商业/roadmap/产品 → Notion(除非用户关心)。** 公开 build-in-public blog 从 `docs/log/` 提炼(见最新 log)。

## 易忘、易记混的事实(读代码为准)
- **OCR 是各平台原生,不是单一引擎**:桌面 mac=Apple Vision / Win=Windows.Media.Ocr / Linux=PP-OCRv5;移动 iOS=Vision、Android=ML Kit(Dart 层,不走 Rust ocr crate)。见 [ADR 0005](docs/ADR/0005-ocr-per-platform-native.md)。**PP-OCRv5 ≠ 移动端引擎。**
- **抽取当前是正则**(`parser::assemble_summary`,分享时跑);MedGemma 只探索过、**0 集成**(#150/#157)。
- 存储是**事件溯源**(core-model:append_event + materialize + CAS);vault 格式须与桌面逐字节兼容——加事件类型 = 动格式,慎。
- 移动端 build 纪律见 `apps/mobile_flutter/CLAUDE.md`(不日常跑 release/全 ABI)。

## 工作纪律
- 提方案/结论前**先读代码**,别猜、别拿没验证的当事实、别在「好/不好」间摇摆(见 memory `verify-before-asserting`)。
- 性能测试用 `--release`。医疗数据:只输出原文逐字内容,逐字子串校验挡幻觉。

### 三条硬规矩(2026-07-18 会话代价换来的,别再犯)

1. **不许自己发明约束。** 用户没提的限制(体积、性能、兼容性、"手机上会不会慢")**不构成拒绝或缩水的理由**。可以**说出来**供他判断,但不能拿它替他做决定、更不能反复拿它挡事。
   - 触发词自检:说出「但是 / 不过 / 考虑到」后面跟着一个用户没提过的限制 —— 停,改成一句提示,然后**按他说的做**。
   - 那次的真实代价:用户要网页版 demo,我拿"手机加载慢"砍了三轮数据,被连续纠正三次。

2. **先找现成的,别造。** 要数据先翻 `examples/demo-dataset/`、`apps/desktop/src-tauri/demo-data/`(张建国全套真实示例);要结论先翻 `docs/ADR`、`docs/log`、PR body。
   - **凡是"演示/示例"数据,一律走生产代码路径产出**(如 `build_encrypted_share`),不手写 —— 手写的必然和生产结构不一致,而且是编的。

3. **对外产出必须独立核查,不许自审。** blog、公开页、给医生看的东西,一律派独立 subagent 逐条核到 `file:line`。
   - 那次三轮核查抓出 5 条硬错误,**包括我"修正"时新引入的错误**。自己查一定漏。

**不确定就问,别猜着做。** 问一句的成本远低于返工三轮。
