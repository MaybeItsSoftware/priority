# Task conditions, scheduling and focus precedence

Status: implemented, 16 September 2026. Final automated verification is recorded
below; interactive macOS verification remains pending.

## Intended behaviour

Focus answers two questions in order: what can I do now, and which of those
tasks should I do first? Conditions and start times determine availability;
deadlines determine urgency; matching the current context promotes work that
would be harder to do elsewhere. Unconditional tasks remain available as
general laptop work.

Interpretation of the request: a task that has been overdue for months comes
before newer overdue tasks and tasks due today. A months-old task whose actual
deadline is today belongs in the due-today group, with its age breaking ties.
Task age is measured from creation; the existing database cannot tell whether
a deadline has repeatedly been postponed. Never infer that history from
`updatedAt`, which also changes for ordinary edits.

## Existing implementation and changes required

- `WorkspaceTask.dueAt` and `estimateSeconds` already exist.
- `TaskMetadata.startAt` already exists, with a store API and a schedule-for-later
  action. Expose it in the inspector and include it in atomic drafts and saves.
- `Sources/PriorityCore/NextUpSelector.swift` filters future starts, then uses
  additive scores. Dailies receive the largest single contribution; overdue age
  stops increasing after 30 days. Manual `focusRank` positions can override all
  urgency. Replace these behaviours with the policy below.
- `WorkspaceStore+Dailies.swift` builds candidates from open leaf tasks in
  unarchived lists. Keep this scope and make completed-today and off-schedule
  daily treatment explicit rather than relying on a missing daily score.
- `WorkspaceViewModel+Dailies.swift` owns focus staging, estimates and ordering;
  `WorkspaceViewModel+Focus.swift` starts and completes sessions.
- `WorkspaceStore.swift` stores focus sessions and per-item `plannedSeconds`.
  Advancing the queue currently leaves the previous session work duration in
  place. Ordinary block completion also completes the underlying task.
- The main panel and floating timer share workspace sessions. Extend that path
  and its shared display policy; keep local UUID tasks distinct from the legacy
  Checkvist timer's integer IDs.

## 1. Conditions and current context

Provide a workspace condition catalogue, initially offering Home, Campus,
Private and Floor space. Users can add and rename conditions. Reference each by
stable ID so renaming cannot change which tasks require it. Conditions are
separate from descriptive tags.

Use requirement groups: all groups must match, but any alternative inside a
group is sufficient. The UI initially offers a straightforward list of required
conditions, plus an explicit “either” option.

Examples:

- No requirements: available anywhere, with the assumed laptop setup.
- Home: requires Home to be active.
- Campus + Private: both must be active.
- Home or Campus, plus Floor space: one location and Floor space must be active.

Current context is set manually through chips in the focus header. An optional
location category allows one current location; capabilities such as Private and
Floor space can be combined freely. Unknown conditions count as unavailable.
No conditions active means unconditional tasks are available, not every task.

Selecting a context both reveals matching tasks and promotes them within the
urgency rules. Do not multiply promotion by the number of condition labels;
adding redundant labels must not improve rank. An optional context end time
(“on campus until 4pm”) makes a temporary opportunity visible and limits the
available work window. Context changes never silently interrupt a running block.

Remember the condition catalogue permanently. Restore the last context as a
visible suggestion requiring confirmation after restart; do not silently assume
the user is still at yesterday's location. An end time expires automatically.
Keep confirmed context and time budgets outside task edit undo history.

Initial release applies requirements directly to executable tasks. Project
parents remain planning containers. Provide a deliberate, undoable “apply to
descendants” action rather than implicit inheritance, so moving a task cannot
unexpectedly change its conditions or schedule.

## 2. Start times, deadlines and estimates

| Field | Meaning | Focus behaviour |
| --- | --- | --- |
| Start | Earliest date/time to work | Exclude before it; mark scheduled work ready afterwards. |
| Due | Completion deadline | Promote by lateness, today and time remaining. |
| Estimate | Expected total work | Seed sessions and calculate remaining work and deadline risk. |
| Minimum block, optional | Shortest useful uninterrupted sitting | Exclude when the available work window is too short. |
| Must finish in one sitting | Work cannot usefully be split | Require enough time for the full remaining estimate. |

Start and Due are independent optional fields. Support date-only and timed
deadlines. A date-only deadline remains due today throughout that local day and
becomes overdue at the following day's boundary. An exact time becomes overdue
immediately after that instant. Store date-only values as calendar dates rather
than pretending midnight is the deadline; use the current app calendar/timezone
to resolve their boundaries. Preserve existing `dueAt` values as exact instants.
Start controls currently select an explicit date and time.

Reject a newly entered start after its effective deadline, showing the error
beside the fields and retaining the draft. Surface contradictory legacy data
without silently adjusting it. Future-start overdue tasks appear among blocked
deadlines with “scheduled to start later,” not among executable recommendations.

Estimates keep their exact stored seconds and fractional-minute editing. Unknown
and zero estimates are not evidence that a task fits any window. Require a
positive estimate for one-sitting tasks. Ordinary tasks can have no estimate.

## 3. Available time as a condition

Add “I have 15 / 30 / 60 minutes,” a custom duration and “until [time]” to Focus.
Treat this as a numeric constraint, not a catalogue entry called “30 minutes.”
Convert a chosen duration into an absolute end time when confirmed so it shrinks
as time passes. The usable window is the earlier of that end time and an active
context's expiry; unset limits mean unrestricted time.

Offer two explicit modes:

- **Make progress** (default): a long task can appear when its minimum useful
  block fits. Default minimum is one minute, matching the current workspace
  timer's minimum. Suggest a block capped by the available window.
- **Finish something**: require a known positive remaining estimate that fits.
  Unestimated tasks appear separately with “add an estimate to check fit.”

One-sitting tasks always use the stricter test. A 60-minute task needing one
sitting is unavailable in a 20-minute window; a splittable 60-minute task can
offer a 20-minute progress block. Sub-minute windows have no automatic picks.
The existing workspace queue has no automatic break handoff; its budget tests
apply to work blocks. Legacy plugin timer breaks retain their existing behaviour.

## 4. Deterministic precedence

Evaluate availability first: workspace/list/task state, executable leaf, daily
schedule, start, requirements and time fit. Return excluded candidates with
structured reasons rather than throwing away the information.

Then rank eligible tasks in these strict groups:

| Order | Group | Primary ordering |
| --- | --- | --- |
| 1 | Overdue | Oldest effective deadline first, without a 30-day cap. |
| 2 | Due today, not yet overdue | Earliest effective deadline first; older task first for equal deadlines. |
| 3 | Deadline at risk | Future deadline whose remaining work plus a buffer consumes the time left; lowest slack first. |
| 4 | Other available work | Context opportunity, scheduled readiness, daily/Today commitment and importance. |

Deadline slack is `effectiveDeadline - now - remainingWork - buffer`. Initially
use a buffer of the greater of five minutes or 20% of remaining work, defined
as named policy constants. Negative slack means “may miss deadline,” not a
guarantee of failure. A missing estimate cannot produce a reliable slack value;
nearby deadlines still contribute urgency in group 4 using the existing 14-day
horizon. This model does not claim to account for sleep or an external calendar.

Within group 4, compare this tuple, in order:

1. Matched conditional work before unconditional work; an expiring matched
   context before a context with no expiry.
2. Explicit start time has arrived, before work with no start time. An elapsed
   start is a readiness signal, not a deadline that gains infinite urgency.
3. Outstanding scheduled daily or task placed in Today, before uncommitted work.
4. Matrix importance and explicit priority, then approaching-deadline urgency.
5. Older creation time, then shorter known remaining work.
6. Persistent task order and stable ID for reproducible ties.

In groups 1–3, deadline/slack ordering wins; use context, readiness, commitment,
importance, priority and stable tie-breakers only when primary values tie.
Keep the oldest-created due-today tie-break before these secondary signals.
A matching campus task must not overtake a months-overdue eligible laptop task.

Manual ordering operates within group 4, and among tasks with equal primary
deadline/slack values in groups 1–3, after availability filtering. It cannot
push ordinary work above overdue deadlines, reverse overdue age or restore an
unavailable task. Keep existing pins, interpret their relative order within
these allowed sets, and label the restriction in Focus. Context changes must
not rewrite pins.
Explicitly choosing to start another task remains possible. That choice affects
the current session, not future automatic precedence.

Return a primary explanation and supporting facts: “overdue by 42 days,” “due
today; added three months ago,” “campus is available until 4pm,” “start time
reached,” or “12 minutes of work fits your 20-minute window.” Replace the current
largest-score-term explanation with these actual ordering decisions.

Show blocked deadlines separately: “3 urgent tasks unavailable: needs Home,
starts tomorrow, needs 45 uninterrupted minutes.” Keep tasks visible in planning
views; show unmet conditions rather than making them disappear from the app.

## 5. Timer and progress integration

Keep three quantities distinct: estimated total task work, remaining task work,
and the duration committed to for this sitting. Editing an estimate must not
rewrite elapsed time or an active session's chosen duration.

Add canonical focus work records for all credited blocks, including blocks with
no quality score. Quality awards remain optional and continue using actual work
minutes. Daily contributions and awards are credited with the work block in one
transaction; remaining task work reads only canonical blocks, not their sum.

Compute remaining work from the current total estimate minus credited work,
clamped to zero. If an open task reaches zero, show “estimate exceeded” and ask
for a revised estimate or explicit session duration; never mark it completed or
pretend it requires no further work. Under a strict finish filter it needs a
revised estimate. Daily fit uses today's remaining target, not lifetime task
time. A fully met daily drops out of today's automatic recommendations.

Seed a session from the day's remaining daily target, otherwise the task's
remaining estimate, otherwise the existing 25-minute default. Cap splittable
work at the usable window; retain the existing editable session estimate.
Revalidate eligibility when Start is pressed, since the context or clock may
have changed since staging. Show the reason and allow a deliberate manual
override; never bypass constraints for an automatic start.

Provide separate “Log progress” and “Complete task” actions. Progress records
time and keeps ordinary tasks open; daily progress accumulates towards the
day's target and daily completion retains its underlying task. Timer expiry
requests a decision rather than completing work automatically. Pausing,
stopping or switching records elapsed active work exactly once and excludes
paused time. Recovery after restart must offer review of interrupted time rather
than crediting all time while the app was closed.

Use one shared block-ending transaction and idempotency key to prevent a double
click, panel/floating timer race or restart retry from crediting time twice.
Update both the main panel and floating timer from the same persisted session.

When a queue advances, recheck the next task's availability and use that item's
own planned duration, falling back to its current remaining-work suggestion.
Keep blocked items pending with explanations and select the next eligible item;
if none fit, stop advancement and show the blocked queue. Preserve explicit
queue order among eligible entries and show new urgent automatic suggestions
separately. Never interrupt the current block because rank changed. The Today
handoff must use this same eligibility path rather than blindly starting its
first card.

Historical data cannot reconstruct unscored ordinary work. Backfill work records
only from provably distinct existing focus awards; retain old daily totals as
their existing daily history, without guessing extra ordinary work or counting
an award and its daily contribution twice. Label pre-feature totals as partial
where appropriate.

## 6. Persistence, drafts and architecture

Extend the local workspace path, preserving the organisation/rename fixes:

- `task_conditions`: single stable `id`, workspace, label, optional category,
  archive state and timestamps.
- Requirement groups are stored in `TaskPlanning` JSON on the existing task
  metadata row. Stable catalogue IDs preserve rename identity. Store validation
  prevents empty/duplicate groups and references from another workspace. Keeping
  the complete requirement value together also matches atomic draft conflict
  reconciliation and existing metadata undo.
- Task planning JSON holds optional minimum block, one-sitting flag and a
  calendar-date deadline. Reuse `startAt`; date-only deadlines and `dueAt` are
  mutually exclusive through editor validation.
- `focus_work_blocks`: stable block/idempotency key, task/session references,
  title snapshot, actual active seconds and recording time; preserve history
  when a task is deleted. Keep its original stable task ID for undo restoration.
  Sessions persist pause/accumulated-work state. New awards use the block ID,
  and daily contributions are updated in the same exactly-once credit transaction.
- Store transient current context/end times separately from task undo history.

Make condition catalogue and requirement edits journalled. Catalogue rows use
single stable IDs; requirements are recorded with their metadata row.
Archiving a condition retains existing requirements and their meaning; it
prevents new assignment and remains visible as an archived requirement.
No hard-delete UI is exposed. Removing a used requirement is an explicit
undoable edit, never an implicit consequence of renaming or archiving.

Migration v12 follows v11 and rebuilds capture triggers. New planning columns
are nullable, so old journal JSON replays safely with absent values. Upgrade
tests cover old metadata undo/redo entries and backfilling known focus awards.

Add start, due mode/date, requirements and time-fit fields to
`TaskEditorSnapshot`, `TaskEditorValues` and `TaskEditorField`. Include them in
three-way reconciliation, stale-save detection and one atomic editor save.
Version draft storage with a migration that preserves existing unsaved drafts;
default missing new fields without destroying a corrupt or future-version file.
Conflicting requirement edits should initially reconcile as one field rather
than silently unioning two incompatible sets.

Introduce pure `TaskAvailabilityPolicy` and focus-order policy types in
`PriorityCore`. Flatten workspace records into candidates in one consistent
read, with batched metadata, conditions and logged-work queries rather than a
query per task. Return ranked tasks, blocked tasks and the next reevaluation
instant. Keep SwiftUI limited to inputs, displays and explicit actions.

Reevaluate after edits, history, progress, context changes, session handoffs,
app activation, system clock/timezone changes and the next relevant start,
deadline/day boundary or budget/expiry threshold. Debounce background updates.
Preserve the selected task by capturing its ID before replacing the ladder;
clear staging only when its task becomes unavailable. Do not shift a user's
active selection every second as a time budget decreases.

## 7. Delivery sequence and acceptance

| Step | Deliverable | Required proof |
| --- | --- | --- |
| 1 | Pure availability and precedence policies, candidate/result types | Deterministic tables covering conditions, deadlines, age, starts, time fit and pins. |
| 2 | Conditions/schedule schema, store APIs and draft migration | Upgrade fixtures; atomic rollback; no-op history; full undo/redo; retained draft recovery. |
| 3 | Work records, progress/pause actions and queue duration fixes | Exactly-once credit; paused time excluded; partial work stays open; differing queue durations. |
| 4 | Condition editor, Start/Due controls and current-context/time UI | Stable rename identity; invalid input preserved; visible unmatched requirements and time fit. |
| 5 | Integrated focus ranking, blocked deadlines and reevaluation | Launcher, ladder, Start, Today and queue share eligibility; context expiry and midnight refresh. |
| 6 | Full verification and documentation | Swift suite, lint, Debug/Release builds and manual keyboard/timer checks on disposable fixtures. |

Steps 2 and 3 follow policy tests before the final focus integration; remaining
work calculations must not be shipped before canonical work accounting exists.
Each step should include its own tests and remain reviewable. No external
calendar, location detection or plugin dependency is required for this release.

Essential scenario tests:

- An unconditional task is available with no selected context. A campus task
  requires Campus; Home does not reveal it. All-of and either/or work correctly.
- Selecting Campus promotes a campus task above equivalent general work, but
  never above an eligible older-overdue task. A blocked overdue home task stays
  visible among urgent unavailable work.
- A 90-day overdue task precedes a 3-day overdue task, a task due today and a
  daily. A months-old task due today precedes an otherwise equal new one.
- A task remains unavailable one second before Start and becomes ready exactly
  at Start. Timed deadlines, date-only deadlines, DST and timezone changes work.
- A 20-minute window admits a splittable hour-long task for progress, excludes
  an uninterrupted hour-long task, and admits a known 12-minute finish.
- Unknown/zero/exceeded estimates never pass a finish-fit test. Reducing a total
  estimate below time already worked does not erase time or complete the task.
- Log 15 minutes of a 60-minute task, then reopen: 45 estimated minutes remain,
  task stays open, and no daily or award double counts those 15 minutes.
- A partial daily uses today's remaining target; completed and off-schedule
  dailies do not reappear as ordinary automatic recommendations.
- Queue entries planned for 10 and 40 minutes each receive their own countdown;
  a newly unmet condition defers advancement without discarding queued work.
- Timer expiry, double-click completion, panel/floating timer races, pause,
  interrupted-session recovery and retries never fabricate or duplicate time.
- Rename/archive a condition; requirements retain stable identity. Undo a
  combined conditions/start/estimate Save; all editable values restore together.
- Restart with an old retained draft or old undo entry; migration retains it.
  Advancing time refreshes availability while keeping the current block intact.

Done means the same task data and policy explain every focus recommendation,
unavailable urgent work is visible, deadlines cannot be displaced by incidental
scores or global pins, and all timing surfaces agree on planned and actual work.


## Implementation and verification record

Implemented in `PriorityCore`, `PriorityWorkspace` and the local macOS workspace:

- Context conditions, all-of/either-or requirements, stable renames and archival.
- Atomic Start/Due/condition/block-rule saves, one undo step, retained v1/v2 draft
  loading and per-field conflicts. Invalid saves retain the draft.
- Progress/finish time windows, explicit scheduling readiness, deadline risk,
  uncapped overdue ordering and manual pins restricted by deadline precedence.
- Inspector controls, current-context controls, due/start/condition badges,
  blocked-task explanations and context-specific recommendation reasons.
- Canonical scored/unscored work, partial progress, pause/resume, safe retries,
  per-queue-item countdowns, blocked queue retention and deliberate resume after
  restart. Existing timers consume the same persisted elapsed-time calculation.
- Clock/calendar and time-window reevaluation without interrupting current work.
  Wall-clock changes rebase elapsed work against live uptime; system sleep pauses
  the block before the laptop sleeps.

The work records store only known actual work. Pre-feature unscored ordinary
sessions cannot be reconstructed. Interrupted sessions reopen paused at the last
checkpoint (every 30 seconds), so up to 30 seconds before an unexpected shutdown
may need to be redone or accounted for separately. Normal termination pauses
and persists the current elapsed time.

Automated checks: 1,071 Swift tests passed, including 34 new policy/storage/work
cases, old-schema upgrade and retained-draft regressions. Final Debug and Release app
builds passed. SwiftLint completed
with no errors and five existing file/type size warnings. Manual macOS gesture,
layout and keyboard checks remain pending; no GUI automation tool is available
in this session.


### Manual macOS checks still to run

Use a disposable workspace for this pass:

1. Create unconditional, Campus, Home + Private and either-location tasks; set
   current conditions and verify the ladder and blocked explanations match.
2. Edit Start, date-only/timed Due, estimate and requirements; save with Cmd+S,
   undo/redo and switch tasks with an unsaved draft.
3. Select a short progress window, then Finish something; try a task requiring
   one uninterrupted sitting and a fractional-minute minimum block.
4. Rename and archive a used condition; check requirements retain their meaning
   and newly assigned archived conditions are prevented.
5. Log partial work, pause/resume and end a session from the panel and floating
   timer; verify elapsed work and remaining estimates agree.
6. Advance a queue with different block durations; make an entry unavailable,
   change context and verify a blocked queue resumes deliberately.
7. Let the timer and context expire; cross a deadline/day boundary; sleep and
   wake the Mac; restart during a block and review its paused recovery state.
8. Check narrow-window layouts, scrolling, keyboard focus and sheet dismissal;
   no quality prompt may disappear while leaving an invisible running block.
