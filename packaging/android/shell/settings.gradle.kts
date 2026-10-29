pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    // Fails loudly if a module build file declares its own repositories
    // instead of using these -- one place to see, and change, where
    // dependencies come from.
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "forgehub-shell"
include(":app")
