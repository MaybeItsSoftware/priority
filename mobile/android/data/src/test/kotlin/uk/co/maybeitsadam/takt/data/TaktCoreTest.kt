package uk.co.maybeitsadam.takt.data

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test
import uniffi.takt_core.coreVersion

/**
 * The Kotlin side of the Rust core's boundary (core/, docs/rust-core-migration.md):
 * proves the bindings load the host library through JNA and match it. A
 * UniFFI checksum mismatch fails the first call, so this is the canary for a
 * stale build after a change in core/ — rerun scripts/build_core_android.sh.
 */
class TaktCoreTest {
    @Test
    fun theCoreAnswersWithItsCrateVersion() {
        val manifest = generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, "core/Cargo.toml") }
            .first { it.exists() }
        val expected = manifest.readLines()
            .first { it.startsWith("version = ") }
            .substringAfter('"').substringBefore('"')
        assertEquals(expected, coreVersion())
    }
}
