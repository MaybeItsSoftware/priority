package uk.co.maybeitsadam.takt.baselineprofile

import androidx.benchmark.macro.junit4.BaselineProfileRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Generates the app's baseline profile: a cold start to Today, then the Lists
 * tab and a fling through the seeded 5,000-task outline.
 *
 *   ./gradlew :app:generateBaselineProfile      (a device or emulator connected)
 *
 * The result lands in app/src/release/generated/baselineProfiles and is committed.
 */
@RunWith(AndroidJUnit4::class)
@LargeTest
class BaselineProfileGenerator {
    @get:Rule
    val rule = BaselineProfileRule()

    @Test
    fun generate() = rule.collect(packageName = PACKAGE, includeInStartupProfile = true) {
        seedBenchmarkList()
        pressHome()
        startActivityAndWait()
        openBenchmarkOutline()
        scrollOutline()
    }
}
