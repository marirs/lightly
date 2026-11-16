"""Pulls the image-maths section out of an EnhancePipeline.kt into a JVM-only file in the given package."""
import re, sys
source, package, out = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(source).read()
maths = text[text.index("// Image maths"):]
maths = re.sub(r"private class Face\(.*?\n}\n", "", maths, flags=re.S)
maths = maths.replace("private fun", "internal fun").replace("private class", "internal class").replace("private val", "internal val")
header = f"package {package}\nimport kotlin.math.*\nimport java.util.stream.IntStream\nimport java.nio.ByteBuffer\nimport java.nio.ByteOrder\n"
open(out, "w").write(header + maths)
