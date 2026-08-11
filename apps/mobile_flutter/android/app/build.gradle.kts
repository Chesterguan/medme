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
        // launcher 上的名字。默认值放在 `defaultConfig` 而不是逐个 buildType 写:
        // Flutter 的 gradle 插件会自己加一个 `profile` buildType,只写 debug/release
        // 的话 profile 构建会因为 manifest 里的 `${appLabel}` 解析不出来而挂掉。
        // debug 覆盖成「医我 dev」,见下。
        manifestPlaceholders["appLabel"] = "医我"
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
            // **图标名字也要区分,不然后缀等于白加。** 两个包在 launcher 上都叫
            // 「医我」、图标一模一样,谁也分不出点的是哪个 —— 真实后果:清空模拟器
            // 后两份都在,点进旧那份看到的是几个月前的界面(直角 banner、四宫格),
            // 然后花时间去查一个不存在的回归。
            manifestPlaceholders["appLabel"] = "医我 dev"
        }
        // Flutter 自己加的 `profile` buildType —— **它此前不带 `.dev` 后缀,是个
        // 会伤到真实数据的陷阱。**
        //
        // profile 构建存在的意义就是「跑真实性能」:cargokit 把它映射到 Rust 的
        // **release** profile(见 `cargokit/build_tool/lib/src/builder.dart`:
        // `BuildConfiguration.profile => 'release'`),而 debug 构建的 Rust 是
        // 未优化的 —— PP-OCRv5 这种神经网络推理在 debug 下慢几十到几百倍。
        // 所以任何「手机上到底多快」的问题,都只能用 profile/release 包回答。
        //
        // 但它此前的 applicationId 是 `com.medme.mobile`,与**正式版同名**:想在
        // 真机上量一次性能,就得把用户正在用的、装着真实病历的那个 app 覆盖掉。
        // 而这个 app 本地优先、没有云端副本 —— 签名不一致装不上,签名一致则是拿
        // 一个未发布的分支构建替换掉人家在用的版本。两条路都不该走。
        //
        // 加上同一个后缀,`profile` 与 debug 共用 `com.medme.mobile.dev`,与正式版
        // 永远并存互不覆盖;性能测量随时可做,不必拿真实病历冒险。
        //
        // 写法注意:`profile` 是 Flutter 的 gradle 插件**动态注册**的 buildType,
        // Kotlin DSL 里没有它的静态访问器,直接写 `profile { ... }` 编不过
        // (`Expression 'profile' cannot be invoked as a function`)。按名字取。
        getByName("profile") {
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-profile"
            manifestPlaceholders["appLabel"] = "医我 dev"
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
            // Flutter 自己的产物(libflutter/libapp/libc++_shared),**管不到 AAR 带
            // 进来的 jniLibs**,也**管不到 cargokit** —— 后者按自己的清单编 Rust 库。
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

// release 包再补一道:把非 arm64 的 .so 直接排除在打包之外。
//
// **`ndk.abiFilters` 挡不住 cargokit。** 实测 1.6.0+54 的 release APK 里
// `librust_lib_mobile_flutter.so` 三个 ABI 全在(arm64 57MB / v7a 14MB /
// x86_64 18MB),而 `libflutter.so`、`libapp.so`、`libc++_shared.so` **只有
// arm64** —— `--target-platform android-arm64` 管住了 Flutter 自己的产物,
// cargokit 按自己的清单编,两道过滤都没拦住它。
//
// 后果不是「多几十 MB 死重」,是**装上就崩**:32 位手机看到 `lib/armeabi-v7a/`
// 存在,就认定自己该用那一份,于是只解压 v7a 的库 —— 而那里面没有
// `libflutter.so`,app 一启动就 UnsatisfiedLinkError。x86_64 同理。
// 走蒲公英分发时,任何一台 32 位测试机拿到的都是一个必崩的包。
//
// 用变体 API 而不是 `--split-per-abi`:后者与上面的 `ndk.abiFilters` 冲突
// (`Conflicting configuration : 'arm64-v8a' in ndk abiFilters cannot be present
// when splits abi filters are set`),二选一的话 abiFilters 那道还得留着挡 AAR。
// 只作用于 release,debug 的 x86_64 模拟器支持不受影响。
androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        variant.packaging.jniLibs.excludes.addAll(
            listOf("lib/armeabi-v7a/**", "lib/x86/**", "lib/x86_64/**"),
        )
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
