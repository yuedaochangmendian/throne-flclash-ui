@file:Suppress("UnstableApiUsage")

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("com.google.devtools.ksp")
    id("kotlin-parcelize")
}

setupApp()

val generatedLicenseAssets = layout.buildDirectory.dir("generated/assets/rootLicense")
val generateRootLicenseAsset by tasks.registering(Copy::class) {
    from(rootProject.layout.projectDirectory.file("LICENSE"))
    into(generatedLicenseAssets)
}

android {
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
    }
    ksp {
        arg("room.incremental", "true")
        arg("room.schemaLocation", "$projectDir/schemas")
    }
    bundle {
        language {
            enableSplit = false
        }
    }
    buildFeatures {
        buildConfig = true
        viewBinding = true
        aidl = true
    }
    namespace = "io.nekohasekai.sagernet"
    packaging {
        jniLibs {
            // Legacy packaging keeps the .so files deflated in the APK and extracts them
            // at install time. `useLegacyPackaging = false` was tried in 3.2.4 and reverted:
            // it forces every library to be STORED uncompressed (libthrone.so alone is
            // 82 MB), which doubled the download to 120 MB per ABI for a disk saving that
            // the extracted copy mostly paid back anyway. This app updates in-app over
            // mobile networks — the download is the scarcer resource.
            useLegacyPackaging = true
            // Flutter's *debug* engine ships the Vulkan validation layer: 237 MB uncompressed, ~65 MB inside the APK,
            // second only to libflutter.so itself. It exists purely for graphics debugging and is absent from the
            // release engine jar (verified: 0 VkLayer entries there), so nothing can depend on it at runtime.
            excludes += setOf("**/libVkLayer_khronos_validation.so")
        }
    }
    androidResources {
        generateLocaleConfig = true
    }
    sourceSets.named("main") {
        assets.srcDir(generatedLicenseAssets)
    }
}

tasks.matching { it.name == "preBuild" }.configureEach {
    dependsOn(generateRootLicenseAsset)
}

dependencies {

    implementation(project(":bboxmodel"))

    // B-box's own interface, built by `flutter build aar` into flutter/build/host/outputs/repo.
    // Every variant links the release AAR, not just release builds. The debug one ships the JIT engine plus Dart as
    // interpreted kernel, which costs ~150 MB of APK and buys hot reload — something this host never exercises,
    // because the Dart lives in the Flutter module and is developed there on its own.
    implementation("io.ericlee.bbox_ui:flutter_release:1.0")

    implementation(fileTree("libs"))

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    implementation("androidx.core:core-ktx:1.9.0")
    implementation("androidx.recyclerview:recyclerview:1.3.0")
    implementation("androidx.activity:activity-ktx:1.10.1")
    implementation("androidx.fragment:fragment-ktx:1.5.6")
    implementation("androidx.browser:browser:1.5.0")
    implementation("androidx.preference:preference-ktx:1.2.0")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("androidx.work:work-runtime-ktx:2.8.1")
    implementation("androidx.work:work-multiprocess:2.8.1")

    implementation("com.google.android.material:material:1.8.0")
    implementation("com.google.code.gson:gson:2.9.0")

    implementation("com.github.jenly1314:zxing-lite:2.1.1")
    // 0.24.x now matches the host's Kotlin 2.2 toolchain, but still needs a separate editor regression pass.
    // Keep 0.23.7 and its stdlib exclusion until that optional U3 upgrade.
    implementation("io.github.rosemoe:editor:0.23.7") {
        exclude(group = "org.jetbrains.kotlin", module = "kotlin-stdlib")
    }

    implementation("com.squareup.okhttp3:okhttp:5.0.0-alpha.3")
    implementation("org.yaml:snakeyaml:1.30")
    implementation("com.github.daniel-stoneuk:material-about-library:3.2.0-rc01")
    implementation("com.jakewharton:process-phoenix:2.1.2")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20231013")

    implementation("com.simplecityapps:recyclerview-fastscroll:2.0.1") {
        exclude(group = "androidx.recyclerview")
        exclude(group = "androidx.appcompat")
    }

    implementation("androidx.room:room-runtime:2.6.1")
    ksp("androidx.room:room-compiler:2.6.1")
    implementation("androidx.room:room-ktx:2.6.1")

    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.3")
}

// Flutter plugin AARs and the host now share one Kotlin toolchain: the host builds on Kotlin 2.4.10,
// which reads the 2.4.0 metadata that mobile_scanner_release (pulled in by the B-box Flutter module)
// was compiled with, so no `force` or `-Xskip-metadata-version-check` is needed to bridge the gap.
// CameraX likewise resolves to 1.6.1 on its own (AGP 8.12.3 satisfies its min AGP 8.9.1). The one
// thing still enforced out-of-band is CI's tools/diagnostics/scan_aar_apis.py, which proves the AAR
// references nothing the resolved stdlib/coroutines versions don't provide.
