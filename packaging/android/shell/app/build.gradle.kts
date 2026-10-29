plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "app.forgehub.shell"
    compileSdk = 34

    // Controller ruling 4: the keystore itself lives OUTSIDE this repo
    // entirely (see ../make-release-keystore.sh and task-5-report.md for
    // exactly where it is on this build host) -- this only reads a path
    // and three credentials from the environment, never a literal. Left
    // null when FORGEHUB_RELEASE_KEYSTORE is unset so that unrelated tasks
    // (":app:testDebugUnitTest", ":app:assembleDebug") keep working without
    // a keystore on hand; a release build with no signing config simply
    // comes out unsigned rather than failing the whole module's
    // configuration.
    val releaseKeystorePath: String? = System.getenv("FORGEHUB_RELEASE_KEYSTORE")

    signingConfigs {
        create("release") {
            if (releaseKeystorePath != null) {
                storeFile = file(releaseKeystorePath)
                // FORGEHUB_RELEASE_KEYSTORE being set is this build's
                // signal that a real signed release is actually wanted --
                // from here on, a missing credential is a loud
                // configuration failure, not a silent fall-through to an
                // unsigned APK that LOOKS like a release build.
                storePassword =
                    System.getenv("FORGEHUB_RELEASE_KEYSTORE_PASSWORD")
                        ?: error(
                            "FORGEHUB_RELEASE_KEYSTORE is set but " +
                                "FORGEHUB_RELEASE_KEYSTORE_PASSWORD is not -- refusing to " +
                                "build a release APK with half a signing config.",
                        )
                keyAlias =
                    System.getenv("FORGEHUB_RELEASE_KEY_ALIAS")
                        ?: error("FORGEHUB_RELEASE_KEYSTORE is set but FORGEHUB_RELEASE_KEY_ALIAS is not.")
                keyPassword =
                    System.getenv("FORGEHUB_RELEASE_KEY_PASSWORD")
                        ?: error("FORGEHUB_RELEASE_KEYSTORE is set but FORGEHUB_RELEASE_KEY_PASSWORD is not.")
            }
        }
    }

    defaultConfig {
        applicationId = "app.forgehub.shell"
        // minSdk 26: this app's only launcher icon is the adaptive icon
        // under res/mipmap-anydpi-v26 (see that directory), which only
        // resolves on API 26+. There is no legacy PNG fallback for older
        // devices -- deliberately, since the owner's own phone is nowhere
        // near API 25, and adding density-specific PNGs just to support
        // devices this app will never run on is exactly the kind of
        // speculative work this project avoids.
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            if (releaseKeystorePath != null) {
                signingConfig = signingConfigs.getByName("release")
            }
            // else: stays unsigned (see releaseKeystorePath's comment above).
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    // androidx.activity's OnBackPressedCallback/registerForActivityResult
    // (used by MainActivity for the back-button mapping and the camera/
    // gallery file chooser) come in transitively via appcompat -- no
    // separate dependency line needed for them.
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")

    testImplementation("junit:junit:4.13.2")
}
