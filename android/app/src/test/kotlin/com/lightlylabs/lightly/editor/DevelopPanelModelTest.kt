package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.session.LookRef
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The Develop panel's content rules (prototype `developPanel`), on the real catalogue. */
class DevelopPanelModelTest {
    private val pack = BundledPack.library.pack
    private val hiking = BundledPack.preset("landscape", 37)
    private fun look(preset: com.lightlylabs.lightly.develop.LookPreset, strength: Float = 1f) = LookRef(preset.id, preset.lookVersion, strength)
    private fun derive(look: LookRef? = null, auto: AutoState = AutoState.UNAVAILABLE, favourites: List<String> = emptyList(), ui: DevelopUi = DevelopUi(), amounts: Map<String, Int> = emptyMap()) =
        DevelopPanelModel.derive(pack, look, auto, favourites, ui, amounts)

    @Test
    fun `categories are Favourites first, then the catalogue in order, without counts`() {
        val model = derive()
        assertEquals(listOf("favourites", "portrait", "landscape", "film", "cinematic", "street", "travel", "wedding", "golden-hour", "black-white"), model.categories.map { it.id })
        assertEquals("Black & White", model.categories.last().label)
    }

    @Test
    fun `the shared readable names apply over the catalogue names, ids and versions unchanged`() {
        // shared/look-pack/names/display-names.json (owner feedback 2026-10-05), bundled as catalogue/display-names.json.
        val root = java.io.File(checkNotNull(System.getProperty("lightly.lookPackDir"))).parentFile.parentFile.parentFile
        val names = com.lightlylabs.lightly.develop.PresetDisplayNames.parse(root.resolve("shared/look-pack/names/display-names.json").readText())
        val packDir = java.io.File(checkNotNull(System.getProperty("lightly.lookPackDir")))
        val model = com.lightlylabs.lightly.develop.DevelopModel.parse(java.io.File(checkNotNull(System.getProperty("lightly.renderingContract"))).readText())
        val renamed = com.lightlylabs.lightly.develop.LookPack.parse(packDir.resolve("manifest.json").readText(), model, names)
        val original = pack.preset(hiking.id)!!
        val shown = renamed.preset(hiking.id)!!
        assertEquals("05 Hiking 05", original.displayName)
        assertEquals("Hiking 5", shown.displayName)
        assertEquals(original.lookVersion, shown.lookVersion)
        assertEquals(original.stop, shown.stop)
        assertEquals(pack.presetCount, renamed.presetCount)
    }

    @Test
    fun `stop zero reads Auto only when Auto is applied, otherwise Original`() {
        assertEquals("Original", derive(auto = AutoState.UNAVAILABLE).name)
        assertEquals("Original", derive(auto = AutoState.OFF).name)
        assertEquals("Original", derive(auto = AutoState.FAILED).name)
        assertEquals("Auto", derive(auto = AutoState.APPLIED).name)
    }

    @Test
    fun `with nothing applied Landscape is shown at stop zero with the star and Amount hidden`() {
        val model = derive()
        assertEquals("landscape", model.categoryId)
        assertEquals(0, model.stop)
        assertEquals("0 / 518", model.position)
        assertFalse(model.presetShown)
        assertEquals("", model.context)
        assertTrue(model.categories.none { it.dotted })
    }

    @Test
    fun `an applied preset shows its name, position, Amount and the category dot`() {
        val model = derive(look(hiking, 0.7f))
        assertEquals("05 Hiking 05", model.name)
        assertEquals("37 / 518", model.position)
        assertEquals(70, model.amount)
        assertTrue(model.presetShown)
        assertEquals(listOf("landscape"), model.categories.filter { it.dotted }.map { it.id })
    }

    @Test
    fun `browsing another category keeps naming the applied preset, never Original`() {
        // Owner amendment 2026-10-05: the underline moves (categoryId), the dot stays, the name row names the applied preset.
        val model = derive(look(hiking), ui = DevelopUi(category = "cinematic"))
        assertEquals("cinematic", model.categoryId)
        assertEquals(0, model.stop)
        assertEquals("05 Hiking 05", model.name)
        assertEquals("Applied from Landscape", model.context)
        assertEquals("37 / 518", model.position, "the applied preset's own position, once")
        assertTrue(model.presetShown)
        assertTrue(model.categories.first { it.id == "landscape" }.dotted)
        assertTrue(model.categories.first { it.id == "cinematic" }.selected)
        // Dragging to stop zero previews the original and says so.
        assertEquals("Original", derive(look(hiking), ui = DevelopUi(category = "cinematic", dragStop = 0)).name)
    }

    @Test
    fun `dragging previews the stop under the needle without changing the applied Look`() {
        val model = derive(look(hiking), ui = DevelopUi(dragStop = 41, fine = true))
        assertEquals(BundledPack.preset("landscape", 41).displayName, model.name)
        assertEquals("41 / 518", model.position)
        assertTrue(model.fine)
        assertEquals("", model.context)
    }

    @Test
    fun `favourites list the starred presets in order and find the applied one`() {
        val portrait = BundledPack.preset("portrait", 13)
        val favs = listOf(portrait.id, hiking.id, BundledPack.preset("film", 12).id)
        val model = derive(look(hiking), favourites = favs, ui = DevelopUi(category = "favourites"))
        assertTrue(model.categories.first().dotted, "Favourites contains the applied preset")
        assertEquals(favs, model.presets.map { it.id })
        assertEquals(2, model.stop)
        assertTrue(model.starred)
    }

    @Test
    fun `a full favourites notice takes precedence over the Auto notice`() {
        assertNull(derive().notice, "unavailable Auto has no standing notice (owner amendment 2026-10-05)")
        assertEquals(DevelopNotice.AutoFailed, derive(auto = AutoState.FAILED).notice)
        assertEquals(DevelopNotice.FavouritesFull, derive(ui = DevelopUi(favouritesFull = true)).notice)
        assertNull(derive(auto = AutoState.APPLIED).notice)
    }

    @Test
    fun `a preset not yet applied shows the Amount last set for it in this session`() {
        val other = BundledPack.preset("landscape", 38)
        val model = derive(look(hiking), ui = DevelopUi(dragStop = 38), amounts = mapOf(other.id to 40))
        assertEquals(40, model.amount)
    }

    @Test
    fun `Portrait is offered only for a person, and while detection is pending only in debug builds`() {
        assertTrue(EditorTool.PORTRAIT in EditorTools.visible(PersonPresence.PRESENT, debugBuild = false))
        assertFalse(EditorTool.PORTRAIT in EditorTools.visible(PersonPresence.ABSENT, debugBuild = true))
        assertTrue(EditorTool.PORTRAIT in EditorTools.visible(PersonPresence.PENDING, debugBuild = true))
        assertFalse(EditorTool.PORTRAIT in EditorTools.visible(PersonPresence.PENDING, debugBuild = false))
        assertEquals(6, EditorTools.visible(PersonPresence.ABSENT, debugBuild = false).size)
    }

    @Test
    fun `layout modes follow the approved devices`() {
        fun mode(shell: com.lightlylabs.lightly.shell.ShellLayout, w: Float, h: Float) = EditorLayout.decide(shell, w, h).mode
        assertEquals(EditorMode.BELOW, mode(com.lightlylabs.lightly.shell.ShellLayout.Compact, 427f, 952f))
        assertEquals(EditorMode.WIDE, mode(com.lightlylabs.lightly.shell.ShellLayout.Large, 800f, 1280f))
        assertEquals(EditorMode.SIDE, mode(com.lightlylabs.lightly.shell.ShellLayout.Large, 1280f, 800f))
        assertEquals(EditorMode.SPLIT_V, mode(com.lightlylabs.lightly.shell.ShellLayout.SplitVertical(426f), 852f, 883f))
        assertEquals(EditorMode.SPLIT_H, mode(com.lightlylabs.lightly.shell.ShellLayout.SplitHorizontal(441f), 883f, 852f))
        assertEquals(360f, EditorLayout.decide(com.lightlylabs.lightly.shell.ShellLayout.Large, 1280f, 800f).panelWidthDp)
        assertEquals(400f, EditorLayout.decide(com.lightlylabs.lightly.shell.ShellLayout.Large, 1376f, 1032f).panelWidthDp)
    }
}
