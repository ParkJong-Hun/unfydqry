// This settings file is only used when opening the sample app in isolation.
// When building via the kmp/ root, :sample:androidApp is already included.

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

rootProject.name = "unfydqry-kmp-sample"
include(":androidApp")
