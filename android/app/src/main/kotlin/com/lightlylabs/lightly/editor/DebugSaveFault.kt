package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.export.MediaStoreGateway
import java.io.IOException
import java.io.OutputStream

/**
 * A11 forced conditions (2026-10-07), diagnostics builds only: `--es lightly.debug.saveFails storage|other` makes every
 * Save copy fail when its file is opened, as a full device (an ENOSPC IOException, classified as OutOfStorage) or with
 * another write error, so the approved alerts are reached end to end on the emulator, where filling the disk did not
 * trigger them. Never wired in release (BuildConfig.DIAGNOSTICS false).
 */
object DebugSaveFault {
    @Volatile var mode: String? = null
}

class DebugFaultGateway<H>(private val delegate: MediaStoreGateway<H>) : MediaStoreGateway<H> by delegate {
    override fun openForWrite(handle: H): OutputStream = when (DebugSaveFault.mode) {
        "storage" -> throw IOException("write failed: ENOSPC (No space left on device) [forced]")
        "other" -> throw IOException("write failed: EIO [forced]")
        else -> delegate.openForWrite(handle)
    }
}
