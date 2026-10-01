pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "Lightly"

// Module split follows docs/m1/spec.md §8. core-looks and feature-editor are deferred to M3
// (see docs/m2/android-foundation.md); the editor shell lives in :app until then.
include(":core-session")
include(":core-render")
include(":core-model")
include(":core-export")
