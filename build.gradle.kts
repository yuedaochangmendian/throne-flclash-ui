// Top-level build file where you can add configuration options common to all sub-projects/modules.
allprojects {
    apply(from = "${rootProject.projectDir}/repositories.gradle.kts")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

plugins {
    id("com.google.devtools.ksp") version "2.3.13" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.10" apply false
}
