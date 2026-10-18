import java.util.Properties

// The Wear OS companion (docs/wear-os.md). It holds no workspace and never
// loads the Rust core: it draws the phone's snapshot and sends actions back
// over the Wearable Data Layer, which pairs it with the phone app by sharing
// its applicationId and signing key.
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

// The same upload key as :app (keystore.properties beside settings.gradle.kts);
// without it, release builds are signed with the debug key.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("keystore.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

/**
 * Play wants a versionCode per artifact that no other artifact of the app
 * has used. The phone's code is the commit count (scripts/build_play_bundle.sh),
 * so the watch's is that plus a billion: the two never meet (the phone would
 * need a billion commits) and both still rise with every release. Play caps
 * versionCode at 2,100,000,000.
 */
val wearVersionCodeOffset = 1_000_000_000

android {
    namespace = "uk.co.maybeitsadam.takt.watch"
    compileSdk = 36
    defaultConfig {
        applicationId = "uk.co.maybeitssoftware.takt"
        minSdk = 30
        targetSdk = 36
        versionCode = wearVersionCodeOffset + ((findProperty("versionCode") as String?)?.toInt() ?: 1)
        // Kept in step with :app's default; scripts/build_wear_bundle.sh passes the phone's.
        versionName = (findProperty("versionName") as String?) ?: "0.4.0"
    }
    signingConfigs {
        if (keystoreProperties.isNotEmpty()) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }
    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures {
        compose = true
    }
    testOptions {
        unitTests.isReturnDefaultValues = true
    }
    packaging {
        resources.excludes += setOf("META-INF/LICENSE*", "META-INF/NOTICE*", "META-INF/*.kotlin_module")
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation(project(":wearcontract"))
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.play.services.wearable)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.coroutines.play.services)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.wear.compose.material3)
    implementation(libs.wear.compose.foundation)
    implementation(libs.wear.compose.navigation)
    implementation(libs.wear.tiles)
    implementation(libs.wear.protolayout)
    implementation(libs.wear.protolayout.expression)
    implementation(libs.wear.complications.data.source.ktx)
    implementation(libs.androidx.concurrent.futures)
    debugImplementation(libs.compose.ui.tooling)

    testImplementation(libs.junit)
}
