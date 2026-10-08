plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

kotlin {
    jvmToolchain(17)
}

/**
 * The built-in themes are defined once, in Swift, and exported as complete
 * JSON to `shared/themes/` (docs/themes.md). They are copied onto this
 * module's classpath on every build rather than checked in twice, the same
 * way `:data` copies the workspace schema, so a colour changed on the Mac
 * reaches Android with the next build. A missing folder copies nothing, and
 * `BuiltInThemeSpecifications` falls back to its own definition.
 */
val sharedThemes = rootProject.layout.projectDirectory.dir("../../shared/themes")

val copySharedThemes = tasks.register<Sync>("copySharedThemes") {
    from(sharedThemes) {
        include("*.json")
        into("uk/co/maybeitsadam/takt/core/theme/builtin")
    }
    into(layout.buildDirectory.dir("generated/sharedThemes"))
}

sourceSets.main {
    resources.srcDir(copySharedThemes)
}

// The Rust core's Kotlin bindings (src/main/java/uniffi) are written by
// :data's buildRustCore, which builds the core's libraries alongside them, so
// they are regenerated before this module compiles against them.
tasks.named("compileKotlin") { dependsOn(":data:buildRustCore") }

tasks.withType<Test>().configureEach {
    // The bindings load the core through JNA; on the JVM that is the host
    // build scripts/build_core_android.sh leaves in core/target.
    systemProperty("jna.library.path", rootProject.file("../../core/target/release").absolutePath)
    // The resolution cases the Swift tests write; ThemeConformanceTest reads them in place.
    val conformance = sharedThemes.dir("conformance").asFile
    inputs.files(fileTree(conformance)).withPropertyName("themeConformance")
    systemProperty("priority.themeConformanceDir", conformance.absolutePath)
}

dependencies {
    api(libs.kotlinx.serialization.json)
    // The bindings compile against JNA. On Android its classes and natives
    // come from the AAR :data ships; the JVM tests take the plain jar.
    compileOnly(libs.jna)
    testImplementation(libs.jna)
    testImplementation(libs.junit)
}
