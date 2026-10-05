package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.develop.AdjustParams
import com.lightlylabs.lightly.develop.AdjustStage
import com.lightlylabs.lightly.develop.BorderParams
import com.lightlylabs.lightly.develop.BorderStage
import com.lightlylabs.lightly.develop.DevelopModel
import com.lightlylabs.lightly.develop.DevelopRenderPlan
import com.lightlylabs.lightly.develop.DevelopRenderer
import com.lightlylabs.lightly.develop.EffectsParams
import com.lightlylabs.lightly.develop.EffectsStage
import com.lightlylabs.lightly.develop.FrameView
import com.lightlylabs.lightly.develop.GeometryParams
import com.lightlylabs.lightly.develop.GeometryTransform
import com.lightlylabs.lightly.develop.KeptColour
import com.lightlylabs.lightly.develop.LowResPlane
import com.lightlylabs.lightly.develop.PixelRect
import com.lightlylabs.lightly.export.ExportRenderPlan
import com.lightlylabs.lightly.export.ExportTileRenderer
import com.lightlylabs.lightly.render.gpu.Tile
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.session.EditState
import com.lightlylabs.lightly.session.RemoveStatus
import java.util.concurrent.ExecutorService
import kotlin.math.max

/** The recipe's Edit and Effects sections as the render stages' plain values. */
object EditMapping {
    fun geometry(state: EditState): GeometryParams {
        val g = state.tools.edit.geometry
        return GeometryParams(g.quarterTurns, g.flipHorizontal, g.flipVertical, g.perspective.vertical, g.perspective.horizontal, g.straighten,
            g.crop.rect.x, g.crop.rect.y, g.crop.rect.width, g.crop.rect.height)
    }

    fun adjust(state: EditState): AdjustParams {
        val a = state.tools.edit.adjust
        return AdjustParams(a.exposure, a.contrast, a.highlights, a.shadows, a.temp, a.tint, a.saturation, a.vibrance, a.sharpness, a.clarity, a.noise)
    }

    fun effects(state: EditState): EffectsParams {
        val e = state.tools.effects
        return EffectsParams(
            e.lightLeak.enabled, e.lightLeak.style.name.lowercase(), e.lightLeak.intensity, e.lightLeak.x, e.lightLeak.y, e.lightLeak.rotation,
            e.grain.enabled, e.grain.style.name.lowercase(), e.grain.amount, e.grain.size, e.grain.roughness, e.grain.seed,
            e.vignette.enabled, e.vignette.amount, e.vignette.size, e.vignette.softness,
            selectiveColours = e.selectiveColour?.colours.orEmpty().map { KeptColour(it.oklab[0], it.oklab[1], it.oklab[2]) },
            selectiveRange = e.selectiveColour?.range ?: 40.0,
            selectiveStrength = e.selectiveColour?.strength ?: 100.0,
        )
    }

    fun border(state: EditState): BorderParams {
        val b = state.tools.border
        return BorderParams(b.type.name.lowercase(), b.colour, b.width, b.spacing, b.mat)
    }

    /** The applied strokes' patch digests, in order. */
    fun patchDigests(state: EditState): List<String> =
        state.tools.edit.remove.strokes.filter { it.result.status == RemoveStatus.APPLIED }.mapNotNull { it.result.patch?.sha256 }

    /**
     * True when a slice-4 or slice-5 stage changes pixels (Edit, Effects, Border, Watermark). Otherwise the slice-2/3
     * path runs unchanged (the preset's finishing inside the Develop pass), so their renders and captures
     * stay valid.
     */
    fun usesEditOrEffects(state: EditState): Boolean =
        !geometry(state).isIdentity || !adjust(state).isNeutral || patchDigests(state).isNotEmpty() || effects(state).anyEnabled || !border(state).isNone ||
            state.tools.watermark.type != com.lightlylabs.lightly.session.WatermarkType.NONE
}

/**
 * Every stage of a recipe that uses Edit or Effects, in this order:
 * Remove patches → Auto (1) → Look (2, 3) → Adjust (5) → Background (7, 8) → geometry (4) → Effects with
 * the preset's finishing (10) → Border (11, frame → canvas) → Watermark (12, canvas).
 */
// CONTRACT GAP (reported, as iOS C1/C2): rendering-v2 §1 orders geometry (4) before Adjust (5), Remove
// (6) and Background (7–8). This port, like iOS:
// - replays Remove patches on the source before stage 1, as remove-evaluation §7 specifies ("on the
//   full-resolution source pixels, before tone and colour adjustments"), so a later tone or colour
//   change never needs the model again;
// - runs Adjust and Background in source coordinates, then geometry: the subject matte and depth are
//   in source coordinates. Colour is per pixel, so only resolution-relative radii differ: Detail's and
//   Focus & Blur's radii follow the uncropped long edge instead of the cropped frame's.
/**
 * Stage 12: the watermark for a canvas of this size with the photo at [imageRect] (canvas pixels), or null
 * when there is none (or its saved signature is missing or changed: never substituted).
 */
fun interface WatermarkPainter {
    fun layer(canvasWidth: Int, canvasHeight: Int, imageRect: PixelRect): WatermarkLayer?
}

class EditPipeline(
    private val model: DevelopModel,
    private val renderer: DevelopRenderer,
    private val executor: ExecutorService? = null,
    private val parallelism: Int = 1,
    private val watermark: WatermarkPainter? = null,
) {
    /**
     * The whole frame from a preview-size [source] (patches already composited). [developPlan] is the
     * Develop plan of the recipe (finishing included; it is moved to the effects stage here).
     * [background] composes Background on the developed, adjusted source-coordinate image, if active.
     */
    fun renderPreview(source: Rgba8Image, state: EditState, developPlan: DevelopRenderPlan, background: ((Rgba8Image) -> Rgba8Image)?): Rgba8Image {
        val withoutFinishing = developPlan.withoutFinishing()
        var image = if (withoutFinishing.isIdentity) source else renderer.render(source, withoutFinishing)
        AdjustStage.plan(EditMapping.adjust(state), model, executor = executor, parallelism = parallelism)?.let { image = renderer.render(image, it) }
        background?.let { image = it(image) }
        image = GeometryTransform(EditMapping.geometry(state), image.width, image.height).render(image)
        image = EffectsStage(EditMapping.effects(state), developPlan.finishing, model, image.width, image.height).apply(image)
        val border = EditMapping.border(state)
        val placement = BorderStage.placement(border, image.width, image.height)
        val canvas = BorderStage.apply(border, image)
        // Stage 12, on the canvas after the border.
        return watermark?.layer(canvas.width, canvas.height, PixelRect(placement.side, placement.top, image.width, image.height))?.compositeOnto(canvas) ?: canvas
    }

    /**
     * Save copy of the same recipe at full resolution, tile by tile of the OUTPUT frame. Each frame tile
     * reads the source region its geometry maps to (plus the Adjust Detail apron), renders Develop and
     * Adjust there, composes Background, resamples into the tile and applies Effects at frame coordinates.
     */
    fun exportPlan(
        state: EditState,
        developPlan: DevelopRenderPlan,
        patches: List<RemovePatch>,
        /** Prepares Background for a full frame: returns a composer of developed source regions, or null. */
        background: ((frame: Rgba8Image) -> ((pixels: ByteArray, region: PixelRect, frameWidth: Int, frameHeight: Int) -> ByteArray)?)?,
    ): ExportRenderPlan = ExportRenderPlan { frame ->
        // The export owns its decode: patches are composited into it in place (no second full frame).
        RemoveEngine.composite(patches, frame, inPlace = true)
        val plan = developPlan.withoutFinishing()
        val base = renderer.clarityBase(frame, plan)
        val adjustPlan = AdjustStage.plan(EditMapping.adjust(state), model, executor = executor, parallelism = parallelism)
        val adjustBase = adjustPlan?.let { adjustClarityBase(frame, plan, it) }
        val adjustApron = adjustPlan?.let { renderer.apron(it, frame.width, frame.height) } ?: 0
        val compose = background?.invoke(frame)
        val geometry = GeometryTransform(EditMapping.geometry(state), frame.width, frame.height)
        val effects = EffectsStage(EditMapping.effects(state), developPlan.finishing, model, geometry.frameWidth, geometry.frameHeight)
        val border = EditMapping.border(state)
        val placement = BorderStage.placement(border, geometry.frameWidth, geometry.frameHeight)

        /** One tile of the frame (stages 1–10), in frame coordinates. */
        fun frameTile(source: Rgba8Image, out: PixelRect): Rgba8Image {
            val region = geometry.sourceBounds(out)
            var pixels = renderRegion(source, region, plan, base, adjustPlan, adjustBase, adjustApron)
            compose?.let { pixels = Rgba8Image(region.width, region.height, it(pixels.pixels, region, source.width, source.height)) }
            val framed = if (geometry.isIdentity) pixels else geometry.renderTile(pixels, region.x, region.y, out)
            return effects.apply(framed, out.x, out.y)
        }
        object : ExportTileRenderer {
            // Stage 11 makes the canvas: the frame plus the border.
            override fun outputSize(source: Rgba8Image) = placement.canvasWidth to placement.canvasHeight

            // Stage 12: rendered once for the whole canvas (it is only the watermark's box), composited per tile.
            private val layer = watermark?.layer(placement.canvasWidth, placement.canvasHeight, PixelRect(placement.side, placement.top, placement.frameWidth, placement.frameHeight))

            override fun renderTile(frame: Rgba8Image, tile: Tile): Rgba8Image {
                val out = PixelRect(tile.x, tile.y, tile.width, tile.height)
                val canvas = if (border.isNone) frameTile(frame, out) else BorderStage.renderTile(border, placement, out) { region -> frameTile(frame, region) }
                return layer?.compositeOnto(canvas, out.x, out.y) ?: canvas
            }
        }
    }

    /** Develop then Adjust for one source region. */
    private fun renderRegion(frame: Rgba8Image, region: PixelRect, plan: DevelopRenderPlan, base: LowResPlane?, adjustPlan: DevelopRenderPlan?, adjustBase: LowResPlane?, adjustApron: Int): Rgba8Image {
        if (adjustPlan == null) return renderer.renderTile(frame, region, plan, base)
        // The Adjust pass reads its apron from Develop's output, so Develop renders the region grown by it.
        val x0 = max(0, region.x - adjustApron)
        val y0 = max(0, region.y - adjustApron)
        val grown = PixelRect(x0, y0, minOf(frame.width, region.x + region.width + adjustApron) - x0, minOf(frame.height, region.y + region.height + adjustApron) - y0)
        val developed = renderer.renderTile(frame, grown, plan, base)
        return renderer.renderView(FrameView(developed, grown.x, grown.y, frame.width, frame.height), region, adjustPlan, adjustBase)
    }

    /**
     * Adjust › Clarity's very large blur for the whole developed frame. The full developed frame is never
     * held: the base is computed on a copy of the source at [CLARITY_BASE_LONG_EDGE] and rescaled.
     * Clarity's σ is about 5 % of the long edge, far above what the downscale removes.
     */
    private fun adjustClarityBase(frame: Rgba8Image, plan: DevelopRenderPlan, adjustPlan: DevelopRenderPlan): LowResPlane? {
        if (adjustPlan.spatial.clarity == 0.0) return null
        val longEdge = max(frame.width, frame.height)
        val scale = minOf(1.0, CLARITY_BASE_LONG_EDGE.toDouble() / longEdge)
        val small = if (scale < 1.0) BackgroundSession.resize(frame, max(1, (frame.width * scale).toInt()), max(1, (frame.height * scale).toInt())) else frame
        val developed = if (plan.isIdentity) small else renderer.render(small, plan)
        return renderer.clarityBase(developed, adjustPlan)?.rescaled(frame.width.toDouble() / small.width)
    }

    companion object {
        const val CLARITY_BASE_LONG_EDGE = 1024
    }
}
