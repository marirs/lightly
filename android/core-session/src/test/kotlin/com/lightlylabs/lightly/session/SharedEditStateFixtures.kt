package com.lightlylabs.lightly.session

import java.io.File

/**
 * Reads the saved-edit fixtures shared with iOS (repo `shared/fixtures/edit-state/`). The directory
 * comes from the `lightly.editStateFixturesDir` system property set by android/build.gradle.kts.
 * A missing file FAILS the test: skipping would let the two platforms drift apart unnoticed.
 */
object SharedEditStateFixtures {
    const val V2_WITH_LOOK = "v2-with-look.json"
    const val V2_NO_LOOK = "v2-no-look.json"
    const val V1_NUMERIC_LOOK_VERSION = "v1-numeric-look-version.json"
    const val V1_MIGRATED_TO_V2 = "v1-migrated-to-v2.json"
    const val INVALID_UNKNOWN_KEY = "invalid-unknown-key.json"
    const val INVALID_FUTURE_SCHEMA = "invalid-future-schema.json"
    const val INVALID_STRENGTH_OUT_OF_RANGE = "invalid-strength-out-of-range.json"

    private val directory: File by lazy {
        val path = checkNotNull(System.getProperty("lightly.editStateFixturesDir")) {
            "lightly.editStateFixturesDir is not set; run the tests through Gradle"
        }
        File(path).also { check(it.isDirectory) { "Shared edit-state fixtures not found at $it" } }
    }

    /** The file's exact text. The fixtures have no trailing newline, so nothing is trimmed. */
    fun read(name: String): String {
        val file = File(directory, name)
        check(file.isFile) { "Shared edit-state fixture $name is missing from $directory" }
        return file.readText(Charsets.UTF_8)
    }
}
