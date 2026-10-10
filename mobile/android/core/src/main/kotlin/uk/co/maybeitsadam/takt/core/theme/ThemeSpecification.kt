package uk.co.maybeitsadam.takt.core.theme

import uniffi.takt_core.themeContrastFindings
import uniffi.takt_core.themeIssueMessage
import uniffi.takt_core.themeIssueSeverity
import uniffi.takt_core.themeStructureFindings
import uniffi.takt_core.themeValidate

// The audit is the Rust core's (core/src/theme/audit.rs); these are its types.

/**
 * A whole theme, resolved for one platform: who it is, its palette and its
 * structure. Pure data; the Compose theme is a projection of it.
 */
data class ThemeSpecification(
    val identifier: String,
    val name: String,
    val summary: String,
    /**
     * A theme that exists in one appearance only. Null follows the system (or
     * the appearance setting); set, it overrides both, the way Chalk Dark does.
     */
    val lockedAppearance: ThemeAppearance? = null,
    val palette: ThemePalette,
    val structure: ThemeStructure,
) {
    fun color(role: ThemeColorRole, appearance: ThemeAppearance): ThemeColorValue = palette.color(role, appearance)

    /** Everything wrong with this theme, worst first. Empty means it is fit to ship. */
    fun validate(): List<ThemeIssue> = themeValidate(core).map { it.local() }
}

enum class ThemeIssueSeverity(val rank: Int) {
    /** The theme is broken: something will render wrong. */
    ERROR(2),

    /** The theme renders, but a rule of the house style is being bent. */
    WARNING(1),

    /** True, and worth knowing, but intended. */
    NOTE(0),
    ;

    /** As the conformance cases write it: `error`, `warning`, `note`. */
    val raw: String get() = name.lowercase()
}

/** One finding of the audit. Its severity and wording are the core's, so they read the same on every platform. */
sealed interface ThemeIssue {
    val severity: ThemeIssueSeverity get() = themeIssueSeverity(core).local()
    val message: String get() = themeIssueMessage(core)

    data class MissingRole(val role: ThemeColorRole, val appearance: ThemeAppearance) : ThemeIssue

    /** A role used for running text that does not clear 4.5:1 on its surface. */
    data class BodyTextBelowAA(val role: ThemeColorRole, val appearance: ThemeAppearance, val ratio: Double) : ThemeIssue

    /** An accent under 4.5:1: headlines, large text, components and fills only. */
    data class LargeTextOnly(val role: ThemeColorRole, val appearance: ThemeAppearance, val ratio: Double) : ThemeIssue

    /** `primary` under 3:1; it carries the focus ring, so it cannot go lower. */
    data class AccentBelowUIMinimum(val role: ThemeColorRole, val appearance: ThemeAppearance, val ratio: Double) : ThemeIssue

    data class RaisedIndistinctFromPaper(val appearance: ThemeAppearance, val ratio: Double) : ThemeIssue

    data object ShadowsUsed : ThemeIssue

    data object GradientsOnChrome : ThemeIssue

    data object RadiusScaleOutOfOrder : ThemeIssue

    data class ShellRadiusOffScale(val value: Double) : ThemeIssue

    data class HairlineTooHeavy(val value: Double) : ThemeIssue

    /** A touch target set, but under the 44pt a finger needs. Zero (a pointer platform) is fine. */
    data class TouchTargetTooSmall(val value: Double) : ThemeIssue
}

/** Reads a palette the way a reader does: every role against the surface it is drawn on. */
object ThemeContrastAudit {
    const val BODY_TEXT_MINIMUM = 4.5
    const val UI_MINIMUM = 3.0
    const val RAISED_MINIMUM = 1.03

    val ACCENT_ROLES = listOf(ThemeColorRole.PRIMARY, ThemeColorRole.SUCCESS, ThemeColorRole.DANGER, ThemeColorRole.WARNING)

    /** The one accent that sits bare on the paper, as the focus ring. */
    val CHROME_CARRYING_ROLE = ThemeColorRole.PRIMARY

    fun ratio(role: ThemeColorRole, surface: ThemeColorRole, appearance: ThemeAppearance, palette: ThemePalette): Double =
        palette.color(role, appearance).contrastRatio(palette.color(surface, appearance))

    fun findings(specification: ThemeSpecification): List<ThemeIssue> =
        themeContrastFindings(specification.core).map { it.local() }
}

/** The structural half of the same check. */
object ThemeStructureAudit {
    val SHELL_RADIUS_RANGE = 18.0..22.0
    const val HEAVIEST_HAIRLINE = 2.0
    const val SMALLEST_TOUCH_TARGET = 44.0

    fun findings(structure: ThemeStructure): List<ThemeIssue> = themeStructureFindings(structure.core).map { it.local() }
}
