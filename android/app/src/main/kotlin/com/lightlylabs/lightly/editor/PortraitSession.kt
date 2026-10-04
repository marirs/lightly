package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.background.FloatPlane
import com.lightlylabs.lightly.background.PlaneOps
import com.lightlylabs.lightly.develop.PixelRect
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.session.PortraitTool
import com.lightlylabs.lightly.vision.DetectedFace
import com.lightlylabs.lightly.vision.PeopleAnalysis
import com.lightlylabs.lightly.vision.Point
import com.lightlylabs.lightly.vision.PortraitRenderer
import com.lightlylabs.lightly.vision.RgbaImage
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Portrait for one photo: the people analysis (run once when the photo opens), the person matte (run
 * once, the first time Hair & Beard needs it, as iOS `ensurePersonMatte`), and stage 9 for previews
 * and Save copy.
 */
class PortraitSession {
    @Volatile var people: PeopleAnalysis? = null
        private set

    /** The person matte at the analysis size it was computed at; resized per render size on demand. */
    @Volatile private var personMatte: FloatPlane? = null
    @Volatile private var resizedMatte: FloatPlane? = null

    fun reset() {
        people = null
        personMatte = null
        resizedMatte = null
    }

    fun setPeople(analysis: PeopleAnalysis?) { people = analysis }

    val usableFaces: List<DetectedFace> get() = people?.usableFaces.orEmpty()

    val hasPersonMatte get() = personMatte != null

    fun setPersonMatte(matte: FloatPlane?) {
        personMatte = matte
        resizedMatte = null
    }

    /** True when the recipe changes a usable face (stage 9 runs). */
    fun isActive(tool: PortraitTool): Boolean = activeFaces(tool).isNotEmpty()

    /** True when Hair & Beard needs the person matte and it has not been computed. */
    fun needsPersonMatte(tool: PortraitTool): Boolean = personMatte == null &&
        activeFaces(tool).any { it.edit.hair.definition > 0 || it.edit.hair.flyaways > 0 || it.edit.hair.shine > 0 }

    private fun activeFaces(tool: PortraitTool): List<PortraitRenderer.Face> = usableFaces.mapNotNull { face ->
        tool.faces.firstOrNull { PortraitEdits.matches(it, face) }?.takeIf(PortraitRenderer::hasChanges)?.let { PortraitRenderer.Face(face, it) }
    }

    /** Stage 9 on a whole image in source coordinates (previews: the display proxy). */
    fun render(image: Rgba8Image, tool: PortraitTool): Rgba8Image {
        val faces = activeFaces(tool)
        if (faces.isEmpty()) return image
        val out = PortraitRenderer.render(RgbaImage(image.width, image.height, image.pixels), faces, matteFor(image.width, image.height))
        return Rgba8Image(out.width, out.height, out.pixels)
    }

    private fun matteFor(width: Int, height: Int): FloatPlane? {
        val matte = personMatte ?: return null
        if (matte.width == width && matte.height == height) return matte
        resizedMatte?.takeIf { it.width == width && it.height == height }?.let { return it }
        return PlaneOps.resizeBilinear(matte, width, height).also { resizedMatte = it }
    }

    /** One face's retouch for Save copy: the crop region (frame pixels) and its per-channel change. */
    class Patch(val region: PixelRect, val delta: ShortArray)

    /**
     * Save copy: one patch per changed face at full resolution. [renderRegion] returns the developed
     * pixels (every stage before Portrait) of a full-resolution source region.
     *
     * A patch stores the CHANGE the retouch made, not the crop's pixels, so a tile developed slightly
     * differently from the crop (an approximated Clarity base) never shows a seam at the crop's edge:
     * outside the face's feathered regions the change is zero.
     *
     * Each face's crop is retouched at most [EXPORT_CROP_LONG_EDGE] px on its long edge; when the crop is
     * larger, the retouch is computed on a downscaled copy and its change is upsampled onto the
     * full-resolution crop. Approximate in the same way as Background's export (one render at the
     * analysis size), and bounded in memory: the operators hold about 16 float planes of the crop.
     */
    fun exportPatches(tool: PortraitTool, frameWidth: Int, frameHeight: Int, renderRegion: (PixelRect) -> Rgba8Image): List<Patch> {
        val patches = ArrayList<Patch>()
        for (face in activeFaces(tool)) {
            val c = PortraitRenderer.cropFor(face.detected, frameWidth, frameHeight)
            val region = PixelRect(c[0], c[1], c[2] - c[0], c[3] - c[1])
            // Crops of neighbouring faces overlap (group photos): each face starts from the earlier faces'
            // results, as in the preview, where faces are retouched one after the other.
            val developed = renderRegion(region)
            applyPatches(developed.pixels, region, patches)
            val retouched = retouchCrop(developed, region, frameWidth, frameHeight, face)
            patches += Patch(region, ShortArray(retouched.size) { i -> ((retouched[i].toInt() and 0xff) - (developed.pixels[i].toInt() and 0xff)).toShort() })
        }
        return patches
    }

    private fun retouchCrop(crop: Rgba8Image, region: PixelRect, frameWidth: Int, frameHeight: Int, face: PortraitRenderer.Face): ByteArray {
        val local = remap(face.detected, region, frameWidth, frameHeight)
        val scale = min(1.0, EXPORT_CROP_LONG_EDGE.toDouble() / max(crop.width, crop.height))
        val matte = personMatte?.let { m -> cropMatte(m, region, frameWidth, frameHeight) }
        if (scale >= 1.0) {
            val matteHere = matte?.let { PlaneOps.resizeBilinear(it, crop.width, crop.height) }
            return PortraitRenderer.render(RgbaImage(crop.width, crop.height, crop.pixels), listOf(PortraitRenderer.Face(local, face.edit)), matteHere).pixels
        }
        val w = max(1, (crop.width * scale).roundToInt())
        val h = max(1, (crop.height * scale).roundToInt())
        val small = BackgroundSession.resize(crop, w, h)
        val retouched = PortraitRenderer.render(RgbaImage(w, h, small.pixels), listOf(PortraitRenderer.Face(local, face.edit)), matte?.let { PlaneOps.resizeBilinear(it, w, h) })
        val out = crop.pixels.copyOf()
        val deltas = Array(3) { c -> PlaneOps.resizeBilinear(FloatPlane(w, h, FloatArray(w * h) { i -> ((retouched.pixels[i * 4 + c].toInt() and 0xff) - (small.pixels[i * 4 + c].toInt() and 0xff)).toFloat() }), crop.width, crop.height) }
        for (i in 0 until crop.width * crop.height) for (c in 0 until 3) {
            val d = deltas[c].values[i]
            if (d == 0f) continue
            out[i * 4 + c] = ((out[i * 4 + c].toInt() and 0xff) + d).roundToInt().coerceIn(0, 255).toByte()
        }
        return out
    }

    private fun cropMatte(matte: FloatPlane, region: PixelRect, frameWidth: Int, frameHeight: Int): FloatPlane {
        val sx = matte.width.toDouble() / frameWidth
        val sy = matte.height.toDouble() / frameHeight
        val w = max(1, (region.width * sx).roundToInt())
        val h = max(1, (region.height * sy).roundToInt())
        return FloatPlane(w, h, FloatArray(w * h) { i -> matte.sample(region.x * sx + i % w, region.y * sy + i / w) })
    }

    companion object {
        const val EXPORT_CROP_LONG_EDGE = 2048

        /** [face] in the coordinates of a [region] of the frame (normalised to the region). */
        fun remap(face: DetectedFace, region: PixelRect, frameWidth: Int, frameHeight: Int): DetectedFace {
            fun x(v: Double) = (v * frameWidth - region.x) / region.width
            fun y(v: Double) = (v * frameHeight - region.y) / region.height
            val b = face.box
            val box = DetectedFace.clampedRect(x(b.x), y(b.y), b.width * frameWidth / region.width, b.height * frameHeight / region.height)
            return face.copy(box = box, landmarks = face.landmarks.map { Point(x(it.x), y(it.y)) })
        }

        /** Adds the patches' changes that overlap a tile (tile pixels, frame coordinates) to it, in place. */
        fun applyPatches(tile: ByteArray, tileRect: PixelRect, patches: List<Patch>) {
            for (patch in patches) {
                val region = patch.region
                val x0 = max(tileRect.x, region.x)
                val y0 = max(tileRect.y, region.y)
                val x1 = min(tileRect.x + tileRect.width, region.x + region.width)
                val y1 = min(tileRect.y + tileRect.height, region.y + region.height)
                if (x0 >= x1 || y0 >= y1) continue
                for (y in y0 until y1) for (x in x0 until x1) {
                    val p = ((y - region.y) * region.width + (x - region.x)) * 4
                    val t = ((y - tileRect.y) * tileRect.width + (x - tileRect.x)) * 4
                    for (c in 0 until 3) {
                        val d = patch.delta[p + c].toInt()
                        if (d != 0) tile[t + c] = ((tile[t + c].toInt() and 0xff) + d).coerceIn(0, 255).toByte()
                    }
                }
            }
        }
    }
}
