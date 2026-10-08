import org.gradle.api.file.DirectoryProperty
import org.gradle.api.file.RegularFileProperty

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "uk.co.maybeitsadam.takt.data"
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
 * The schema fixture the Rust core generates (scripts/dump_workspace_schema.sh),
 * copied into the unit tests' resources, which hold the core's migrations to
 * it. The app itself never reads it: the core migrates the database.
 */
abstract class CopyWorkspaceSchema : DefaultTask() {
    @get:InputFile
    abstract val fixture: RegularFileProperty

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @TaskAction
    fun copy() {
        val target = outputDir.get().asFile.resolve("uk/co/maybeitsadam/takt/data/workspace_schema.sql")
        target.parentFile.mkdirs()
        fixture.get().asFile.copyTo(target, overwrite = true)
    }
}

val copyWorkspaceSchema = tasks.register<CopyWorkspaceSchema>("copyWorkspaceSchema") {
    fixture.set(rootProject.layout.projectDirectory.file("../../cli/src/fixtures/workspace_schema.sql"))
}

androidComponents {
    onVariants { variant ->
        variant.hostTests[com.android.build.api.variant.HostTestBuilder.UNIT_TEST_TYPE]
            ?.sources?.resources?.addGeneratedSourceDirectory(copyWorkspaceSchema, CopyWorkspaceSchema::outputDir)
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

// The Android flavour's natives: libsqliteJni.so, which is SQLite itself with
// its whole C API exported. The Rust core links against this file rather than
// bundling a second SQLite, so the app has one SQLite library in its process:
// two copies sharing a database file can each release the other's POSIX locks
// and corrupt it, and the core writes the file while the app holds it open.
val sqliteAndroidNatives: Configuration by configurations.creating {
    isTransitive = false
}

val unpackSqliteAndroidNatives = tasks.register<Sync>("unpackSqliteAndroidNatives") {
    from({ sqliteAndroidNatives.map { zipTree(it) } }) {
        include("jni/**/libsqliteJni.so")
        eachFile { path = path.removePrefix("jni/") }
        includeEmptyDirs = false
    }
    into(layout.buildDirectory.dir("sqliteAndroidNatives"))
}

// The Rust core (core/): its Android libraries, the Kotlin bindings and the
// host library the JVM unit tests load are all produced by one script. Gradle
// runs it whenever core/ has changed, so Android Studio, the scripts and CI
// cannot build against a stale core.
val coreDir = rootProject.file("../../core")
val buildRustCore = tasks.register<Exec>("buildRustCore") {
    description = "Builds takt-core for Android and regenerates its Kotlin bindings."
    inputs.dir(coreDir.resolve("src"))
    inputs.file(coreDir.resolve("Cargo.toml"))
    inputs.file(coreDir.resolve("Cargo.lock"))
    outputs.dir(layout.projectDirectory.dir("src/main/jniLibs"))
    outputs.dir(rootProject.layout.projectDirectory.dir("core/src/main/java/uniffi"))
    outputs.dir(coreDir.resolve("target/release"))
    dependsOn(unpackSqliteAndroidNatives)
    val natives = layout.buildDirectory.dir("sqliteAndroidNatives")
    inputs.dir(natives)
    environment("TAKT_SQLITE_JNI_DIR", natives.get().asFile.absolutePath)
    commandLine(rootProject.file("../../scripts/build_core_android.sh").absolutePath)
}
tasks.named("preBuild") { dependsOn(buildRustCore) }

tasks.withType<Test>().configureEach {
    dependsOn(unpackSqliteHostNatives, buildRustCore)
    systemProperty("java.library.path", layout.buildDirectory.dir("sqliteHostNatives").get().asFile.absolutePath)
    // The Rust core's UniFFI bindings load it through JNA. On the JVM that is
    // the host build scripts/build_core_android.sh leaves in core/target.
    systemProperty("jna.library.path", rootProject.file("../../core/target/release").absolutePath)
}

dependencies {
    api(project(":core"))
    api(libs.kotlinx.coroutines.core)
    api(libs.androidx.sqlite)
    implementation(libs.androidx.sqlite.bundled)
    implementation(libs.okhttp)
    implementation(libs.kotlinx.serialization.json)
    // The Rust core (core/, docs/rust-core-migration.md): the AAR carries
    // JNA's Android natives; the plain jar carries the desktop ones the JVM
    // unit tests need.
    implementation("${libs.jna.get()}@aar")
    testImplementation(libs.jna)
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    sqliteHostNatives(libs.androidx.sqlite.bundled.jvm)
    // The same version as the driver above, so the core and the app agree on one library.
    sqliteAndroidNatives("androidx.sqlite:sqlite-bundled-android:${libs.versions.sqlite.get()}@aar")
}
