# Takt for Android

A native Android client for Takt's workspace. It keeps its own copy of the
Mac app's SQLite database, on the same schema, and syncs it with the Mac and
iPhone through the sync server (`docs/sync.md`).

This is stage 1: the Gradle project, the policy logic, the data layer and
sync. The app module is a placeholder that opens the workspace and shows task
counts. The Compose UI is built on top of these APIs in the next stage.

## Modules

| Module | Kind | What it holds |
| --- | --- | --- |
| `:core` | Kotlin/JVM library, no Android | Ports of the pure policy code. Each file is named after its Swift original: `PeriodicSchedule`, `TaskCaptureSyntax`, `DueDateParsing`, `NextUpSelector`, `DayBoundary`, `DayPlanSelector`, `StaleFocusPolicy`, `FocusDayTimeline`, `TaskProgressSeries`, `CompletedWorkDigest`, `WorkProgressSummary`, `WorkspaceSidebarOutline`, `KanbanColumn`, `Daily`, `MatrixGeometry`, `WorkspaceModels`, `TaskPlanning`, `TaskOutlineFolding`, `WorkspaceListTree`, `FocusPoints`, `WorkspaceNextUpSnapshot`. It also holds the sync clock (`HybridLogicalClock`) and the wire types (`SyncWire`, kotlinx.serialization). |
| `:data` | Android library | The SQLite store and sync. `db/` holds the connection pool (`WorkspaceDatabase`), the schema (`WorkspaceSchema`), GRDB-compatible dates (`SqlDates`) and a thin statement API (`Db`, `Row`). `workspace/` holds `WorkspaceRepository`, the port of `WorkspaceStore` and its extensions. `sync/` holds `SyncStore`, `SyncEngine`, `SyncScheduler` and `SyncTransport` with its OkHttp implementation. |
| `:app` | Android application | Application id `uk.co.maybeitssoftware.takt`; Kotlin namespace `uk.co.maybeitsadam.takt`. It contains `TaktApplication`, which owns the repository, and a placeholder `MainActivity`. The fonts are bundled in `res/font`: IBM Plex Sans and Lilex. Their OFL licences are in `assets/licenses`. |

minSdk 29, target and compile SDK 36. The versions are pinned in
`gradle/libs.versions.toml`. Compose stays on BOM 2026.05.00 because later
BOMs need compileSdk 37.

## Running the tests

```bash
cd mobile/android
./gradlew :core:test :data:testDebugUnitTest :app:assembleDebug lint
```

The `:data` tests run on the JVM against the real bundled SQLite, with FTS5,
not against a mock. The build unpacks the host's native library from
`androidx.sqlite:sqlite-bundled-jvm` and puts it on `java.library.path` (see
`unpackSqliteHostNatives` in `data/build.gradle.kts`). The sync tests run two
database files against `InMemorySyncServer`, which applies the server's merge
rules from `docs/sync.md`.

To try the app on an emulator:

```bash
~/Library/Android/sdk/emulator/emulator -avd flutter_android -no-window -no-audio &
./gradlew :app:installDebug
adb shell am start -n uk.co.maybeitssoftware.takt/uk.co.maybeitsadam.takt.MainActivity
```

## Where the schema comes from

The Swift app owns the schema, and Android does not keep its own copy. At
build time, the `copyWorkspaceSchema` task in `data/build.gradle.kts` copies
`cli/src/fixtures/workspace_schema.sql` into the module's generated resources.
That fixture is the file `scripts/dump_workspace_schema.sh` regenerates from
the Mac app's migrations, and the Rust CLI's tests use the same file.

A fresh database runs the following steps in one transaction:

1. Execute the fixture.
2. Apply `v17_sync` exactly as `WorkspaceStore+Sync.swift` writes it:
   - `sync_control`, `sync_outbox` and `sync_state`.
   - The outbox triggers on every synced table.
   - A `grdb_migrations` row.

   Step 2 checks `grdb_migrations` first, so it is skipped once the fixture
   itself carries v17.

`WorkspaceSchemaTest` checks that the resulting `sqlite_master` equals the
fixture's objects plus exactly the v17 objects.

When the Mac app adds a migration, regenerate the fixture. If the migration
changes the columns of a synced or journalled table, the triggers have to be
reinstalled, and the Kotlin repository's row mapping (`workspace/Records.kt`)
needs the new column.

Rows are written the way GRDB writes them:

- Dates are `"yyyy-MM-dd HH:mm:ss.SSS"` UTC text.
- Booleans are `0` and `1`.
- Ids are uppercase UUIDs.
- JSON columns use Foundation's encoding. `/` is escaped, and dates inside `planningJSON` are seconds since 2001.

## Using the data layer from a ViewModel

```kotlin
val repository = (application as TaktApplication).repository
val workspace = repository.bootstrapIfNeeded()           // suspend
val lists: Flow<List<TaskList>> = repository.observeLists(workspace.id)
repository.createTask(capturing = "Write report 45m #work !1", listId = inboxId)
repository.undo()
```

Every read is a suspend function. Most also have an `observe…` variant that
returns a `Flow` and re-queries when a write touches its tables. Every edit to
the user's work runs as one undo step, under the same labels the Mac uses.

Accounts are Supabase Auth users (docs/sync.md). `SupabaseAccounts` signs in
with supabase-kt — email and password, Google through Credential Manager, or
Apple in a Custom Tab that comes back to `takt://auth-callback` — and
hands the transport its tokens. Sync is then set up like this:

```kotlin
val deviceId = credentialStore.deviceId()                // a uuid, made once and kept
val transport = OkHttpSyncTransport(BuildConfig.SYNC_SERVER, deviceId, accounts.tokens)
transport.registerDevice("Adam's Pixel")                 // POST /v1/devices, after every sign-in
val store = SyncStore(database).also { it.beginSync(deviceId, BuildConfig.SYNC_SERVER) }
val engine = SyncEngine(store, transport, deviceId)
val scheduler = SyncScheduler(engine, scope).apply { watchLocalWrites(store); start() }
```

Every request sends `Authorization: Bearer <access token>` and
`X-Priority-Device`. The token is refreshed before a request when it is about
to expire, and once more on a `401`; only a refresh Supabase refuses stops the
scheduler and has Settings ask for a sign-in. The session (never the
password) is kept outside the database, sealed with a Keystore key in
`SyncCredentialStore`.

The default server is `https://takt-sync.up.railway.app`. Build against
another with `./gradlew -PprioritySyncServer=https://… :app:assembleDebug`;
Settings → Sync can also be pointed elsewhere under "Use a different server".
The Supabase project is `-PprioritySupabaseUrl=…` and `-PprioritySupabaseKey=…`
(the publishable key). Sign in with Google needs the Google Cloud **Web**
OAuth client id as `-PpriorityGoogleWebClientId=…` (or in
`~/.gradle/gradle.properties`); without it the Google button is hidden.
