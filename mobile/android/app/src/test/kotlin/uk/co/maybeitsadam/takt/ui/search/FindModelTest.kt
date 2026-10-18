package uk.co.maybeitsadam.takt.ui.search

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.ui.commands.PhoneCommands

/** Find's matching is the core's; these hold Android to it and to the core's command list. */
class FindModelTest {
    private val places = listOf(
        FindPlace(null, "Everything", "All active lists", FindPlaceKind.EVERYTHING),
        FindPlace("a", "Groceries", "Home", FindPlaceKind.LIST),
        FindPlace("b", "Work projects", "", FindPlaceKind.LIST),
    )

    @Test fun androidRunsEveryCommandTheCoreOffersThePhones() {
        assertEquals(FindModel.commands.map { it.id }.toSet(), PhoneCommands.HANDLED)
    }

    @Test fun aQueryFindsTheCommandAndThePlaceByAbbreviation() {
        val palette = FindModel.palette("wp", emptyList(), places)
        assertEquals("Work projects", palette.places.first().name)
        val today = FindModel.palette("today", emptyList(), places)
        assertEquals("goToday", today.commands.first().id)
    }

    @Test fun nothingTypedListsRecentCommandsFirstAndEveryPlace() {
        val palette = FindModel.palette("", listOf("phoneSettings"), places)
        assertEquals("phoneSettings", palette.commands.first().id)
        assertEquals(places, palette.places)
        assertEquals(FindModel.commands.size, palette.commands.size)
    }

    @Test fun recentsRoundTripNewestFirst() {
        val recents = FindModel.recording("goFocus", listOf("goToday", "goFocus"))
        assertEquals(listOf("goFocus", "goToday"), recents)
        assertEquals(recents, FindModel.decodeRecents(FindModel.encodeRecents(recents)))
        assertTrue(FindModel.decodeRecents(null).isEmpty())
    }
}
