package com.lightlylabs.lightly.editor

import androidx.test.core.app.ApplicationProvider
import com.lightlylabs.lightly.develop.LeakPack
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.security.MessageDigest
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * The light-leak pack as this build bundles it (BundleLeakPackTask → assets/leakpack/) and as the editor loads it at startup
 * (LeakLibrary.fromAssets): every image the manifest names is in the assets with its SHA-256, decodes at its recorded size,
 * and is decoded once.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class LeakPackAssetsTest {
    private val assets = ApplicationProvider.getApplicationContext<android.app.Application>().assets

    private fun sha256(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    @Test
    fun `every bundled leak image is present with the manifest's SHA-256 and decodes at its size`() {
        val bundled = runCatching { assets.open(LeakPack.ASSET_MANIFEST).close() }.isSuccess
        assumeTrue("this build bundles no leak pack (shared/leaks/out not built)", bundled)
        val warnings = mutableListOf<String>()
        val library = LeakLibrary.fromAssets(assets) { warnings += it }
        assertTrue(warnings.isEmpty(), "$warnings")
        assertTrue(library.leaks.isNotEmpty())
        for (leak in library.leaks) {
            val bytes = assets.open(LeakPack.ASSET_ROOT + leak.image).use { it.readBytes() }
            assertEquals(leak.imageSha256, sha256(bytes), leak.id)
            assets.open(LeakPack.ASSET_ROOT + leak.thumbnail).close()
        }
        val first = library.leaks.first()
        val image = assertNotNull(library.image(first.id))
        assertEquals(first.width to first.height, image.width to image.height)
        assertSame(image, library.image(first.id), "the decoded image is cached")
        assertNotNull(library.thumbnail(first.id))
    }
}
