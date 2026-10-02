package uk.co.maybeitsadam.priority.benchmark

import androidx.benchmark.macro.MacrobenchmarkScope
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Direction
import androidx.test.uiautomator.Until

const val PACKAGE = "uk.co.maybeitsadam.priority"
private const val TIMEOUT = 10_000L

/**
 * Fills the app's database with the 5,000-task benchmark list through its
 * DUMP-guarded receiver. Idempotent, so every iteration may call it.
 */
fun MacrobenchmarkScope.seedBenchmarkList() {
    device.executeShellCommand(
        "am broadcast -a $PACKAGE.SEED_BENCHMARK -n $PACKAGE/.benchmark.SeedReceiver --ei count 5000",
    )
}

/** From a cold start: Lists tab, the benchmark list, then the outline. */
fun MacrobenchmarkScope.openBenchmarkOutline() {
    device.wait(Until.hasObject(By.res("tab_LISTS")), TIMEOUT)
    device.findObject(By.res("tab_LISTS"))?.click()
    device.wait(Until.hasObject(By.text("Benchmark 5k")), TIMEOUT)
    device.findObject(By.text("Benchmark 5k"))?.click()
    device.wait(Until.hasObject(By.res("outline_list")), TIMEOUT)
}

/** Flings the outline down and back up, the way a person skims a long list. */
fun MacrobenchmarkScope.scrollOutline() {
    val outline = device.findObject(By.res("outline_list")) ?: return
    outline.setGestureMargin(device.displayWidth / 5)
    repeat(3) {
        outline.fling(Direction.DOWN)
        device.waitForIdle()
    }
    repeat(2) {
        outline.fling(Direction.UP)
        device.waitForIdle()
    }
}
