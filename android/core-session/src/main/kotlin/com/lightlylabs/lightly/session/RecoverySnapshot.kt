package com.lightlylabs.lightly.session

import kotlinx.serialization.SerializationException
import kotlinx.serialization.Serializable
import java.io.File
import java.io.IOException
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * Process-death recovery record (spec §5.5): `{assetId, fingerprint, undo stack, cursor}`. Tiny JSON,
 * no pixels. Written on every commit; offered on next launch only if the asset's fingerprint still
 * matches. The full "Continue editing?" UX is M4.
 */
@Serializable
data class RecoverySnapshot(
    val schema: Int = CURRENT_SCHEMA,
    val assetId: String,
    val fingerprint: SourceFingerprint,
    val session: EditSession,
) {
    init {
        require(schema == CURRENT_SCHEMA) { "Unsupported RecoverySnapshot schema $schema" }
        require(session.current.source.assetId == assetId && session.current.source.fingerprint == fingerprint) {
            "Snapshot header does not describe the session's Original"
        }
    }

    companion object {
        const val CURRENT_SCHEMA = 1

        fun of(session: EditSession): RecoverySnapshot = RecoverySnapshot(
            assetId = session.current.source.assetId,
            fingerprint = session.current.source.fingerprint,
            session = session,
        )
    }
}

/**
 * Reads and writes one [RecoverySnapshot] file in app-private storage.
 *
 * Writes go to a sibling temp file and are then moved over the target, so a process kill during a
 * write leaves either the previous snapshot or the new one, never a truncated file.
 */
class RecoverySnapshotStore(private val file: File) {

    fun write(snapshot: RecoverySnapshot) {
        val directory = file.absoluteFile.parentFile
        directory.mkdirs()
        val temp = File(directory, "${file.name}.tmp")
        temp.writeText(SavedEdits.encodeRecoverySnapshot(snapshot), Charsets.UTF_8)
        try {
            Files.move(temp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
        } catch (notAtomic: AtomicMoveNotSupportedException) {
            Files.move(temp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
    }

    /**
     * Returns the stored snapshot, or `null` when there is none. A file that cannot be decoded
     * (corrupt, or written by an unknown schema) is deleted: spec §5.5 says such snapshots are
     * discarded silently, and keeping it would re-offer a broken recovery on every launch.
     */
    fun read(): RecoverySnapshot? {
        if (!file.exists()) return null
        return try {
            // Through SavedEdits so a snapshot written by a schema 1 build is migrated, not discarded.
            SavedEdits.decodeRecoverySnapshot(file.readText(Charsets.UTF_8))
        } catch (corrupt: SerializationException) {
            clear(); null
        } catch (invalid: IllegalArgumentException) {
            clear(); null
        } catch (unreadable: IOException) {
            clear(); null
        }
    }

    /**
     * Returns the snapshot only if it belongs to [assetId] and the asset still has [currentFingerprint].
     * A mismatch means the photo changed or is a different one, so the snapshot is discarded.
     */
    fun readMatching(assetId: String, currentFingerprint: SourceFingerprint): RecoverySnapshot? {
        val snapshot = read() ?: return null
        if (snapshot.assetId == assetId && snapshot.fingerprint == currentFingerprint) return snapshot
        clear()
        return null
    }

    fun clear() {
        file.delete()
    }
}
