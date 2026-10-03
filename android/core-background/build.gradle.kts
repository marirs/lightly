import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// Pure Kotlin/JVM: Background › Focus & Blur and Change background (rendering-v2 stages
// background.replace and background.focus, docs/v1/depth-evaluation.md §6), the embedded depth
// readers (Dynamic Depth 1.0, GDepth) and the depth-model input/output contract. No Android types,
// so every step is tested on the JVM; the model runtime and the segmenter live behind interfaces.
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
    testImplementation(kotlin("test-junit"))
    testImplementation(libs.junit)
}

// The embedded-depth fixtures of the depth evaluation are read in place (git-ignored photos are not needed).
val depthFixturesDir: File = rootDir.parentFile.resolve("experiments/depth/embedded/fixtures")
tasks.withType<Test>().configureEach {
    systemProperty("lightly.depthFixturesDir", depthFixturesDir.absolutePath)
    systemProperty("lightly.refocusVectorsDir", projectDir.resolve("src/test/resources/refocus").absolutePath)
    inputs.property("depthFixturesDir", depthFixturesDir.absolutePath)
}
