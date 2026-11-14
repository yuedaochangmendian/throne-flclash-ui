// Top-level build file where you can add configuration options common to all sub-projects/modules.
allprojects {
    apply(from = "${rootProject.projectDir}/repositories.gradle.kts")
}

// AGP 8.12.3 refuses to consume AARs whose metadata declares minAndroidGradlePluginVersion=9.1.0,
// and androidx.core/core-ktx 1.19.1 declare exactly that. 1.19.1 enters the graph transitively:
// the wifi_ssid Flutter plugin AAR (flutter/build/host/outputs/repo) publishes a `requires` on
// core-ktx 1.19.1 in its Gradle module metadata, which wins over the host's own
// `androidx.core:core-ktx:1.9.0` declaration. Raising AGP to 9 is not an option (buildSrc still
// drives AbstractAppExtension/applicationVariants, both removed in 9), so the two modules that
// moved to AGP 9 metadata are pinned to 1.18.0 — the newest release still inside AGP 8's range
// (minAGP 8.9.1, minCompileSdk 36, and the host already compiles against 37), and the version the
// other plugin AARs (filepicker, connectivity_plus, image_picker) already ask for. Verified
// against every androidx/core reference in those AARs: 1.18.0 provides all of them.
subprojects {
    configurations.all {
        resolutionStrategy {
            force(
                "androidx.core:core:1.18.0",
                "androidx.core:core-ktx:1.18.0",
            )
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

plugins {
    id("com.google.devtools.ksp") version "2.3.13" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.10" apply false
}
