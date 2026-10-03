import com.android.build.api.artifact.SingleArtifact
import com.android.build.api.variant.BuiltArtifactsLoader
import java.io.ByteArrayOutputStream
import java.util.zip.ZipFile
import javax.inject.Inject
import org.gradle.process.ExecOperations

// AGP 9 compiles Kotlin with its built-in Kotlin support; only the Compose compiler plugin is added.
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.lightlylabs.lightly"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.lightlylabs.lightly"
        // Spec U6 (revised after Codex M1 finding 8): the IS_PENDING save path needs API 29.
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0-m2"
    }

    buildFeatures {
        compose = true
        // About shows versionName (versionCode); debug-only launch options read BuildConfig.DEBUG.
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    testOptions {
        unitTests {
            // Robolectric: persistable URI grants (ContentResolverPhotoAccessGrantsTest).
            isIncludeAndroidResources = true
        }
    }
}

dependencies {
    implementation(project(":core-session"))
    implementation(project(":core-model"))
    implementation(project(":core-render"))
    implementation(project(":core-decode"))
    implementation(project(":core-export"))

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.viewmodel)
    implementation(libs.lifecycle.viewmodel.savedstate)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.window)

    testImplementation(kotlin("test-junit"))
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)
    // Compose UI tests run on Robolectric (no device): layout, stop markers, notices, large text.
    testImplementation(platform(libs.compose.bom))
    testImplementation(libs.compose.ui.test.junit4)
    // createComposeRule() needs its host activity in the merged debug manifest; this adds a
    // non-exported test activity to debug builds only. Release is unaffected.
    debugImplementation(platform(libs.compose.bom))
    debugImplementation(libs.compose.ui.test.manifest)
}

// --- Look pack (spec §4.5) ------------------------------------------------------------------------
//
// The pack (manifest.json + luts/*.f32) is built from the private preset collection by
// experiments/presets/look_pack/build_look_pack.py into a git-ignored out/ folder, so it is never in
// the repository; it is copied into every variant's assets under lookpack/ at build time.
// Lookup order:
//   1. -PlightlyLookPackDir=/abs/path (or LIGHTLY_LOOK_PACK_DIR); a given path that has no
//      manifest.json fails the build rather than silently shipping no Looks.
//   2. This checkout's experiments/presets/look_pack/out.
//   3. Inside a git worktree at <main>/.claude/worktrees/<name>, the main checkout's out/ (ignored
//      folders do not exist in a fresh worktree). Derived from the path, never hard-coded.
// No pack found: the build still succeeds, and the app says "No Looks are available in this build."
val lookPackRelativePath = "experiments/presets/look_pack/out"
val lookPackDirectory: File? = resolveLookPackDirectory()

fun resolveLookPackDirectory(): File? {
    val explicit = providers.gradleProperty("lightlyLookPackDir")
        .orElse(providers.environmentVariable("LIGHTLY_LOOK_PACK_DIR"))
        .orNull
    if (explicit != null) {
        val directory = file(explicit)
        if (!directory.resolve("manifest.json").isFile) {
            throw GradleException("lightlyLookPackDir=$explicit has no manifest.json (build it with build_look_pack.py)")
        }
        return directory
    }
    val repoRoot = rootDir.parentFile
    val candidates = listOfNotNull(repoRoot, mainCheckoutOfWorktree(repoRoot)).map { it.resolve(lookPackRelativePath) }
    return candidates.firstOrNull { it.resolve("manifest.json").isFile }
}

/** `<main>/.claude/worktrees/<name>` → `<main>`; null for any other checkout. */
fun mainCheckoutOfWorktree(checkout: File): File? {
    val path = checkout.invariantSeparatorsPath
    val marker = "/.claude/worktrees/"
    val markerIndex = path.indexOf(marker)
    return if (markerIndex > 0) File(path.substring(0, markerIndex)) else null
}

// The loader test that checks the real pack (format 2, 18 Looks, names verbatim) reads it in place.
tasks.withType<Test>().configureEach {
    // The catalogue test parses the real approved catalogue in place.
    systemProperty("lightly.presetCatalogue", presetCatalogueFile.absolutePath)
    inputs.file(presetCatalogueFile).withPathSensitivity(PathSensitivity.NONE).withPropertyName("presetCatalogue")
    lookPackDirectory?.let { pack ->
        systemProperty("lightly.lookPackDir", pack.absolutePath)
        inputs.file(pack.resolve("manifest.json")).withPathSensitivity(PathSensitivity.NONE).withPropertyName("lookPackManifest")
    }
}

if (lookPackDirectory == null) {
    logger.warn("Lightly: no Look pack found ($lookPackRelativePath or -PlightlyLookPackDir); this build has no Looks.")
} else {
    logger.info("Lightly: bundling the Look pack from $lookPackDirectory")
}

/** Copies only the pack's own files (manifest + .f32 LUTs) into a generated assets root. */
abstract class BundleLookPackTask : DefaultTask() {
    @get:Optional
    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val packDirectory: DirectoryProperty

    @get:OutputDirectory
    abstract val assetsDirectory: DirectoryProperty

    @TaskAction
    fun bundle() {
        val assetsRoot = assetsDirectory.get().asFile
        assetsRoot.deleteRecursively()
        assetsRoot.mkdirs()
        val pack = packDirectory.orNull?.asFile ?: return // no pack: no assets, the app reports it
        val target = assetsRoot.resolve("lookpack")
        pack.resolve("manifest.json").copyTo(target.resolve("manifest.json"))
        pack.resolve("luts").listFiles { lut -> lut.extension == "f32" }.orEmpty().forEach { lut ->
            lut.copyTo(target.resolve("luts/${lut.name}"))
        }
    }
}

// --- Develop catalogue (Lightly 1.0) ---------------------------------------------------------------
//
// presets/develop-design-ui.json is the approved category/stop catalogue (ids, display names). It is
// versioned in the repository and bundled verbatim under assets/catalogue/, so the app and the design
// read the same ids (favourites in slice 1; Develop in slice 2). A missing file fails the build.
val presetCatalogueFile: File = rootDir.parentFile.resolve("presets/develop-design-ui.json")

abstract class BundlePresetCatalogueTask : DefaultTask() {
    @get:InputFile
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val catalogueFile: RegularFileProperty

    @get:OutputDirectory
    abstract val assetsDirectory: DirectoryProperty

    @TaskAction
    fun bundle() {
        val assetsRoot = assetsDirectory.get().asFile
        assetsRoot.deleteRecursively()
        catalogueFile.get().asFile.copyTo(assetsRoot.resolve("catalogue/develop-design-ui.json"))
    }
}

// --- Launcher icon packaging check ----------------------------------------------------------------
//
// Inspects the BUILT apk, not the sources: an icon that exists in res/ but is dropped by the
// manifest merge, resource shrinking or a bad qualifier would pass a source check and still ship
// the default robot. Every assemble<Variant> depends on it, so a build without its icon fails.

/**
 * Fails unless `aapt2 dump badging` reports an application icon, every icon path it names is in the
 * apk, and each icon that is an adaptive-icon XML has a foreground and a background that resolve
 * (a foreground drawable file must be in the apk too).
 */
abstract class VerifyLauncherIconTask : DefaultTask() {
    @get:InputFiles
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val apkDirectory: DirectoryProperty

    @get:Internal
    abstract val builtArtifactsLoader: Property<BuiltArtifactsLoader>

    @get:InputFile
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val aapt2: RegularFileProperty

    @get:OutputFile
    abstract val reportFile: RegularFileProperty

    @get:Inject
    abstract val execOperations: ExecOperations

    @TaskAction
    fun verify() {
        val artifacts = builtArtifactsLoader.get().load(apkDirectory.get())
            ?: throw GradleException("No apk metadata in ${apkDirectory.get()}")
        val report = artifacts.elements.joinToString("\n") { element -> verifyApk(File(element.outputFile)) }
        reportFile.get().asFile.writeText(report + "\n")
    }

    private fun verifyApk(apk: File): String {
        val badging = aapt2Output("dump", "badging", apk.absolutePath)
        val applicationLine = badging.lineSequence().firstOrNull { it.startsWith("application:") }
        val iconPaths = (Regex("""^application-icon-\d+:'([^']+)'""", RegexOption.MULTILINE).findAll(badging).map { it.groupValues[1] } +
            Regex("""icon='([^']+)'""").findAll(applicationLine.orEmpty()).map { it.groupValues[1] }).toSortedSet()
        if (iconPaths.isEmpty()) fail(apk, "aapt2 dump badging reports no application icon")
        val resourceFiles = resourceFilesById(apk)
        ZipFile(apk).use { zip ->
            iconPaths.forEach { path ->
                if (zip.getEntry(path) == null) fail(apk, "icon $path is not in the apk")
                if (path.endsWith(".xml")) verifyAdaptiveIcon(apk, zip, path, resourceFiles)
            }
        }
        return "${apk.name}: icon ${iconPaths.joinToString()} OK"
    }

    private fun verifyAdaptiveIcon(apk: File, zip: ZipFile, iconPath: String, resourceFiles: Map<String, List<String>>) {
        val tree = aapt2Output("dump", "xmltree", "--file", iconPath, apk.absolutePath)
        if (!tree.contains("E: adaptive-icon")) fail(apk, "$iconPath is not an adaptive-icon")
        listOf("foreground", "background").forEach { layer ->
            // Only this element's own attributes: stop at the next element so a layer without a
            // drawable cannot borrow the other layer's reference.
            val layerBlock = tree.substringAfter("E: $layer", missingDelimiterValue = "").substringBefore("E: ")
            if (layerBlock.isEmpty()) fail(apk, "$iconPath has no <$layer>")
            val reference = Regex("""android:drawable\(0x[0-9a-f]+\)=@(0x[0-9a-f]+)""").find(layerBlock)?.groupValues?.get(1)
                ?: fail(apk, "$iconPath <$layer> has no drawable reference")
            val files = resourceFiles[reference] ?: fail(apk, "$iconPath <$layer> references $reference, which is not in the resource table")
            files.forEach { file -> if (zip.getEntry(file) == null) fail(apk, "$iconPath <$layer> file $file is not in the apk") }
            if (layer == "foreground" && files.isEmpty()) fail(apk, "$iconPath foreground $reference is not a drawable file")
        }
    }

    /** Resource id (0x7f…) → the files it points to; empty for value resources such as colours. */
    private fun resourceFilesById(apk: File): Map<String, List<String>> {
        val table = mutableMapOf<String, MutableList<String>>()
        var currentId: String? = null
        aapt2Output("dump", "resources", apk.absolutePath).lineSequence().forEach { line ->
            Regex("""^\s*resource (0x[0-9a-f]+) """).find(line)?.let { currentId = it.groupValues[1]; table[it.groupValues[1]] = mutableListOf() }
            Regex("""\(file\) (\S+)""").find(line)?.let { match -> currentId?.let { table.getValue(it) += match.groupValues[1] } }
        }
        return table
    }

    private fun aapt2Output(vararg arguments: String): String {
        val output = ByteArrayOutputStream()
        execOperations.exec {
            commandLine(aapt2.get().asFile.absolutePath, *arguments)
            standardOutput = output
        }
        return output.toString(Charsets.UTF_8)
    }

    private fun fail(apk: File, reason: String): Nothing =
        throw GradleException("Launcher icon check failed for ${apk.name}: $reason")
}

val aapt2Executable = androidComponents.sdkComponents.sdkDirectory.map { sdk ->
    sdk.file("build-tools/${android.buildToolsVersion}/aapt2")
}

androidComponents {
    onVariants { variant ->
        val variantName = variant.name.replaceFirstChar { it.uppercase() }

        val bundleLookPack = tasks.register<BundleLookPackTask>("bundle${variantName}LookPack") {
            lookPackDirectory?.let { packDirectory.set(it) }
        }
        variant.sources.assets?.addGeneratedSourceDirectory(bundleLookPack, BundleLookPackTask::assetsDirectory)

        val bundleCatalogue = tasks.register<BundlePresetCatalogueTask>("bundle${variantName}PresetCatalogue") {
            catalogueFile.set(presetCatalogueFile)
        }
        variant.sources.assets?.addGeneratedSourceDirectory(bundleCatalogue, BundlePresetCatalogueTask::assetsDirectory)

        val verifyIcon = tasks.register<VerifyLauncherIconTask>("verify${variantName}LauncherIcon") {
            apkDirectory.set(variant.artifacts.get(SingleArtifact.APK))
            builtArtifactsLoader.set(variant.artifacts.getBuiltArtifactsLoader())
            aapt2.set(aapt2Executable)
            reportFile.set(layout.buildDirectory.file("reports/launcher-icon/${variant.name}.txt"))
        }
        tasks.matching { it.name == "assemble$variantName" }.configureEach { dependsOn(verifyIcon) }
    }
}
