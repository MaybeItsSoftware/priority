package uk.co.maybeitsadam.takt.core.theme

import uniffi.takt_core.CoreThemeFileSource
import uniffi.takt_core.themeDecode
import uniffi.takt_core.themeIdentifier
import uniffi.takt_core.themeLoad
import uniffi.takt_core.themeMergeStructure
import uniffi.takt_core.themeResolve

// Resolution is the Rust core's (core/src/theme), which the Mac and the
// iPhone call too; this is its Kotlin face, one call per folder or file.

/**
 * Something a theme file got wrong, in a sentence someone editing it can act
 * on. Never fatal: a bad value is skipped and the value it would have
 * replaced stays; only a theme that cannot paint every role is dropped.
 */
data class ThemeFileIssue(
    val source: String,
    val severity: ThemeIssueSeverity,
    val message: String,
    /**
     * A finding of the `validate()` audit of the theme the file produced, as
     * opposed to something the file says. Audit findings depend on the
     * platform the theme was resolved for; everything else does not.
     */
    val isAudit: Boolean = false,
) {
    override fun toString(): String = "$source: $message"
}

/** One file's text, named (`dusk.json`). */
data class ThemeFileSource(val name: String, val text: String)

/** What became of one file. */
data class ThemeFileOutcome(
    val source: String,
    /** Null when the theme was skipped; [skippedReason] says why. */
    val specification: ThemeSpecification?,
    val skippedReason: String?,
    /** Everything reported about this file, worst first, including the audit of the theme it produced. */
    val issues: List<ThemeFileIssue>,
)

/** A folder (or table) of theme files, loaded. */
data class ThemeFileLibrary(val outcomes: List<ThemeFileOutcome>) {
    /** The themes that loaded, in file-name order. */
    val themes: List<ThemeSpecification> get() = outcomes.mapNotNull { it.specification }

    val issues: List<ThemeFileIssue> get() = outcomes.flatMap { it.issues }

    companion object {
        val EMPTY = ThemeFileLibrary(emptyList())
    }
}

/** Turns theme files into [ThemeSpecification]s for one platform: decodes, follows `extends`, merges, audits. */
object ThemeFileLoader {
    const val FILE_EXTENSION = "json"

    /** A theme with no `identifier` is named after its file under this prefix. */
    const val DERIVED_IDENTIFIER_PREFIX = "user."

    /**
     * Decodes one file. A document that is not a theme is null plus the
     * reason; keys the format does not have are warnings.
     */
    fun decode(text: String, source: String): Pair<ThemeFile?, List<ThemeFileIssue>> {
        val decoded = themeDecode(text.encodeToByteArray(), source)
        return decoded.file?.local() to decoded.issues.map { it.local() }
    }

    /**
     * Lays a partial [overrides] over [base] exactly as a theme file's own
     * `structure` is laid over its base: each bad value is reported and leaves
     * the base's value standing.
     */
    fun merge(
        overrides: ThemeFile.Structure?,
        base: ThemeStructure,
        path: String = "structure",
        report: (ThemeIssueSeverity, String) -> Unit = { _, _ -> },
    ): ThemeStructure {
        if (overrides == null) return base
        val merged = themeMergeStructure(overrides.core, base.core, path)
        merged.reports.forEach { report(it.severity.local(), it.message) }
        return merged.structure.local()
    }

    /**
     * Loads every source for [platform], resolving `extends` against
     * [builtIns] and each other, in name order. [builtIns] and [defaultBase]
     * default to the built-ins resolved for [platform].
     */
    fun load(
        sources: List<ThemeFileSource>,
        platform: ThemePlatform = ThemePlatform.MACOS,
        builtIns: List<ThemeSpecification>? = null,
        defaultBase: ThemeSpecification? = null,
    ): ThemeFileLibrary = ThemeFileLibrary(
        themeLoad(
            sources.map { CoreThemeFileSource(it.name, it.text.encodeToByteArray()) },
            platform.core,
            builtIns?.map { it.core },
            defaultBase?.core,
        ).map { it.local() },
    )

    /** Resolves one decoded file against a base (null inherits no colours). */
    fun resolve(
        file: ThemeFile,
        source: String,
        base: ThemeSpecification?,
        platform: ThemePlatform = ThemePlatform.MACOS,
    ): ThemeFileOutcome = themeResolve(file.core, source, base?.core, platform.core).local()

    /** The file's own identifier, or one derived from its name. */
    fun identifier(file: ThemeFile, source: String): String = themeIdentifier(file.core, source)

    /** `dusk.json` → `dusk`. */
    fun stem(source: String): String = source.removeSuffix(".$FILE_EXTENSION")
}
