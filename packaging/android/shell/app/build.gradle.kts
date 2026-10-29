plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "app.forgehub.shell"
    compileSdk = 34

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
