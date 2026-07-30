# App Store 提审物料(iOS)

**2026-07-30** · 个人开发者身份提交 · Bundle ID `com.medme.mobile`

App Store Connect 里每一个要填的框,照抄即可。**凡是涉及「我们采什么/存哪」的答案,
都必须与这三处一致**:[`analytics-catalog.md`](./analytics-catalog.md) ·
`ios/Runner/PrivacyInfo.xcprivacy` · <https://medmenow.com/privacy.html>。
改任何一处,回来改这里。

---

## 一、App 信息(App Information)

| 字段 | 填什么 |
|---|---|
| 名称 | `MedMe 医我` |
| 副标题 | `跨院看病的病历助手` |
| 主要语言 | **简体中文** —— App 界面强制中文(`main.dart` 里写死 `zh-CN`),元数据语言必须对上 |
| 类别(主) | **医疗**(Medical) |
| 类别(次) | 效率(Productivity) |
| 隐私政策 URL | `https://medmenow.com/privacy.html` |
| 支持 URL | `https://medmenow.com/about.html` |
| 营销 URL | `https://medmenow.com/` |

## 二、App Store Regulations & Permits

| 项 | 怎么填 |
|---|---|
| **China Mainland ICP Filing Number** | **留空**。它写的是「If you have an ICP Filing Number」,是选填。已验证:同账号另一个 App 未填,175 个区域全部可售 |
| **Regulated Medical Devices** | 声明**否**(不作为受监管医疗器械运行)。与全站口径一致:不是医疗器械、不提供诊断或用药建议 |
| Digital Services Act | 按账号实际信息填(个人开发者需验证联系方式) |
| 韩国 / 越南 | 不适用(非游戏) |

## 三、加密与出口合规(Export Compliance)

⚠️ **这一项是对美国政府的申报,不是 App Store 的小勾选。请自己逐条读问卷再选。**

事实依据(供你判断,不是替你判断):

- App **自己实现了 AES-256-GCM**(`packages/share/src/share.rs`,Rust `aes-gcm` crate),
  用于分享/代拍时端到端加密病历。**不是**只调用 iOS 系统加密,**不是**只走 HTTPS。
- 用途是保护用户自己的医疗数据,不含认证/DRM 以外的其他密码学功能。
- `ios/Runner/Info.plist` 目前写的是 `ITSAppUsesNonExemptEncryption = false`。
  **鉴于上面第一条,这个值可能需要改。** 苹果问卷里有「专为医疗用途设计」一档豁免,
  MedMe 看起来符合,但**措辞以问卷原文为准**。

## 四、App 隐私(App Privacy 营养标签)

问卷按下面答。**每一条都能在 `analytics-catalog.md` 里找到对应行。**

### 「你的 App 收集数据吗?」→ **是**

只有一类:

| 数据类型 | 选 | 说明 |
|---|---|---|
| **使用数据 → 产品交互**(Product Interaction) | ✅ 唯一勾选项 | 「导入了几份、成没成、用了多久」这类计数,全部分桶 |

对这一类的三个追问:

- **用途**:仅 **分析**(Analytics)。不勾「App 功能」「产品个性化」「广告」
- **是否与身份关联**(Linked to You):**否** —— 每次启动 `Posthog().reset()`,没有跨会话持久 ID
- **是否用于追踪**(Tracking):**否** —— 无 IDFA、无 ATT 弹窗、无广告 SDK

### 明确**不勾**的(容易勾错)

联系信息 · 健康与健身 · 财务 · 位置 · 通讯录 · 用户内容 · 搜索历史 · 标识符 · 诊断数据 · 购买项目

⚠️ **「健康与健身」尤其别勾。** 病历确实是健康数据,但**它一个字都不上传** ——
营养标签问的是「你收集什么」,不是「App 处理什么」。全都留在设备上就不算收集。

## 五、年龄分级问卷

照实答。与本 App 相关的只有一项:

- **医疗/治疗信息(Medical or Treatment Information)**:App 会显示用户自己上传的病历内容
  → 按实际选。⚠️ 若选「频繁/强烈」,会触发第二节的 **Regulated Medical Devices** 声明,
  那一项照样声明「否」即可,两者不冲突。

其余(暴力、色情、赌博、酒精药物、恐怖等)全部 **无**。

## 六、审核备注(App Review Information → Notes)

照抄:

```
MedMe(医我)是个人病历的本地整理工具,不是医疗器械,不提供诊断或用药建议。
无需注册、无账号、无需登录,打开即用。

【快速体验(重要)】
App 初始状态是空档案。请走:设置 → 载入示例数据(张建国) → 会灌入 22 份
示例病历(化验单、处方、检查报告),之后可在「健康档案」逐份查看,在
「导出分享」生成二维码或导出可打印时间线。

【第二种模式(容易漏看)】
App 有「医生代拍」模式:设置 → 模式 → 切换到「为病人代拍」。
医生当面征得患者知情同意(含手写签名)后拍摄患者的纸质病历,生成一份
端到端加密文件与口令,当场交给患者本人。该模式的数据不进医生自己的档案,
本机最多保留 12 小时后自动清除。

【数据与隐私】
病历、原件照片、文字识别结果只保存在设备本地,不上传我们的服务器。
文字识别使用随 App 打包的开源模型(PP-OCRv5),在设备本地运行,不需要联网。
无账号体系,因此不适用账号注销流程 —— 卸载 App 即删除本机全部数据。
仅在用户主动生成二维码分享给医生时,会把端到端加密的密文临时上传中转
(15 天后自动删除),解密密钥放在链接 # 之后,从不发送到服务器。

隐私政策:https://medmenow.com/privacy.html
用户协议:https://medmenow.com/terms.html
```

**演示账号**:不需要(无登录)。该字段留空并在备注里说明。

## 七、截图

只需要 **6.9 吋 iPhone**(1320 × 2868),苹果会自动缩放到其他机型。至少 1 张,最多 10 张。
sRGB 的 PNG 或 JPEG,不能带透明通道。

建议这 6 张(按「审核员一眼看懂这是什么」排序):

1. **健康档案**(载入示例后,22 份记录的时间线)
2. **文档详情**(处方解析:诊断 + 用药列表)
3. **导出 · 分享**两张卡
4. **二维码**(「本码含 22 份病历,含原件」)
5. **医生代拍**的知情同意屏(体现「当面征得同意」)
6. **首启告知**四条(体现「不是医生」的免责)

## 八、提交前最后一遍

- [ ] `ios/Runner/PrivacyInfo.xcprivacy` 确实进了包(见下面「怎么验」)
- [ ] 加密声明按第三节自己判断后填/改
- [ ] App Privacy 问卷按第四节填,且与隐私政策对得上
- [ ] 审核备注贴了第六节那段(**尤其是医生模式那两行**)
- [ ] 截图 6.9 吋已上传
- [ ] 构建版本号递增(当前 `1.3.6+48`)

### 怎么验隐私清单真的进了包

```bash
unzip -l build/ios/ipa/*.ipa | grep -i privacyinfo
# 或对 .app:
ls Payload/Runner.app/PrivacyInfo.xcprivacy
```

**光有文件不算数** —— 它必须在 Xcode 的 Copy Bundle Resources 里,才会被打进去。
