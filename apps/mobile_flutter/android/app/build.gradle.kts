import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 正式签名凭证。`android/key.properties` 已被 .gitignore 挡住,**绝不入库**;CI 由
// workflow 从 Secrets 现写一份。文件不存在时 release 退回 debug 签名(见 buildTypes)
// —— 本地开发不必持有正式 keystore 也能出包。
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        FileInputStream(keystorePropertiesFile).use { load(it) }
    }
}

android {
    namespace = "com.medme.mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.medme.mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        debug {
            // **debug 包用独立的 applicationId,与正式版并存。**
            // 两者同名时,想在装着正式版的真机上验 debug 构建就只有两条路:签名
            // 冲突装不上(白跑),或者先 uninstall —— 而这个 app 本地优先、无云端
            // 副本,卸载就把那台机器上的病历删干净了,恢复不回来。
            // 加个后缀,两份各自独立、互不覆盖,真机验证随时可做。
            //
            // 代价:深链与 App Links 认的是正式包名 + 正式签名指纹
            // (web/well-known/assetlinks.json),debug 包本来就走不通那条路,
            // 所以这个后缀没有额外损失。
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
        }
        release {
            // 有正式 keystore 就用它,否则退回 debug 签名 —— 本地开发不必持有正式
            // 私钥也能出 release 包。**安卓 App Links 只认正式签名的指纹**
            // (web/well-known/assetlinks.json 里那串),debug 签的包深链会退回
            // 「选择打开方式」,不是坏了。
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }

            // **只打包 arm64-v8a。** CI 的 `--target-platform android-arm64` 只过滤
            // Flutter 自己的产物(libflutter/libapp/librust_*),**管不到 AAR 带进来的
            // jniLibs** —— 实测 release APK 里躺着 x86_64 与 armeabi-v7a 的 ML Kit
            // (11.6 + 6.8 MB)和 dartjni,合计 18.6 MB 死重,arm64 机器永远不会加载。
            // 我们本来就只发 arm64(PP-OCR 的 ort 预编译库与 libc++_shared 都只做了
            // arm64,见 rust/build.rs 与 rust_builder/android/JNILIBS_NOTES.md)。
            //
            // **必须放在 release 里,不能放 defaultConfig**:cargokit 给 debug 构建
            // 硬编码追加 x86 ABI(给模拟器),在 defaultConfig 限死会弄坏本地 debug 装机。
            ndk {
                abiFilters.clear()
                abiFilters.add("arm64-v8a")
            }
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
