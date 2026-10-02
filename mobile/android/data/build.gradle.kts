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
    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

kotlin {
    jvmToolchain(17)
}

// One source of truth for the schema: the fixture the CLI's tests already
// regenerate from the Swift app (scripts/dump_workspace_schema.sh). It is
// copied into the module's assets on every build rather than checked in.
val schemaFixture = rootProject.layout.projectDirectory.file("../../cli/src/fixtures/workspace_schema.sql")
val copyWorkspaceSchema by tasks.registering(Copy::class) {
    from(schemaFixture)
    into(layout.projectDirectory.dir("src/main/assets/generated"))
}
tasks.named("preBuild") { dependsOn(copyWorkspaceSchema) }
tasks.matching { it.name.startsWith("merge") && it.name.endsWith("Assets") || it.name.contains("lint", ignoreCase = true) }
    .configureEach { dependsOn(copyWorkspaceSchema) }

dependencies {
    api(project(":core"))
    api(libs.kotlinx.coroutines.core)
    api(libs.androidx.sqlite)
    implementation(libs.androidx.sqlite.bundled)
    implementation(libs.okhttp)
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
