plugins {
    kotlin("multiplatform")
    id("com.android.library")
}

kotlin {
    // ── Android ──────────────────────────────────────────────────────────────
    androidTarget {
        compilations.all {
            kotlinOptions.jvmTarget = "17"
        }
    }

    // ── iOS ──────────────────────────────────────────────────────────────────
    // Default hierarchy template (KMP 2.0+) automatically creates iosMain
    // as a parent of the three iOS leaf targets below.
    listOf(iosArm64(), iosSimulatorArm64(), iosX64()).forEach { target ->
        target.compilations["main"].cinterops {
            val unfydqryBridge by creating {
                defFile = file("src/iosMain/cinterop/unfydqry_bridge.def")
                // ios_bridge/ is the include directory for UnfydqryBridge.h.
                includeDirs(rootProject.file("ios_bridge"))
            }
        }
    }

    // ── Source sets ──────────────────────────────────────────────────────────
    sourceSets {
        commonMain.dependencies {}

        // Include the generated UniFFI Kotlin binding directly so the KMP lib
        // compiles without modifying the android/sample Gradle project.
        androidMain {
            kotlin.srcDir("../../android/sample/unifiedquery/src/main/kotlin")
            dependencies {
                compileOnly("net.java.dev.jna:jna:5.14.0")
            }
        }

        // iosMain is created automatically by the default hierarchy template.
        // src/iosMain/kotlin/ is picked up by convention.

    }
}

android {
    namespace = "unfydqry.kmp"
    compileSdk = 34

    defaultConfig {
        minSdk = 24
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets["main"].jniLibs.srcDirs("../../android/jniLibs")
}
