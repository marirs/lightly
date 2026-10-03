package com.lightlylabs.lightly.export

import android.content.ContentResolver
import android.media.ExifInterface
import android.net.Uri
import java.io.File
import java.io.IOException
import java.io.InputStream

/**
 * EXIF through the PLATFORM android.media.ExifInterface. androidx.exifinterface is not a dependency
 * of this project and slice 1 adds no downloads; on API 29+ (our minSdk) the platform class reads
 * and writes JPEG EXIF in pure Java, which is all Save copy needs.
 */
object PlatformExifMetadata {

    /** Reads whitelisted tags from any JPEG/HEIF/DNG stream the platform understands. */
    fun readTags(stream: InputStream, tags: List<String>): Map<String, String> {
        val exif = ExifInterface(stream)
        return tags.mapNotNull { tag -> exif.getAttribute(tag)?.takeIf { it.isNotBlank() }?.let { tag to it } }.toMap()
    }

    /** Writes [attributes] into the JPEG at [jpeg] (ExifInterface rewrites the file in place). */
    val writer = JpegMetadataWriter { jpeg, attributes ->
        val exif = ExifInterface(jpeg)
        attributes.forEach { (tag, value) -> exif.setAttribute(tag, value) }
        exif.saveAttributes()
    }

    /**
     * Reads the Original through the ContentResolver.
     *
     * Platform limit (documented in docs/v1/slice1-android.md): MediaStore redacts GPS from photos
     * read without ACCESS_MEDIA_LOCATION, and the Photo Picker hands out location-redacted copies.
     * "Include location" therefore copies whatever location the readable Original still carries;
     * DEFERRED(slice 5): decide with the product owner whether to request ACCESS_MEDIA_LOCATION.
     */
    fun contentResolverReader(resolver: ContentResolver) = SourceMetadataReader<Uri> { source, tags ->
        val stream = resolver.openInputStream(source) ?: throw IOException("No input stream for $source")
        stream.use { readTags(it, tags) }
    }

    fun step(resolver: ContentResolver, scratchDirectory: File): ExportMetadataStep<Uri> =
        ExportMetadataStep(contentResolverReader(resolver), writer, scratchDirectory)
}
