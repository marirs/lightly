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
    // Reads shared/fixtures/rendering/index.json and shared/contracts/rendering-v2.json in tests only.
    testImplementation(libs.kotlinx.serialization.json)
}

// The embedded-depth fixtures of the depth evaluation are read in place (git-ignored photos are not needed).
val depthFixturesDir: File = rootDir.parentFile.resolve("experiments/depth/embedded/fixtures")
tasks.withType<Test>().configureEach {
    systemProperty("lightly.depthFixturesDir", depthFixturesDir.absolutePath)
    systemProperty("lightly.refocusVectorsDir", projectDir.resolve("src/test/resources/refocus").absolutePath)
    // Shared parity goldens (rendering-v2 revision 1, contract fixes 1 G5) and the contract they belong to.
    systemProperty("lightly.renderingGoldensDir", rootDir.parentFile.resolve("shared/fixtures/rendering").absolutePath)
    systemProperty("lightly.renderingContract", rootDir.parentFile.resolve("shared/contracts/rendering-v2.json").absolutePath)
    inputs.dir(rootDir.parentFile.resolve("shared/fixtures/rendering"))
    inputs.file(rootDir.parentFile.resolve("shared/contracts/rendering-v2.json"))
    inputs.property("depthFixturesDir", depthFixturesDir.absolutePath)
    // BackgroundSpeedProbe (completion plan A1) runs only with -Plightly.probe; it prints timings, never fails.
    if (project.hasProperty("lightly.probe")) {
        systemProperty("lightly.probe", "true")
        project.findProperty("lightly.probe.only")?.let { systemProperty("lightly.probe.only", it.toString()) }
        project.findProperty("lightly.probe.heap")?.let { maxHeapSize = "${it}m" }
        project.findProperty("lightly.probe.cap")?.let { systemProperty("lightly.probe.cap", it.toString()) }
        project.findProperty("lightly.probe.label")?.let { systemProperty("lightly.probe.label", it.toString()) }
        // DragFrameProbe: worker threads as on a 4-core device (the caller plus 3 pool threads).
        project.findProperty("lightly.probe.threads")?.let { systemProperty("java.util.concurrent.ForkJoinPool.common.parallelism", it.toString()) }
        outputs.upToDateWhen { false }
        testLogging.showStandardStreams = true
    }
}

// Peak-heap bound (BackgroundMemoryTest): Background with a subject matte in a 150 MB JVM heap, so an
// allocation regression fails the build instead of an OutOfMemoryError on a phone (192 MB app heap).
val backgroundMemoryTest = tasks.register<Test>("backgroundMemoryTest") {
    description = "Background rendering within a 150 MB heap"
    testClassesDirs = sourceSets["test"].output.classesDirs
    classpath = sourceSets["test"].runtimeClasspath
    filter { includeTestsMatching("*BackgroundMemoryTest") }
    maxHeapSize = "150m"
}
tasks.named<Test>("test") {
    filter { excludeTestsMatching("*BackgroundMemoryTest") }
    dependsOn(backgroundMemoryTest)
}
