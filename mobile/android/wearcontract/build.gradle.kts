// What the phone and the watch say to each other over the Wearable Data Layer
// (docs/wear-os.md): the day's snapshot one way, actions the other. Pure
// Kotlin with no Android and no Rust core, so the watch can carry it.
plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    api(libs.kotlinx.serialization.json)
    testImplementation(libs.junit)
}
