package com.lightlylabs.lightly.export

import java.io.File

/**
 * Lightly 1.0 metadata policy for saved copies (docs/v1/plan.md, "Metadata"): two INDEPENDENT
 * switches, captured when Save copy is tapped. The same policy will apply to Share (slice 5).
 *
 * - [keepPhotoMetadata] (default on): camera, lens, aperture, shutter speed, ISO and date taken.
 * - [includeLocation] (default off): GPS tags. Location is never implied by [keepPhotoMetadata].
 *
 * Both off writes a JPEG with no EXIF block at all. In every combination the new file keeps its
 * colour profile (the encoder's ICC segment) and never inherits the Original's dimensions,
 * orientation or thumbnail: only the whitelisted tags below are copied, onto a freshly encoded,
 * already-upright image.
 */
data class MetadataPolicy(
    val keepPhotoMetadata: Boolean = true,
    val includeLocation: Boolean = false,
) {
    /** The EXIF tag names to copy from the Original under this policy (empty: write no EXIF). */
    val tagsToCopy: List<String>
        get() = buildList {
            if (keepPhotoMetadata) addAll(ExportMetadataTags.CAPTURE)
            if (includeLocation) addAll(ExportMetadataTags.LOCATION)
        }

    companion object {
        val DEFAULT = MetadataPolicy()
    }
}

/**
 * EXIF tag names (the strings android.media.ExifInterface uses), kept here as plain strings so the
 * policy is testable on the JVM. Deliberately absent from both lists: Orientation, ImageWidth /
 * ImageLength / PixelXDimension / PixelYDimension, every thumbnail tag, and the maker note. Those
 * describe the Original's pixels, not the saved copy's, so copying them would be wrong.
 */
object ExportMetadataTags {
    /**
     * DEFERRED(dependency): "LensModel" (EXIF 0xA434). The platform android.media.ExifInterface does
     * not know that tag (it neither reads nor writes it, checked against API 34), and
     * androidx.exifinterface, which does, is not a project dependency. Add it here once that
     * dependency is approved; the policy and tests are already shaped for it.
     */
    val CAPTURE: List<String> = listOf(
        "Make",
        "Model",
        "FNumber",
        "ExposureTime",
        // EXIF 0x8827. The platform class names it "ISOSpeedRatings" (EXIF 2.2); androidx calls the
        // same tag "PhotographicSensitivity".
        "ISOSpeedRatings",
        "DateTimeOriginal",
    )

    val LOCATION: List<String> = listOf(
        "GPSLatitude",
        "GPSLatitudeRef",
        "GPSLongitude",
        "GPSLongitudeRef",
        "GPSAltitude",
        "GPSAltitudeRef",
        "GPSTimeStamp",
        "GPSDateStamp",
    )
}

/**
 * Reads the whitelisted tags from the Original. Returns only tags that are present. A read failure
 * returns an empty map: the copy is then saved without metadata rather than not at all, which can
 * only ever drop information, never leak any.
 */
fun interface SourceMetadataReader<H> {
    fun read(source: H, tags: List<String>): Map<String, String>
}

/** Writes [attributes] as the EXIF block of the JPEG file at [jpeg], in place. */
fun interface JpegMetadataWriter {
    fun write(jpeg: File, attributes: Map<String, String>)
}

/**
 * The optional metadata step of [SaveCopyExporter]. [scratchDirectory] holds the one temporary JPEG
 * that EXIF is written into before it is streamed to the new MediaStore row (the platform EXIF
 * writer needs a seekable file; streaming through a file keeps memory bounded for large photos).
 */
class ExportMetadataStep<H>(
    val reader: SourceMetadataReader<H>,
    val writer: JpegMetadataWriter,
    val scratchDirectory: File,
)
