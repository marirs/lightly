import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// Pure Kotlin/JVM: on-device vision for Portrait and Background (docs/v1/android-vision-evaluation.md).
// The MediaPipe .tflite models run on LiteRT in :app behind [TensorModel]; everything around them
// (letterboxing, SSD anchors, decoding, weighted NMS, landmark ROIs and their mapping back to the
// photo, matte upsampling and refinement) and Portrait's retouching operators live here, so they are
// tested on the JVM without a device.
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
    // FloatPlane / PlaneOps (mattes) and the SubjectSegmenter contract.
    api(project(":core-background"))
    // Recipe types: tools.portrait (FaceEdit), NormalisedRect, ModelRef.
    api(project(":core-session"))
    // OKLab (ColourMath) for the Portrait operators.
    implementation(project(":core-develop"))
    testImplementation(kotlin("test-junit"))
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.core)
}
