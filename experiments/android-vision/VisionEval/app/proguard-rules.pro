# MediaPipe Tasks ships no consumer R8 rules; its native graph runner reaches Java classes and
# protobuf-lite messages by name through JNI/reflection, so they must survive shrinking.
-keep class com.google.mediapipe.** { *; }
-keep class com.google.protobuf.** { *; }
-dontwarn com.google.mediapipe.**
-dontwarn com.google.protobuf.**
-dontwarn javax.lang.model.**
-dontwarn com.google.auto.value.**
-dontwarn org.checkerframework.**
-dontwarn com.google.errorprone.annotations.**
-dontwarn com.google.j2objc.annotations.**
-dontwarn org.codehaus.mojo.animal_sniffer.**
# Candidates are discovered through the per-flavour CandidateRegistry, which R8 can see; keep the
# harness entry point names stable for adb `am start`.
-keep class com.lightlylabs.visioneval.MainActivity { *; }
# Flogger (tasks-core's logger) finds its caller by class name on the stack; R8 renaming made
# com.google.mediapipe.framework.Graph.<clinit> throw "no caller found on the stack" (2026-10-04).
-keep class com.google.common.flogger.** { *; }
-keepnames class com.google.mediapipe.** { *; }
