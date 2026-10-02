package uk.co.maybeitsadam.priority.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.UUID

class KanbanColumnLoadTest {
    private fun column(limit: Int?) = KanbanColumn(name = "Doing", conditions = listOf(KanbanColumnCondition.CatchAll), wipLimit = limit)

    @Test fun noLimitIsAlwaysUnlimited() {
        assertEquals(KanbanColumn.Load.Unlimited, column(null).load(500))
    }

    @Test fun aZeroOrNegativeLimitIsTreatedAsNoLimit() {
        assertEquals(KanbanColumn.Load.Unlimited, column(0).load(3))
        assertEquals(KanbanColumn.Load.Unlimited, column(-2).load(3))
    }

    @Test fun theThreeStatesOfALimitedColumn() {
        assertEquals(KanbanColumn.Load.Within, column(3).load(2))
        assertEquals(KanbanColumn.Load.AtLimit, column(3).load(3))
        assertEquals(KanbanColumn.Load.Over(2), column(3).load(5))
    }

    @Test fun anEmptyLimitedColumnIsWithinIt() {
        assertEquals(KanbanColumn.Load.Within, column(3).load(0))
    }

    @Test fun aColumnSavedWithoutALimitDecodesAsUnlimited() {
        val legacy = """{"id":"${UUID.randomUUID().toString().uppercase()}","name":"Today","conditions":[],"sortOrder":"position"}"""
        val decoded = KanbanColumn.fromJson(legacy)
        assertNull(decoded.wipLimit)
        assertEquals(KanbanColumn.Load.Unlimited, decoded.load(99))
    }

    @Test fun conditionsRoundTripInSwiftsSynthesisedShape() {
        val column = KanbanColumn.defaults.first().copy(wipLimit = 4)
        val json = column.toJson().toString()
        assert(json.contains("""{"dueBucket":{"_0":1}}""")) { json }
        assertEquals(column, KanbanColumn.fromJson(json))
        assertEquals("""{"catchAll":{}}""", KanbanColumnCondition.CatchAll.toJson().toString())
    }
}
