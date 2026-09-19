# UX Stage 3 · 九屏截图对照(Task 16 验收)

**日期** 2026-09-19 · **build** `c978a35` · **模拟器** iPhone 17。

九屏截图与 mockup v24(唯一认可的视觉正本)模板逐屏并排比对。**下面列出的「对不上的地方」不是缺陷清单,是留给用户拍板的清单**——他认可过的是 mockup v24,不是实施者对 mockup 的理解;哪些差异要照 mockup 改、哪些是数据/结构限制下的合理偏差,由用户逐条定,这份文档不越俎代庖。截图文件不进仓库,路径引用即可(见每节「截图路径」)。

**本次实测已修**(截图前发现、当场处理,不在下面的「对不上」清单里):
- R18:头像块白底不可见
- R20:主卡日期截断
- R21:病程档案条孤悬 chevron

---

## 1. 病历(主页)

- 截图路径:`/private/tmp/claude-501/-Volumes-extraSupply-Projects-Medme/6fb778b0-c9b5-404d-ae65-0c0319ec1c97/scratchpad/stage3-shots/s1-病历.png`
- mockup 模板:`s1`
- 对不上的地方:主卡「最近就诊」值只有日期(mockup 是「7 月 20 日 中山医院 出院」,数据层没有医院/类型)

## 2. 趋势

- 截图路径:`/private/tmp/claude-501/-Volumes-extraSupply-Projects-Medme/6fb778b0-c9b5-404d-ae65-0c0319ec1c97/scratchpad/stage3-shots/s2-趋势.png`
- mockup 模板:`s2`
- 对不上的地方:病历本条标题两行(mockup 病名短「狼疮」,我们是「系统性红斑狼疮」,字不能改);78×24 折线槽为空(真折线是 Stage 2);无「看懂」蓝横幅(该屏当前数据没触发 UnderstandBanner 内容)

## 3. 病程档案

- 截图路径:`/private/tmp/claude-501/-Volumes-extraSupply-Projects-Medme/6fb778b0-c9b5-404d-ae65-0c0319ec1c97/scratchpad/stage3-shots/s3-病程档案.png`
- mockup 模板:`s3`
- 对不上的地方:结构是 Stage 1 的 section 渲染(「现行方案」大标题 26px + 用药 _ItemRow 灰左条+缩进),mockup s3 是 .lr 三列行 + 琥珀提醒横幅 + .read 块;本次数据没有提醒/时间轴内容可见(需滚动)

## 4. 给医生看

- 截图路径:`/private/tmp/claude-501/-Volumes-extraSupply-Projects-Medme/6fb778b0-c9b5-404d-ae65-0c0319ec1c97/scratchpad/stage3-shots/s4-给医生看.png`
- mockup 模板:`s4`
- 对不上的地方:「估算肾小球滤过率」这类长名+长单位的行,值簇折到名称下一行(LabLine 的折行兜底,非溢出);mockup 的诊断块(clinic)在我们数据里没有对应 section

## 5. 我

- 截图路径:`/private/tmp/claude-501/-Volumes-extraSupply-Projects-Medme/6fb778b0-c9b5-404d-ae65-0c0319ec1c97/scratchpad/stage3-shots/s5-我.png`
- mockup 模板:`s5`
- 对不上的地方:一致

## 6. 一份病历

- 截图路径:`/private/tmp/claude-501/-Volumes-extraSupply-Projects-Medme/6fb778b0-c9b5-404d-ae65-0c0319ec1c97/scratchpad/stage3-shots/s6-一份病历.png`
- mockup 模板:`s8`
- 对不上的地方:无 表格/文字/原件 三段 chip、无「报告上的提示」蓝横幅、无「看这几项的趋势」按钮 —— 代码里没有这些元素(评审确认),按「不动结构」未造

## 7. 成员页

- 截图路径:`/private/tmp/claude-501/-Volumes-extraSupply-Projects-Medme/6fb778b0-c9b5-404d-ae65-0c0319ec1c97/scratchpad/stage3-shots/s7-成员页.png`
- mockup 模板:`s10`
- 对不上的地方:只有两组(示例成员未开云端备份,云端那组不出现);mockup 三组

## 8. 出码

- 截图路径:`/private/tmp/claude-501/-Volumes-extraSupply-Projects-Medme/6fb778b0-c9b5-404d-ae65-0c0319ec1c97/scratchpad/stage3-shots/s8-出码.png`
- mockup 模板:`s13`
- 对不上的地方:走的是「简版码」路径(本机 API 403,上传失败态是旧样式的 FilledButton「继续上传」—— 失败/重试态不在 mockup 里,未改);首次提示 sheet 未出现(已同意过)

## 9. 首次启动

- 截图路径:`/private/tmp/claude-501/-Volumes-extraSupply-Projects-Medme/6fb778b0-c9b5-404d-ae65-0c0319ec1c97/scratchpad/stage3-shots/s9-首次启动.png`
- mockup 模板:`s16`
- 对不上的地方:场景靠左,mockup 居中;标题/正文是 Stage 1 定稿文案(mockup 是「你的病历,自己拿着」+ 三条短句),字不能改;滚到底后主按钮才变渐变(截图为禁用态)
