import org.gradle.api.file.DuplicatesStrategy
import org.gradle.api.tasks.Sync

plugins {
    id("com.android.application")
}

val proxyAccessTokenFile = file("${System.getProperty("user.home")}/.config/typing-dongnanya/access-token")
val proxyAccessToken = if (proxyAccessTokenFile.isFile) proxyAccessTokenFile.readText().trim() else ""
if (!proxyAccessToken.matches(Regex("^[a-fA-F0-9]{48}$"))) {
    throw GradleException("缺少有效的 ~/.config/typing-dongnanya/access-token，请先部署或同步翻译服务 capability")
}
val translationBaseEndpoint = "https://114.132.185.123/typing-dongnanya-api/v1/chat/completions"
val translationEndpoint = "$translationBaseEndpoint/$proxyAccessToken"
val generatedRimeAssetsRoot = file("$projectDir/build/generated/rimeAssets")
val generatedHandwritingAssetsRoot = file("$projectDir/build/generated/handwritingAssets")
val compilerLauncherPath = rootProject.file("../../scripts/android/apple-clang-launcher.ts").absolutePath

android {
    namespace = "com.caizhichao.typingdongnanya"
    compileSdk = 36
    buildToolsVersion = "36.0.0"
    ndkVersion = "28.2.13676358"

    defaultConfig {
        applicationId = "com.caizhichao.typingdongnanya"
        minSdk = 26
        targetSdk = 36
        versionCode = 8
        versionName = "0.3.2"

        buildConfigField("String", "TRANSLATION_ENDPOINT", "\"$translationEndpoint\"")
        ndk {
            abiFilters += "arm64-v8a"
        }
        externalNativeBuild {
            cmake {
                arguments += listOf(
                    "-DANDROID_STL=c++_shared",
                    "-DCMAKE_C_COMPILER_LAUNCHER=$compilerLauncherPath",
                    "-DCMAKE_CXX_COMPILER_LAUNCHER=$compilerLauncherPath",
                )
                cppFlags += listOf("-std=c++17", "-fno-sized-deallocation")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.31.6"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        buildConfig = true
    }

    androidResources {
        noCompress += listOf("yaml", "txt", "ocd2")
    }

    sourceSets.getByName("main").assets.directories.addAll(listOf(
        generatedRimeAssetsRoot.absolutePath,
        generatedHandwritingAssetsRoot.absolutePath,
    ))
}

dependencies {
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.21.1")
}

// Android 与 macOS 共用同一份方案 patch，构建期只生成包内副本，不回写共享数据。
val prepareRimeAssets = tasks.register<Sync>("prepareRimeAssets") {
    duplicatesStrategy = DuplicatesStrategy.FAIL
    into(generatedRimeAssetsRoot)
    into("rime") {
        from(rootProject.file("../../shared/RimeData"))
    }
    into("licenses") {
        from(rootProject.file("../../vendor/librime/LICENSE")) {
            rename { "librime.LICENSE" }
        }
        from(rootProject.file("../../vendor/librime/deps/yaml-cpp/LICENSE")) {
            rename { "yaml-cpp.LICENSE" }
        }
        from(rootProject.file("../../vendor/librime/deps/leveldb/LICENSE")) {
            rename { "leveldb.LICENSE" }
        }
        from(rootProject.file("../../vendor/librime/deps/marisa-trie/COPYING.md")) {
            rename { "marisa-trie.COPYING.md" }
        }
        from(rootProject.file("../../vendor/librime/deps/opencc/LICENSE")) {
            rename { "opencc.LICENSE" }
        }
        from(rootProject.file("../../vendor/librime/deps/opencc/deps/darts-clone-0.32h/COPYING.md")) {
            rename { "darts-clone.COPYING.md" }
        }
        from(rootProject.file("../../vendor/aosp-pinyinime-data/NOTICE")) {
            rename { "aosp-pinyinime.NOTICE" }
        }
        from(rootProject.file("../../vendor/aosp-pinyinime-data/SOURCE.json")) {
            rename { "aosp-pinyinime.SOURCE.json" }
        }
        from(rootProject.file("../../vendor/wubimb-data/LICENSE")) {
            rename { "wubimb.LICENSE" }
        }
        from(rootProject.file("../../vendor/wubimb-data/SOURCE.json")) {
            rename { "wubimb.SOURCE.json" }
        }
        from(rootProject.file("../../vendor/paddleocr-handwriting/LICENSE")) {
            rename { "paddleocr.LICENSE" }
        }
        from(rootProject.file("../../vendor/paddleocr-handwriting/SOURCE.json")) {
            rename { "paddleocr-handwriting.SOURCE.json" }
        }
        from(rootProject.file("licenses/onnxruntime.LICENSE"))
        from(rootProject.file("licenses/boost.LICENSE"))
    }
}

tasks.named("preBuild").configure {
    dependsOn(prepareRimeAssets)
}
