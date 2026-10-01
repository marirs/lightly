import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// Pure Kotlin/JVM: scheduling and the CPU reference LUT math. The GLES renderer (EGL, 3D texture,
// FBO tiles) will live in an Android source set/module next to this in M3; it is validated against
// the CPU reference here, which is why the reference must not depend on Android.
plugins {
    alias(libs.plugins.kotlin.jvm)
    `java-test-fixtures`
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

dependencies {
    api(libs.kotlinx.coroutines.core)

    // Golden-fixture loading (javax.imageio PNG decode, little-endian float files) is shared with
    // core-model's tests through test fixtures rather than duplicated.
    testFixturesImplementation(kotlin("test-junit"))

    testImplementation(kotlin("test-junit"))
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
