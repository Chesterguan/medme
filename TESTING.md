# MedMe 测试指南

面向测试者。两种方式:**装 .dmg(推荐,无需开发环境)** 或 **从源码运行**。

---

## 方式 A:安装 .dmg(推荐)

1. 拿到 `MedMe_x.x.x_aarch64.dmg`(Apple Silicon)或 `_x64.dmg`(Intel),双击打开。
2. 把 **MedMe** 拖进 **Applications**。
3. **首次打开会被 macOS 拦住**(应用未签名,属正常)。两种放行方式任选:
   - 在「访达」里**右键 MedMe → 打开 → 再点“打开”**;或
   - 终端执行:`xattr -cr /Applications/MedMe.app` 后再双击打开。
4. 之后正常双击即可。

> 未签名是因为还没接入 Apple 开发者证书;正式版会签名 + 公证,届时无此步骤。

## 方式 B:从源码运行(开发者)

前置:**Rust**(rustup)、**Node 18+**、**pnpm**、**CMake + C/C++ 工具链**(编译内置的 JPEG2000/JPEG-LS 影像编解码;macOS:`brew install cmake`)。首次构建会编译 OpenJPEG/CharLS,较慢;**装好的 .dmg 无需这些**(编解码已静态打包)。

```bash
git clone https://github.com/Lexuan-Lin/shadow_medical_record-.git
cd shadow_medical_record-
pnpm -C apps/desktop install
pnpm -C apps/desktop tauri dev     # 开发运行(热重载)
# 或打包:pnpm -C apps/desktop tauri build   → 产物在 apps/desktop/src-tauri/target/release/bundle/
```

首次编译较久(Rust 全量构建 + 首次 OCR 会自动下载 ~21MB 模型到 `~/.oar`)。

---

## 首次使用

- 启动后 app 自动创建:
  - 数据保险箱:`~/Library/Application Support/com.medme.app/vault`
  - 自动收件箱:`~/Documents/MedMe收件箱`(往里放文件即自动入库)
- **导入病历**:进「导入 · 导出」页,把 PDF / 图片 / DICOM 拖进去;或存进上面的收件箱。
- **一键试用(推荐给刚装完 .dmg 的测试者)**:时间线为空时会看到「加载示例数据(张建国)」按钮,
  「导入 · 导出」页顶部也有同款卡片。点一下即导入内置的“张建国”示例数据集(检验报告、门诊病历、
  处方、影像检查等),**无需自己找文件、无需 clone 仓库**。示例数据可随时删除保险箱(见「设置」)重来。
- 从源码跑的开发者也可以直接拖 `examples/demo-dataset/` 里的文件体验(和内置示例数据集是同一批素材的完整版)。

## 建议测试的点

- 导入不同格式:PDF、手机照片(JPG/PNG)、扫描件、DICOM(`.dcm`)
- 生命时间线:就诊/住院/转院/手术是否聚合合理;日期是否正确
- 搜索:中文关键词能否搜到(含照片里的文字)
- 文档详情:化验表格、处方用药清单、报告分节;OCR 置信度提示
- **DICOM 阅片**:窗宽窗位 / 缩放 / 关闭是否顺畅
- **导出**:导出 HTML → 浏览器打印/另存 PDF
- **加密分享**:生成加密分享文件 + 口令 → 用浏览器打开、输口令能否看到数据
- 收件箱:往 `~/Documents/MedMe收件箱` 丢张照片,是否自动入库

## 生成演示分享(免安装体验)

想让别人不装 .dmg 也能在浏览器里看一眼效果?

1. 「导入 · 导出」页点「加载示例数据(张建国)」(已装过则跳过)。
2. 「加密分享给医生」卡片:有效期填 **36500**(≈100 年,长期有效,免得过期),
   口令自拟(如 `medme-demo`)→ 点「生成加密分享文件」。
3. 得到一个自包含 HTML 文件 + 口令。把 HTML 发给对方(邮件/网盘/IM 均可),
   口令单独告知。对方**任意浏览器打开该 HTML → 输口令**即可体验完整时间线,无需安装 MedMe。

## 反馈

记录:**做了什么操作 → 期望 → 实际**;能截图最好。发给开发者即可。

> ⚠️ MedMe 是数据整理工具,不提供医疗建议;测试数据请用示例或脱敏文件,勿上传真实敏感病历。
