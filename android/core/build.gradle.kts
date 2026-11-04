plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "io.throne.bbox.core"
    compileSdk = 35

    defaultConfig {
        minSdk = 21
        consumerProguardFiles("proguard-rules.pro")
    }

    buildTypes {
        release {
            isJniDebuggable = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("src/main/jniLibs")
        }
    }

    externalNativeBuild {
        cmake {
            path("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation("androidx.annotation:annotation-jvm:1.9.1")
}

// The Go shared library lives inside ThroneCore.aar (built by CI through
// buildScript/); extract it per ABI so CMake can link it.
val copyNativeLibs by tasks.register<Copy>("copyNativeLibs") {
    from(zipTree(rootProject.file("app/libs/ThroneCore.aar"))) {
        include("jni/**")
        eachFile {
            path = path.removePrefix("jni/")
        }
        includeEmptyDirs = false
    }
    into("src/main/jniLibs")
}

afterEvaluate {
    tasks.named("preBuild") {
        dependsOn(copyNativeLibs)
    }
}
