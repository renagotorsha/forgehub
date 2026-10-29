// Root build file. Plugin versions are declared once here (`apply false`)
// and actually applied in app/build.gradle.kts -- the standard AGP/Kotlin
// DSL split, so the version string exists in exactly one place instead of
// two copies that can drift apart.
plugins {
    id("com.android.application") version "8.4.2" apply false
    id("org.jetbrains.kotlin.android") version "1.9.24" apply false
}
