package uk.co.maybeitsadam.priority.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class MatrixGeometryTest {
    private val plot = 400.0

    @Test fun theCentreIsTheOrigin() {
        val offset = MatrixGeometry.offset(0.0, 0.0, plot)
        assertEquals(0.0, offset.x, 0.0)
        assertEquals(0.0, abs(offset.y), 0.0)
    }

    @Test fun positiveImportanceOffsetsUpward() {
        assertTrue(MatrixGeometry.offset(0.0, 5.0, plot).y < 0)
    }

    @Test fun positiveUrgencyOffsetsRightward() {
        assertTrue(MatrixGeometry.offset(5.0, 0.0, plot).x > 0)
    }

    @Test fun theExtremeCoordinateStaysInsideTheSquare() {
        val offset = MatrixGeometry.offset(9.0, 9.0, plot)
        assertTrue(abs(offset.x) < plot / 2)
        assertTrue(abs(offset.y) < plot / 2)
    }

    @Test fun aCoordinateSurvivesARoundTrip() {
        var urgency = -9.0
        while (urgency <= 9.0) {
            var importance = -9.0
            while (importance <= 9.0) {
                val offset = MatrixGeometry.offset(urgency, importance, plot)
                val back = MatrixGeometry.coordinate(offset.x, offset.y, plot)
                assertEquals(urgency, back.urgency, 0.0001)
                assertEquals(importance, back.importance, 0.0001)
                importance += 3.0
            }
            urgency += 3.0
        }
    }

    @Test fun aDropOutsideTheSquareClampsOntoTheBoard() {
        val far = MatrixGeometry.coordinate(10_000.0, -10_000.0, plot)
        assertEquals(9.0, far.urgency, 0.0)
        assertEquals(9.0, far.importance, 0.0)
    }

    @Test fun snappingCommitsWholeSteps() {
        val offset = MatrixGeometry.offset(4.4, -2.6, plot)
        val snapped = MatrixGeometry.snappedCoordinate(offset.x, offset.y, plot)
        assertEquals(4.0, snapped.urgency, 0.0)
        assertEquals(-3.0, snapped.importance, 0.0)
    }

    @Test fun aZeroSizedPlotYieldsTheOriginRatherThanNaN() {
        val c = MatrixGeometry.coordinate(10.0, 10.0, 0.0)
        assertEquals(0.0, c.urgency, 0.0)
        assertEquals(0.0, c.importance, 0.0)
    }

    @Test fun eachSignPairNamesItsQuadrant() {
        assertEquals(MatrixQuadrant.DO_NOW, MatrixGeometry.quadrant(5.0, 5.0))
        assertEquals(MatrixQuadrant.SCHEDULE, MatrixGeometry.quadrant(-5.0, 5.0))
        assertEquals(MatrixQuadrant.DELEGATE, MatrixGeometry.quadrant(5.0, -5.0))
        assertEquals(MatrixQuadrant.ELIMINATE, MatrixGeometry.quadrant(-5.0, -5.0))
    }

    @Test fun aCoordinateOnAnAxisFallsToTheLowerSide() {
        assertEquals(MatrixQuadrant.SCHEDULE, MatrixGeometry.quadrant(0.0, 5.0))
        assertEquals(MatrixQuadrant.DELEGATE, MatrixGeometry.quadrant(5.0, 0.0))
        assertEquals(MatrixQuadrant.ELIMINATE, MatrixGeometry.quadrant(0.0, 0.0))
    }

    @Test fun theOriginIsTheUnplacedSentinel() {
        assertFalse(MatrixGeometry.isPlaced(0.0, 0.0))
        assertTrue(MatrixGeometry.isPlaced(0.0, -1.0))
        assertTrue(MatrixGeometry.isPlaced(1.0, 0.0))
    }

    @Test fun everyQuadrantsRepresentativeCoordinateLandsInIt() {
        for (quadrant in MatrixQuadrant.entries) {
            val point = quadrant.representativeCoordinate
            assertEquals(quadrant, MatrixGeometry.quadrant(point.urgency, point.importance))
            assertTrue(MatrixGeometry.isPlaced(point.urgency, point.importance))
        }
    }

    @Test fun quadrantsAreNamedByTheirCommandWords() {
        assertEquals(MatrixQuadrant.DO_NOW, MatrixQuadrant.named("do"))
        assertEquals(MatrixQuadrant.SCHEDULE, MatrixQuadrant.named("  SCHEDULE "))
        assertEquals(MatrixQuadrant.ELIMINATE, MatrixQuadrant.named("bin"))
        assertNull(MatrixQuadrant.named("urgent"))
    }
}
