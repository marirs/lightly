import com.android.build.api.artifact.SingleArtifact
import com.android.build.api.variant.BuiltArtifactsLoader
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.zip.ZipFile
import javax.inject.Inject
import org.gradle.process.ExecOperations

// AGP 9 compiles Kotlin with its built-in Kotlin support; only the Compose compiler plugin is added.
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

/**
 * Build types that carry the development assets and the scripted diagnostics: "debug", and "benchmark" (2026-10-07,
 * completion plan A1), which is debug's content compiled and run like release (not debuggable, so ART optimises as it
 * does for the shipped app; profileable from the shell for simpleperf). Every Android drag-frame timing before this was
 * measured on the debuggable APK, which ART runs without its optimisations.
 */
fun isInternalBuild(buildType: String) = buildType == "debug" || buildType == "benchmark"

// --- Depth model release gate -----------------------------------------------------------------
//
// "pending legal sign-off (training data)": Depth Anything V2 Small (Apache-2.0 weights,
// depth-anything/Depth-Anything-V2-Small-hf@5426e4f; our LiteRT conversion, docs/v1/depth-evaluation.md)
// is packaged into debug builds when the local conversion exists, and into release builds only with
// -PlightlyDepthLegalSignOff=true. Without it the app wires no estimator and shows the approved
// unavailable state. The file is git-ignored and checked against its recorded SHA-256 when bundled.
val depthModelFile: File = (findProperty("lightlyDepthModelFile") as String?)?.let(::File)
    ?: rootDir.parentFile.resolve("experiments/depth/models/converted/da2_small_518x392_wi8.tflite")
val depthModelSha256 = "8e719085ce210eb4fb8e737ae9bca4f25e4e35b3aeafb80c468c3ff6c4eb8078"
val depthLegalSignOff = (findProperty("lightlyDepthLegalSignOff") as String?) == "true"
fun depthModelEnabled(buildType: String) = depthModelFile.isFile && (isInternalBuild(buildType) || depthLegalSignOff)

// --- Remove model release gate ----------------------------------------------------------------
//
// "pending legal sign-off (training data: Places2)": LaMa big-lama (Apache-2.0 code and weights,
// advimman/lama @ 786f593; weights big-lama.zip from the README-linked mirror
// huggingface.co/smartywu/big-lama @ 05cb2be7, SHA-256 f1b358ca…75f6), our LiteRT fp32 conversion
// (experiments/inpaint/convert_tflite.py, docs/v1/remove-evaluation.md §6). Packaged into debug builds
// when the local conversion exists, into release builds only with -PlightlyRemoveLegalSignOff=true.
// Without it every Remove stroke shows the approved failure state; nothing else fills. The file is
// git-ignored and checked against its recorded SHA-256 when bundled.
val removeModelFile: File = (findProperty("lightlyRemoveModelFile") as String?)?.let(::File)
    ?: rootDir.parentFile.resolve("experiments/inpaint/models/exported/lama_512_fp32.tflite")
val removeModelSha256 = "39fa82d6a2b576de99b30481c85d73d48955f126deb7bea8504e58b15b43ca0e"
val removeLegalSignOff = (findProperty("lightlyRemoveLegalSignOff") as String?) == "true"
fun removeModelEnabled(buildType: String) = removeModelFile.isFile && (isInternalBuild(buildType) || removeLegalSignOff)

// --- Vision models (faces, landmarks, people, person matte) ---------------------------------------
//
// MediaPipe .tflite models (Apache-2.0, consented training data per their model cards) run on the LiteRT
// runtime above, without MediaPipe Tasks and its Firelog telemetry (docs/v1/android-vision-evaluation.md
// §1–§3). They are read from experiments/android-vision/models (git-ignored; scripts/prepare_assets.sh
// fetches and verifies them), each checked against its SHA-256; the landmark and pose models are
// extracted from their .task bundles and checked again. Debug builds package them when present.
// Release builds package them only with -PlightlyVisionModels=true: the D3 resolution in
// docs/v1/release/dependencies.md item 3 is the owner's to record. Without them Portrait stays
// hidden in release and Background shows the approved failure state for subjects.
val visionModelsDirectory: File = (findProperty("lightlyVisionModelsDir") as String?)?.let(::File)
    ?: rootDir.parentFile.resolve("experiments/android-vision/models")
/** Asset name → (source file, its SHA-256, entry inside a .task zip or null, the entry's SHA-256). */
val visionModels = mapOf(
    "blaze_face_full_range.tflite" to listOf("blaze_face_full_range.tflite", "3698b18f063835bc609069ef052228fbe86d9c9a6dc8dcb7c7c2d69aed2b181b", "", ""),
    "face_landmarks_detector.tflite" to listOf("face_landmarker.task", "64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff",
        "face_landmarks_detector.tflite", "c7d54204ce0448474c7f3fa9af494787c0965cbdd6f20fc72867e43046bd43d5"),
    "pose_detector.tflite" to listOf("pose_landmarker_lite.task", "59929e1d1ee95287735ddd833b19cf4ac46d29bc7afddbbf6753c459690d574a",
        "pose_detector.tflite", "46837eb883e6ec75b52c5f5ff6a9b78bd35e66c13f95e8c3566c582d146cb1d9"),
    // The selfie segmenter with its one MediaPipe custom op (Convolution2DTransposeBias) replaced by the builtin
    // TRANSPOSE_CONV (experiments/android-vision/scripts/patch_selfie_segmenter.py, from the original
    // 191ac952…658b; outputs equal within 1.6e-12): LiteRT's built-in kernels lack the custom op, and the
    // arm64 emulator cannot use XNNPACK, which implements it.
    "selfie_segmenter.tflite" to listOf("selfie_segmenter_builtin.tflite", "400dd25939e56f7374f2aa2345ddf31ded21f525627cbeb707a4f022ba90ef2d", "", ""),
)
/**
 * Optional vision models: packaged with the others when their source file is present, never required.
 * MODNet portrait matting (experiments/android-vision/scripts/convert_modnet.py, Apache-2.0; training data
 * undocumented: counsel before release, same gate as the models above): the person matte with hair detail
 * that replaces the selfie segmenter's soft mask for Background; without it the selfie segmenter is used.
 * U²-Netp class-agnostic subject saliency (experiments/android-vision/scripts/convert_u2netp.py, Apache-2.0;
 * training data DUTS-TR without an explicit licence: counsel before release, same gate): Background's subject for
 * photos without people (boats, animals) and its "No clear subject" decision; without it those photos show the
 * approved "Couldn't separate the subject" state. Experimental (docs/v1/android-vision-evaluation.md §5).
 */
val optionalVisionModels = mapOf(
    "portrait_matte.tflite" to listOf("modnet_photographic_512_fp16.tflite", "4b57ff612f1a78d331af496f30eca2f10ae64cd47c4e90ed001f65b2a9d8d078", "", ""),
    "subject_saliency.tflite" to listOf("u2netp_320_fp32.tflite", "40655434570d0716e005904f2f833f6a87856ed2ac26a26d529c7234a3fe399e", "", ""),
)
val visionModelsRelease = (findProperty("lightlyVisionModels") as String?) == "true"
fun visionModelsEnabled(buildType: String) =
    visionModels.values.all { visionModelsDirectory.resolve(it[0]).isFile } && (isInternalBuild(buildType) || visionModelsRelease)

/** Marketing version and build number shared with iOS (version.properties, scripts/version.sh). */
/** "1.0.0", or "1.0.0-dev" when ios/, android/ or shared/ has uncommitted changes (scripts/version.sh decides both). */
val lightlyMarketingVersion: String = providers.exec {
    commandLine("bash", rootDir.parentFile.resolve("scripts/version.sh").path)
}.standardOutput.asText.get().trim().substringBefore(" ")
val lightlyBuildNumber: Int = ((findProperty("lightlyBuildNumber") as String?) ?: providers.exec {
    commandLine("bash", rootDir.parentFile.resolve("scripts/version.sh").path, "--build")
}.standardOutput.asText.get().trim()).toInt()

android {
    namespace = "com.lightlylabs.lightly"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.lightlylabs.lightly"
        // Spec U6 (revised after Codex M1 finding 8): the IS_PENDING save path needs API 29.
        minSdk = 29
        targetSdk = 36
        // version.properties and scripts/version.sh, shared with iOS: marketing version and the git-derived build
        // number (YYMMDD + the commit's three-digit sequence that day). -PlightlyBuildNumber overrides it.
        versionCode = lightlyBuildNumber
        versionName = lightlyMarketingVersion
    }

    buildFeatures {
        compose = true
        // About shows versionName (versionCode); debug-only launch options read BuildConfig.DEBUG.
        buildConfig = true
    }

    buildTypes {
        getByName("debug") {
            buildConfigField("boolean", "DEPTH_MODEL_ENABLED", depthModelEnabled("debug").toString())
            buildConfigField("boolean", "REMOVE_MODEL_ENABLED", removeModelEnabled("debug").toString())
            buildConfigField("boolean", "VISION_MODELS_ENABLED", visionModelsEnabled("debug").toString())
            // Scripted launch scenarios, capture hook and diagnostic logs (DebugLaunchOptions); never in release.
            buildConfigField("boolean", "DIAGNOSTICS", "true")
        }
        create("benchmark") {
            initWith(getByName("debug"))
            isDebuggable = false
            signingConfig = signingConfigs.getByName("debug")
            // The library modules have only debug and release: link their release (optimised) variants.
            matchingFallbacks += listOf("release")
            buildConfigField("boolean", "DIAGNOSTICS", "true")
        }
        getByName("release") {
            buildConfigField("boolean", "DEPTH_MODEL_ENABLED", depthModelEnabled("release").toString())
            buildConfigField("boolean", "REMOVE_MODEL_ENABLED", removeModelEnabled("release").toString())
            buildConfigField("boolean", "VISION_MODELS_ENABLED", visionModelsEnabled("release").toString())
            buildConfigField("boolean", "DIAGNOSTICS", "false")
        }
    }

    // The benchmark build uses debug's capture hook (src/debug) and adds <profileable> (src/benchmark).
    sourceSets.getByName("benchmark").kotlin.srcDir("src/debug/kotlin")

    // The depth and Remove models are memory-mapped from the APK, which needs them stored uncompressed.
    androidResources { noCompress += "tflite" }

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
    implementation(project(":core-background"))
    implementation(project(":core-vision"))
    implementation(project(":core-session"))
    implementation(project(":core-develop"))
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
    implementation(libs.litert)

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

// --- Look pack, format 3 (docs/v1/preset-pack.md) ------------------------------------------------
//
// The Develop catalogue's recipes: shared/look-pack/build_pack.py writes manifest.json (formatVersion
// 3, one recipe per preset, no per-preset LUTs) into the git-ignored shared/look-pack/out/. It is
// copied verbatim into every variant's assets under lookpack/, together with the rendering contract
// (shared/contracts/rendering-v2.json), whose developModel holds the calibrated constants the device
// bakes each preset's 33³ LUT with. The app refuses a pack whose model digest differs from the
// contract's, and so does this task, at build time.
// Lookup order:
//   1. -PlightlyLookPackDir=/abs/path (or LIGHTLY_LOOK_PACK_DIR) holding manifest.json.
//   2. This checkout's shared/look-pack/out.
//   3. Inside a git worktree at <main>/.claude/worktrees/<name>, the main checkout's out/.
// v3 differs: format 2 (experiments/presets/look_pack/out, 18 Looks as .f32 LUTs) is retired, and a
// build WITHOUT a pack now fails: Develop is the core of the editor, so an APK without presets is broken.
val lookPackRelativePath = "shared/look-pack/out"
val renderingContractFile: File = rootDir.parentFile.resolve("shared/contracts/rendering-v2.json")
val lookPackDirectory: File? = resolveLookPackDirectory()

fun resolveLookPackDirectory(): File? {
    val explicit = providers.gradleProperty("lightlyLookPackDir")
        .orElse(providers.environmentVariable("LIGHTLY_LOOK_PACK_DIR"))
        .orNull
    if (explicit != null) {
        val directory = file(explicit)
        if (!directory.resolve("manifest.json").isFile) {
            throw GradleException("lightlyLookPackDir=$explicit has no manifest.json (build it with shared/look-pack/build_pack.py)")
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

// The pack and contract tests read the real files in place.
tasks.withType<Test>().configureEach {
    // The catalogue test parses the real approved catalogue in place.
    systemProperty("lightly.presetCatalogue", presetCatalogueFile.absolutePath)
    inputs.file(presetCatalogueFile).withPathSensitivity(PathSensitivity.NONE).withPropertyName("presetCatalogue")
    systemProperty("lightly.renderingContract", renderingContractFile.absolutePath)
    inputs.file(renderingContractFile).withPathSensitivity(PathSensitivity.NONE).withPropertyName("renderingContract")
    lookPackDirectory?.let { pack ->
        systemProperty("lightly.lookPackDir", pack.absolutePath)
        inputs.property("lookPackManifest", pack.resolve("manifest.json").absolutePath)
    }
}

/**
 * The facts both pack checks need: the manifest's formatVersion, and whether its developModel digest
 * equals the contract's. Read with Groovy's JSON parser (a 6.5 MB manifest parses in well under 1 s).
 * An object (not a script function) so the task classes, which are not inner classes, can call it.
 */
object LookPackFacts {
    @Suppress("UNCHECKED_CAST")
    fun read(manifestText: String, contractText: String): Pair<Int, Boolean> {
        val manifest = groovy.json.JsonSlurper().parseText(manifestText) as Map<String, Any?>
        val contract = groovy.json.JsonSlurper().parseText(contractText) as Map<String, Any?>
        val packDigest = (manifest["developModel"] as? Map<String, Any?>)?.get("constantsSha256")
        val contractDigest = (contract["developModel"] as? Map<String, Any?>)?.get("constantsSha256")
        return ((manifest["formatVersion"] as? Number)?.toInt() ?: -1) to (packDigest != null && packDigest == contractDigest)
    }
}

/**
 * rendering-v2 revision this app implements (contract fixes 2: stage order C1/C2, perspective C3, light leak C4;
 * fixes 1 unchanged): revision 1 moved background.focus
 * `maxBlurRadius` from `params` to `constants` (0.06). Bundling or shipping any other revision fails.
 */
object RenderingContractFacts {
    const val SUPPORTED_REVISION = 6

    @Suppress("UNCHECKED_CAST")
    fun problems(contractText: String): List<String> {
        val contract = groovy.json.JsonSlurper().parseText(contractText) as Map<String, Any?>
        val out = ArrayList<String>()
        val revision = (contract["revision"] as? Number)?.toInt()
        if (revision != SUPPORTED_REVISION) out += "rendering-v2 revision $revision, this app implements $SUPPORTED_REVISION"
        val focus = (contract["stages"] as? List<Map<String, Any?>>)?.firstOrNull { it["id"] == "background.focus" }
        val constants = ((focus?.get("operators") as? List<Map<String, Any?>>)?.firstOrNull()?.get("constants")) as? Map<String, Any?>
        val maxBlur = ((constants?.get("maxBlurRadius") as? Map<String, Any?>)?.get("value") as? Number)?.toDouble()
        if (maxBlur != 0.06) out += "background.focus constants.maxBlurRadius is $maxBlur, expected 0.06"
        return out
    }
}

/** Copies manifest.json and the rendering contract into a generated assets root, after checking them. */
abstract class BundleLookPackTask : DefaultTask() {
    @get:Optional
    @get:InputFile
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val manifestFile: RegularFileProperty

    @get:InputFile
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val contractFile: RegularFileProperty

    @get:OutputDirectory
    abstract val assetsDirectory: DirectoryProperty

    @TaskAction
    fun bundle() {
        val manifest = manifestFile.orNull?.asFile
            ?: throw GradleException("No look pack: build shared/look-pack/out/manifest.json with shared/look-pack/build_pack.py, or pass -PlightlyLookPackDir")
        val contract = contractFile.get().asFile
        val (format, digestMatches) = LookPackFacts.read(manifest.readText(), contract.readText())
        if (format != 3) throw GradleException("$manifest is look-pack format $format; this app reads format 3 only")
        if (!digestMatches) throw GradleException("$manifest was built for other Develop model constants than $contract")
        RenderingContractFacts.problems(contract.readText()).takeIf { it.isNotEmpty() }?.let { throw GradleException("$contract: ${it.joinToString("; ")}") }
        val assetsRoot = assetsDirectory.get().asFile
        assetsRoot.deleteRecursively()
        manifest.copyTo(assetsRoot.resolve("lookpack/manifest.json"))
        contract.copyTo(assetsRoot.resolve("lookpack/rendering-v2.json"))
    }
}

/** Fails unless the BUILT apk carries a format-3 pack and the contract that matches it. */
abstract class VerifyLookPackTask : DefaultTask() {
    @get:InputFiles
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val apkDirectory: DirectoryProperty

    @get:Internal
    abstract val builtArtifactsLoader: Property<BuiltArtifactsLoader>

    @get:OutputFile
    abstract val reportFile: RegularFileProperty

    @TaskAction
    fun verify() {
        val artifacts = builtArtifactsLoader.get().load(apkDirectory.get()) ?: throw GradleException("No apk metadata in ${apkDirectory.get()}")
        val report = artifacts.elements.joinToString("\n") { element ->
            val apk = File(element.outputFile)
            ZipFile(apk).use { zip ->
                fun text(path: String) = zip.getEntry(path)?.let { entry -> zip.getInputStream(entry).use { it.readBytes().toString(Charsets.UTF_8) } }
                    ?: throw GradleException("Look pack check failed for ${apk.name}: $path is not in the apk")
                val manifest = text("assets/lookpack/manifest.json")
                val contract = text("assets/lookpack/rendering-v2.json")
                val (format, digestMatches) = LookPackFacts.read(manifest, contract)
                if (format != 3 || !digestMatches) throw GradleException("Look pack check failed for ${apk.name}: format $format, model digest matches: $digestMatches")
                RenderingContractFacts.problems(contract).takeIf { it.isNotEmpty() }?.let { throw GradleException("Contract check failed for ${apk.name}: ${it.joinToString("; ")}") }
                "${apk.name}: look pack format 3, ${manifest.length} bytes, model digest OK, rendering-v2 revision ${RenderingContractFacts.SUPPORTED_REVISION}"
            }
        }
        reportFile.get().asFile.writeText(report + "\n")
    }
}

// --- Develop catalogue (Lightly 1.0) ---------------------------------------------------------------
//
// presets/develop-design-ui.json is the approved category/stop catalogue (ids, display names). It is
// versioned in the repository and bundled verbatim under assets/catalogue/, so the app and the design
// read the same ids (favourites in slice 1; Develop in slice 2). A missing file fails the build.
val presetCatalogueFile: File = rootDir.parentFile.resolve("presets/develop-design-ui.json")
/** Readable preset display names shared with iOS (shared/look-pack/display_names.py), bundled as catalogue/display-names.json. */
val presetDisplayNamesFile: File = rootDir.parentFile.resolve("shared/look-pack/names/display-names.json")

abstract class BundlePresetCatalogueTask : DefaultTask() {
    @get:InputFile
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val catalogueFile: RegularFileProperty

    @get:InputFile
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val displayNamesFile: RegularFileProperty

    @get:OutputDirectory
    abstract val assetsDirectory: DirectoryProperty

    @TaskAction
    fun bundle() {
        val assetsRoot = assetsDirectory.get().asFile
        assetsRoot.deleteRecursively()
        catalogueFile.get().asFile.copyTo(assetsRoot.resolve("catalogue/develop-design-ui.json"))
        displayNamesFile.get().asFile.copyTo(assetsRoot.resolve("catalogue/display-names.json"))
    }
}

// --- Bundled background photos (Background › Change background › Image) -------------------------
//
// The approved prototype offers four bundled background photos (docs/ui/app/data.js BACKGROUNDS) from
// the licensed sample set. Their licence for redistribution in a released app is not confirmed, so they
// are packaged into DEBUG builds only (release builds show the same row without them, reported as a
// blocker in docs/v1/slice3-android.md). Read in place from docs/ui/assets/photos; never copied into git.
abstract class BundleBackgroundPhotosTask : DefaultTask() {
    @get:InputFiles
    @get:PathSensitive(PathSensitivity.NAME_ONLY)
    abstract val photos: ConfigurableFileCollection

    @get:OutputDirectory
    abstract val assetsDirectory: DirectoryProperty

    @TaskAction
    fun bundle() {
        val root = assetsDirectory.get().asFile
        root.deleteRecursively()
        photos.files.forEach { it.copyTo(root.resolve("backgrounds/${it.name}")) }
    }
}

/** Copies a gated model (depth, Remove) into assets/models/ after checking its SHA-256 (release gates above). */
abstract class BundleDepthModelTask : DefaultTask() {
    @get:InputFile
    @get:PathSensitive(PathSensitivity.NAME_ONLY)
    abstract val modelFile: RegularFileProperty

    @get:Input
    abstract val expectedSha256: Property<String>

    @get:OutputDirectory
    abstract val assetsDirectory: DirectoryProperty

    @TaskAction
    fun bundle() {
        val model = modelFile.get().asFile
        val digest = MessageDigest.getInstance("SHA-256")
        model.inputStream().use { input -> val buffer = ByteArray(1 shl 16); while (true) { val n = input.read(buffer); if (n < 0) break; digest.update(buffer, 0, n) } }
        val actual = digest.digest().joinToString("") { "%02x".format(it) }
        if (actual != expectedSha256.get()) throw GradleException("Model ${model.name} has SHA-256 $actual, expected ${expectedSha256.get()}")
        val root = assetsDirectory.get().asFile
        root.deleteRecursively()
        model.copyTo(root.resolve("models/${model.name}"))
    }
}

/**
 * The vision models into assets/vision: each source file's SHA-256 is checked, .task bundles are opened
 * and only the named entry is copied, after checking its own SHA-256. A mismatch fails the build.
 */
abstract class BundleVisionModelsTask : DefaultTask() {
    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val modelsDirectory: DirectoryProperty

    /** asset name → "source|sha256|entry|entrySha256" (entry empty for a plain .tflite). */
    @get:Input
    abstract val models: MapProperty<String, String>

    @get:OutputDirectory
    abstract val assetsDirectory: DirectoryProperty

    @TaskAction
    fun bundle() {
        val root = assetsDirectory.get().asFile
        root.deleteRecursively()
        val target = root.resolve("vision").apply { mkdirs() }
        for ((asset, spec) in models.get()) {
            val (source, sha, entry, entrySha) = spec.split("|")
            val file = modelsDirectory.get().asFile.resolve(source)
            check(file.name, sha256(file.readBytes()), sha)
            val bytes = if (entry.isEmpty()) file.readBytes() else ZipFile(file).use { zip ->
                val found = zip.getEntry(entry) ?: throw GradleException("${file.name} has no entry $entry")
                zip.getInputStream(found).use { it.readBytes() }
            }
            if (entry.isNotEmpty()) check("${file.name}!$entry", sha256(bytes), entrySha)
            target.resolve(asset).writeBytes(bytes)
        }
    }

    private fun sha256(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun check(name: String, actual: String, expected: String) {
        if (actual != expected) throw GradleException("Vision model $name has SHA-256 $actual, expected $expected")
    }
}

// --- Merged-manifest privacy check ----------------------------------------------------------------
//
// LiteRT approval condition: the merged manifest gains no INTERNET permission, no Google datatransport
// and no telemetry/analytics components. Checks the merged manifest of every variant.
abstract class VerifyManifestPrivacyTask : DefaultTask() {
    @get:InputFile
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val mergedManifest: RegularFileProperty

    @get:OutputFile
    abstract val reportFile: RegularFileProperty

    @TaskAction
    fun verify() {
        val manifest = mergedManifest.get().asFile.readText()
        val forbidden = listOf(
            "android.permission.INTERNET", "android.permission.ACCESS_NETWORK_STATE", "datatransport",
            "firebase", "com.google.android.gms.measurement", "analytics", "telemetry", "crashlytics",
        )
        val found = forbidden.filter { manifest.contains(it, ignoreCase = true) }
        if (found.isNotEmpty()) throw GradleException("Merged manifest contains forbidden entries: ${found.joinToString()}")
        reportFile.get().asFile.writeText("OK: none of ${forbidden.joinToString()}\n")
    }
}

/**
 * The four approved watermark fonts and their OFL licences (shared/fonts; the OFL requires the licence to
 * ship with the fonts), copied into assets/fonts at build time after checking shared/fonts/SHA256SUMS.
 * No private copies live under android/.
 */
abstract class BundleWatermarkFontsTask : DefaultTask() {
    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val fontsDirectory: DirectoryProperty

    @get:OutputDirectory
    abstract val assetsDirectory: DirectoryProperty

    @TaskAction
    fun bundle() {
        val source = fontsDirectory.get().asFile
        val sums = source.resolve("SHA256SUMS").readLines().filter { it.isNotBlank() }.associate { line ->
            val (digest, name) = line.trim().split(Regex("\\s+"), limit = 2)
            name.removePrefix("*") to digest
        }
        val root = assetsDirectory.get().asFile
        root.deleteRecursively()
        source.listFiles { f -> f.name.endsWith(".ttf") || f.name.endsWith("-OFL.txt") }!!.forEach { file ->
            if (file.name.endsWith(".ttf")) {
                val expected = sums[file.name] ?: throw GradleException("${file.name} is not in shared/fonts/SHA256SUMS")
                val actual = MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }
                if (actual != expected) throw GradleException("${file.name} has SHA-256 $actual, expected $expected")
            }
            file.copyTo(root.resolve("fonts/${file.name}"))
        }
    }
}

val backgroundPhotoNames = listOf("landscape_01", "sunset_03", "wellexposed_02", "backlit_02")

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
            lookPackDirectory?.let { manifestFile.set(it.resolve("manifest.json")) }
            contractFile.set(renderingContractFile)
        }
        variant.sources.assets?.addGeneratedSourceDirectory(bundleLookPack, BundleLookPackTask::assetsDirectory)

        val bundleFonts = tasks.register<BundleWatermarkFontsTask>("bundle${variantName}WatermarkFonts") {
            fontsDirectory.set(rootDir.parentFile.resolve("shared/fonts"))
        }
        variant.sources.assets?.addGeneratedSourceDirectory(bundleFonts, BundleWatermarkFontsTask::assetsDirectory)

        val bundleCatalogue = tasks.register<BundlePresetCatalogueTask>("bundle${variantName}PresetCatalogue") {
            catalogueFile.set(presetCatalogueFile)
            displayNamesFile.set(presetDisplayNamesFile)
        }
        variant.sources.assets?.addGeneratedSourceDirectory(bundleCatalogue, BundlePresetCatalogueTask::assetsDirectory)

        if (isInternalBuild(variant.buildType ?: "")) {
            val bundleBackgrounds = tasks.register<BundleBackgroundPhotosTask>("bundle${variantName}BackgroundPhotos") {
                val folder = rootDir.parentFile.resolve("docs/ui/assets/photos")
                photos.from(backgroundPhotoNames.flatMap { listOf(folder.resolve("$it.jpg"), folder.resolve("${it}_thumb.jpg")) })
            }
            variant.sources.assets?.addGeneratedSourceDirectory(bundleBackgrounds, BundleBackgroundPhotosTask::assetsDirectory)
        }

        if (depthModelEnabled(variant.buildType ?: "")) {
            val bundleDepthModel = tasks.register<BundleDepthModelTask>("bundle${variantName}DepthModel") {
                modelFile.set(depthModelFile)
                expectedSha256.set(depthModelSha256)
            }
            variant.sources.assets?.addGeneratedSourceDirectory(bundleDepthModel, BundleDepthModelTask::assetsDirectory)
        }

        if (removeModelEnabled(variant.buildType ?: "")) {
            val bundleRemoveModel = tasks.register<BundleDepthModelTask>("bundle${variantName}RemoveModel") {
                modelFile.set(removeModelFile)
                expectedSha256.set(removeModelSha256)
            }
            variant.sources.assets?.addGeneratedSourceDirectory(bundleRemoveModel, BundleDepthModelTask::assetsDirectory)
        }

        if (visionModelsEnabled(variant.buildType ?: "")) {
            val bundleVisionModels = tasks.register<BundleVisionModelsTask>("bundle${variantName}VisionModels") {
                modelsDirectory.set(visionModelsDirectory)
                models.set((visionModels + optionalVisionModels.filterValues { visionModelsDirectory.resolve(it[0]).isFile }).mapValues { (_, v) -> v.joinToString("|") })
            }
            variant.sources.assets?.addGeneratedSourceDirectory(bundleVisionModels, BundleVisionModelsTask::assetsDirectory)
        }

        val verifyPrivacy = tasks.register<VerifyManifestPrivacyTask>("verify${variantName}ManifestPrivacy") {
            mergedManifest.set(variant.artifacts.get(SingleArtifact.MERGED_MANIFEST))
            reportFile.set(layout.buildDirectory.file("reports/manifest-privacy/${variant.name}.txt"))
        }

        val verifyIcon = tasks.register<VerifyLauncherIconTask>("verify${variantName}LauncherIcon") {
            apkDirectory.set(variant.artifacts.get(SingleArtifact.APK))
            builtArtifactsLoader.set(variant.artifacts.getBuiltArtifactsLoader())
            aapt2.set(aapt2Executable)
            reportFile.set(layout.buildDirectory.file("reports/launcher-icon/${variant.name}.txt"))
        }
        val verifyPack = tasks.register<VerifyLookPackTask>("verify${variantName}LookPack") {
            apkDirectory.set(variant.artifacts.get(SingleArtifact.APK))
            builtArtifactsLoader.set(variant.artifacts.getBuiltArtifactsLoader())
            reportFile.set(layout.buildDirectory.file("reports/look-pack/${variant.name}.txt"))
        }
        tasks.matching { it.name == "assemble$variantName" }.configureEach { dependsOn(verifyIcon, verifyPack, verifyPrivacy) }
    }
}
