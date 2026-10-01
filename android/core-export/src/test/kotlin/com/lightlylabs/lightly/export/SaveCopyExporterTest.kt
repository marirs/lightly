package com.lightlylabs.lightly.export

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.OutputStream
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertTrue

/** Flow tests on a pure-JVM fake gateway (String handles stand in for content URIs). */
class SaveCopyExporterTest {

    private val source = "content://media/external/images/media/42"
    private val spec = NewImageSpec(displayName = "IMG_0042_lightly.jpg")

    private class FakeGateway(
        private val insertResult: () -> String? = { "content://media/external_primary/images/media/1001" },
        private val publishResult: Boolean = true,
        private val streamFailure: IOException? = null,
        private val closeFailure: IOException? = null,
        private val deleteFailure: RuntimeException? = null,
    ) : MediaStoreGateway<String> {
        val calls = mutableListOf<String>()
        val written = ByteArrayOutputStream()

        override fun insertPending(spec: NewImageSpec): String? = insertResult().also { calls += "insertPending:$it" }

        override fun openForWrite(handle: String): OutputStream {
            calls += "open:$handle"
            return object : OutputStream() {
                override fun write(b: Int) {
                    streamFailure?.let { throw it }
                    written.write(b)
                }
                override fun close() {
                    calls += "close:$handle"
                    closeFailure?.let { throw it }
                }
            }
        }

        override fun publish(handle: String): Boolean = publishResult.also { calls += "publish:$handle" }

        override fun delete(handle: String) {
            calls += "delete:$handle"
            deleteFailure?.let { throw it }
        }
    }

    private class CountingEncoder(private val failure: Exception? = null) : JpegEncoder<ByteArray> {
        var calls = 0
        var lastQuality = -1
        override fun encode(image: ByteArray, quality: Int, sink: OutputStream) {
            calls++
            lastQuality = quality
            failure?.let { throw it }
            sink.write(image)
        }
    }

    private val jpegBytes = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 1, 2, 3, 0xFF.toByte(), 0xD9.toByte())
    private val target = "content://media/external_primary/images/media/1001"

    @Test
    fun `success inserts pending, encodes once, closes, then publishes`() {
        val gateway = FakeGateway()
        val encoder = CountingEncoder()

        val saved = SaveCopyExporter(gateway, encoder).save(source, spec, jpegBytes)

        assertEquals(target, saved)
        assertEquals(1, encoder.calls, "D9: exactly one JPEG encode per export")
        assertEquals(92, encoder.lastQuality)
        assertEquals(listOf("insertPending:$target", "open:$target", "close:$target", "publish:$target"), gateway.calls)
        assertTrue(gateway.written.toByteArray().contentEquals(jpegBytes))
    }

    @Test
    fun `the source is never opened`() {
        val gateway = FakeGateway()
        SaveCopyExporter(gateway, CountingEncoder()).save(source, spec, jpegBytes)
        assertTrue(gateway.calls.none { source in it }, "calls touching the Original: ${gateway.calls}")
    }

    @Test
    fun `encoder failure deletes the pending row and is not retried`() {
        val gateway = FakeGateway()
        val encoder = CountingEncoder(failure = IOException("encoder blew up"))

        val failure = assertFailsWith<SaveCopyFailure.WriteFailed> { SaveCopyExporter(gateway, encoder).save(source, spec, jpegBytes) }

        assertEquals("encoder blew up", failure.cause?.message)
        assertEquals(1, encoder.calls)
        assertEquals(listOf("insertPending:$target", "open:$target", "close:$target", "delete:$target"), gateway.calls)
    }

    @Test
    fun `out of space while flushing maps to OutOfStorage and cleans up`() {
        val gateway = FakeGateway(closeFailure = IOException("write failed: ENOSPC (No space left on device)"))

        assertFailsWith<SaveCopyFailure.OutOfStorage> { SaveCopyExporter(gateway, CountingEncoder()).save(source, spec, jpegBytes) }

        assertEquals("delete:$target", gateway.calls.last())
        assertTrue("publish:$target" !in gateway.calls)
    }

    @Test
    fun `failed publish deletes the pending row`() {
        val gateway = FakeGateway(publishResult = false)
        val encoder = CountingEncoder()

        assertFailsWith<SaveCopyFailure.PublishFailed> { SaveCopyExporter(gateway, encoder).save(source, spec, jpegBytes) }

        assertEquals(listOf("publish:$target", "delete:$target"), gateway.calls.takeLast(2))
        assertEquals(1, encoder.calls)
    }

    @Test
    fun `rejected insert writes nothing and encodes nothing`() {
        val gateway = FakeGateway(insertResult = { null })
        val encoder = CountingEncoder()

        assertFailsWith<SaveCopyFailure.InsertRejected> { SaveCopyExporter(gateway, encoder).save(source, spec, jpegBytes) }

        assertEquals(0, encoder.calls)
        assertEquals(listOf("insertPending:null"), gateway.calls)
    }

    @Test
    fun `security exception on insert maps to PermissionDenied`() {
        val gateway = FakeGateway(insertResult = { throw SecurityException("no access") })
        assertFailsWith<SaveCopyFailure.PermissionDenied> { SaveCopyExporter(gateway, CountingEncoder()).save(source, spec, jpegBytes) }
    }

    @Test
    fun `a failing cleanup does not hide the original error`() {
        val gateway = FakeGateway(streamFailure = IOException("I/O error"), deleteFailure = IllegalStateException("provider gone"))

        val failure = assertFailsWith<SaveCopyFailure.WriteFailed> { SaveCopyExporter(gateway, CountingEncoder()).save(source, spec, jpegBytes) }

        val suppressed = failure.cause!!.suppressed.single()
        assertIs<IllegalStateException>(suppressed)
    }

    @Test
    fun `a gateway that returns the source row is refused without writing or deleting`() {
        val gateway = FakeGateway(insertResult = { source })
        val encoder = CountingEncoder()

        assertFailsWith<IllegalStateException> { SaveCopyExporter(gateway, encoder).save(source, spec, jpegBytes) }

        assertEquals(0, encoder.calls)
        assertEquals(listOf("insertPending:$source"), gateway.calls, "must not open or delete the Original")
    }
}
