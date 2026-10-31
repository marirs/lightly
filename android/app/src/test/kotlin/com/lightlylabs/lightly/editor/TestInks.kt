package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.develop.InkKind
import com.lightlylabs.lightly.develop.InkPack
import com.lightlylabs.lightly.develop.InkPackEntry
import com.lightlylabs.lightly.render.image.Rgba8Image

/** A small stand-in ink pack for JVM tests: a stroke ink (a white bar across a black mask) and an overlay ink (mid grey). */
object TestInks {
    const val STROKE = "ink-000000000001"
    const val OVERLAY = "ink-000000000002"

    /** 40 × 20: 255 in the middle rows, so the photo shows through a horizontal bar and the rest is paper. */
    private fun bar(): Rgba8Image = Rgba8Image(40, 20, ByteArray(40 * 20 * 4) { i -> if (i % 4 == 3) -1 else if ((i / 4) / 40 in 6..13) -1 else 0 })
    private fun grey(): Rgba8Image = Rgba8Image(40, 20, ByteArray(40 * 20 * 4) { i -> if (i % 4 == 3) -1 else 128.toByte() })

    val library: InkLibrary by lazy {
        val pack = InkPack(listOf(
            InkPackEntry(STROKE, "Dry Sweep", InkKind.STROKE, "img/$STROKE.png", "thumb/$STROKE.png", "0".repeat(64), 40, 20),
            InkPackEntry(OVERLAY, "Splatter", InkKind.OVERLAY, "img/$OVERLAY.jpg", "thumb/$OVERLAY.jpg", "0".repeat(64), 40, 20),
        ))
        // The "file" names its ink; decoding makes that ink's image.
        InkLibrary(pack, readFile = { path -> byteArrayOf(if (path.contains(STROKE)) 0 else 1) }, decode = { bytes -> if (bytes[0].toInt() == 0) bar() else grey() })
    }
}
