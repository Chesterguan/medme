plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
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

    buildTypes {
        release {
            // 内测阶段先用 debug 签名(CI 出可侧载 APK);正式上架前换正式 keystore。
            signingConfig = signingConfigs.getByName("debug")

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
