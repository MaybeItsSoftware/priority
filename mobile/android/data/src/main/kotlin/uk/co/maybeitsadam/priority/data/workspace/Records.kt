package uk.co.maybeitsadam.priority.data.workspace

import uk.co.maybeitsadam.priority.core.DailyContribution
import uk.co.maybeitsadam.priority.core.FocusAward
import uk.co.maybeitsadam.priority.core.FocusQueueItem
import uk.co.maybeitsadam.priority.core.FocusQueueState
import uk.co.maybeitsadam.priority.core.FocusSession
import uk.co.maybeitsadam.priority.core.FocusSessionPhase
import uk.co.maybeitsadam.priority.core.FocusWorkBlock
import uk.co.maybeitsadam.priority.core.ListFolder
import uk.co.maybeitsadam.priority.core.TaskCondition
import uk.co.maybeitsadam.priority.core.TaskList
import uk.co.maybeitsadam.priority.core.TaskListRole
import uk.co.maybeitsadam.priority.core.TaskMetadata
import uk.co.maybeitsadam.priority.core.TaskStatus
import uk.co.maybeitsadam.priority.core.Workspace
import uk.co.maybeitsadam.priority.core.WorkspaceDaily
import uk.co.maybeitsadam.priority.core.WorkspaceItemKind
import uk.co.maybeitsadam.priority.core.WorkspaceTask
import uk.co.maybeitsadam.priority.data.db.Db
import uk.co.maybeitsadam.priority.data.db.Row

// The GRDB records' fetch/insert/update, by hand. `update` writes every
// column like GRDB's `record.update(db)`; the triggers then record only what
// actually differs.

internal fun Row.toWorkspace() = Workspace(
    id = string("id"), name = string("name"), createdAt = instant("createdAt"), updatedAt = instant("updatedAt"),
)

internal fun Row.toFolder() = ListFolder(
    id = string("id"), workspaceId = string("workspaceId"), parentFolderId = stringOrNull("parentFolderId"),
    name = string("name"), sortOrder = int("sortOrder"), createdAt = instant("createdAt"),
    updatedAt = instant("updatedAt"),
)

internal fun Row.toList() = TaskList(
    id = string("id"), workspaceId = string("workspaceId"), folderId = stringOrNull("folderId"),
    name = string("name"), colorHex = stringOrNull("colorHex"), sortOrder = int("sortOrder"),
    isArchived = bool("isArchived"), systemRole = TaskListRole.of(stringOrNull("systemRole")),
    visibleRootTaskId = stringOrNull("visibleRootTaskId"), completedAt = instantOrNull("completedAt"),
    createdAt = instant("createdAt"), updatedAt = instant("updatedAt"),
)

internal fun Row.toTask() = WorkspaceTask(
    id = string("id"), listId = string("listId"), parentTaskId = stringOrNull("parentTaskId"),
    title = string("title"), notes = string("notes"), status = TaskStatus.of(string("status")),
    sortOrder = int("sortOrder"), dueAt = instantOrNull("dueAt"), estimateSeconds = intOrNull("estimateSeconds"),
    sourceSystem = stringOrNull("sourceSystem"), sourceId = stringOrNull("sourceId"),
    itemKind = WorkspaceItemKind.of(stringOrNull("itemKind")), isPromoted = boolOrNull("isPromoted"),
    archivedAt = instantOrNull("archivedAt"), completedAt = instantOrNull("completedAt"),
    createdAt = instant("createdAt"), updatedAt = instant("updatedAt"),
)

internal fun Row.toMetadata() = TaskMetadata(
    taskId = string("taskId"), priority = intOrNull("priority"), startAt = instantOrNull("startAt"),
    tagsJSON = string("tagsJSON"), recurrenceRule = stringOrNull("recurrenceRule"),
    matrixUrgency = intOrNull("matrixUrgency"), matrixImportance = intOrNull("matrixImportance"),
    kanbanColumn = stringOrNull("kanbanColumn"), externalLinksJSON = string("externalLinksJSON"),
    focusRank = intOrNull("focusRank"), updatedAt = instant("updatedAt"), planningJSON = stringOrNull("planningJSON"),
)

internal fun Row.toSession() = FocusSession(
    id = string("id"), startedAt = instant("startedAt"), endedAt = instantOrNull("endedAt"),
    phase = FocusSessionPhase.of(string("phase")), activeTaskId = stringOrNull("activeTaskId"),
    activeTaskStartedAt = instant("activeTaskStartedAt"), workDurationSeconds = int("workDurationSeconds"),
    breakDurationSeconds = int("breakDurationSeconds"), breakEndsAt = instantOrNull("breakEndsAt"),
    activeBlockId = stringOrNull("activeBlockId"), accumulatedSeconds = intOrNull("accumulatedSeconds"),
    pausedAt = instantOrNull("pausedAt"), checkpointAt = instantOrNull("checkpointAt"),
)

internal fun Row.toQueueItem() = FocusQueueItem(
    id = string("id"), sessionId = string("sessionId"), taskId = string("taskId"), sortOrder = int("sortOrder"),
    state = FocusQueueState.of(string("state")), plannedSeconds = intOrNull("plannedSeconds"),
    completedAt = instantOrNull("completedAt"), skippedAt = instantOrNull("skippedAt"),
    createdAt = instant("createdAt"),
)

internal fun Row.toDaily() = WorkspaceDaily(
    id = string("id"), taskId = string("taskId"), activeWeekdaysMask = int("activeWeekdaysMask"),
    intervalDays = intOrNull("intervalDays"), intervalAnchor = instantOrNull("intervalAnchor"),
    targetSeconds = intOrNull("targetSeconds"), sortOrder = int("sortOrder"), archivedAt = instantOrNull("archivedAt"),
    legacyDailyId = stringOrNull("legacyDailyId"), createdAt = instant("createdAt"), updatedAt = instant("updatedAt"),
)

internal fun Row.toContribution() = DailyContribution(
    id = string("id"), dailyId = string("dailyId"), taskId = string("taskId"), dayKey = string("dayKey"),
    secondsLogged = int("secondsLogged"), completedAt = instantOrNull("completedAt"), createdAt = instant("createdAt"),
)

internal fun Row.toCondition() = TaskCondition(
    id = string("id"), workspaceId = string("workspaceId"), name = string("name"), isLocation = bool("isLocation"),
    isArchived = bool("isArchived"), createdAt = instant("createdAt"), updatedAt = instant("updatedAt"),
)

internal fun Row.toWorkBlock() = FocusWorkBlock(
    id = string("id"), sessionId = stringOrNull("sessionId"), taskId = stringOrNull("taskId"),
    taskTitle = string("taskTitle"), seconds = int("seconds"), recordedAt = instant("recordedAt"),
    originalTaskId = stringOrNull("originalTaskId"),
)

internal fun Row.toAward() = FocusAward(
    id = string("id"), sessionId = stringOrNull("sessionId"), taskId = stringOrNull("taskId"),
    taskTitle = string("taskTitle"), seconds = int("seconds"), minutes = double("minutes"),
    multiplier = double("multiplier"), points = double("points"), awardedAt = instant("awardedAt"),
)

// Fetch by key.

internal fun Db.workspace(id: String) = queryOne("SELECT * FROM workspaces WHERE id = ?", id) { it.toWorkspace() }
internal fun Db.folder(id: String) = queryOne("SELECT * FROM list_folders WHERE id = ?", id) { it.toFolder() }
internal fun Db.list(id: String) = queryOne("SELECT * FROM task_lists WHERE id = ?", id) { it.toList() }
internal fun Db.task(id: String) = queryOne("SELECT * FROM tasks WHERE id = ?", id) { it.toTask() }
internal fun Db.metadata(taskId: String) =
    queryOne("SELECT * FROM task_metadata WHERE taskId = ?", taskId) { it.toMetadata() }
internal fun Db.session(id: String) = queryOne("SELECT * FROM focus_sessions WHERE id = ?", id) { it.toSession() }
internal fun Db.daily(id: String) = queryOne("SELECT * FROM dailies WHERE id = ?", id) { it.toDaily() }
internal fun Db.condition(id: String) =
    queryOne("SELECT * FROM task_conditions WHERE id = ?", id) { it.toCondition() }
internal fun Db.workBlockExists(id: String) = exists("SELECT 1 FROM focus_work_blocks WHERE id = ?", id)

/** Siblings in GRDB's `.order(sortOrder, createdAt, id)`. */
internal fun Db.taskSiblings(listId: String, parentTaskId: String?, withId: Boolean = true): List<WorkspaceTask> =
    query(
        "SELECT * FROM tasks WHERE listId = ? AND parentTaskId IS ? ORDER BY sortOrder, createdAt" +
            if (withId) ", id" else "",
        listId, parentTaskId,
    ) { it.toTask() }

// Insert / update.

internal fun Db.insert(w: Workspace) = execute(
    "INSERT INTO workspaces (id, name, createdAt, updatedAt) VALUES (?, ?, ?, ?)",
    w.id, w.name, w.createdAt, w.updatedAt,
)

internal fun Db.insert(f: ListFolder) = execute(
    "INSERT INTO list_folders (id, workspaceId, parentFolderId, name, sortOrder, createdAt, updatedAt) " +
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
    f.id, f.workspaceId, f.parentFolderId, f.name, f.sortOrder, f.createdAt, f.updatedAt,
)

internal fun Db.update(f: ListFolder) = execute(
    "UPDATE list_folders SET workspaceId = ?, parentFolderId = ?, name = ?, sortOrder = ?, createdAt = ?, " +
        "updatedAt = ? WHERE id = ?",
    f.workspaceId, f.parentFolderId, f.name, f.sortOrder, f.createdAt, f.updatedAt, f.id,
)

internal fun Db.insert(l: TaskList) = execute(
    "INSERT INTO task_lists (id, workspaceId, folderId, name, colorHex, sortOrder, isArchived, systemRole, " +
        "visibleRootTaskId, completedAt, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    l.id, l.workspaceId, l.folderId, l.name, l.colorHex, l.sortOrder, l.isArchived, l.systemRole?.raw,
    l.visibleRootTaskId, l.completedAt, l.createdAt, l.updatedAt,
)

internal fun Db.update(l: TaskList) = execute(
    "UPDATE task_lists SET workspaceId = ?, folderId = ?, name = ?, colorHex = ?, sortOrder = ?, isArchived = ?, " +
        "systemRole = ?, visibleRootTaskId = ?, completedAt = ?, createdAt = ?, updatedAt = ? WHERE id = ?",
    l.workspaceId, l.folderId, l.name, l.colorHex, l.sortOrder, l.isArchived, l.systemRole?.raw,
    l.visibleRootTaskId, l.completedAt, l.createdAt, l.updatedAt, l.id,
)

internal fun Db.insert(t: WorkspaceTask) = execute(
    "INSERT INTO tasks (id, listId, parentTaskId, title, notes, status, sortOrder, dueAt, estimateSeconds, " +
        "createdAt, updatedAt, sourceSystem, sourceId, itemKind, isPromoted, archivedAt, completedAt) " +
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    t.id, t.listId, t.parentTaskId, t.title, t.notes, t.status.raw, t.sortOrder, t.dueAt, t.estimateSeconds,
    t.createdAt, t.updatedAt, t.sourceSystem, t.sourceId, t.itemKind?.raw, t.isPromoted, t.archivedAt, t.completedAt,
)

internal fun Db.update(t: WorkspaceTask) = execute(
    "UPDATE tasks SET listId = ?, parentTaskId = ?, title = ?, notes = ?, status = ?, sortOrder = ?, dueAt = ?, " +
        "estimateSeconds = ?, createdAt = ?, updatedAt = ?, sourceSystem = ?, sourceId = ?, itemKind = ?, " +
        "isPromoted = ?, archivedAt = ?, completedAt = ? WHERE id = ?",
    t.listId, t.parentTaskId, t.title, t.notes, t.status.raw, t.sortOrder, t.dueAt, t.estimateSeconds,
    t.createdAt, t.updatedAt, t.sourceSystem, t.sourceId, t.itemKind?.raw, t.isPromoted, t.archivedAt,
    t.completedAt, t.id,
)

internal fun Db.insert(m: TaskMetadata) = execute(
    "INSERT INTO task_metadata (taskId, priority, startAt, tagsJSON, recurrenceRule, matrixUrgency, " +
        "matrixImportance, kanbanColumn, externalLinksJSON, updatedAt, focusRank, planningJSON) " +
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    m.taskId, m.priority, m.startAt, m.tagsJSON, m.recurrenceRule, m.matrixUrgency, m.matrixImportance,
    m.kanbanColumn, m.externalLinksJSON, m.updatedAt, m.focusRank, m.planningJSON,
)

internal fun Db.update(m: TaskMetadata) = execute(
    "UPDATE task_metadata SET priority = ?, startAt = ?, tagsJSON = ?, recurrenceRule = ?, matrixUrgency = ?, " +
        "matrixImportance = ?, kanbanColumn = ?, externalLinksJSON = ?, updatedAt = ?, focusRank = ?, " +
        "planningJSON = ? WHERE taskId = ?",
    m.priority, m.startAt, m.tagsJSON, m.recurrenceRule, m.matrixUrgency, m.matrixImportance, m.kanbanColumn,
    m.externalLinksJSON, m.updatedAt, m.focusRank, m.planningJSON, m.taskId,
)

/** GRDB's `save`: update when the row exists, insert otherwise. */
internal fun Db.save(m: TaskMetadata) {
    if (exists("SELECT 1 FROM task_metadata WHERE taskId = ?", m.taskId)) update(m) else insert(m)
}

internal fun Db.insert(s: FocusSession) = execute(
    "INSERT INTO focus_sessions (id, startedAt, endedAt, phase, activeTaskId, workDurationSeconds, " +
        "breakDurationSeconds, breakEndsAt, activeTaskStartedAt, activeBlockId, accumulatedSeconds, pausedAt, " +
        "checkpointAt) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    s.id, s.startedAt, s.endedAt, s.phase.raw, s.activeTaskId, s.workDurationSeconds, s.breakDurationSeconds,
    s.breakEndsAt, s.activeTaskStartedAt, s.activeBlockId, s.accumulatedSeconds, s.pausedAt, s.checkpointAt,
)

internal fun Db.update(s: FocusSession) = execute(
    "UPDATE focus_sessions SET startedAt = ?, endedAt = ?, phase = ?, activeTaskId = ?, workDurationSeconds = ?, " +
        "breakDurationSeconds = ?, breakEndsAt = ?, activeTaskStartedAt = ?, activeBlockId = ?, " +
        "accumulatedSeconds = ?, pausedAt = ?, checkpointAt = ? WHERE id = ?",
    s.startedAt, s.endedAt, s.phase.raw, s.activeTaskId, s.workDurationSeconds, s.breakDurationSeconds,
    s.breakEndsAt, s.activeTaskStartedAt, s.activeBlockId, s.accumulatedSeconds, s.pausedAt, s.checkpointAt, s.id,
)

internal fun Db.insert(q: FocusQueueItem) = execute(
    "INSERT INTO focus_queue_items (id, sessionId, taskId, sortOrder, state, completedAt, skippedAt, createdAt, " +
        "plannedSeconds) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    q.id, q.sessionId, q.taskId, q.sortOrder, q.state.raw, q.completedAt, q.skippedAt, q.createdAt, q.plannedSeconds,
)

internal fun Db.update(q: FocusQueueItem) = execute(
    "UPDATE focus_queue_items SET sessionId = ?, taskId = ?, sortOrder = ?, state = ?, completedAt = ?, " +
        "skippedAt = ?, createdAt = ?, plannedSeconds = ? WHERE id = ?",
    q.sessionId, q.taskId, q.sortOrder, q.state.raw, q.completedAt, q.skippedAt, q.createdAt, q.plannedSeconds, q.id,
)

internal fun Db.insert(d: WorkspaceDaily) = execute(
    "INSERT INTO dailies (id, taskId, activeWeekdaysMask, intervalDays, intervalAnchor, targetSeconds, sortOrder, " +
        "archivedAt, legacyDailyId, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    d.id, d.taskId, d.activeWeekdaysMask, d.intervalDays, d.intervalAnchor, d.targetSeconds, d.sortOrder,
    d.archivedAt, d.legacyDailyId, d.createdAt, d.updatedAt,
)

internal fun Db.update(d: WorkspaceDaily) = execute(
    "UPDATE dailies SET taskId = ?, activeWeekdaysMask = ?, intervalDays = ?, intervalAnchor = ?, " +
        "targetSeconds = ?, sortOrder = ?, archivedAt = ?, legacyDailyId = ?, createdAt = ?, updatedAt = ? " +
        "WHERE id = ?",
    d.taskId, d.activeWeekdaysMask, d.intervalDays, d.intervalAnchor, d.targetSeconds, d.sortOrder, d.archivedAt,
    d.legacyDailyId, d.createdAt, d.updatedAt, d.id,
)

internal fun Db.insert(c: DailyContribution) = execute(
    "INSERT INTO daily_contributions (id, dailyId, taskId, dayKey, secondsLogged, completedAt, createdAt) " +
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
    c.id, c.dailyId, c.taskId, c.dayKey, c.secondsLogged, c.completedAt, c.createdAt,
)

internal fun Db.update(c: DailyContribution) = execute(
    "UPDATE daily_contributions SET dailyId = ?, taskId = ?, dayKey = ?, secondsLogged = ?, completedAt = ?, " +
        "createdAt = ? WHERE id = ?",
    c.dailyId, c.taskId, c.dayKey, c.secondsLogged, c.completedAt, c.createdAt, c.id,
)

internal fun Db.insert(c: TaskCondition) = execute(
    "INSERT INTO task_conditions (id, workspaceId, name, isLocation, isArchived, createdAt, updatedAt) " +
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
    c.id, c.workspaceId, c.name, c.isLocation, c.isArchived, c.createdAt, c.updatedAt,
)

internal fun Db.update(c: TaskCondition) = execute(
    "UPDATE task_conditions SET workspaceId = ?, name = ?, isLocation = ?, isArchived = ?, createdAt = ?, " +
        "updatedAt = ? WHERE id = ?",
    c.workspaceId, c.name, c.isLocation, c.isArchived, c.createdAt, c.updatedAt, c.id,
)

internal fun Db.insert(b: FocusWorkBlock) = execute(
    "INSERT INTO focus_work_blocks (id, sessionId, taskId, taskTitle, seconds, recordedAt, originalTaskId) " +
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
    b.id, b.sessionId, b.taskId, b.taskTitle, b.seconds, b.recordedAt, b.originalTaskId,
)

internal fun Db.insert(a: FocusAward) = execute(
    "INSERT INTO focus_awards (id, sessionId, taskId, taskTitle, seconds, minutes, multiplier, points, awardedAt) " +
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    a.id, a.sessionId, a.taskId, a.taskTitle, a.seconds, a.minutes, a.multiplier, a.points, a.awardedAt,
)
