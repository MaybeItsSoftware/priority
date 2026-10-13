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
  /// Every stop on screen, top to bottom.
  @State private var stops: [String] = []

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
    .onPreferenceChange(InspectorStopsKey.self) { stops = $0 }
    .onAppear {
      model.openTaskEditor(task)
      if requestedFocusArea == .inspector && model.inspectorFocusesTitle { focus = Self.titleStop }
    }
    .onChange(of: task.id) { _, _ in model.openTaskEditor(task) }
    .onChange(of: focusRequest) { _, _ in
      if requestedFocusArea == .inspector && model.inspectorFocusesTitle { focus = Self.titleStop }
    }
    .onChange(of: model.inspectorStepRequest) { _, _ in step(by: model.inspectorStepOffset) }
    .onDisappear { model.taskEditor.flush() }
  }

  static let titleStop = "title"

  /// One stop on, or back, from wherever the keyboard is; from the pane
  /// itself, the first or last. The ends stop rather than wrap: falling off
  /// the bottom of a form onto its title is not a thing anyone means.
  private func step(by offset: Int) {
    guard !stops.isEmpty else { return }
    let current = focus.flatMap { stops.firstIndex(of: $0) }
    let next = current.map { $0 + offset } ?? (offset > 0 ? 0 : stops.count - 1)
    guard stops.indices.contains(next) else { return }
    focus = stops[next]
    withAnimation(.easeOut(duration: 0.12)) { scroll?.scrollTo(stops[next]) }
  }

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
            .inspectorStop("conflict.\(field).saved")
          Button("Keep my edit") { model.taskEditor.resolve(task.id, field: field, useSaved: false) }
            .inspectorStop("conflict.\(field).mine")
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
          .inspectorStop("focus.queue")
          .commandHelp(.taskStartFocus, note: "Add this task to the focus queue")
          Button("Open focus") { model.run(.goFocus) }
            .buttonStyle(InspectorValueButtonStyle(tone: .muted))
            .inspectorStop("focus.open")
            .commandHelp(.goFocus)
          Spacer(minLength: 0)
          FocusStopButton()
        }
      } else {
        Button { model.startFocus(on: task) } label: {
          Label("Start focus", systemImage: "bolt.fill")
        }
        .buttonStyle(FocusActionButtonStyle(prominent: true))
        .inspectorStop("focus.start")
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
            set: { exact in
              model.taskEditor.edit(task.id) {
                if exact {
                  $0.dueAt = $0.dueDate.flatMap { TaskCalendarDate.date($0) } ?? .now
                  $0.dueDate = nil
                } else {
                  $0.dueDate = TaskCalendarDate.string($0.dueAt ?? .now)
                  $0.dueAt = nil
                }
              }
            })
        ) {
          quietValue(exact ? "At a set time" : "Any time that day", tone: exact ? .ink : .dim)
        }
        .toggleStyle(.themedSwitch)
        .inspectorStop("due.exact")
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
      .inspectorStop("single-sitting")
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
        .inspectorStop("daily")
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
        .inspectorStop("commit")
        .commandHelp(.taskToggleDaily, note: "Add a subtask that comes round in Dailies on its days until this is done")
    }
  }

  private func commitmentRow(_ commitment: WorkspaceCommitment, committedTo parent: WorkspaceTask?) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: theme.space.xs) {
      VStack(alignment: .leading, spacing: 0) {
        Text(commitment.title)
          .font(theme.bodyFont())
          .foregroundStyle(theme.ink)
          .lineLimit(1)
        Text(Self.commitmentSummary(commitment))
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
      }
      Spacer(minLength: 0)
      if let parent {
        Button("Edit") { model.presentCommitmentForm(for: parent, editing: commitment) }
          .buttonStyle(InspectorValueButtonStyle(tone: .muted))
          .help("Change its name, schedule or end")
      }
      Button("Stop") { model.stopCommitment(commitment) }
        .buttonStyle(InspectorValueButtonStyle(tone: .muted))
        .help("Stop it coming round; what was logged is kept")
    }
    .padding(.leading, theme.space.xs)
    .inspectorStop("commitment.\(commitment.taskId)")
  }

  /// "Every friday · until Fri 31 Oct".
  static func commitmentSummary(_ commitment: WorkspaceCommitment) -> String {
    guard let last = commitment.lastDay() else { return "\(commitment.ruleLabel) · until the task is done" }
    return "\(commitment.ruleLabel) · until \(last.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))"
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
    .inspectorStop(stop)
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
        .inspectorStop("save")
        .help("Save · ⌘S")
        .disabled(
          !draft.isDirty || draft.isUnavailable || !draft.conflicts.isEmpty
            || draft.values.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      Button("Revert") { model.revertTaskEditor(task) }
        .buttonStyle(InspectorValueButtonStyle(tone: .muted))
        .inspectorStop("revert")
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

struct WorkspaceSidebarEditorSheet: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let editor: WorkspaceSidebarEditor

  var body: some View {
    switch editor {
    case .list(let list):
      ListSettingsEditor(list: list, dismiss: dismiss)
    case .folder(let folder):
      FolderSettingsEditor(folder: folder, dismiss: dismiss)
    }
  }
}

private struct ListSettingsEditor: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let list: TaskList
  let dismiss: DismissAction
  @State private var name: String
  @State private var colorHex: String
  @State private var iconSymbol = "list.bullet"
  @State private var folderID: String?
  @State private var isArchived: Bool
  @State private var visibleRootTaskID: String?
  @State private var agentInstructions = ""
  @State private var saveError: String?
  @FocusState private var nameIsFocused: Bool

  init(list: TaskList, dismiss: DismissAction) {
    self.list = list
    self.dismiss = dismiss
    _name = State(initialValue: list.name)
    _colorHex = State(initialValue: list.colorHex ?? "")
    _folderID = State(initialValue: list.folderId)
    _isArchived = State(initialValue: list.isArchived)
    _visibleRootTaskID = State(initialValue: list.visibleRootTaskId)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.lg) {
      SheetTitle("List settings")
      VStack(alignment: .leading, spacing: theme.space.sm) {
        ThemedControlRow("Name") {
          TextField("Name", text: $name)
            .themedTextField()
            .focused($nameIsFocused)
            .onSubmit { save() }
            .help("↩ saves, esc cancels")
        }
        ThemedControlRow("Color (hex)") {
          TextField("Color (hex)", text: $colorHex, prompt: Text("#4F86C6"))
            .themedTextField()
        }
        ThemedPicker("Icon", selection: $iconSymbol, options: LocalTaskInspector.iconOptions(including: iconSymbol))
          .focusable()
        ThemedPicker(
          "Folder", selection: $folderID,
          options: [ThemedPickerOption("Ungrouped", value: nil as String?)]
            + model.folders.map { ThemedPickerOption($0.name, value: Optional($0.id)) }
        )
        .focusable()
        Toggle("Archived", isOn: $isArchived)
          .toggleStyle(.themedSwitch)
          .focusable()
          .disabled(list.isSystemList)
          .commandHelp(.listArchive, note: "Archive the list")
        if !model.visibleRootCandidates(for: list).isEmpty || visibleRootTaskID != nil {
          ThemedPicker(
            "Show at list root", selection: $visibleRootTaskID, options: visibleRootOptions)
          Text("Choose an imported project's children as the list's visible work. Tasks keep their titles and placement.")
            .font(theme.captionFont).foregroundStyle(theme.muted)
          let preview = model.visibleRootPreview(for: list, rootID: visibleRootTaskID)
          Text("Preview: \(preview.prefix(3).map(\.title).joined(separator: ", "))\(preview.count > 3 ? "…" : "")")
            .font(theme.captionFont).foregroundStyle(theme.muted)
        }
        ThemedControlRow("Tasks") {
          Text("\(model.taskCount(for: list))")
            .font(theme.bodyFont())
            .monospacedDigit()
            .foregroundStyle(theme.muted)
        }
        AgentInstructionsField(
          prompt: "Agent instructions for this list", text: $agentInstructions, onSubmit: save)
      }
      if let saveError { Text(saveError).font(theme.captionFont).foregroundStyle(theme.danger) }
      HStack(spacing: theme.space.xs) {
        Button("Delete list", role: .destructive) {
          model.requestDeletion(of: .list(list))
          dismiss()
        }
        .focusable()
        .disabled(list.isSystemList)
        .commandHelp(.listDelete, note: "Delete the list")
        Button("Move up") { model.moveListWithinFolder(list, by: -1) }
          .focusable()
          .commandHelp(.listMoveUp, note: "Move the list up")
        Button("Move down") { model.moveListWithinFolder(list, by: 1) }
          .focusable()
          .commandHelp(.listMoveDown, note: "Move the list down")
        Spacer()
        Button("Cancel") { dismiss() }
          .focusable()
          .keyboardShortcut(.cancelAction)
          .help("Cancel · esc")
        Button("Save") { save() }
          .buttonStyle(FocusActionButtonStyle(prominent: true))
          .focusable()
          .keyboardShortcut(.defaultAction)
          .help("Save · ↩")
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .buttonStyle(FocusActionButtonStyle())
    }
    .padding(theme.space.xl)
    .frame(width: 380)
    .background(theme.raised)
    .onAppear {
      iconSymbol = model.icon(for: list)
      agentInstructions = model.agentInstructions.list(list.id)
      nameIsFocused = true
    }
  }

  private var visibleRootOptions: [ThemedPickerOption<String?>] {
    let candidates = model.visibleRootCandidates(for: list)
    var options = [ThemedPickerOption("Top-level tasks", value: nil as String?)]
    options += candidates.map { ThemedPickerOption("Children of \($0.title)", value: Optional($0.id)) }
    if let rootID = visibleRootTaskID, !candidates.contains(where: { $0.id == rootID }) {
      options.append(ThemedPickerOption("Current imported root (unavailable)", value: Optional(rootID)))
    }
    return options
  }

  private func save() {
    do {
      try model.saveListSettings(list, name: name, colorHex: colorHex, folderID: folderID,
                                isArchived: isArchived, visibleRootTaskID: visibleRootTaskID)
      model.setIcon(iconSymbol, for: list)
      model.agentInstructions.setList(agentInstructions, for: list.id)
      dismiss()
    } catch { saveError = error.localizedDescription }
  }
}

private struct FolderSettingsEditor: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let folder: ListFolder
  let dismiss: DismissAction
  @State private var name: String
  @State private var parentFolderID: String?
  @State private var agentInstructions = ""
  @State private var saveError: String?
  @FocusState private var nameIsFocused: Bool

  init(folder: ListFolder, dismiss: DismissAction) {
    self.folder = folder
    self.dismiss = dismiss
    _name = State(initialValue: folder.name)
    _parentFolderID = State(initialValue: folder.parentFolderId)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.lg) {
      SheetTitle("Folder settings")
      VStack(alignment: .leading, spacing: theme.space.sm) {
        ThemedControlRow("Name") {
          TextField("Name", text: $name)
            .themedTextField()
            .focused($nameIsFocused)
            .onSubmit { save() }
            .help("↩ saves, esc cancels")
        }
        ThemedPicker(
          "Parent folder", selection: $parentFolderID,
          options: [ThemedPickerOption("At sidebar root", value: nil as String?)]
            + model.validParentFolders(for: folder).map { ThemedPickerOption($0.name, value: Optional($0.id)) }
        )
        .focusable()
        AgentInstructionsField(
          prompt: "Agent instructions for every list in this folder", text: $agentInstructions, onSubmit: save)
      }
      if let saveError { Text(saveError).font(theme.captionFont).foregroundStyle(theme.danger) }
      HStack(spacing: theme.space.xs) {
        Button("Delete folder", role: .destructive) {
          model.requestDeletion(of: .folder(folder))
          dismiss()
        }
        .focusable()
        .commandHelp(.listDelete, note: "Delete the folder")
        Button("Move up") { model.moveFolderWithinSiblings(folder, by: -1) }
          .focusable()
          .commandHelp(.folderMoveUp)
        Button("Move down") { model.moveFolderWithinSiblings(folder, by: 1) }
          .focusable()
          .commandHelp(.folderMoveDown)
        Spacer()
        Button("Cancel") { dismiss() }
          .focusable()
          .keyboardShortcut(.cancelAction)
          .help("Cancel · esc")
        Button("Save") { save() }
          .buttonStyle(FocusActionButtonStyle(prominent: true))
          .focusable()
          .keyboardShortcut(.defaultAction)
          .help("Save · ↩")
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .buttonStyle(FocusActionButtonStyle())
    }
    .padding(theme.space.xl)
    .frame(width: 380)
    .background(theme.raised)
    .onAppear {
      agentInstructions = model.agentInstructions.folder(folder.id)
      nameIsFocused = true
    }
  }

  private func save() {
    do {
      try model.saveFolderSettings(folder, name: name, parentFolderID: parentFolderID)
      model.agentInstructions.setFolder(agentInstructions, for: folder.id)
      dismiss()
    } catch { saveError = error.localizedDescription }
  }
}
