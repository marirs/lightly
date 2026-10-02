// Android library: decoding needs ImageDecoder/Bitmap/ColorSpace. Size and policy maths are plain
// Kotlin in the same module and are unit-tested without Android; the ImageDecoder path is exercised
// under Robolectric's native graphics. Real-device decoding (HEIF, 10-bit, Ultra HDR, P3 camera
// JPEGs, timings, memory) is PENDING.
plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "com.lightlylabs.lightly.decode"
    compileSdk = 36

    defaultConfig {
        minSdk = 29
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
        }
    }
}

dependencies {
    api(project(":core-render"))

    testImplementation(kotlin("test-junit"))
    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)
}
