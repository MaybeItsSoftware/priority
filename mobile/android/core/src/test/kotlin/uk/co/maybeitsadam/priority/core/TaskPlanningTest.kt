package uk.co.maybeitsadam.priority.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** No Swift suite of its own; pins `normalized` and the JSON shape Swift's encoder writes. */
class TaskPlanningTest {
    @Test fun anEmptyPlanNormalisesAway() {
        assertNull(TaskPlanning().normalized)
        assertNull(TaskPlanning(requirementGroups = emptyList(), requiresSingleSitting = false).normalized)
        assertEquals(TaskPlanning(minimumBlockSeconds = 600), TaskPlanning(minimumBlockSeconds = 600, requiresSingleSitting = false).normalized)
    }

    @Test fun jsonOmitsAbsentFieldsAndDatesAreReferenceSeconds() {
        val plan = TaskPlanning(startAt = SwiftJSON.REFERENCE_DATE.plusSeconds(100), dueDate = "2026-10-02",
            requirementGroups = listOf(listOf("A", "B")), requiresSingleSitting = true)
        val json = plan.toJson()
        assertEquals("""{"startAt":100.0,"dueDate":"2026-10-02","requirementGroups":[["A","B"]],"requiresSingleSitting":true}""", json)
        assertEquals(plan, TaskPlanning.fromJson(json))
        assertEquals(plan, TaskPlanning.fromJson(json.replace("100.0", "100")))
    }

    @Test fun stringArraysEscapeSlashesAsSwiftDoes() {
        assertEquals("""["a\/b"]""", SwiftJSON.encodeStrings(listOf("a/b")))
        assertEquals(listOf("a/b"), SwiftJSON.decodeStrings("""["a\/b"]"""))
        assertNull(SwiftJSON.decodeStrings("not json"))
    }
}
