package com.lightlylabs.lightly.editor.enhance

import com.lightlylabs.lightly.render.image.Rgba8Image
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.zip.DeflaterOutputStream
import java.util.zip.InflaterInputStream

/** What Edit › Enhance runs (EditorViewModel): the engine in the app, a stand-in in JVM tests. */
fun interface Enhancer {
    /** Throws [EnhanceEngine.Failure.Cancelled] once [isCancelled] is true; [progress] gets 0..1. */
    fun enhance(photo: Rgba8Image, isCancelled: () -> Boolean, progress: (Double) -> Unit): EnhanceOutput
}

/** An Enhance run's result: twice the photo (the 2000 px cap applied first), and whether it was taken for a painting. */
class EnhanceOutput(val image: Rgba8Image, val painting: Boolean)

/**
 * Edit › Enhance results (rendering-v2 §7.6), by digest: the recipe's `edit.enhance.result` is a derivedRef to one of
 * them. Stored lossless (RGBA deflated, fastest level: the result is the source of every later stage and of the saved
 * copy, so it must come back bit for bit), in app-private no-backup storage beside the Remove patches.
 * The digest is the SHA-256 of the width, height and pixels, so it never depends on the compressor.
 */
class EnhanceResultStore(private val directory: File? = null) {
    private val memory = ConcurrentHashMap<String, Rgba8Image>()

    /** Stores [image] and returns its digest; a failed write keeps it for this process (never re-enhanced silently). */
    fun put(image: Rgba8Image): String {
        val digest = digest(image)
        directory?.let { dir -> runCatching { write(dir, digest, image) }.onFailure { memory[digest] = image } } ?: run { memory[digest] = image }
        return digest
    }

    /** The stored result, or null when it is unknown, missing or corrupt (its pixels no longer match the digest). */
    operator fun get(digest: String): Rgba8Image? = memory[digest] ?: directory?.let { dir ->
        runCatching { read(File(dir, "${safe(digest)}$SUFFIX")) }.getOrNull()?.takeIf { digest(it) == digest }
    }

    /** Forgets the results kept in memory (another photo is loading); the files stay for a restore. */
    fun clearMemory() = memory.clear()

    /** Deletes every stored result: a new photo was chosen, so no recovery can name them again. */
    fun clearAll() {
        memory.clear()
        directory?.listFiles { file -> file.name.endsWith(SUFFIX) || file.name.endsWith(".tmp") }?.forEach { it.delete() }
    }

    private fun write(dir: File, digest: String, image: Rgba8Image) {
        dir.mkdirs()
        val target = File(dir, "${safe(digest)}$SUFFIX")
        if (target.isFile) return
        val temporary = File(dir, "${safe(digest)}.tmp")
        val deflater = java.util.zip.Deflater(java.util.zip.Deflater.BEST_SPEED)
        try {
            DataOutputStream(DeflaterOutputStream(temporary.outputStream().buffered(1 shl 16), deflater, 1 shl 16)).use { out ->
                out.writeInt(MAGIC); out.writeInt(image.width); out.writeInt(image.height)
                out.write(image.pixels)
            }
        } finally { deflater.end() }
        check(temporary.renameTo(target)) { "could not store the Enhance result" }
    }

    private fun read(file: File): Rgba8Image = DataInputStream(InflaterInputStream(file.inputStream().buffered(1 shl 16), java.util.zip.Inflater(), 1 shl 16)).use { input ->
        check(input.readInt() == MAGIC) { "not an Enhance result" }
        val width = input.readInt()
        val height = input.readInt()
        require(width in 1..MAX_SIDE && height in 1..MAX_SIDE) { "Enhance result size ${width}x$height" }
        val pixels = ByteArray(width * height * 4)
        input.readFully(pixels)
        Rgba8Image(width, height, pixels)
    }

    companion object {
        private const val SUFFIX = ".enhanced"
        private const val MAGIC = 0x4C454E31   // "LEN1"
        /** Twice the 2000 px cap. */
        private const val MAX_SIDE = 2 * EnhanceEngine.INPUT_LONG_SIDE_MAX

        /** Digests are hex; anything else never names a file. */
        private fun safe(digest: String) = if (digest.all { it in "0123456789abcdef" }) digest else "invalid"

        fun digest(image: Rgba8Image): String {
            val sha = MessageDigest.getInstance("SHA-256")
            sha.update(java.nio.ByteBuffer.allocate(8).putInt(image.width).putInt(image.height).array())
            sha.update(image.pixels)
            return sha.digest().joinToString("") { "%02x".format(it) }
        }
    }
}
