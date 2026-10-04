package com.lightlylabs.lightly.shell

import android.content.Intent
import com.lightlylabs.lightly.BuildConfig
import com.lightlylabs.lightly.editor.AutoState
import com.lightlylabs.lightly.editor.DevelopUi
import com.lightlylabs.lightly.editor.EditorOverlay
import com.lightlylabs.lightly.editor.EditorPhase
import com.lightlylabs.lightly.editor.EditorViewModel
import com.lightlylabs.lightly.editor.PersonPresence
import java.io.File
import com.lightlylabs.lightly.prefs.Appearance
import com.lightlylabs.lightly.prefs.PreferencesStore

/**
 * Debug builds only: opens a given slice-1 screen directly, so the scripted emulator comparison can
 * capture every screen without tapping through. Release builds ignore the extras entirely
 * (BuildConfig.DEBUG is a compile-time false there, so this is dead code R8 removes).
 *
 * ```
 * adb shell am start -n com.lightlylabs.lightly/.MainActivity \
 *   --es lightly.debug.screen preferences --es lightly.debug.favourites look-a,look-b \
 *   --es lightly.debug.appearance dark
 * ```
 * Screens: welcome, camera-denied, load-failed, and every [MorePage] name in lower case
 * (more, preferences, favourites, signature, preferred_border, legal, privacy, terms, about, support).
 *
 * Slice 2 editor states: `--es lightly.debug.photo <absolute path in the app's external files folder>`
 * opens that file as the photo, `--es lightly.debug.editor <prototype screen id>` (dev-preset, dev-amount, …)
 * sets the session as the prototype's screen registry does, and `--es lightly.debug.people present|absent`
 * stands in for the pending person detector (D3) so Portrait matches the reference photo.
 *
 * Every Auto state other than "unavailable" is INJECTED here for layout comparison only: no Auto model
 * ships (D1), so the photo is never corrected; captures made this way are labelled in
 * docs/v1/slice2-android.md.
 */
object DebugLaunchOptions {
    private const val EXTRA_SCREEN = "lightly.debug.screen"
    private const val EXTRA_FAVOURITES = "lightly.debug.favourites"
    private const val EXTRA_APPEARANCE = "lightly.debug.appearance"

    private const val EXTRA_PHOTO = "lightly.debug.photo"
    private const val EXTRA_EDITOR = "lightly.debug.editor"
    private const val EXTRA_PEOPLE = "lightly.debug.people"

    /** One capture state, read from launch extras or (persistent capture runner) a broadcast's extras. */
    data class Request(
        val screen: String?,
        val photo: String?,
        val editor: String?,
        val people: String?,
        val favourites: String?,
        val appearance: String?,
        val benchmark: Boolean = false,
    ) {
        companion object {
            fun from(intent: Intent) = Request(
                screen = intent.getStringExtra(EXTRA_SCREEN),
                photo = intent.getStringExtra(EXTRA_PHOTO),
                editor = intent.getStringExtra(EXTRA_EDITOR),
                people = intent.getStringExtra(EXTRA_PEOPLE),
                favourites = intent.getStringExtra(EXTRA_FAVOURITES),
                appearance = intent.getStringExtra(EXTRA_APPEARANCE),
                benchmark = intent.getBooleanExtra("lightly.debug.benchmark", false),
            )
        }
    }

    fun apply(intent: Intent?, shell: AppViewModel, preferences: PreferencesStore, editor: EditorViewModel): kotlinx.coroutines.Job? {
        if (!BuildConfig.DEBUG || intent == null) return null
        // D3 functional check: `--es lightly.debug.visionProbe <folder>` (see VisionProbe).
        intent.getStringExtra("lightly.debug.visionProbe")?.let { folder -> return com.lightlylabs.lightly.editor.VisionProbe.run(File(folder)) }
        return apply(Request.from(intent), shell, preferences, editor)
    }

    /**
     * Applies [request] to freshly created view models. Returns the job that finishes when the editor
     * state is configured (null when nothing asynchronous was started), so the capture runner can wait
     * for it before it waits for the render.
     */
    fun apply(request: Request, shell: AppViewModel, preferences: PreferencesStore, editor: EditorViewModel): kotlinx.coroutines.Job? {
        if (!BuildConfig.DEBUG) return null
        // Watermark and Saved signature screens show the prototype's sample signature as saved.
        if (request.screen == "signature" || request.editor?.startsWith("wm-") == true || request.editor == "bd-polaroid") editor.debugSeedSignatures()
        val editorJob = applyEditor(request, shell, editor)
        request.favourites?.let { ids ->
            preferences.update { it.copy(favouritePresetIds = ids.split(",").filter(String::isNotBlank).take(5)) }
        }
        // Lets the comparison switch light/dark in-app instead of toggling the system night mode,
        // which restarts System UI on every switch.
        request.appearance?.let { name ->
            Appearance.entries.firstOrNull { it.name.equals(name, ignoreCase = true) }?.let { appearance -> preferences.update { it.copy(appearance = appearance) } }
        }
        val screen = request.screen ?: return editorJob
        val state = when (screen) {
            "welcome" -> AppNavigator.toWelcome()
            "camera-denied" -> AppNavigator.showCameraDenied()
            "load-failed" -> AppNavigator.showLoadFailed()
            "welcome-privacy" -> AppNavigator.openPrivacyFromWelcome(AppNavigator.toWelcome())
            else -> MorePage.entries.firstOrNull { it.name.lowercase() == screen }?.let { AppNavigator.openPage(AppNavigator.toWelcome(), it) }
        } ?: return editorJob
        shell.navigate(state)
        return editorJob
    }

    private fun applyEditor(request: Request, shell: AppViewModel, editor: EditorViewModel): kotlinx.coroutines.Job? {
        val path = request.photo ?: return null
        val screen = request.editor ?: "model-unavailable"
        editor.debugPresence = when (request.people) {
            "present" -> PersonPresence.PRESENT
            "absent" -> PersonPresence.ABSENT
            else -> null
        }
        editor.debugHoldLoading = screen == "loading" || screen == "developing"
        editor.debugHoldSeparation = screen == "bg-separating"
        editor.debugFailSeparation = screen == "bg-failed"
        editor.debugHoldRemove = screen == "ed-removing"
        editor.openPhoto("file://" + File(path).absolutePath)
        shell.navigate(if (screen == "more") AppNavigator.openMore(AppNavigator.openEditor()) else AppNavigator.openEditor())
        if (screen == "developing") {
            editor.debugSetPhase(EditorPhase.Developing)
            return null
        }
        if (screen == "loading") return null
        if (request.benchmark) {
            editor.debugBenchmark { line -> android.util.Log.i("LightlyBench", line) }
            return null
        }
        return editor.applyDebugState { api ->
            val auto = when (screen) {
                "model-unavailable" -> AutoState.UNAVAILABLE
                "develop-failed" -> AutoState.FAILED
                "dev-original" -> AutoState.OFF
                else -> AutoState.APPLIED // injected, see the class comment
            }
            api.setAuto(auto)
            fun preset(category: String, stop: Int, amount: Int = 100) = api.applyPreset(category, stop, amount)
            when (screen) {
                "developed" -> api.setUi { it.copy(toast = "Developed") }
                "dev-preset", "dev-starred" -> preset("landscape", 37)
                // Prototype `edited`: Landscape 37 and the Effects vignette on (closes the M5 equivalent:
                // the Effects dot and the vignette show on these screens, as approved).
                "compare", "saving", "saved", "leave-unsaved", "more" -> { preset("landscape", 37); api.effects { it.copy(vignette = it.vignette.copy(enabled = true)) } }
                "dev-dragging" -> {
                    preset("landscape", 37)
                    val target = api.library?.pack?.category("landscape")?.presets?.getOrNull(40)
                    api.setUi { it.copy(develop = DevelopUi(dragStop = 41, fine = true)) }
                    target?.let { api.preview(globalOnly = true, look = com.lightlylabs.lightly.session.LookRef(it.id, it.lookVersion, 1f)) }
                }
                "dev-browse" -> { preset("landscape", 37); api.setUi { it.copy(develop = DevelopUi(category = "cinematic", dragStop = 0)) } }
                "dev-large" -> preset("cinematic", 564)
                "dev-long-name" -> {
                    val stop = api.library?.pack?.category("landscape")?.presets?.indexOfFirst { it.displayName == "Landscape 15 - Winter Wonderland" }?.plus(1) ?: 0
                    if (stop > 0) preset("landscape", stop)
                }
                "dev-amount" -> { preset("landscape", 37, amount = 70); api.setUi { it.copy(develop = DevelopUi(amountOpen = true), rememberedAmounts = emptyMap()) } }
                "dev-favourites" -> { preset("portrait", 13); api.setUi { it.copy(develop = DevelopUi(category = "favourites")) } }
                "dev-fav-full" -> { preset("travel", 5); api.setUi { it.copy(develop = DevelopUi(favouritesFull = true)) } }
                "dev-fav-replace" -> { preset("travel", 5); api.setUi { it.copy(overlay = EditorOverlay.FAVOURITE_REPLACE) } }
                "dev-bw" -> preset("black-white", 8)
                "dev-landscape-photo" -> preset("golden-hour", 12)
                "dev-portrait-photo", "bg-failed" -> preset("portrait", 13)
            }
            applySlice4(api, screen)
            applyBorder(api, screen)
            applyWatermark(api, screen)
            // ed-remove rebases once the real removal has finished (see applySlice4).
            if (screen == "ed-remove" || screen == "s4-export") return@applyDebugState
            // History starts at the configured recipe (Undo disabled, as on the prototype's screens);
            // "Leaving with unsaved changes" keeps the recipe unsaved.
            api.rebaseHistory(keepUnsaved = screen == "leave-unsaved")
            when (screen) {
                "compare" -> api.setUi { it.copy(compareToggled = true) }
                "saving" -> api.setUi { it.copy(overlay = EditorOverlay.SAVING) }
                "saved" -> api.setUi { it.copy(overlay = EditorOverlay.SAVED) }
                "leave-unsaved" -> api.setUi { it.copy(overlay = EditorOverlay.LEAVE) }
                // Slice 3: bg-separating holds the real separation; bg-failed injects its failure (debugFailSeparation),
                // because with the vision models the woman photo now separates.
                "bg-separating", "bg-failed" -> api.openBackground(com.lightlylabs.lightly.editor.BackgroundSub.CHANGE)
                "bg-no-subject" -> api.openBackground(com.lightlylabs.lightly.editor.BackgroundSub.FOCUS)
                // docs/ui/app/screens.js: blur 55, and the style for bg-soft / bg-swirl / bg-motion.
                "bg-focus", "bg-soft", "bg-swirl", "bg-motion" -> {
                    val style = when (screen) {
                        "bg-soft" -> com.lightlylabs.lightly.session.FocusStyle.SOFT
                        "bg-swirl" -> com.lightlylabs.lightly.session.FocusStyle.SWIRL
                        "bg-motion" -> com.lightlylabs.lightly.session.FocusStyle.MOTION
                        else -> null
                    }
                    api.openBackground(com.lightlylabs.lightly.editor.BackgroundSub.FOCUS) { api.focus(55.0, style); api.rebaseHistory() }
                }
                else -> applySubjectAndPortrait(api, screen)
            }
        }
    }

    /**
     * docs/ui/app/screens.js, the `bg-*` screens that need a subject matte and the `pt-*` setups, applied as
     * the user would once the real separation and people analysis have run (D3, the vision models).
     */
    private fun applySubjectAndPortrait(api: EditorViewModel.DebugEditorApi, screen: String) {
        val bg = com.lightlylabs.lightly.editor.BackgroundOptions
        val firstImage = { tool: com.lightlylabs.lightly.session.BackgroundTool ->
            tool.copy(replacement = com.lightlylabs.lightly.session.Replacement.Image(com.lightlylabs.lightly.session.AssetRef.Bundled(bg.IMAGES[0].first), 50.0, 50.0, 120.0))
        }
        fun change(kind: com.lightlylabs.lightly.editor.ReplacementKind, replace: (com.lightlylabs.lightly.session.BackgroundTool) -> com.lightlylabs.lightly.session.BackgroundTool) =
            api.openBackground(com.lightlylabs.lightly.editor.BackgroundSub.CHANGE) {
                api.background(replace)
                api.setUi { it.copy(background = it.background.copy(kind = kind)) }
                api.rebaseHistory()
            }
        val face = { tab: com.lightlylabs.lightly.editor.PortraitTab, settings: List<Pair<String, Double>> ->
            api.openPortrait(tab)
            settings.forEach { (field, value) -> api.portrait(field, value) }
            api.rebaseHistory()
        }
        when (screen) {
            "bg-refine" -> api.openBackground(com.lightlylabs.lightly.editor.BackgroundSub.FOCUS) {
                api.focus(55.0, null)
                api.setUi { it.copy(background = it.background.copy(sub = com.lightlylabs.lightly.editor.BackgroundSub.REFINE)) }
                api.rebaseHistory()
            }
            "bg-change-image" -> change(com.lightlylabs.lightly.editor.ReplacementKind.IMAGE, firstImage)
            "bg-change-colour" -> change(com.lightlylabs.lightly.editor.ReplacementKind.COLOUR) { it.copy(replacement = com.lightlylabs.lightly.session.Replacement.Colour(bg.SWATCHES[3])) }
            "bg-change-gradient" -> change(com.lightlylabs.lightly.editor.ReplacementKind.GRADIENT) {
                val (angle, stops) = bg.GRADIENTS[0]
                it.copy(replacement = com.lightlylabs.lightly.session.Replacement.Gradient(angle, listOf(
                    com.lightlylabs.lightly.session.GradientStop(stops[0], 0.0), com.lightlylabs.lightly.session.GradientStop(stops[1], 1.0))))
            }
            "bg-replaced-blur" -> api.openBackground(com.lightlylabs.lightly.editor.BackgroundSub.FOCUS) {
                api.background(firstImage)
                api.focus(60.0, null)
                api.rebaseHistory()
            }
            // Not prototype screens: the Save copy check of slice 3 (the saved JPEG is pulled and inspected).
            "bg-export-blur" -> api.openBackground(com.lightlylabs.lightly.editor.BackgroundSub.FOCUS) { api.focus(60.0, null); api.saveCopy() }
            "bg-export-replaced" -> api.openBackground(com.lightlylabs.lightly.editor.BackgroundSub.FOCUS) {
                api.background(firstImage)
                api.focus(60.0, null)
                api.saveCopy()
            }
            // Replacement edge checks against the lightest and darkest approved Change-background swatches.
            "bg-export-light", "bg-export-dark" -> api.openBackground(com.lightlylabs.lightly.editor.BackgroundSub.FOCUS) {
                val hex = if (screen == "bg-export-light") "#F4F1EC" else "#1F2328"
                api.background { it.copy(replacement = com.lightlylabs.lightly.session.Replacement.Colour(hex)) }
                api.saveCopy()
            }
            "pt-skin" -> face(com.lightlylabs.lightly.editor.PortraitTab.SKIN, listOf("skin.smoothing" to 24.0, "skin.blemishes" to 40.0, "skin.evenTone" to 18.0))
            "pt-under" -> face(com.lightlylabs.lightly.editor.PortraitTab.UNDER, listOf("underEye.brighten" to 20.0, "underEye.softenLines" to 15.0))
            "pt-eyes" -> face(com.lightlylabs.lightly.editor.PortraitTab.EYES, listOf("eyes.brighten" to 15.0))
            "pt-teeth" -> face(com.lightlylabs.lightly.editor.PortraitTab.TEETH, listOf("teeth.brighten" to 20.0))
            "pt-hair" -> face(com.lightlylabs.lightly.editor.PortraitTab.HAIR, listOf("hair.definition" to 30.0))
            "pt-landscape-photo", "pt-multi" -> face(com.lightlylabs.lightly.editor.PortraitTab.SKIN, listOf("skin.smoothing" to 20.0))
            "pt-no-usable-face" -> api.openPortrait(com.lightlylabs.lightly.editor.PortraitTab.SKIN)
            // pt-hidden: field with Landscape 120 on Develop (Portrait is not offered).
            "pt-hidden" -> { api.applyPreset("landscape", 120); api.rebaseHistory() }
        }
    }

    /** docs/ui/app/screens.js, the `ed-*` and `fx-*` setups, applied as the user would (one commit each). */
    private fun applySlice4(api: EditorViewModel.DebugEditorApi, screen: String) {
        val tool = when {
            screen.startsWith("ed-") || screen == "s4-export" -> com.lightlylabs.lightly.editor.EditorTool.EDIT
            screen.startsWith("fx-") -> com.lightlylabs.lightly.editor.EditorTool.EFFECTS
            else -> return
        }
        val edit = { sub: com.lightlylabs.lightly.editor.EditSub, group: com.lightlylabs.lightly.editor.AdjustGroup ->
            api.openTool(tool) { it.copy(edit = it.edit.copy(sub = sub, group = group)) }
        }
        val fx = { sub: com.lightlylabs.lightly.editor.EffectsSub -> api.openTool(tool) { it.copy(effects = it.effects.copy(sub = sub)) } }
        val light = com.lightlylabs.lightly.editor.AdjustGroup.LIGHT
        when (screen) {
            "ed-crop" -> { api.cropAspect(com.lightlylabs.lightly.session.CropAspect.FOUR_FIVE); edit(com.lightlylabs.lightly.editor.EditSub.CROP, light) }
            "ed-rotate" -> { api.edit { it.copy(geometry = it.geometry.copy(flipHorizontal = true)) }; edit(com.lightlylabs.lightly.editor.EditSub.ROTATE, light) }
            "ed-straighten" -> { api.edit { it.copy(geometry = it.geometry.copy(straighten = -3.0)) }; edit(com.lightlylabs.lightly.editor.EditSub.STRAIGHTEN, light) }
            "ed-perspective" -> { api.edit { it.copy(geometry = it.geometry.copy(perspective = it.geometry.perspective.copy(vertical = 18.0))) }; edit(com.lightlylabs.lightly.editor.EditSub.PERSPECTIVE, light) }
            "ed-adjust-light" -> { api.edit { it.copy(adjust = it.adjust.copy(exposure = 12.0, contrast = 10.0, highlights = -20.0, shadows = 25.0)) }; edit(com.lightlylabs.lightly.editor.EditSub.ADJUST, light) }
            "ed-adjust-colour" -> { api.edit { it.copy(adjust = it.adjust.copy(temp = 15.0, tint = -4.0, vibrance = 12.0)) }; edit(com.lightlylabs.lightly.editor.EditSub.ADJUST, com.lightlylabs.lightly.editor.AdjustGroup.COLOUR) }
            "ed-adjust-detail" -> { api.edit { it.copy(adjust = it.adjust.copy(sharpness = 30.0, clarity = 15.0, noise = 20.0)) }; edit(com.lightlylabs.lightly.editor.EditSub.ADJUST, com.lightlylabs.lightly.editor.AdjustGroup.DETAIL) }
            "ed-remove" -> {
                edit(com.lightlylabs.lightly.editor.EditSub.REMOVE, light)
                // The real model removes the stroke; then, as `stateFor`, the result is the start of history.
                api.prototypeStroke()?.let { stroke -> api.remove(stroke) { api.rebaseHistory() } }
            }
            "ed-removing" -> { edit(com.lightlylabs.lightly.editor.EditSub.REMOVE, light); api.prototypeStroke()?.let { api.holdRemove(com.lightlylabs.lightly.editor.RemoveOp.REMOVING, it) } }
            "ed-remove-failed" -> {
                api.applyPreset("landscape", 37)
                edit(com.lightlylabs.lightly.editor.EditSub.REMOVE, light)
                // Injected for the capture: the approved failure state with the stroke the person drew.
                api.prototypeStroke()?.let { api.holdRemove(com.lightlylabs.lightly.editor.RemoveOp.FAILED, it) }
            }
            // Not a prototype screen: the export check (docs/v1/slice4-android.md) saves one recipe with
            // geometry, Adjust, a real Remove stroke and Effects, and the saved JPEG is inspected.
            "s4-export" -> {
                edit(com.lightlylabs.lightly.editor.EditSub.ADJUST, light)
                api.prototypeStroke()?.let { stroke ->
                    api.remove(stroke) {
                        api.edit { it.copy(geometry = it.geometry.copy(straighten = -3.0), adjust = it.adjust.copy(exposure = 30.0, contrast = 20.0, temp = 25.0)) }
                        api.cropAspect(com.lightlylabs.lightly.session.CropAspect.FOUR_FIVE)
                        api.effects { it.copy(lightLeak = it.lightLeak.copy(enabled = true), grain = it.grain.copy(enabled = true), vignette = it.vignette.copy(enabled = true, amount = 60.0)) }
                    }
                }
            }
            "fx-leak" -> { api.effects { it.copy(lightLeak = it.lightLeak.copy(enabled = true)) }; fx(com.lightlylabs.lightly.editor.EffectsSub.LEAK) }
            "fx-grain" -> { api.effects { it.copy(grain = it.grain.copy(enabled = true, amount = 45.0)) }; fx(com.lightlylabs.lightly.editor.EffectsSub.GRAIN) }
            "fx-vignette" -> { api.effects { it.copy(vignette = it.vignette.copy(enabled = true)) }; fx(com.lightlylabs.lightly.editor.EffectsSub.VIGNETTE) }
            "fx-combined" -> {
                api.effects { it.copy(lightLeak = it.lightLeak.copy(enabled = true), grain = it.grain.copy(enabled = true), vignette = it.vignette.copy(enabled = true)) }
                fx(com.lightlylabs.lightly.editor.EffectsSub.VIGNETTE)
            }
            "fx-preset-conflict" -> {
                // Deviation F1 (as iOS): the prototype picks Film n by its stand-in hash `presetHasEffect`; the
                // first Film preset whose real recipe has its own grain is applied instead.
                val stop = api.library?.pack?.category("film")?.presets?.indexOfFirst { (it.recipe.finishing.grain?.amount ?: 0.0) != 0.0 }?.plus(1) ?: 0
                if (stop > 0) api.applyPreset("film", stop)
                api.effects { it.copy(grain = it.grain.copy(enabled = true)) }
                fx(com.lightlylabs.lightly.editor.EffectsSub.GRAIN)
            }
        }
    }

    /** docs/ui/app/screens.js, the `bd-*` setups (Border, slice 5). */
    private fun applyBorder(api: EditorViewModel.DebugEditorApi, screen: String) {
        if (!screen.startsWith("bd-")) return
        val type = when (screen) {
            "bd-solid" -> com.lightlylabs.lightly.session.BorderType.SOLID
            "bd-frame" -> com.lightlylabs.lightly.session.BorderType.FRAME
            "bd-polaroid" -> com.lightlylabs.lightly.session.BorderType.POLAROID
            else -> com.lightlylabs.lightly.session.BorderType.NONE
        }
        api.border {
            when (screen) {
                "bd-solid" -> it.copy(type = type, width = 5.0)
                "bd-frame" -> it.copy(type = type, colour = "#111111", width = 3.0, spacing = 5.0)
                "bd-polaroid" -> it.copy(type = type)
                else -> it
            }
        }
        // Prototype `bd-polaroid`: the saved signature on the margin.
        if (screen == "bd-polaroid") api.drawnSignature()?.let { ref ->
            api.watermark { it.copy(type = com.lightlylabs.lightly.session.WatermarkType.SIGNATURE, signature = ref, placement = com.lightlylabs.lightly.session.WatermarkPlacement.BORDER) }
        }
        api.openTool(com.lightlylabs.lightly.editor.EditorTool.BORDER) { it.copy(border = it.border.copy(shown = type)) }
    }

    /** docs/ui/app/screens.js, the `wm-*` setups (Watermark, slice 5). */
    private fun applyWatermark(api: EditorViewModel.DebugEditorApi, screen: String) {
        if (!screen.startsWith("wm-") && screen != "s5-export") return
        val signature = api.drawnSignature()
        fun text(font: com.lightlylabs.lightly.session.WatermarkFont) = { w: com.lightlylabs.lightly.session.WatermarkTool ->
            w.copy(type = com.lightlylabs.lightly.session.WatermarkType.TEXT, signature = null, logo = null, text = com.lightlylabs.lightly.session.WatermarkText(com.lightlylabs.lightly.editor.WatermarkOptions.DEFAULT_TEXT, font))
        }
        val shown = when (screen) {
            "wm-signature", "wm-sig-draw", "wm-sig-import" -> {
                signature?.let { ref -> api.watermark { it.copy(type = com.lightlylabs.lightly.session.WatermarkType.SIGNATURE, signature = ref) } }
                com.lightlylabs.lightly.session.WatermarkType.SIGNATURE
            }
            "wm-text" -> { api.watermark(text(com.lightlylabs.lightly.session.WatermarkFont.CORMORANT_GARAMOND)); com.lightlylabs.lightly.session.WatermarkType.TEXT }
            "wm-logo" -> {
                api.watermark { it.copy(type = com.lightlylabs.lightly.session.WatermarkType.LOGO, logo = com.lightlylabs.lightly.session.WatermarkLogo(com.lightlylabs.lightly.session.AssetRef.Bundled(com.lightlylabs.lightly.editor.WatermarkStage.SAMPLE_LOGO_ID)), position = 2) }
                com.lightlylabs.lightly.session.WatermarkType.LOGO
            }
            "wm-on-border" -> {
                api.border { it.copy(type = com.lightlylabs.lightly.session.BorderType.SOLID, width = 8.0) }
                api.watermark { text(com.lightlylabs.lightly.session.WatermarkFont.CAVEAT)(it).copy(placement = com.lightlylabs.lightly.session.WatermarkPlacement.BORDER) }
                com.lightlylabs.lightly.session.WatermarkType.TEXT
            }
            // Not a prototype screen: the saved-JPEG check (a frame border and a text watermark on the photo).
            "s5-export" -> {
                api.border { it.copy(type = com.lightlylabs.lightly.session.BorderType.FRAME, colour = "#111111", width = 3.0, spacing = 5.0) }
                api.watermark(text(com.lightlylabs.lightly.session.WatermarkFont.CAVEAT))
                com.lightlylabs.lightly.session.WatermarkType.TEXT
            }
            else -> com.lightlylabs.lightly.session.WatermarkType.NONE
        }
        api.openTool(com.lightlylabs.lightly.editor.EditorTool.WATERMARK) { it.copy(watermark = it.watermark.copy(shown = shown)) }
        when (screen) {
            // The prototype's sample in the pad (`sigSvg(70)` at left 24, bottom 34).
            "wm-sig-draw" -> api.setUi { it.copy(overlay = com.lightlylabs.lightly.editor.EditorOverlay.SIGNATURE_DRAW, watermark = it.watermark.copy(pad = com.lightlylabs.lightly.editor.prototypePadStrokes())) }
            // The import sheet with the prototype's imported signature as the extracted one.
            "wm-sig-import" -> api.setUi { it.copy(overlay = com.lightlylabs.lightly.editor.EditorOverlay.SIGNATURE_IMPORT, watermark = it.watermark.copy(imported = com.lightlylabs.lightly.signatures.SignatureImages.prototypeImportedSample())) }
        }
    }
}
