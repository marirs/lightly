# R8 for release builds (Play Console, 2026-10-19: "DEX code optimization is below our threshold", obfuscation 1 %).
# The libraries ship their own consumer rules (LiteRT's @UsedByReflection, kotlinx.serialization, Compose); these are
# the app's own reflective and native edges.

# Our XNNPACK delegate (src/main/jni): JNI binds the native methods by class and method name.
-keepclasseswithmembernames class com.lightlylabs.lightly.editor.ThreadedXnnpackDelegate { native <methods>; }

# LiteRT's interpreter looks up delegate and tensor classes from native code.
-keep class org.tensorflow.lite.** { *; }
-dontwarn org.tensorflow.lite.**

# Crash reports stay readable with the uploaded mapping file (Play Console › App bundle explorer).
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
