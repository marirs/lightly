package com.lightlylabs.lightly.signatures

import com.lightlylabs.lightly.session.SignatureKind
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Saved signatures (edit-recipe `signatureRef`): stable ids, content versions, never substituted. */
class SignatureStoreTest {
    private val sample = DrawnSignature.PROTOTYPE_SAMPLE

    @Test
    fun `a drawn signature's canonical bytes round-trip and give a stable version`() {
        val bytes = sample.canonicalData
        val parsed = assertNotNull(DrawnSignature.parse(bytes))
        assertContentEquals(bytes, parsed.canonicalData)
        assertEquals(170.0, parsed.viewBox.width); assertEquals(2.4, parsed.strokeWidth)
        assertEquals(SavedSignature("a", SignatureKind.DRAWN, bytes).version, SavedSignature("b", SignatureKind.DRAWN, parsed.canonicalData).version)
        assertNull(DrawnSignature.parse("not json".toByteArray()))
    }

    @Test
    fun `a pad drawing keeps the prototype's stroke-to-height proportion`() {
        val drawing = assertNotNull(DrawnSignature.fromPad(listOf(listOf(DrawnSignature.Point(10.0, 20.0), DrawnSignature.Point(110.0, 30.0))), penWidth = 3.36))
        assertEquals(70.0, drawing.viewBox.height, 1e-9)
        assertEquals(3.36 / 70, drawing.strokeWidth / drawing.viewBox.height, 1e-12)
        assertNull(DrawnSignature.fromPad(emptyList(), 3.36))
    }

    @Test
    fun `saving again keeps the id and changes the version, deleting makes it missing, and it all persists`() {
        val dir = kotlin.io.path.createTempDirectory("signatures").toFile()
        val store = SignatureStore(dir)
        val first = store.saveDrawn(sample)
        assertEquals(first, store.resolve(first.reference))
        val moved = DrawnSignature(sample.strokes.map { s -> s.map { DrawnSignature.Point(it.x + 1, it.y) } }, sample.viewBox, sample.strokeWidth)
        val second = store.saveDrawn(moved)
        assertEquals(first.id, second.id)
        assertNotEquals(first.version, second.version)
        assertNull(store.resolve(first.reference), "a changed signature is not substituted")
        val png = byteArrayOf(1, 2, 3)
        val imported = store.saveImported(png)
        // A new process reads the same signatures back, the versions recomputed from the bytes.
        val reopened = SignatureStore(dir)
        assertEquals(second, reopened.resolve(second.reference))
        assertEquals(SignatureKind.IMPORTED, reopened.contents.value.shown?.kind)
        reopened.delete(SignatureKind.IMPORTED)
        assertNull(reopened.resolve(imported.reference))
        assertEquals(SignatureKind.DRAWN, reopened.contents.value.shown?.kind)
        assertNull(SignatureStore(dir).contents.value.imported)
        val digest = reopened.saveLogo(png)
        assertTrue(SignatureStore(dir).logo(digest)!!.contentEquals(png))
    }
}
