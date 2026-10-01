import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// Pure Kotlin/JVM: preprocessing, fusion and guardrail are deterministic math that must match the
// golden tensors on any JVM. ONNX Runtime is NOT a dependency yet: inference sits behind
// AutoModel, and the real ORT-backed implementation is PENDING on physical devices.
plugins {
    alias(libs.plugins.kotlin.jvm)
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

dependencies {
    api(project(":core-session"))
    api(project(":core-render"))

    testImplementation(testFixtures(project(":core-render")))
    testImplementation(kotlin("test-junit"))
    testImplementation(libs.junit)
}
