import java.security.MessageDigest

// Enhance (1.3) models as a Play install-time asset pack (owner decision 2026-11-13: every model ships with the app).
// CodeFormer alone is 360 MB, past what the base module can carry, so release bundles deliver the models in this pack:
// Play installs it together with the app, and its assets join the app's own (context.assets reads assets/enhance/*
// exactly as in debug builds, which carry the same files in the app module instead; APKs built with assemble* never
// include asset packs). The app adds this pack to release bundles unless -PlightlyEnhanceModelsInRelease=false (app/build.gradle.kts, Enhance gate).
// The asset-pack plugin ships inside the Android Gradle plugin already on the build classpath (root build.gradle.kts),
// so it is applied by id without a version of its own.
plugins {
    id("com.android.asset-pack")
}

assetPack {
    packName.set("enhance_models")
    dynamicDelivery {
        deliveryType.set("install-time")
    }
}

val enhanceModelsDirectory: File = (findProperty("lightlyEnhanceModelsDir") as String?)?.let(::File)
    ?: rootDir.parentFile.resolve("experiments/enhance-2026-11-12/tflite")
val enhanceModels: Map<String, String> = file("models.sha256").readLines()
    .filter { it.isNotBlank() && !it.startsWith("#") }
    .associate { line -> line.trim().split(Regex("\\s+")).let { (name, sha) -> name to sha } }

// The asset-pack plugin reads src/main/assets only, so the checked copies are written there (git-ignored).
val packAssets = layout.projectDirectory.dir("src/main/assets/enhance")
val prepareEnhanceModels = tasks.register("prepareEnhanceModels") {
    description = "Copies the Enhance models into this pack's assets, each checked against its SHA-256."
    inputs.files(enhanceModels.keys.map { enhanceModelsDirectory.resolve(it) })
    inputs.property("models", enhanceModels)
    outputs.dir(packAssets)
    doLast {
        val target = packAssets.asFile
        target.deleteRecursively()
        target.mkdirs()
        for ((name, expected) in enhanceModels) {
            val source = enhanceModelsDirectory.resolve(name)
            if (!source.isFile) throw GradleException("Enhance model $name missing from $enhanceModelsDirectory")
            val digest = MessageDigest.getInstance("SHA-256")
            source.inputStream().use { input ->
                val buffer = ByteArray(1 shl 16)
                while (true) { val n = input.read(buffer); if (n < 0) break; digest.update(buffer, 0, n) }
            }
            val actual = digest.digest().joinToString("") { "%02x".format(it) }
            if (actual != expected) throw GradleException("Enhance model $name has SHA-256 $actual, expected $expected")
            source.copyTo(target.resolve(name))
        }
    }
}

// The pack's assets must be in place before the app's bundle reads them.
tasks.named("generateAssetPackManifest") { dependsOn(prepareEnhanceModels) }
