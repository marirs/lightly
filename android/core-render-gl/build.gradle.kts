// Android library holding the only GLES/EGL code. Everything it needs that can be checked on a JVM
// (shader source, LUT texture layout, tile plan, the CPU oracle) lives in :core-render and is tested
// there. Executing this module on a GPU is PENDING on physical devices (Adreno, Mali).
plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "com.lightlylabs.lightly.render.gl"
    compileSdk = 37

    defaultConfig {
        minSdk = 29
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }
}

dependencies {
    api(project(":core-render"))
}
