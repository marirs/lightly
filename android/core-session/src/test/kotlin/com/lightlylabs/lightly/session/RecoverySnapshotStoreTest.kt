package com.lightlylabs.lightly.session

import com.lightlylabs.lightly.session.SessionFixtures.fingerprint
import com.lightlylabs.lightly.session.SessionFixtures.newSession
import com.lightlylabs.lightly.session.SessionFixtures.portra
import com.lightlylabs.lightly.session.SessionFixtures.source
import org.junit.Rule
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull

class RecoverySnapshotStoreTest {

    @get:Rule
    val temporaryFolder = TemporaryFolder()

    private fun store(): Pair<RecoverySnapshotStore, File> {
        val file = File(temporaryFolder.root, "recovery/editor-session.json")
        return RecoverySnapshotStore(file) to file
    }

    @Test
    fun `written snapshot reads back identically`() {
        val (store, _) = store()
        val session = newSession().selectLook(portra).undo()

        store.write(RecoverySnapshot.of(session))

        assertEquals(session, store.read()?.session)
    }

    @Test
    fun `missing snapshot reads as null`() {
        assertNull(store().first.read())
    }

    @Test
    fun `fingerprint mismatch discards the snapshot`() {
        val (store, file) = store()
        store.write(RecoverySnapshot.of(newSession().selectLook(portra)))

        val changedPhoto = fingerprint.copy(byteSize = fingerprint.byteSize + 1)

        assertNull(store.readMatching(source.assetId, changedPhoto))
        assertFalse(file.exists(), "a stale snapshot must not be offered again on the next launch")
    }

    @Test
    fun `matching fingerprint returns the snapshot`() {
        val (store, _) = store()
        val session = newSession().selectLook(portra)
        store.write(RecoverySnapshot.of(session))

        assertEquals(session, store.readMatching(source.assetId, fingerprint)?.session)
    }

    @Test
    fun `corrupt snapshot is discarded silently`() {
        val (store, file) = store()
        file.parentFile.mkdirs()
        file.writeText("{\"schema\":1,\"assetId\":")

        assertNull(store.read())
        assertFalse(file.exists())
    }

    @Test
    fun `a snapshot written by a schema 1 build is migrated, not discarded`() {
        val (store, file) = store()
        val v1Entry = SharedEditStateFixtures.read(SharedEditStateFixtures.V1_NUMERIC_LOOK_VERSION)
        val sourceJson = """{"assetId":"content://media/picker/0/42","fingerprint":{"headSha256":"${"ab".repeat(32)}","byteSize":1048576,"pixelWidth":4032,"pixelHeight":3024}"""
        file.parentFile.mkdirs()
        file.writeText(
            """{"schema":1,${sourceJson.removePrefix("{")},"session":{"history":{"entries":[$v1Entry],"cursor":0,"capacity":50},"lastIssuedRevision":7}}""",
        )

        val restored = store.read()

        val expected = SavedEdits.decodeEditState(SharedEditStateFixtures.read(SharedEditStateFixtures.V1_MIGRATED_TO_V2))
        assertEquals(expected, restored?.session?.current)
    }

    @Test
    fun `fingerprint hashes only the first 64 KiB`() {
        val head = ByteArray(SourceFingerprints.HEAD_BYTES) { (it % 251).toByte() }
        val fileA = head + ByteArray(1000) { 1 }
        val fileB = head + ByteArray(1000) { 2 }
        val fileC = head.copyOf().also { it[10] = 99 } + ByteArray(1000) { 1 }

        fun fp(bytes: ByteArray) = SourceFingerprints.compute(ByteArrayInputStream(bytes), bytes.size.toLong(), 10, 10)

        assertEquals(fp(fileA).headSha256, fp(fileB).headSha256, "bytes past 64 KiB are not hashed")
        assertNotEquals(fp(fileA).headSha256, fp(fileC).headSha256)
    }
}
