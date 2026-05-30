plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.unfydqry.searchsample"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.unfydqry.searchsample"
        minSdk = 29
        targetSdk = 34
        versionCode = 1
        versionName = "0.1"
    }

    buildFeatures { compose = true }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions { jvmTarget = "17" }

    packaging {
        // .so files are picked up from jniLibs.
    }
}

dependencies {
    // The binding (uniffi.unfydqry.*) is brought in via the :unifiedquery module.
    // Symmetric to depending on the SwiftPM library target (UnifiedQuery) on iOS.
    implementation(project(":unifiedquery"))

    implementation("androidx.activity:activity-compose:1.9.3")
    implementation(platform("androidx.compose:compose-bom:2024.10.01"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    // JNA's native dispatch part (libjnidispatch.so) is only delivered via the AAR.
    // :unifiedquery is distributed as a jar, so on Android the :app side must add this AAR.
    implementation("net.java.dev.jna:jna:5.14.0@aar")
}
