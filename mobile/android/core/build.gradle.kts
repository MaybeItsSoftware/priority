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
        into("uk/co/maybeitsadam/priority/core/theme/builtin")
    }
    into(layout.buildDirectory.dir("generated/sharedThemes"))
}

sourceSets.main {
    resources.srcDir(copySharedThemes)
}

tasks.withType<Test>().configureEach {
    // The resolution cases the Swift tests write; ThemeConformanceTest reads them in place.
    val conformance = sharedThemes.dir("conformance").asFile
    inputs.files(fileTree(conformance)).withPropertyName("themeConformance")
    systemProperty("priority.themeConformanceDir", conformance.absolutePath)
}

dependencies {
    api(libs.kotlinx.serialization.json)
    testImplementation(libs.junit)
}
