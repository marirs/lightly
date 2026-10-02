// Android library: the save path is MediaStore + Bitmap, so it cannot be pure JVM. The export
// *flow* (insert pending → encode once → publish, delete on failure) is written against a small
// gateway interface so it is unit-testable without Android; the real ContentResolver gateway is
// exercised under Robolectric.
plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "com.lightlylabs.lightly.export"
    compileSdk = 36

    defaultConfig {
        // Spec U6: IS_PENDING and permissionless scoped-storage inserts exist only from API 29.
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
    // Export renders through the same LutPassRenderer and TilePlan as previews (Invariant P=E).
    api(project(":core-render"))

    testImplementation(kotlin("test-junit"))
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)
}
