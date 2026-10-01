// AGP 9 compiles Kotlin with its built-in Kotlin support; no kotlin-android plugin is applied.
plugins {
    id("com.android.application")
}

android {
    namespace = "com.lightlylabs.lutbench"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.lightlylabs.lutbench"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
        // Both target phones are arm64; dropping other ABIs keeps the ORT AAR from bloating the APK.
        ndk { abiFilters += listOf("arm64-v8a") }
    }

    buildTypes {
        release {
            // Timings must come from a non-debuggable build. Signing with the debug key keeps
            // the harness installable without a release keystore; it does not make it debuggable.
            isMinifyEnabled = false
            isDebuggable = false
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.30.0")
}
