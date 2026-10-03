package uk.co.maybeitsadam.priority.core.theme

import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/**
 * Kotlin's resolution must reproduce the cases the Swift tests write to
 * `shared/themes/conformance/`, for every platform and appearance
 * (docs/themes.md, "Built-ins are shared files").
 */
class ThemeConformanceTest {
    private val directory: File? = System.getProperty("priority.themeConformanceDir")?.let(::File)

    private fun cases(): List<File> =
        directory?.listFiles { file -> file.extension == ThemeFileLoader.FILE_EXTENSION }?.sortedBy { it.name }.orEmpty()

    @Test
    fun kotlinResolvesEveryConformanceCaseAsSwiftDoes() {
        val cases = cases()
        assumeTrue(
            "No theme conformance cases in ${directory ?: "shared/themes/conformance"} yet; " +
                "the Swift tests write them. Skipping.",
            cases.isNotEmpty(),
        )
        val failures = cases.flatMap { ThemeConformance.check(it.name, it.readText()) }
        if (failures.isNotEmpty()) throw AssertionError(failures.joinToString("\n"))
    }
}
