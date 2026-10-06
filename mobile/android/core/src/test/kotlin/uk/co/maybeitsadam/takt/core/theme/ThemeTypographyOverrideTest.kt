package uk.co.maybeitsadam.takt.core.theme

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** The cases of corelogic-tests/ThemeTypographyOverrideTests.swift, against the Android resolution. */
class ThemeTypographyOverrideTest {
    private val priority = BuiltInThemeSpecifications.priority(ThemePlatform.ANDROID)

    private fun expected(value: Double, factor: Double) = schoolbookRound(value * factor * 2) / 2

    @Test
    fun anEmptyOverrideLeavesTheThemeAlone() {
        val override = ThemeTypographyOverride()
        assertTrue(override.isEmpty)
        assertNull(override.structureOverlay(priority.structure.typography))
        assertSame(priority, override.applied(priority))
    }

    @Test
    fun blankFamiliesAndAUnitScaleCountAsEmpty() {
        val override = ThemeTypographyOverride(bodyFamily = "  ", displayFamily = "", textScale = 1.0)
        assertTrue(override.isEmpty)
        assertEquals(priority, override.applied(priority))
    }

    @Test
    fun aChosenFamilyGoesFirstWithTheThemesRequestBehindIt() {
        val base = priority.structure.typography
        val applied = ThemeTypographyOverride(bodyFamily = "Inter").applied(priority)
        val body = applied.structure.typography.body

        assertEquals("Inter", body.families.first())
        assertEquals(base.body.families.filter { it != "Inter" }, body.families.drop(1))
        assertEquals(base.body.design, body.design)
        // Only the role chosen moves.
        assertEquals(base.display, applied.structure.typography.display)
        assertEquals(base.mono, applied.structure.typography.mono)
        assertEquals(base.bodySize, applied.structure.typography.bodySize, 0.0)
        assertEquals(base.scale, applied.structure.typography.scale)
    }

    @Test
    fun eachRoleIsIndependentlyOverridable() {
        val type = ThemeTypographyOverride(bodyFamily = "Geist", displayFamily = "Arvo", monoFamily = "JetBrains Mono")
            .applied(priority).structure.typography
        assertEquals("Geist", type.body.families.first())
        assertEquals("Arvo", type.display.families.first())
        assertEquals("JetBrains Mono", type.mono.families.first())
    }

    @Test
    fun textSizeScalesTheBodyAndEveryStepInProportion() {
        val base = priority.structure.typography
        val type = ThemeTypographyOverride(textScale = 1.2).applied(priority).structure.typography

        assertEquals(expected(base.bodySize, 1.2), type.bodySize, 0.0)
        assertEquals(expected(base.scale.caption, 1.2), type.scale.caption, 0.0)
        assertEquals(expected(base.scale.body, 1.2), type.scale.body, 0.0)
        assertEquals(expected(base.scale.title, 1.2), type.scale.title, 0.0)
        assertEquals(expected(base.scale.display, 1.2), type.scale.display, 0.0)
        assertEquals(expected(base.scale.hero, 1.2), type.scale.hero, 0.0)
        assertEquals(expected(base.microLabel.size, 1.2), type.microLabel.size, 0.0)
        // The label's other tokens, and the faces, are the theme's.
        assertEquals(base.microLabel.weight, type.microLabel.weight)
        assertEquals(base.microLabel.tracking, type.microLabel.tracking, 0.0)
        assertEquals(base.microLabel.isUppercased, type.microLabel.isUppercased)
        assertEquals(base.microLabel.role, type.microLabel.role)
        assertEquals(base.body, type.body)
    }

    @Test
    fun sizesLandOnHalfPoints() {
        val type = ThemeTypographyOverride(textScale = 1.1).applied(priority).structure.typography
        for (size in listOf(type.bodySize, type.scale.caption, type.scale.title, type.microLabel.size)) {
            assertEquals(0.0, (size * 2) % 1, 0.0)
        }
    }

    @Test
    fun textSizeIsClampedToTheOfferedRange() {
        assertEquals(1.3, ThemeTypographyOverride(textScale = 4.0).effectiveTextScale, 0.0)
        assertEquals(0.85, ThemeTypographyOverride(textScale = 0.1).effectiveTextScale, 0.0)
        assertEquals(1.0, ThemeTypographyOverride(textScale = Double.NaN).effectiveTextScale, 0.0)
        assertEquals(1.0, ThemeTypographyOverride().effectiveTextScale, 0.0)
    }

    /** The point of keeping the choices apart from the theme: the same override lands on every theme. */
    @Test
    fun theSameChoicesApplyToEveryBuiltIn() {
        val override = ThemeTypographyOverride(bodyFamily = "Inter", textScale = 1.1)
        for (builtIn in BuiltInThemeSpecifications.all(ThemePlatform.ANDROID)) {
            val applied = override.applied(builtIn)
            assertEquals(builtIn.identifier, applied.identifier)
            assertEquals(builtIn.name, applied.name)
            assertEquals(builtIn.lockedAppearance, applied.lockedAppearance)
            assertEquals(builtIn.palette, applied.palette)
            assertEquals(builtIn.structure.radius, applied.structure.radius)
            assertEquals(builtIn.structure.spacing, applied.structure.spacing)
            assertEquals(builtIn.structure.touchTarget, applied.structure.touchTarget, 0.0)
            assertEquals("Inter", applied.structure.typography.body.families.first())
            assertTrue(applied.structure.typography.bodySize > builtIn.structure.typography.bodySize)
            val errors = { spec: ThemeSpecification -> spec.validate().filter { it.severity == ThemeIssueSeverity.ERROR } }
            assertEquals(errors(builtIn), errors(applied))
        }
    }

    @Test
    fun theOverrideRoundTripsThroughTheMacsJson() {
        val override = ThemeTypographyOverride(bodyFamily = "Inter", monoFamily = "Lilex", textScale = 1.15)
        assertEquals(override, ThemeTypographyOverride.fromJson(override.toJson()))
        // What the Mac's JSONEncoder writes for the same value.
        val mac = """{"bodyFamily":"Inter","monoFamily":"Lilex","textScale":1.15}"""
        assertEquals(override, ThemeTypographyOverride.fromJson(mac))
        assertEquals(ThemeTypographyOverride(), ThemeTypographyOverride.fromJson("not json"))
        assertEquals(ThemeTypographyOverride(), ThemeTypographyOverride.fromJson(null))
    }

    @Test
    fun aRoleIsSetAndClearedOnItsOwn() {
        val set = ThemeTypographyOverride(bodyFamily = "Geist").withFamily(ThemeFontRole.MONO, "Lilex")
        assertEquals("Geist", set.family(ThemeFontRole.BODY))
        assertEquals("Lilex", set.family(ThemeFontRole.MONO))
        assertNull(set.withFamily(ThemeFontRole.BODY, null).family(ThemeFontRole.BODY))
    }

    @Test
    fun theNearestOfferedStepIsChosen() {
        assertEquals(1.1, ThemeTypographyOverride.nearestTextScale(1.12), 0.0)
        assertEquals(0.85, ThemeTypographyOverride.nearestTextScale(0.5), 0.0)
        assertEquals(1.0, ThemeTypographyOverride.nearestTextScale(1.0), 0.0)
    }

    @Test
    fun bundledFamiliesAreUniqueFindableAndOrderedForTheRole() {
        val names = BundledFontFamily.all.map { it.name }
        assertEquals(names.size, names.toSet().size)
        assertEquals(ThemeFontDesign.SERIF, BundledFontFamily.named("Arvo")?.design)
        assertNull(BundledFontFamily.named("Comic Sans MS"))
        assertEquals(ThemeFontDesign.MONOSPACED, BundledFontFamily.ordered(ThemeFontRole.MONO).first().design)
        assertTrue(BundledFontFamily.ordered(ThemeFontRole.BODY).first().design != ThemeFontDesign.MONOSPACED)
        assertEquals(BundledFontFamily.all.toSet(), BundledFontFamily.ordered(ThemeFontRole.DISPLAY).toSet())
    }
}
