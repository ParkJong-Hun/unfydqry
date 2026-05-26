plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "unfydqry.kmp.sample"
    compileSdk = 34

    defaultConfig {
        applicationId = "unfydqry.kmp.sample"
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
}

dependencies {
    // The KMP lib wraps the UniFFI binding; :app only needs to depend on it.
    implementation(project(":lib"))

    implementation("androidx.activity:activity-compose:1.9.3")
    implementation(platform("androidx.compose:compose-bom:2024.10.01"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    // JNA AAR supplies libjnidispatch.so required by the JVM UniFFI binding.
    implementation("net.java.dev.jna:jna:5.14.0@aar")
}
