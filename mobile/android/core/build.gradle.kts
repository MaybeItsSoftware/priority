plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

kotlin {
    jvmToolchain(17)
}

/**
 * The built-in themes and the resolver are the Rust core's (docs/themes.md),
 * reached through the bindings below. `shared/themes/` holds what the core
 * writes; the tests read it in place to hold this module to it.
 */
val sharedThemes = rootProject.layout.projectDirectory.dir("../../shared/themes")

// The Rust core's Kotlin bindings (src/main/java/uniffi) are written by
// :data's buildRustCore, which builds the core's libraries alongside them, so
// they are regenerated before this module compiles against them.
tasks.named("compileKotlin") { dependsOn(":data:buildRustCore") }

tasks.withType<Test>().configureEach {
    // The bindings load the core through JNA; on the JVM that is the host
    // build scripts/build_core_android.sh leaves in core/target.
    systemProperty("jna.library.path", rootProject.file("../../core/target/release").absolutePath)
    // The built-in files and resolution cases the core writes; the theme tests read them in place.
    val shared = sharedThemes.asFile
    inputs.files(fileTree(shared)).withPropertyName("sharedThemes")
    systemProperty("priority.themeConformanceDir", shared.resolve("conformance").absolutePath)
    systemProperty("priority.sharedThemesDir", shared.absolutePath)
}

dependencies {
    api(libs.kotlinx.serialization.json)
    // The bindings compile against JNA. On Android its classes and natives
    // come from the AAR :data ships; the JVM tests take the plain jar.
    compileOnly(libs.jna)
    testImplementation(libs.jna)
    testImplementation(libs.junit)
}
