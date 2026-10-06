import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// Pure Kotlin/JVM port of the Develop stage of rendering contract v2 (shared/contracts/rendering-v2.md,
// shared/look-pack/reference_model.py): the format-3 look-pack reader, develop.global and its 33³ bake,
// lookVersion, the portable random field and the develop.spatial / finishing operators. It has no
// Android dependency so the parity tests against shared/fixtures/look-pack run on any JVM.
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
    // Lut3D and Rgba8Image are the render path's types; the bake writes straight into a Lut3D.
    api(project(":core-render"))
    api(libs.kotlinx.serialization.json)
    testImplementation(kotlin("test-junit"))
    testImplementation(libs.junit)
}

// The shared parity fixtures, the rendering contract and the built pack are read in place (never
// copied into the Android tree), so a contract change on either platform fails the other's tests.
val repoRoot: File = rootDir.parentFile
val lookPackFixturesDir: File = repoRoot.resolve("shared/fixtures/look-pack")
val renderingContractFile: File = repoRoot.resolve("shared/contracts/rendering-v2.json")
val builtPackManifest: File = repoRoot.resolve("shared/look-pack/out/manifest.json")

tasks.withType<Test>().configureEach {
    systemProperty("lightly.lookPackFixturesDir", lookPackFixturesDir.absolutePath)
    systemProperty("lightly.renderingContract", renderingContractFile.absolutePath)
    systemProperty("lightly.renderingGoldensDir", repoRoot.resolve("shared/fixtures/rendering").absolutePath)
    systemProperty("lightly.builtPackManifest", builtPackManifest.absolutePath)
    systemProperty("lightly.spatialFixturesDir", projectDir.resolve("src/test/resources/spatial").absolutePath)
    inputs.dir(lookPackFixturesDir).withPathSensitivity(PathSensitivity.RELATIVE).withPropertyName("lookPackFixtures")
    inputs.file(renderingContractFile).withPathSensitivity(PathSensitivity.NONE).withPropertyName("renderingContract")
    inputs.dir(repoRoot.resolve("shared/fixtures/rendering")).withPathSensitivity(PathSensitivity.RELATIVE).withPropertyName("renderingGoldens")
    // The full pack is git-ignored and large: record its path, not its contents.
    inputs.property("builtPackManifest", builtPackManifest.absolutePath)
    // AutoEvaluationProbe (completion plan A3) runs only with -Plightly.probe; it writes experiments/auto-android/eval.txt.
    if (project.hasProperty("lightly.probe")) {
        systemProperty("lightly.probe", "true")
        systemProperty("lightly.autoEvalDir", repoRoot.resolve("experiments/auto-android").absolutePath)
        outputs.upToDateWhen { false }
        testLogging.showStandardStreams = true
    }
}
