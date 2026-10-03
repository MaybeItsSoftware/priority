package uk.co.maybeitsadam.priority.core.theme

import java.util.Locale

// Port of Sources/PriorityCore/Theming/ThemeSpecification.swift.

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
    fun validate(): List<ThemeIssue> {
        val issues = mutableListOf<ThemeIssue>()
        for (appearance in ThemeAppearance.entries) {
            issues += palette.missingRoles(appearance).map { ThemeIssue.MissingRole(it, appearance) }
        }
        issues += ThemeContrastAudit.findings(this)
        issues += ThemeStructureAudit.findings(structure)
        return issues.sortedByDescending { it.severity.rank }
    }
}

enum class ThemeIssueSeverity(val rank: Int) {
    /** The theme is broken: something will render wrong. */
    ERROR(2),

    /** The theme renders, but a rule of the house style is being bent. */
    WARNING(1),

    /** True, and worth knowing, but intended. */
    NOTE(0),
}

sealed interface ThemeIssue {
    val severity: ThemeIssueSeverity
    val message: String

    data class MissingRole(val role: ThemeColorRole, val appearance: ThemeAppearance) : ThemeIssue {
        override val severity get() = ThemeIssueSeverity.ERROR
        override val message get() = "${role.raw} has no ${appearance.raw} value"
    }

    /** A role used for running text that does not clear 4.5:1 on its surface. */
    data class BodyTextBelowAA(val role: ThemeColorRole, val appearance: ThemeAppearance, val ratio: Double) : ThemeIssue {
        override val severity get() = ThemeIssueSeverity.WARNING
        override val message get() = "${role.raw} is ${format(ratio)}:1 on ${appearance.raw} paper — below AA for body text"
    }

    /** An accent under 4.5:1: headlines, large text, components and fills only. */
    data class LargeTextOnly(val role: ThemeColorRole, val appearance: ThemeAppearance, val ratio: Double) : ThemeIssue {
        override val severity get() = ThemeIssueSeverity.NOTE
        override val message get() = "${role.raw} is ${format(ratio)}:1 on ${appearance.raw} paper — not for body copy"
    }

    /** `primary` under 3:1; it carries the focus ring, so it cannot go lower. */
    data class AccentBelowUIMinimum(val role: ThemeColorRole, val appearance: ThemeAppearance, val ratio: Double) : ThemeIssue {
        override val severity get() = ThemeIssueSeverity.WARNING
        override val message get() =
            "${role.raw} is ${format(ratio)}:1 on ${appearance.raw} paper — too low even for a UI component"
    }

    data class RaisedIndistinctFromPaper(val appearance: ThemeAppearance, val ratio: Double) : ThemeIssue {
        override val severity get() = ThemeIssueSeverity.WARNING
        override val message get() =
            "raised is ${format(ratio)}:1 against paper in ${appearance.raw} — the card needs its hairline to exist"
    }

    data object ShadowsUsed : ThemeIssue {
        override val severity get() = ThemeIssueSeverity.WARNING
        override val message get() = "the theme declares shadows; separation is supposed to come from 1px borders"
    }

    data object GradientsOnChrome : ThemeIssue {
        override val severity get() = ThemeIssueSeverity.WARNING
        override val message get() = "the theme declares gradients on chrome"
    }

    data object RadiusScaleOutOfOrder : ThemeIssue {
        override val severity get() = ThemeIssueSeverity.ERROR
        override val message get() =
            "the radius scale is not panel ≥ control (or a square panel), or the pill is not a pill"
    }

    data class ShellRadiusOffScale(val value: Double) : ThemeIssue {
        override val severity get() = ThemeIssueSeverity.WARNING
        override val message get() = "shell radius ${format(value)} is outside the 18–22 reserved for the app shell"
    }

    data class HairlineTooHeavy(val value: Double) : ThemeIssue {
        override val severity get() = ThemeIssueSeverity.WARNING
        override val message get() = "a ${format(value)}pt hairline is a border, not a hairline"
    }

    companion object {
        fun format(value: Double): String = String.format(Locale.ROOT, "%.2f", value)
    }
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

    fun findings(specification: ThemeSpecification): List<ThemeIssue> {
        val issues = mutableListOf<ThemeIssue>()
        val palette = specification.palette
        for (appearance in ThemeAppearance.entries) {
            for (role in ThemeColorRole.BODY_TEXT_ROLES) {
                val value = ratio(role, ThemeColorRole.PAPER, appearance, palette)
                if (value < BODY_TEXT_MINIMUM) issues += ThemeIssue.BodyTextBelowAA(role, appearance, value)
            }
            for (role in ACCENT_ROLES) {
                val value = ratio(role, ThemeColorRole.PAPER, appearance, palette)
                if (role == CHROME_CARRYING_ROLE && value < UI_MINIMUM) {
                    issues += ThemeIssue.AccentBelowUIMinimum(role, appearance, value)
                } else if (value < BODY_TEXT_MINIMUM) {
                    issues += ThemeIssue.LargeTextOnly(role, appearance, value)
                }
            }
            val raised = ratio(ThemeColorRole.RAISED, ThemeColorRole.PAPER, appearance, palette)
            if (raised < RAISED_MINIMUM) issues += ThemeIssue.RaisedIndistinctFromPaper(appearance, raised)
        }
        return issues
    }
}

/** The structural half of the same check. */
object ThemeStructureAudit {
    val SHELL_RADIUS_RANGE = 18.0..22.0
    const val HEAVIEST_HAIRLINE = 2.0

    fun findings(structure: ThemeStructure): List<ThemeIssue> {
        val issues = mutableListOf<ThemeIssue>()
        val radius = structure.radius
        // A square panel is the one exception to "panel ≥ control".
        val panelOutOfOrder = radius.panel != 0.0 && radius.panel < radius.control
        if (panelOutOfOrder || radius.pill < 999) issues += ThemeIssue.RadiusScaleOutOfOrder
        if (radius.shell != 0.0 && radius.shell !in SHELL_RADIUS_RANGE) issues += ThemeIssue.ShellRadiusOffScale(radius.shell)
        if (structure.border.hairline > HEAVIEST_HAIRLINE) issues += ThemeIssue.HairlineTooHeavy(structure.border.hairline)
        if (structure.usesShadows) issues += ThemeIssue.ShadowsUsed
        if (structure.usesGradientsOnChrome) issues += ThemeIssue.GradientsOnChrome
        return issues
    }
}
