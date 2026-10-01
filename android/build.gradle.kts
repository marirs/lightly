plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.kotlin.compose) apply false
}

// Golden fixtures (experiments/lut3d/golden, ~600 MB, git-ignored) and the research basis LUTs
// (experiments/lut3d/models, git-ignored) are read in place, never copied into the Android tree,
// because the weights are research-only and must not end up in any build output.
// Override with -PlightlyGoldenDir=/abs/path (or LIGHTLY_GOLDEN_DIR) when running from a git
// worktree, where the ignored folders do not exist. Tests that need them FAIL when missing.
val repoRoot = rootDir.parentFile
val lightlyGoldenDir: String = providers.gradleProperty("lightlyGoldenDir")
    .orElse(providers.environmentVariable("LIGHTLY_GOLDEN_DIR"))
    .getOrElse(repoRoot.resolve("experiments/lut3d/golden").absolutePath)
val lightlyModelsDir: String = providers.gradleProperty("lightlyModelsDir")
    .orElse(providers.environmentVariable("LIGHTLY_MODELS_DIR"))
    .getOrElse(repoRoot.resolve("experiments/lut3d/models").absolutePath)

// Robolectric instruments JDK classes with ASM; on JDK 26 it fails with "Unsupported class file major
// version 70", which surfaces as misleading test failures. Fail fast with the fix instead.
val maxTestJdk = 25

subprojects {
    tasks.withType<Test>().configureEach {
        doFirst {
            val running = JavaVersion.current().majorVersion.toInt()
            if (running > maxTestJdk) {
                throw GradleException(
                    "Unit tests need JDK <= $maxTestJdk (running $running): Robolectric cannot instrument newer class files. " +
                        "Set JAVA_HOME to Android Studio's bundled JDK, e.g. " +
                        "JAVA_HOME=\"/Applications/Android Studio.app/Contents/jbr/Contents/Home\" ./gradlew test"
                )
            }
        }
        systemProperty("lightly.goldenDir", lightlyGoldenDir)
        systemProperty("lightly.modelsDir", lightlyModelsDir)
        // The fixture folders are too large to hash as task inputs; record the paths so pointing at a
        // different folder re-runs the tests instead of reusing a cached result.
        inputs.property("lightlyGoldenDir", lightlyGoldenDir)
        inputs.property("lightlyModelsDir", lightlyModelsDir)
        maxHeapSize = "3g"
        testLogging {
            events("failed")
            exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
            showStandardStreams = false
        }
    }
}
