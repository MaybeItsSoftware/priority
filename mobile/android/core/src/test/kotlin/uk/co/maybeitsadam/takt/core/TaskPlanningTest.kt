package uk.co.maybeitsadam.takt.core

import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** No Swift suite of its own; pins `normalized` and the JSON shape Swift's encoder writes. */
class TaskPlanningTest {
    private val referenceDate: Instant = Instant.parse("2001-01-01T00:00:00Z")

    @Test fun anEmptyPlanNormalisesAway() {
        assertNull(TaskPlanning().normalized)
        assertNull(TaskPlanning(requirementGroups = emptyList(), requiresSingleSitting = false).normalized)
        assertEquals(TaskPlanning(minimumBlockSeconds = 600), TaskPlanning(minimumBlockSeconds = 600, requiresSingleSitting = false).normalized)
    }

    @Test fun jsonOmitsAbsentFieldsAndDatesAreReferenceSeconds() {
        val plan = TaskPlanning(startAt = referenceDate.plusSeconds(100), dueDate = "2026-10-02",
            requirementGroups = listOf(listOf("A", "B")), requiresSingleSitting = true)
        val json = plan.toJson()
        // Swift writes a whole Double without the `.0`, and Swift wins.
        assertEquals("""{"startAt":100,"dueDate":"2026-10-02","requirementGroups":[["A","B"]],"requiresSingleSitting":true}""", json)
        assertEquals(plan, TaskPlanning.fromJson(json))
        assertEquals(plan, TaskPlanning.fromJson(json.replace("100", "100.0")))
    }

    @Test fun refusalsReadAsTheyAlwaysHave() {
        assertEquals("Start must be before the deadline.", TaskPlanningError.INVALID_SCHEDULE.message)
        assertEquals(
            "This task or planned block is no longer available in the current conditions and time window.",
            TaskPlanningError.UNAVAILABLE.message,
        )
    }
}
