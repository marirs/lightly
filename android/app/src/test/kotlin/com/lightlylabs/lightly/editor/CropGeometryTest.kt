package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.session.NormalisedRect
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Free crop (owner amendment 2026-10-05): the same cases as iOS CropGeometryTests. */
class CropGeometryTest {
    @Test fun `pinch preserves centre and clamps to image`() {
        val small = CropGeometry.scaled(rect, 2.0)
        assertEquals(0.25, small.width, 1e-9)
        assertEquals(rect.x + rect.width / 2, small.x + small.width / 2, 1e-9)
        assertEquals(NormalisedRect(0.0, 0.0, 1.0, 1.0), CropGeometry.scaled(rect, 0.1))
    }
    private val rect = NormalisedRect(0.2, 0.2, 0.5, 0.4)

    @Test
    fun `handles are corners, edges, the inside and nothing far away`() {
        // The rectangle spans x 60..210, y 40..120 px of a 300 x 200 frame.
        fun at(x: Float, y: Float) = CropGeometry.handle(x, y, rect, 300f, 200f, reach = 22f)
        assertEquals(CropGeometry.Handle.Corner(left = true, top = true), at(62f, 42f))
        assertEquals(CropGeometry.Handle.Corner(left = false, top = false), at(208f, 119f))
        assertEquals(CropGeometry.Handle.Side(CropGeometry.Edge.TOP), at(135f, 41f))
        assertEquals(CropGeometry.Handle.Side(CropGeometry.Edge.RIGHT), at(211f, 80f))
        assertEquals(CropGeometry.Handle.Move, at(135f, 80f))
        assertNull(at(290f, 190f))
    }

    @Test
    fun `free corners and edges move only their own sides`() {
        val corner = CropGeometry.dragged(rect, CropGeometry.Handle.Corner(left = false, top = true), 0.1, -0.05, null, 1.5)
        assertEquals(0.2, corner.x, 1e-9); assertEquals(0.6, corner.width, 1e-9)
        assertEquals(0.15, corner.y, 1e-9); assertEquals(0.6, corner.y + corner.height, 1e-9)
        val edge = CropGeometry.dragged(rect, CropGeometry.Handle.Side(CropGeometry.Edge.LEFT), -0.1, 0.3, null, 1.5)
        assertEquals(0.1, edge.x, 1e-9); assertEquals(0.7, edge.x + edge.width, 1e-9)
        assertEquals(rect.y, edge.y, 1e-9); assertEquals(rect.height, edge.height, 1e-9)
    }

    @Test
    fun `moving stays inside the frame and keeps the size`() {
        val moved = CropGeometry.dragged(rect, CropGeometry.Handle.Move, 0.5, -0.5, null, 1.5)
        assertEquals(0.5, moved.x, 1e-9); assertEquals(0.0, moved.y, 1e-9)
        assertEquals(rect.width, moved.width, 1e-9); assertEquals(rect.height, moved.height, 1e-9)
    }

    @Test
    fun `a preset locks the ratio on corners and edges`() {
        for (handle in listOf(CropGeometry.Handle.Corner(left = true, top = false), CropGeometry.Handle.Side(CropGeometry.Edge.RIGHT), CropGeometry.Handle.Side(CropGeometry.Edge.BOTTOM))) {
            val r = CropGeometry.dragged(rect, handle, 0.07, 0.05, 1.0, 1.5)
            assertEquals(1.0, r.width * 1.5 / r.height, 1e-9, "$handle")
            assertTrue(r.x >= 0 && r.y >= 0 && r.x + r.width <= 1 + 1e-9 && r.y + r.height <= 1 + 1e-9, "$handle inside")
        }
    }

    @Test
    fun `never smaller than the minimum`() {
        val r = CropGeometry.dragged(rect, CropGeometry.Handle.Corner(left = true, top = true), 0.9, 0.9, null, 1.5)
        assertEquals(CropGeometry.MINIMUM, r.width, 1e-9); assertEquals(CropGeometry.MINIMUM, r.height, 1e-9)
    }
}
