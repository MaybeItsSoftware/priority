package uk.co.maybeitsadam.priority.core.theme

import org.junit.Assert.assertEquals
import org.junit.Test

class ThemeRowsTest {
    @Test
    fun aRowLoadsBackUnderItsOwnIdentifier() {
        assertEquals("dusk.json", ThemeRows.fileName("user.dusk", """{ "name": "Dusk" }"""))
        assertEquals("mine.base.json", ThemeRows.fileName("mine.base", """{ "identifier": "mine.base" }"""))
        assertEquals("a-b.json", ThemeRows.fileName("a/b", "not json"))
        val library = ThemeFileLoader.load(
            ThemeRows.sources(mapOf("user.dusk" to """{ "name": "Dusk" }""", "mine.base" to """{ "identifier": "mine.base" }""")),
            ThemePlatform.ANDROID,
        )
        assertEquals(setOf("user.dusk", "mine.base"), library.themes.map { it.identifier }.toSet())
    }

    @Test
    fun anImportIsStoredUnderTheIdentifierItWillLoadAs() {
        assertEquals("user.dusk", ThemeRows.identifier("dusk.json", """{ "name": "Dusk" }"""))
        assertEquals("user.dusk", ThemeRows.identifier("dusk", "{ broken"))
        assertEquals("mine", ThemeRows.identifier("whatever.json", """{ "identifier": "mine" }"""))
    }
}
