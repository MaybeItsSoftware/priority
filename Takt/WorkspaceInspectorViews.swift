import TaktWorkspace
import TaktCore
import SwiftUI

struct LocalTaskInspector: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let task: WorkspaceTask
  let focusRequest: Int
  let requestedFocusArea: WorkspaceFocusArea
  /// The dock's scroll view, so a stop below the fold comes into view as the
  /// keyboard reaches it.
  var scroll: ScrollViewProxy?
  /// Which stop has the keyboard — see `inspectorStop`.
  @FocusState private var focus: String?
  /// The row cursor, and whether its row is being edited (`InspectorCursor`).
  @State private var cursor = InspectorCursor()
  /// The draft as it was when the field being edited took the caret, so Esc
  /// can put the field back.
  @State private var editStart: TaskEditorValues?
  /// The last press or step handed to one stop.
  @State private var stopRequest: InspectorStopRequest?

  var body: some View {
    // A stack, not a Group: a Group hands its modifiers to each child, and
    // the stops have to be gathered once, over all of them.
    VStack(alignment: .leading, spacing: theme.space.sm) {
      if let draft = model.taskEditor.draft(for: task.id) {
        editor(draft)
      } else if let error = model.taskEditor.errors[task.id] {
        Text(error).foregroundStyle(theme.danger)
      } else {
        ProgressView()
      }
    }
    .environment(\.inspectorFocus, $focus)
    .environment(\.inspectorCursor, model.keyboardFocusArea == .inspector ? cursor.current : nil)
    .environment(\.inspectorEditing, cursor.isEditing)
    .environment(\.inspectorStopRequest, stopRequest)
    .onPreferenceChange(InspectorStopsKey.self) { stops in
      cursor.updateStops(stops)
      // The title can take the caret before its row has been gathered.
      if let focus, cursor.keyboardStop != focus { keyboardMoved(to: focus) }
      sync()
    }
    .onAppear {
      model.openTaskEditor(task)
      if requestedFocusArea == .inspector && model.inspectorFocusesTitle { focus = Self.titleStop }
    }
    .onChange(of: task.id) { _, _ in
      cursor.reset()
      editStart = nil
      model.openTaskEditor(task)
    }
    .onChange(of: focusRequest) { _, _ in
      if requestedFocusArea == .inspector && model.inspectorFocusesTitle { focus = Self.titleStop }
    }
    .onChange(of: focus) { _, focus in
      // The cursor's own moves set the focus it already wants; anything
      // else is a click, or the keyboard going elsewhere.
      if focus != cursor.keyboardStop { keyboardMoved(to: focus) }
    }
    .onChange(of: model.inspectorKeyRequest) { _, request in handle(request.action) }
    .onDisappear { model.taskEditor.flush() }
  }

  static let titleStop = "title"

  /// The editor, in the order a task is decided on.
  ///
  /// What it is, and the thing you came to do with it. Then the three things
  /// that decide whether it is next — when it is due, what it needs, how long
  /// it takes — and then what it says. Then the rest, most used first, and
  /// last the changes that turn it into something else.
  ///
  /// It used to be nine boxed sections under eyebrows, every control in its
  /// own frame, every empty field drawn in full: noisy for a panel you mostly
  /// glance at. Now a row is a muted label and a value, an empty value is one
  /// dim "Add …", and hairlines part the groups (`WorkspaceInspectorRows`).
  @ViewBuilder
  private func editor(_ draft: TaskEditorDraft) -> some View {
    InspectorGroup {
      VStack(alignment: .leading, spacing: theme.space.sm) {
        title(draft)
        primaryAction
      }
    }
    FocusRule(muted: true)
    InspectorGroup { when(draft) }
    InspectorGroup { WorkspaceTaskConditionsEditor(task: task, values: draft.values) }
    InspectorGroup { effort(draft) }
    FocusRule(muted: true)
    InspectorGroup { notes(draft) }
    FocusRule(muted: true)
    InspectorGroup { filing(draft) }
    if !task.isList {
      InspectorGroup {
        WorkspaceDependencyInspectorSection(task: task)
        WorkspaceWaitingInspectorSection(task: task)
      }
    }
    InspectorGroup { repeating(draft) }
    InspectorGroup { links(draft) }
    FocusRule(muted: true)
    InspectorGroup { actions }
    FocusRule(muted: true)
    saveControls(draft)
  }

  @ViewBuilder
  private func title(_ draft: TaskEditorDraft) -> some View {
    TextField("Task title", text: binding(\.title, fallback: draft.values.title))
      .font(theme.titleFont)
      .foregroundStyle(theme.ink)
      .textFieldStyle(.plain)
      .inspectorField(Self.titleStop)
      .onSubmit { model.saveTaskEditor(task) }
      .help("Task title · ↩ or ⌘S saves")
    if let error = model.taskEditor.errors[task.id] {
      Text(error).font(theme.captionFont).foregroundStyle(theme.danger)
    }
    if let error = model.taskEditor.persistenceError {
      Text(error).font(theme.captionFont).foregroundStyle(theme.danger)
    }
    ForEach(TaskEditorField.allCases.filter { draft.conflicts.contains($0) }, id: \.self) { field in
      VStack(alignment: .leading, spacing: theme.space.xs) {
        Text("\(field.label) changed in the saved task")
          .font(theme.bodyFont(size: theme.scale.caption, weight: .medium))
          .foregroundStyle(theme.ink)
        Group {
          Text("Saved: \(display(field, in: draft.baseline.values))").lineLimit(3)
          Text("Your edit: \(display(field, in: draft.values))").lineLimit(3)
        }
        .font(theme.captionFont)
        .foregroundStyle(theme.muted)
        HStack(spacing: theme.space.xs) {
          Button("Use saved") { model.taskEditor.resolve(task.id, field: field, useSaved: true) }
            .inspectorStop("conflict.\(field).saved", press: { model.taskEditor.resolve(task.id, field: field, useSaved: true) })
          Button("Keep my edit") { model.taskEditor.resolve(task.id, field: field, useSaved: false) }
            .inspectorStop("conflict.\(field).mine", press: { model.taskEditor.resolve(task.id, field: field, useSaved: false) })
        }
        .buttonStyle(FocusActionButtonStyle())
      }
      .padding(theme.space.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        theme.warning.opacity(Theme.statusFillOpacity),
        in: RoundedRectangle(cornerRadius: theme.controlRadius))
      .overlay(
        RoundedRectangle(cornerRadius: theme.controlRadius)
          .strokeBorder(theme.warning.opacity(Theme.statusBorderOpacity), lineWidth: theme.hairline))
    }
  }

  /// What you came here to do. A list has nothing to focus on, so it gets
  /// nothing rather than a button that would do nothing.
  @ViewBuilder
  private var primaryAction: some View {
    if !task.isList {
      if model.activeFocusSession != nil {
        HStack(spacing: theme.space.xs) {
          Button { model.addToFocusQueue(task) } label: {
            Label("Add to queue", systemImage: "plus.circle")
          }
          .buttonStyle(FocusActionButtonStyle(prominent: true))
          .inspectorStop("focus.queue", press: { model.addToFocusQueue(task) })
          .commandHelp(.taskStartFocus, note: "Add this task to the focus queue")
          Button("Open focus") { model.run(.goFocus) }
            .buttonStyle(InspectorValueButtonStyle(tone: .muted))
            .inspectorStop("focus.open", press: { model.run(.goFocus) })
            .commandHelp(.goFocus)
          Spacer(minLength: 0)
          FocusStopButton()
        }
      } else {
        Button { model.startFocus(on: task) } label: {
          Label("Start focus", systemImage: "bolt.fill")
        }
        .buttonStyle(FocusActionButtonStyle(prominent: true))
        .inspectorStop("focus.start", press: { model.startFocus(on: task) })
        .commandHelp(.taskStartFocus, note: "Start a block on this task")
      }
    }
  }

  /// When it is due, and when it may start.
  @ViewBuilder
  private func when(_ draft: TaskEditorDraft) -> some View {
    let hasDue = draft.values.dueAt != nil || draft.values.dueDate != nil
    InspectorOptionalRow(
      "Due", add: "Add date", isSet: hasDue, stop: "due",
      add: {
        model.taskEditor.edit(task.id) {
          $0.dueDate = $0.dueDate ?? TaskCalendarDate.string(.now)
          $0.dueAt = nil
        }
      },
      clear: {
        model.taskEditor.edit(task.id) {
          $0.dueAt = nil
          $0.dueDate = nil
        }
      },
      value: {
        if let dueAt = draft.values.dueAt {
          ThemedDateField(
            selection: Binding(
              get: { model.taskEditor.draft(for: task.id)?.values.dueAt ?? dueAt },
              set: { date in model.taskEditor.edit(task.id) { $0.dueAt = date } }),
            includesTime: true, stop: "due.date", framed: false)
          .commandHelp(.taskEditDue)
        } else if let day = draft.values.dueDate {
          ThemedDateField(
            selection: Binding(
              get: {
                TaskCalendarDate.date(model.taskEditor.draft(for: task.id)?.values.dueDate ?? day)
                  ?? .now
              },
              set: { date in
                model.taskEditor.edit(task.id) {
                  $0.dueDate = TaskCalendarDate.string(date)
                  $0.dueAt = nil
                }
              }), stop: "due.date", framed: false)
          .commandHelp(.taskEditDue)
        }
      })
    .commandHelp(.taskDueToday)
    if hasDue {
      InspectorRow("Time") {
        let exact = draft.values.dueAt != nil
        Toggle(
          isOn: Binding(
            get: { model.taskEditor.draft(for: task.id)?.values.dueAt != nil },
            set: { exact in setExactDue(exact) })
        ) {
          quietValue(exact ? "At a set time" : "Any time that day", tone: exact ? .ink : .dim)
        }
        .toggleStyle(.themedSwitch)
        .inspectorStop("due.exact", press: { toggleExactDue() })
        .help("Due at a set time rather than any time that day")
      }
    }
    InspectorOptionalRow(
      "Start", add: "Add start", isSet: draft.values.startAt != nil, stop: "start",
      add: { model.taskEditor.edit(task.id) { $0.startAt = $0.startAt ?? .now } },
      clear: { model.taskEditor.edit(task.id) { $0.startAt = nil } },
      value: {
        if let start = draft.values.startAt {
          ThemedDateField(
            selection: Binding(
              get: { model.taskEditor.draft(for: task.id)?.values.startAt ?? start },
              set: { date in model.taskEditor.edit(task.id) { $0.startAt = date } }),
            includesTime: true, stop: "start.date", framed: false)
          .commandHelp(.taskEditStart)
        }
      })
    .commandHelp(.taskEditStart)
  }

  private func setExactDue(_ exact: Bool) {
    model.taskEditor.edit(task.id) {
      if exact {
        $0.dueAt = $0.dueDate.flatMap { TaskCalendarDate.date($0) } ?? .now
        $0.dueDate = nil
      } else {
        $0.dueDate = TaskCalendarDate.string($0.dueAt ?? .now)
        $0.dueAt = nil
      }
    }
  }

  private func toggleExactDue() {
    setExactDue(model.taskEditor.draft(for: task.id)?.values.dueAt == nil)
  }

  /// How long it takes: the estimate and what has been worked against it,
  /// and the rules for the block it is done in.
  @ViewBuilder
  private func effort(_ draft: TaskEditorDraft) -> some View {
    InspectorRow("Estimate") {
      InspectorTextField(
        add: "Add estimate", hint: "Minutes",
        text: binding(\.estimateMinutes, fallback: draft.values.estimateMinutes), stop: "estimate",
        unit: "min")
      .commandHelp(.taskEditEstimate)
      if let seconds = model.taskLoggedSeconds[task.id], seconds > 0 {
        Text(
          "Worked \(FocusPoints.formatted(Double(seconds) / 60)) minutes"
            + (task.estimateSeconds.map {
              "; approximately \(FocusPoints.formatted(Double(max(0, $0 - seconds)) / 60)) minutes remain"
            } ?? "")
        )
        .font(theme.captionFont).monospacedDigit().foregroundStyle(theme.muted)
        .padding(.horizontal, theme.space.xs)
        if let estimate = task.estimateSeconds, seconds >= estimate {
          Text("Estimate exhausted. Revise it or choose a session duration to keep making progress.")
            .font(theme.captionFont).foregroundStyle(theme.warning)
            .padding(.horizontal, theme.space.xs)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    InspectorRow("Min. block") {
      InspectorTextField(
        add: "Add minimum", hint: "Minutes",
        text: Binding(
          get: { model.taskEditor.draft(for: task.id)?.values.minimumBlockMinutes ?? "" },
          set: { raw in model.taskEditor.edit(task.id) { $0.minimumBlockMinutes = raw.isEmpty ? nil : raw } }),
        stop: "minimum-block", unit: "min")
      .help("The shortest block worth starting it in")
    }
    InspectorRow("One sitting") {
      let required = draft.values.requiresSingleSitting == true
      Toggle(
        isOn: Binding(
          get: { model.taskEditor.draft(for: task.id)?.values.requiresSingleSitting == true },
          set: { enabled in model.taskEditor.edit(task.id) { $0.requiresSingleSitting = enabled ? true : nil } })
      ) {
        quietValue(required ? "Must finish in one go" : "Can be split", tone: required ? .ink : .dim)
      }
      .toggleStyle(.themedSwitch)
      .inspectorStop("single-sitting", press: {
        model.taskEditor.edit(task.id) { $0.requiresSingleSitting = $0.requiresSingleSitting == true ? nil : true }
      })
      .help("Must finish in one sitting")
    }
  }

  /// The description: the whole width, no label, one dim line until it has
  /// something in it.
  private func notes(_ draft: TaskEditorDraft) -> some View {
    InspectorTextEditor(
      add: "Add notes", text: binding(\.notes, fallback: draft.values.notes), stop: "notes", minHeight: 96)
    .commandHelp(.taskEditNotes)
  }

  /// Where it is filed and how it ranks.
  @ViewBuilder
  private func filing(_ draft: TaskEditorDraft) -> some View {
    InspectorRow("Priority") {
      let priority = binding(\.priority, fallback: draft.values.priority)
      let priorities = Self.priorityNames.enumerated().map { ThemedPickerOption($0.element, value: $0.offset) }
      let current = min(max(draft.values.priority, 0), Self.priorityNames.count - 1)
      InspectorMenu(current == 0 ? "Add priority" : Self.priorityNames[current], tone: current == 0 ? .dim : .ink) {
        Picker("Priority", selection: priority) {
          ForEach(priorities) { Text($0.title).tag($0.value) }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      }
      .inspectorStop("priority") { priority.step(by: $0, through: priorities) }
      .commandHelp(.motionSetPriority)
      .accessibilityLabel("Priority")
    }
    InspectorRow("Tags") {
      InspectorTextField(
        add: "Add tags", hint: "Work, launch", text: binding(\.tags, fallback: draft.values.tags), stop: "tags")
      .commandHelp(.taskEditTags)
    }
    InspectorRow("List") {
      InspectorMenu(model.list(for: task)?.name ?? "Move to list") {
        ForEach(model.lists.filter { $0.id != task.listId }) { list in
          Button(list.name) { model.moveTask(task, toListId: list.id) }
        }
      }
      .inspectorStop("move")
      .commandHelp(.taskMove)
    }
    if task.isList {
      InspectorRow("Icon") {
        let icon = Binding(get: { model.itemSymbol(for: task) }, set: { model.setNestedListIcon($0, for: task) })
        let options = Self.iconOptions(including: model.itemSymbol(for: task))
        let current = options.first { $0.value == icon.wrappedValue }
        InspectorMenu(current?.title ?? "Icon", systemImage: current?.systemImage) {
          Picker("Icon", selection: icon) {
            ForEach(options) { option in
              if let symbol = option.systemImage {
                Label(option.title, systemImage: symbol).tag(option.value)
              } else {
                Text(option.title).tag(option.value)
              }
            }
          }
          .pickerStyle(.inline)
          .labelsHidden()
        }
        .inspectorStop("icon") { icon.step(by: $0, through: Self.iconOptions) }
        .accessibilityLabel("Icon")
      }
    }
  }

  /// How it comes round again: its repeat rule, and its periodic commitments.
  @ViewBuilder
  private func repeating(_ draft: TaskEditorDraft) -> some View {
    InspectorRow("Repeat") {
      InspectorTextField(
        add: "Add repeat", hint: "Every Monday",
        text: binding(\.recurrenceRule, fallback: draft.values.recurrenceRule), stop: "repeat")
      .commandHelp(.taskEditRecurrence)
      commitments
    }
    // A task that is a daily itself — the older "daily progress" — keeps its
    // switch so it can be turned off; committing now makes a subtask.
    if draft.values.dailyProgress && model.commitment(carriedBy: task) == nil && !model.isHabitTask(task) {
      InspectorRow("Daily") {
        Toggle(isOn: binding(\.dailyProgress, fallback: draft.values.dailyProgress)) {
          quietValue("Make daily progress", tone: .ink)
        }
        .toggleStyle(.themedSwitch)
        .inspectorStop("daily", press: { model.taskEditor.edit(task.id) { $0.dailyProgress.toggle() } })
        .commandHelp(.taskToggleDaily, note: "Show this ongoing task in Dailies without completing the task itself")
      }
    }
  }

  private func links(_ draft: TaskEditorDraft) -> some View {
    InspectorRow("Links") {
      InspectorTextEditor(
        add: "Add links", text: binding(\.links, fallback: draft.values.links), stop: "links",
        minHeight: 44, maxHeight: 90)
      .commandHelp(.taskOpenLink, note: "One link per line; the first opens")
    }
  }

  /// The task's periodic commitments, each with a way to edit or stop it, and
  /// the button that makes one. On a commitment's own subtask, the commitment
  /// it carries.
  @ViewBuilder
  private var commitments: some View {
    if let carried = model.commitment(carriedBy: task) {
      commitmentRow(carried, committedTo: model.task(withID: carried.parentTaskId))
    } else if !task.isList {
      ForEach(model.commitments(for: task)) { commitment in
        commitmentRow(commitment, committedTo: task)
      }
      Button("Commit periodically…") { model.presentCommitmentForm(for: task, editing: nil) }
        .buttonStyle(InspectorValueButtonStyle(tone: .dim))
        .inspectorStop("commit", press: { model.presentCommitmentForm(for: task, editing: nil) })
        .commandHelp(.taskToggleDaily, note: "Add a subtask that comes round in Dailies on its days until this is done")
    }
  }

  private func commitmentTodayMarker(_ commitment: WorkspaceCommitment) -> String {
    if model.isCommitmentDoneToday(commitment) { return " · ✓ today" }
    if model.isCommitmentSkippedToday(commitment) { return " · skipped today" }
    return ""
  }

  private func commitmentRow(_ commitment: WorkspaceCommitment, committedTo parent: WorkspaceTask?) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: theme.space.xs) {
      VStack(alignment: .leading, spacing: 0) {
        Text(commitment.title)
          .font(theme.bodyFont())
          .foregroundStyle(theme.ink)
          .lineLimit(1)
        // "✓ today" once today's is ticked, "skipped today" once it is set
        // aside: either way its subtask is resting, out of the outline and
        // the boards until its next day.
        Text(Self.commitmentSummary(commitment) + commitmentTodayMarker(commitment))
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
      }
      Spacer(minLength: 0)
      // Each its own stop, so the cursor reaches both. Stop is not what `x`
      // does: what was logged is kept, but the commitment is gone.
      if let parent {
        Button("Edit") { model.presentCommitmentForm(for: parent, editing: commitment) }
          .buttonStyle(InspectorValueButtonStyle(tone: .muted))
          .inspectorStop(
            "commitment.\(commitment.taskId).edit",
            press: { model.presentCommitmentForm(for: parent, editing: commitment) })
          .help("Change its name, schedule or end")
      }
      Button("Stop") { model.stopCommitment(commitment) }
        .buttonStyle(InspectorValueButtonStyle(tone: .muted))
        .inspectorStop("commitment.\(commitment.taskId).stop", press: { model.stopCommitment(commitment) })
        .help("Stop it coming round; what was logged is kept")
    }
    .padding(.leading, theme.space.xs)
  }

  /// "Every friday · until Fri 31 Oct", and "· stacks, 2 missed" for one
  /// whose missed appearances stack.
  static func commitmentSummary(_ commitment: WorkspaceCommitment) -> String {
    let ends =
      commitment.lastDay().map { "until \($0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))" }
      ?? "until the task is done"
    guard commitment.stacksMissed else { return "\(commitment.ruleLabel) · \(ends)" }
    let stack = commitment.missed > 0 ? "stacks, \(commitment.missed) missed" : "stacks"
    return "\(commitment.ruleLabel) · \(ends) · \(stack)"
  }

  /// What you do to the task rather than set on it, least often wanted
  /// last: turning it into a different kind of thing is what you can least
  /// easily undo.
  @ViewBuilder
  private var actions: some View {
    if !task.isList {
      actionButton("Add to Google Calendar", systemImage: "calendar.badge.plus", stop: "calendar") {
        model.addTaskToGoogleCalendar(task)
      }
      .help("Create a linked event using the task's due date or start time")
    }
    actionButton("Copy requirements to subtasks", systemImage: "arrow.turn.down.right", stop: "apply-planning") {
      model.applyPlanningToDescendants(of: task)
    }
    .help(
      "Apply saved requirements and start to subtasks: copies saved conditions, start and block rules; "
        + "keeps each subtask's own estimate and deadline")
    if task.isList {
      actionButton(
        task.isPromoted == true ? "Unpin from sidebar" : "Pin to sidebar", systemImage: "pin", stop: "pin"
      ) { model.toggleListPromotion(task) }
      .commandHelp(.taskPromoteList)
      actionButton(
        task.status == .open ? "Complete list" : "Reopen list",
        systemImage: task.status == .open ? "checkmark.circle" : "arrow.uturn.backward.circle", stop: "complete"
      ) { model.toggleTask(task) }
      .commandHelp(.taskComplete, note: task.status == .open ? "Complete the list" : "Reopen the list")
      actionButton("Archive list", systemImage: "archivebox", stop: "archive") { model.archiveNestedList(task) }
    }
    actionButton(
      task.isList ? "Convert to task" : "Convert to list",
      systemImage: task.isList ? "checklist" : "list.bullet.indent", stop: "convert"
    ) { model.convertItem(task) }
    .commandHelp(task.isList ? .taskPromoteList : .taskConvertToList)
  }

  private func actionButton(
    _ title: String, systemImage: String, stop: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(InspectorValueButtonStyle(tone: .muted))
    .inspectorStop(stop, press: action)
  }

  /// A switch's words, at the value column's inset.
  private func quietValue(_ text: String, tone: InspectorTone) -> some View {
    Text(text)
      .foregroundStyle(tone.color(theme))
      .lineLimit(1)
      .padding(.leading, theme.space.xs)
  }

  @ViewBuilder
  private func saveControls(_ draft: TaskEditorDraft) -> some View {
    HStack(spacing: theme.space.xs) {
      Button("Save") { model.saveTaskEditor(task) }
        .buttonStyle(FocusActionButtonStyle(prominent: draft.isDirty))
        .keyboardShortcut("s", modifiers: .command)
        .inspectorStop("save", press: { model.saveTaskEditor(task) })
        .help("Save · ⌘S")
        .disabled(
          !draft.isDirty || draft.isUnavailable || !draft.conflicts.isEmpty
            || draft.values.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      Button("Revert") { model.revertTaskEditor(task) }
        .buttonStyle(InspectorValueButtonStyle(tone: .muted))
        .inspectorStop("revert", press: { model.revertTaskEditor(task) })
        .disabled(!draft.isDirty)
      Spacer(minLength: 0)
      if draft.isDirty {
        Text("Unsaved changes").font(theme.captionFont).foregroundStyle(theme.muted)
      }
    }
    .inspectorBand()
  }

  static let iconOptions = WorkspaceViewModel.availableListIcons.map {
    ThemedPickerOption($0.label, value: $0.symbol, systemImage: $0.symbol)
  }

  /// The symbols, with an emoji the list already has at the top — chosen in
  /// the sidebar's icon picker, and offered here so the picker can show it.
  static func iconOptions(including current: String) -> [ThemedPickerOption<String>] {
    guard WorkspaceListIconName.isEmoji(current) else { return iconOptions }
    return [ThemedPickerOption(current, value: current)] + iconOptions
  }

  static var priorityNames: [String] { TaskEditorValues.priorityNames }

  private func binding<Value>(_ keyPath: WritableKeyPath<TaskEditorValues, Value>, fallback: Value) -> Binding<Value> {
    Binding(
      get: { model.taskEditor.draft(for: task.id)?.values[keyPath: keyPath] ?? fallback },
      set: { value in model.taskEditor.edit(task.id) { $0[keyPath: keyPath] = value } })
  }

  private func display(_ field: TaskEditorField, in values: TaskEditorValues) -> String {
    switch field {
    case .title: values.title
    case .notes: values.notes
    case .dueAt: values.dueAt?.formatted() ?? "None"
    case .estimateMinutes: values.estimateMinutes.isEmpty ? "None" : "\(values.estimateMinutes) minutes"
    case .priority: Self.priorityNames[min(max(values.priority, 0), Self.priorityNames.count - 1)]
    case .tags: values.tags
    case .recurrenceRule: values.recurrenceRule
    case .links: values.links
    case .dailyProgress: values.dailyProgress ? "Enabled" : "Disabled"
    case .startAt: values.startAt?.formatted() ?? "None"
    case .dueDate: values.dueDate ?? "None"
    case .requirements: (values.requirementGroups ?? []).map { group in
      group.map { id in model.focusConditions.first(where: { $0.id == id })?.name ?? "Missing condition" }.joined(separator: " or ")
    }.joined(separator: " and ")
    case .minimumBlock: values.minimumBlockMinutes ?? "None"
    case .singleSitting: values.requiresSingleSitting == true ? "Required" : "Not required"
    }
  }
}

// MARK: - The cursor

extension LocalTaskInspector {
  /// A key for the cursor, from `WorkspaceViewModel.sendInspectorKey`.
  private func handle(_ action: InspectorKeyAction) {
    // Whatever has the caret is what is being edited, even if it took it
    // before the cursor heard.
    if let focus, cursor.keyboardStop != focus { keyboardMoved(to: focus) }
    let before = cursor.current
    switch action {
    case .step(let offset): cursor.step(by: offset)
    case .first: cursor.moveToFirst()
    case .last: cursor.moveToLast()
    case .edit: cursor.activate().map(perform)
    case .clear: cursor.clear().map(perform)
    case .copy: copyField(under: cursor.current)
    case .leave(let byArrow): perform(cursor.leave(byArrow: byArrow))
    case .editing(.commit): cursor.finishEditing(commit: true)
    case .editing(.cancel): cursor.finishEditing(commit: false).map(perform)
    case .editing(.tab(let forward)): cursor.tab(forward: forward)
    case .editing(.step(let offset)):
      cursor.finishEditing(commit: true)
      cursor.step(by: offset)
    }
    sync()
    if let current = cursor.current, current != before {
      withAnimation(.easeOut(duration: 0.12)) { scroll?.scrollTo(current) }
    }
  }

  private func keyboardMoved(to stop: String?) {
    cursor.keyboardMoved(to: stop)
    noteEditing()
  }

  /// Remembers the draft when an edit begins, and forgets it when it ends.
  private func noteEditing() {
    if !cursor.isEditing {
      editStart = nil
    } else if editStart == nil {
      editStart = model.taskEditor.draft(for: task.id)?.values
    }
  }

  /// Puts the keyboard where the cursor says: in the field being edited, on
  /// the control under the cursor, or — on a text row in normal mode — on
  /// the inspector itself, so the row is only highlighted.
  private func sync() {
    noteEditing()
    guard model.keyboardFocusArea == .inspector else { return }
    let want = cursor.keyboardStop
    guard focus != want else { return }
    let hadKeyboard = focus != nil
    focus = want
    if want == nil && hadKeyboard { model.requestKeyboardFocus(.inspector, onTitle: false) }
  }

  private func perform(_ effect: InspectorEffect) {
    let serial = (stopRequest?.serial ?? 0) + 1
    switch effect {
    case .press(let id): stopRequest = InspectorStopRequest(id: id, kind: .press, serial: serial)
    case .adjust(let id, let offset): stopRequest = InspectorStopRequest(id: id, kind: .adjust(offset), serial: serial)
    case .clearValue(let id): model.taskEditor.edit(task.id) { Self.clear(id, in: &$0) }
    case .revert(let id):
      guard let start = editStart else { return }
      model.taskEditor.edit(task.id) { Self.restore(id, from: start, into: &$0) }
    case .leave: model.requestKeyboardFocus(.tasks)
    }
  }

  /// ⌘C on a ringed row: the field's whole text, as selecting it all and
  /// copying would. A row with no text to give copies nothing.
  private func copyField(under stop: String?) {
    guard let stop, let values = model.taskEditor.draft(for: task.id)?.values else { return }
    let text: String
    let name: String
    switch stop {
    case Self.titleStop: (text, name) = (values.title, "title")
    case "notes": (text, name) = (values.notes, "notes")
    case "links": (text, name) = (values.links, "links")
    case "tags": (text, name) = (values.tags, "tags")
    case "repeat": (text, name) = (values.recurrenceRule, "repeat rule")
    default: return
    }
    guard !text.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    model.onStatusMessage?("Copied the \(name).")
  }

  /// `x` on a row with no × of its own. The title is left alone: a task
  /// needs one.
  private static func clear(_ stop: String, in values: inout TaskEditorValues) {
    switch stop {
    case "estimate": values.estimateMinutes = ""
    case "minimum-block": values.minimumBlockMinutes = nil
    case "tags": values.tags = ""
    case "repeat": values.recurrenceRule = ""
    case "notes": values.notes = ""
    case "links": values.links = ""
    case "priority": values.priority = 0
    case "single-sitting": values.requiresSingleSitting = nil
    case "daily": values.dailyProgress = false
    case "due.exact":
      guard let at = values.dueAt else { return }
      values.dueDate = TaskCalendarDate.string(at)
      values.dueAt = nil
    default: break
    }
  }

  /// Esc in a one-line field: what it had when the caret went in.
  private static func restore(_ stop: String, from start: TaskEditorValues, into values: inout TaskEditorValues) {
    switch stop {
    case titleStop: values.title = start.title
    case "estimate": values.estimateMinutes = start.estimateMinutes
    case "minimum-block": values.minimumBlockMinutes = start.minimumBlockMinutes
    case "tags": values.tags = start.tags
    case "repeat": values.recurrenceRule = start.recurrenceRule
    default: break
    }
  }
}
