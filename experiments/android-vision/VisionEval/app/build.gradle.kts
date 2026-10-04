// Standalone evaluation harness for on-device face detection and subject segmentation.
// Own application id: never installed over, or alongside as a replacement of, com.lightlylabs.lightly.
// AGP 9 compiles Kotlin with its built-in Kotlin support; no kotlin-android plugin is applied.
plugins {
    id("com.android.application")
}

// One flavour per SDK family so the APK size impact of each dependency can be measured in
// isolation (`all` is the flavour actually installed for the evaluation run).
android {
    namespace = "com.lightlylabs.visioneval"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.lightlylabs.visioneval"
        minSdk = 28 // ImageDecoder; both target phones are far above this
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
        // Both target phones are arm64; keep size measurements comparable to a real arm64 split.
        ndk { abiFilters += listOf("arm64-v8a") }
    }

    flavorDimensions += "sdk"
    productFlavors {
        create("all") { dimension = "sdk" }
        create("none") { dimension = "sdk" }
        create("mlkitFace") { dimension = "sdk" }
        create("mlkitFaceMesh") { dimension = "sdk" }
        create("mlkitSelfie") { dimension = "sdk" }
        create("mlkitSubject") { dimension = "sdk" }
        create("mediapipe") { dimension = "sdk" }
    }

    buildTypes {
        release {
            // Timings must come from a non-debuggable build. R8 is enabled so the per-flavour
            // APK sizes approximate what a shipping app would pay for each dependency.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            isDebuggable = false
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    sourceSets {
        // Candidate code lives in one source dir per SDK so each size-probe flavour compiles exactly
        // the candidates of its own SDK (and R8 keeps what a real integration would keep), while
        // `all` compiles every candidate. Photos and models are assets of `all` only, so the probe
        // APKs measure SDK code + native libraries without the evaluation payload.
        val sdkSourceDirs = mapOf(
            "mlkitFace" to listOf("src/sdkMlkitFace/java"),
            "mlkitFaceMesh" to listOf("src/sdkMlkitFaceMesh/java"),
            "mlkitSelfie" to listOf("src/sdkMlkitSelfie/java"),
            "mlkitSubject" to listOf("src/sdkMlkitSubject/java"),
            "mediapipe" to listOf("src/sdkMediapipe/java"),
        )
        sdkSourceDirs.forEach { (flavourName, dirs) -> getByName(flavourName).kotlin.srcDirs(dirs) }
        getByName("all").kotlin.srcDirs(sdkSourceDirs.values.flatten())
    }

    androidResources {
        // .tflite/.task must stay uncompressed so MediaPipe can memory-map them from the APK.
        noCompress += listOf("tflite", "task")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

val mlkitFaceDetection = "com.google.mlkit:face-detection:16.1.7"
val mlkitFaceMesh = "com.google.mlkit:face-mesh-detection:16.0.0-beta3"
val mlkitSelfieSegmentation = "com.google.mlkit:segmentation-selfie:16.0.0-beta6"
val mlkitSubjectSegmentation = "com.google.android.gms:play-services-mlkit-subject-segmentation:16.0.0-beta1"
val mediapipeTasksVision = "com.google.mediapipe:tasks-vision:1.0.0"

dependencies {
    "allImplementation"(mlkitFaceDetection)
    "allImplementation"(mlkitFaceMesh)
    "allImplementation"(mlkitSelfieSegmentation)
    "allImplementation"(mlkitSubjectSegmentation)
    "allImplementation"(mediapipeTasksVision)

    "mlkitFaceImplementation"(mlkitFaceDetection)
    "mlkitFaceMeshImplementation"(mlkitFaceMesh)
    "mlkitSelfieImplementation"(mlkitSelfieSegmentation)
    "mlkitSubjectImplementation"(mlkitSubjectSegmentation)
    "mediapipeImplementation"(mediapipeTasksVision)
}
