import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// Pure Kotlin/JVM: the edit model must be testable without Android and must not depend on any
// rendering or platform type, so iOS and Android can be checked against the same JSON.
plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

dependencies {
    api(libs.kotlinx.serialization.json)
    testImplementation(kotlin("test-junit"))
    testImplementation(libs.junit)
}
