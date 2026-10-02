import org.gradle.api.file.DirectoryProperty
import org.gradle.api.file.RegularFileProperty

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "uk.co.maybeitsadam.priority.data"
    compileSdk = 36
    defaultConfig {
        minSdk = 29
        consumerProguardFiles("consumer-rules.pro")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    jvmToolchain(17)
}

/**
 * One source of truth for the schema: the fixture the CLI's tests already
 * regenerate from the Swift app (scripts/dump_workspace_schema.sh). It is
 * copied into the module's Java resources on every build rather than checked
 * in, so a schema change on the Mac reaches Android with the next build.
 */
abstract class CopyWorkspaceSchema : DefaultTask() {
    @get:InputFile
    abstract val fixture: RegularFileProperty

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @TaskAction
    fun copy() {
        val target = outputDir.get().asFile.resolve("uk/co/maybeitsadam/priority/data/workspace_schema.sql")
        target.parentFile.mkdirs()
        fixture.get().asFile.copyTo(target, overwrite = true)
    }
}

val copyWorkspaceSchema = tasks.register<CopyWorkspaceSchema>("copyWorkspaceSchema") {
    fixture.set(rootProject.layout.projectDirectory.file("../../cli/src/fixtures/workspace_schema.sql"))
}

androidComponents {
    onVariants { variant ->
        variant.sources.resources?.addGeneratedSourceDirectory(copyWorkspaceSchema, CopyWorkspaceSchema::outputDir)
    }
}

// Host unit tests run on the JVM, where the AAR's Android .so cannot load. The
// JVM flavour of the same driver carries desktop natives; unpack the one for
// this machine onto java.library.path so BundledSQLiteDriver works in tests.
val sqliteHostNatives: Configuration by configurations.creating {
    isTransitive = false
}

val unpackSqliteHostNatives = tasks.register<Sync>("unpackSqliteHostNatives") {
    val os = System.getProperty("os.name").lowercase()
    val arch = System.getProperty("os.arch").lowercase()
    val platform = when {
        os.contains("mac") -> if (arch.contains("aarch64") || arch.contains("arm")) "osx_arm64" else "osx_x64"
        os.contains("win") -> "windows_x64"
        else -> if (arch.contains("aarch64") || arch.contains("arm")) "linux_arm64" else "linux_x64"
    }
    from({ sqliteHostNatives.map { zipTree(it) } }) {
        include("natives/$platform/**")
        eachFile { path = name }
        includeEmptyDirs = false
    }
    into(layout.buildDirectory.dir("sqliteHostNatives"))
}

tasks.withType<Test>().configureEach {
    dependsOn(unpackSqliteHostNatives)
    systemProperty("java.library.path", layout.buildDirectory.dir("sqliteHostNatives").get().asFile.absolutePath)
}

dependencies {
    api(project(":core"))
    api(libs.kotlinx.coroutines.core)
    api(libs.androidx.sqlite)
    implementation(libs.androidx.sqlite.bundled)
    implementation(libs.okhttp)
    implementation(libs.kotlinx.serialization.json)
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    sqliteHostNatives(libs.androidx.sqlite.bundled.jvm)
}
