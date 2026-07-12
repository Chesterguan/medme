# MedMe 移动端 R8/ProGuard 规则

# ML Kit 文字识别:google_mlkit_text_recognition 插件把中/日/韩/梵文识别器都声明成
# compileOnly(插件代码里都有引用),但只打包 Latin。我们只额外加了中文识别包
# (见 build.gradle.kts),日/韩/梵文的识别器类因此在 classpath 缺失。
# 这些脚本 MedMe 用不到,-dontwarn 让 R8 忽略这些缺类(不影响我们用的中文+Latin)。
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# 保留 ML Kit 文字识别相关类(部分经由反射/清单组件加载,避免被 R8 误删)。
-keep class com.google.mlkit.vision.text.** { *; }
-keep class com.google.mlkit.vision.text.chinese.** { *; }
