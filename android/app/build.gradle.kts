// AGP 9 compiles Kotlin with its built-in Kotlin support; only the Compose compiler plugin is added.
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.lightlylabs.lightly"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.lightlylabs.lightly"
        // Spec U6 (revised after Codex M1 finding 8): the IS_PENDING save path needs API 29.
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0-m2"
    }

    buildFeatures {
        compose = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(project(":core-session"))

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.viewmodel)
    implementation(libs.lifecycle.viewmodel.savedstate)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.runtime.compose)

    testImplementation(kotlin("test-junit"))
    testImplementation(libs.junit)
}
