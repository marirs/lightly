package com.lightlylabs.lightly.editor

import java.io.File

/**
 * The saved-edit fixtures shared with iOS (repo `shared/fixtures/edit-state/`), located through the
 * `lightly.editStateFixturesDir` system property set by android/build.gradle.kts. A missing file
 * fails the test. (core-session has the same reader; test sources are not shared across modules.)
 */
object SharedEditStateFixtureFiles {
    const val V1_NUMERIC_LOOK_VERSION = "v1-numeric-look-version.json"

    fun read(name: String): String {
        val directory = checkNotNull(System.getProperty("lightly.editStateFixturesDir")) { "lightly.editStateFixturesDir is not set" }
        val file = File(directory, name)
        check(file.isFile) { "Shared edit-state fixture $name is missing from $directory" }
        return file.readText(Charsets.UTF_8)
    }
}
