package uk.co.maybeitsadam.priority.app

import org.junit.Assert.assertEquals
import org.junit.Test
import uk.co.maybeitsadam.priority.core.theme.BuiltInThemeSpecifications
import uk.co.maybeitsadam.priority.core.theme.ThemeAppearance
import uk.co.maybeitsadam.priority.core.theme.ThemeFileLoader
import uk.co.maybeitsadam.priority.core.theme.ThemeFileSource
import uk.co.maybeitsadam.priority.core.theme.ThemePlatform
import uk.co.maybeitsadam.priority.ui.theme.ResolvedTheme
import uk.co.maybeitsadam.priority.ui.theme.ThemeMode

class ThemeLibraryStateTest {
    private val dusk = StoredThemeFile("dusk.json", """{ "name": "Dusk", "palette": { "light": { "primary": "#7a4de8" } } }""")

    private fun state(files: List<StoredThemeFile>, shared: ThemeSelection, device: ThemeSelection = ThemeSelection(), useDevice: Boolean = false) =
        ThemeLibraryState(
            files = files,
            library = ThemeFileLoader.load(files.map { ThemeFileSource(it.name, it.json) }, ThemePlatform.ANDROID),
            shared = shared,
            device = device,
            useDeviceChoice = useDevice,
        )

    @Test
    fun aChosenUserThemeIsInForceWithAndroidStructure() {
        val s = state(listOf(dusk), ThemeSelection("user.dusk"))
        assertEquals("Dusk", s.specification.name)
        assertEquals(16.0, s.specification.structure.typography.bodySize, 0.0)
        assertEquals(listOf("native.theme.chalk", "native.theme.chalk.dark", "user.dusk"), s.available.map { it.identifier })
    }

    @Test
    fun anUnknownChoiceShowsChalkUntilItArrives() {
        val s = state(emptyList(), ThemeSelection("user.not-here", ThemeMode.DARK))
        assertEquals(BuiltInThemeSpecifications.CHALK_IDENTIFIER, s.specification.identifier)
        assertEquals(ThemeMode.DARK, s.mode)
    }

    @Test
    fun theDeviceChoiceWinsOnlyWhenOptedIn() {
        val shared = ThemeSelection("user.dusk", ThemeMode.LIGHT)
        val device = ThemeSelection(BuiltInThemeSpecifications.CHALK_DARK_IDENTIFIER, ThemeMode.SYSTEM)
        assertEquals("user.dusk", state(listOf(dusk), shared, device).specification.identifier)
        val local = state(listOf(dusk), shared, device, useDevice = true)
        assertEquals(BuiltInThemeSpecifications.CHALK_DARK_IDENTIFIER, local.specification.identifier)
        assertEquals(ThemeMode.SYSTEM, local.mode)
    }

    @Test
    fun aLockedAppearanceOverridesTheSettingAndTheSystem() {
        val dark = BuiltInThemeSpecifications.chalkDark(ThemePlatform.ANDROID)
        assertEquals(ThemeAppearance.DARK, ResolvedTheme.appearance(dark, ThemeMode.LIGHT, systemDark = false))
        val chalk = BuiltInThemeSpecifications.chalk(ThemePlatform.ANDROID)
        assertEquals(ThemeAppearance.LIGHT, ResolvedTheme.appearance(chalk, ThemeMode.SYSTEM, systemDark = false))
        assertEquals(ThemeAppearance.DARK, ResolvedTheme.appearance(chalk, ThemeMode.SYSTEM, systemDark = true))
        assertEquals(ThemeAppearance.LIGHT, ResolvedTheme.appearance(chalk, ThemeMode.LIGHT, systemDark = true))
    }
}
