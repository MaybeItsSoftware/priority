# Wear OS

The Wear OS companion (`mobile/android/wear`, Gradle module `:wear`) shows the
phone's day on the wrist and sends a handful of actions back. The phone stays
the source of truth: the watch holds no workspace database and never loads the
Rust core. It draws the last day the phone published, and anything done on the
watch is a request the phone carries out. The Apple Watch app
(`mobile/ios/TaktWatch`) does the same things over WatchConnectivity.

## What it does

- **Today**: the day's open tasks in the order the phone's Today shows them
  (running first, then planned, overdue, due today, starts today; then the
  dailies still owed). A tap completes the task (a daily logs today): the row
  is crossed out briefly, then goes. Play starts a focus block on it.
- **Focus**: the running block's title, elapsed and remaining time (ticking on
  the watch from the start time, with no per-second messages), Pause/Resume,
  Done (complete the task and end the block) and Stop (log the time, keep the
  task open).
- **Tile** and **complication**: the running block, or the next task and how
  many are left today.
- **Offline**: the last day is kept with its age; actions taken while the phone
  is out of reach are queued on the watch and sent, oldest first, when it is
  back. They are drawn straight away, so the watch looks as it will once the
  phone has caught up.

## Transport

The Wearable Data Layer (`play-services-wearable`). The schema is defined once,
in pure Kotlin, in `mobile/android/wearcontract` (`WearContract.kt`), which
both apps depend on and which has its own tests (`:wearcontract:test`).

- **Phone → watch**: a `DataItem` at `/takt/today`, key `snapshot`, holding the
  day as JSON (`WearSnapshot`: tasks with id, title, detail, isDaily,
  dailyDone, isRunning, estimateSeconds; the session's taskId, phase,
  startedAt, accumulated, plannedSeconds; generatedAt; and the ids of the
  watch's actions the phone has carried out). `WearBridge` in `:app` publishes
  it from the same flows `TodayViewModel` reads, shaped by the same
  `DayShaping.build`, whenever the day or the block changes, and only while a
  watch declaring the `takt_watch` capability is paired.
- **Watch → phone**: `MessageClient` messages at `/takt/action` carrying a
  `WearAction` (`id`, `action` = complete | logDaily | start | pause | resume |
  stop | done, `taskId`, `issuedAt`), and `/takt/refresh`, which asks the phone
  to publish again. `WearActionService` in `:app` (a `WearableListenerService`,
  so a message starts the phone's process) runs each action through the
  `UndoCenter`, as Today and the focus notification do, so it lands as an
  ordinary undoable step on the phone. Each checks the state first and the
  phone remembers the last few action ids, so a queued action replayed after
  the phone moved on does nothing.

The phone declares `takt_phone` (`app/src/main/res/values/wear.xml`); the watch
declares `takt_watch`. Both apps have the same applicationId
(`uk.co.maybeitssoftware.takt`) and the same signing key, which the Data Layer
requires before it will pair them.

## Versions

The watch ships as its own artifact in the same Play listing, so its
versionCode must differ from the phone's for the same release. The phone's is
the commit count (about 870 now); the watch's is that plus **1,000,000,000**
(`wearVersionCodeOffset` in `wear/build.gradle.kts`). The two can never
collide, both keep rising with every commit, and the result stays under Play's
limit of 2,100,000,000. versionName is the phone's.

## Building

```bash
(cd mobile/android && ./gradlew :wear:assembleDebug)
adb -s <watch> install -r mobile/android/wear/build/outputs/apk/debug/wear-debug.apk
scripts/build_wear_bundle.sh          # signed .aab into build/play/, beside the phone's
```

A debug watch build pairs only with a debug phone build (and a release with a
release), because the Data Layer matches signatures. For an emulator, create a
Wear OS AVD in Android Studio and pair it with the phone through the Wear OS
app on the phone (or `adb forward tcp:5601 tcp:5601` for an emulated phone).
