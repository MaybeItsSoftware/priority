package uk.co.maybeitsadam.priority.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import uk.co.maybeitsadam.priority.core.theme.BuiltInThemeSpecifications
import uk.co.maybeitsadam.priority.core.theme.ThemeAppearance
import uk.co.maybeitsadam.priority.core.theme.ThemePlatform
import uk.co.maybeitsadam.priority.data.workspace.WorkspacePreferenceKey
import uk.co.maybeitsadam.priority.ui.theme.ResolvedTheme
import uk.co.maybeitsadam.priority.ui.theme.ThemeMode

class ThemeLibraryStateTest {
    private val duskJson = """{ "name": "Dusk", "palette": { "light": { "primary": "#7a4de8" } } }"""
    private val rows = mapOf("user.dusk" to duskJson)

    private fun state(
        preferences: Map<String, String?>,
        device: ThemeSelection = ThemeSelection(),
        useDevice: Boolean = false,
    ) = ThemeLibraryState.of(rows, preferences, device, useDevice)

    @Test
    fun aChosenRowIsInForceWithAndroidStructure() {
        val s = state(mapOf(WorkspacePreferenceKey.THEME_SELECTED to "user.dusk"))
        assertEquals("Dusk", s.specification.name)
        assertEquals(16.0, s.specification.structure.typography.bodySize, 0.0)
        assertEquals(listOf(UserThemeFile("user.dusk", "dusk.json", duskJson)), s.files)
        assertEquals(listOf("native.theme.chalk", "native.theme.chalk.dark", "user.dusk"), s.available.map { it.identifier })
    }

    @Test
    fun anUnknownOrClearedChoiceShowsChalkUntilItArrives() {
        val s = state(mapOf(WorkspacePreferenceKey.THEME_SELECTED to "user.not-here", WorkspacePreferenceKey.THEME_APPEARANCE to "dark"))
        assertEquals(BuiltInThemeSpecifications.CHALK_IDENTIFIER, s.specification.identifier)
        assertEquals(ThemeMode.DARK, s.mode)
        assertEquals(BuiltInThemeSpecifications.CHALK_IDENTIFIER, state(mapOf(WorkspacePreferenceKey.THEME_SELECTED to null)).specification.identifier)
    }

    @Test
    fun theDeviceChoiceWinsOnlyWhenOptedIn() {
        val shared = mapOf(WorkspacePreferenceKey.THEME_SELECTED to "user.dusk", WorkspacePreferenceKey.THEME_APPEARANCE to "light")
        val device = ThemeSelection(BuiltInThemeSpecifications.CHALK_DARK_IDENTIFIER, ThemeMode.SYSTEM)
        assertEquals("user.dusk", state(shared, device).specification.identifier)
        val local = state(shared, device, useDevice = true)
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

    @Test
    fun dataStoreThemesAndTheirChoiceBecomeRows() {
        val files = """[{"name":"dusk.json","json":"{ \"name\": \"Dusk\" }"},{"name":"mine.json","json":"{ \"identifier\": \"mine\" }"}]"""
        val migration = LocalThemeMigration.of(
            mapOf(LocalThemeMigration.FILES to files, LocalThemeMigration.SELECTED to "mine", LocalThemeMigration.APPEARANCE to "dark"),
        )
        assertEquals(setOf("user.dusk", "mine"), migration.rows.keys)
        assertEquals("mine", migration.selected)
        assertEquals("dark", migration.appearance)
    }

    @Test
    fun theFirstSettingsKeysMigrateToo() {
        val imported = """{ "name": "Paper" }"""
        val active = LocalThemeMigration.of(mapOf(LocalThemeMigration.LEGACY_ACTIVE to imported, LocalThemeMigration.LEGACY_MODE to "light"))
        assertEquals(mapOf("user.imported" to imported), active.rows)
        assertEquals("user.imported", active.selected)
        assertEquals("light", active.appearance)

        val chalkDark = """{"identifier":"native.theme.chalk.dark","extends":"native.theme.chalk.dark"}"""
        val dark = LocalThemeMigration.of(mapOf(LocalThemeMigration.LEGACY_ACTIVE to chalkDark, LocalThemeMigration.LEGACY_LIBRARY to imported))
        assertEquals(mapOf("user.imported" to imported), dark.rows)
        assertEquals(BuiltInThemeSpecifications.CHALK_DARK_IDENTIFIER, dark.selected)
        assertNull(dark.appearance)
    }
}
