import PriorityCore
import PriorityWorkspace
import SwiftUI

/// Every field of a task. A sheet on iPhone, the detail column on iPad.
///
/// Edits a `TaskEditorDraft` through `InspectorModel` and saves it with the
/// store's `saveTaskEditor`, as the Mac inspector does. There is no Save
/// button: a field saves itself a moment after you stop typing, a control at
/// once, and anything still pending when the inspector goes away.
struct TaskInspector: View {
  @Environment(WorkspaceModel.self) private var model
  @Environment(\.isPadLayout) private var isPad
  @Environment(\.dismiss) private var dismiss
  @State private var inspector: InspectorModel
  @FocusState private var focused: Field?
  @State private var showsConditions = false

  enum Field: Hashable { case title, notes, estimate, tags, recurrence, links, minimumBlock }

  init(taskID: String) {
    _inspector = State(initialValue: InspectorModel(taskID: taskID))
  }

  var body: some View {
    Group {
      if let values = inspector.values, let task = inspector.task {
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            header(task, values)
            if !inspector.conflicts.isEmpty { conflictBanner }
            if let error = inspector.error { errorLine(error) }
            if inspector.isUnavailable { unavailableLine }
            notes(values)
            when(values)
            plan(task, values)
            placement
            filing(values)
            actions(task)
          }
          .padding(.bottom, Metrics.xl)
        }
        .scrollDismissesKeyboard(.interactively)
      } else if let error = inspector.error {
        EmptyState(title: "Task unavailable", message: error, systemImage: "exclamationmark.triangle")
      } else {
        ProgressView()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Palette.paper)
    .navigationTitle("Details")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if inspector.isDirty {
        ToolbarItem(placement: .topBarLeading) {
          Button("Revert") { inspector.revert(model) }
            .accessibilityIdentifier("inspector.revert")
        }
      }
      if !isPad {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            inspector.save(model)
            dismiss()
          }
          .accessibilityIdentifier("inspector.done")
        }
      }
    }
    .task { inspector.load(model) }
    .onChange(of: model.revision) { _, _ in inspector.refresh(model) }
    .onChange(of: focused) { previous, _ in
      // Leaving a field is committing it.
      if previous != nil { inspector.save(model) }
    }
    .onDisappear { inspector.save(model) }
    .sheet(isPresented: $showsConditions) { ConditionsSheet().environment(model) }
    .accessibilityIdentifier("inspector")
  }

  // MARK: - Header

  private func header(_ task: WorkspaceTask, _ values: TaskEditorValues) -> some View {
    VStack(alignment: .leading, spacing: Metrics.sm) {
      HStack(alignment: .top, spacing: Metrics.sm) {
        Button { model.toggleComplete(task.id) } label: {
          TaskCheckbox(status: task.status, isList: task.isList, size: 22)
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(task.status == .open ? "Complete" : "Reopen")
        TextField("Title", text: binding(\.title), axis: .vertical)
          .font(Typeface.sans(20, .medium, relativeTo: .title3))
          .foregroundStyle(task.status == .open ? Palette.ink : Palette.muted)
          .focused($focused, equals: .title)
          .submitLabel(.done)
          .onSubmit { inspector.save(model) }
          .accessibilityIdentifier("inspector.title")
      }
      HStack(spacing: Metrics.xs) {
        Tag(text: inspector.listName, systemImage: task.isList ? "list.bullet.indent" : "list.bullet")
        if task.status == .completed { Tag(text: "Done", tint: Palette.success) }
        if task.status == .cancelled { Tag(text: "Invalidated", tint: Palette.muted) }
        if inspector.isDirty {
          Tag(text: "Saving…", tint: Palette.primary)
            .accessibilityIdentifier("inspector.dirty")
        }
      }
    }
    .padding(.horizontal, Metrics.lg)
    .padding(.vertical, Metrics.md)
    .overlay(alignment: .bottom) { Hairline() }
  }

  private var conflictBanner: some View {
    VStack(alignment: .leading, spacing: Metrics.sm) {
      Text("Changed elsewhere while you were editing")
        .font(Typeface.callout).foregroundStyle(Palette.warning)
      if let draft = inspector.draft {
        ForEach(inspector.conflicts, id: \.self) { field in
          VStack(alignment: .leading, spacing: Metrics.xs) {
            Text(field.label).font(Typeface.caption).foregroundStyle(Palette.muted)
            Text("Yours: \(inspector.display(field, in: draft.values))").font(Typeface.caption).lineLimit(2)
            Text("Saved: \(inspector.display(field, in: draft.baseline.values))").font(Typeface.caption).lineLimit(2)
            HStack {
              Button("Keep mine") { inspector.resolve(field, useSaved: false, model: model) }
                .buttonStyle(ThemedButtonStyle(kind: .primary, compact: true))
              Button("Use saved") { inspector.resolve(field, useSaved: true, model: model) }
                .buttonStyle(ThemedButtonStyle(kind: .quiet, compact: true))
            }
          }
        }
      }
    }
    .padding(Metrics.md)
    .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Palette.warning.opacity(0.08)))
    .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Palette.warning.opacity(0.4), lineWidth: 1))
    .padding(Metrics.lg)
    .accessibilityIdentifier("inspector.conflicts")
  }

  private func errorLine(_ error: String) -> some View {
    Text(error)
      .font(Typeface.caption)
      .foregroundStyle(Palette.danger)
      .padding(.horizontal, Metrics.lg)
      .padding(.top, Metrics.sm)
  }

  private var unavailableLine: some View {
    Text("This task was deleted elsewhere. Your edits are kept but can't be saved.")
      .font(Typeface.caption)
      .foregroundStyle(Palette.warning)
      .padding(.horizontal, Metrics.lg)
      .padding(.top, Metrics.sm)
  }

  // MARK: - Notes

  private func notes(_ values: TaskEditorValues) -> some View {
    InspectorSection("Notes") {
      TextField("Add notes", text: binding(\.notes), axis: .vertical)
        .lineLimit(3...12)
        .focused($focused, equals: .notes)
        .controlFrame()
        .accessibilityIdentifier("inspector.notes")
    }
  }

  // MARK: - When

  private func when(_ values: TaskEditorValues) -> some View {
    InspectorSection("When") {
      InspectorRow("Due") {
        ChoiceChips(
          options: InspectorModel.DueKind.allCases.map { ($0.title, $0) },
          selection: Binding(get: { inspector.dueKind }, set: { inspector.setDueKind($0, model: model) }),
          identifier: "inspector.dueKind")
      }
      switch inspector.dueKind {
      case .time:
        DatePicker(
          "Due at",
          selection: Binding(
            get: { inspector.values?.dueAt ?? .now },
            set: { date in inspector.edit(model, immediate: true) { $0.dueAt = date } }),
          displayedComponents: [.date, .hourAndMinute]
        )
        .font(Typeface.body)
        .foregroundStyle(Palette.muted)
      case .day:
        DatePicker(
          "Due on",
          selection: Binding(
            get: { inspector.values?.dueDate.flatMap { TaskCalendarDate.date($0) } ?? .now },
            set: { date in inspector.edit(model, immediate: true) { $0.dueDate = TaskCalendarDate.string(date); $0.dueAt = nil } }),
          displayedComponents: [.date]
        )
        .font(Typeface.body)
        .foregroundStyle(Palette.muted)
      case .none:
        quickDueButtons
      }
      Toggle("Start later", isOn: Binding(
        get: { inspector.values?.startAt != nil },
        set: { on in inspector.edit(model, immediate: true) { $0.startAt = on ? ($0.startAt ?? defaultStart) : nil } }))
        .toggleStyle(ThemedToggleStyle())
        .accessibilityIdentifier("inspector.start")
      if values.startAt != nil {
        DatePicker(
          "Starts",
          selection: Binding(
            get: { inspector.values?.startAt ?? .now },
            set: { date in inspector.edit(model, immediate: true) { $0.startAt = date } }),
          displayedComponents: [.date, .hourAndMinute]
        )
        .font(Typeface.body)
        .foregroundStyle(Palette.muted)
      }
      InspectorRow("Repeat") {
        TextField("Every Monday", text: binding(\.recurrenceRule))
          .textInputAutocapitalization(.never)
          .focused($focused, equals: .recurrence)
          .submitLabel(.done)
          .onSubmit { inspector.save(model) }
          .controlFrame()
          .accessibilityIdentifier("inspector.recurrence")
      }
      Toggle("Planned for today", isOn: Binding(
        get: { inspector.isPlanned }, set: { inspector.setPlanned($0, model: model) }))
        .toggleStyle(ThemedToggleStyle())
        .accessibilityIdentifier("inspector.planned")
      Toggle("Make daily progress", isOn: Binding(
        get: { inspector.values?.dailyProgress ?? false },
        set: { on in inspector.edit(model, immediate: true) { $0.dailyProgress = on } }))
        .toggleStyle(ThemedToggleStyle())
        .accessibilityIdentifier("inspector.daily")
    }
  }

  private var defaultStart: Date {
    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now)) ?? .now
    return Calendar.current.date(byAdding: .hour, value: 9, to: tomorrow) ?? tomorrow
  }

  private var quickDueButtons: some View {
    HStack(spacing: Metrics.xs) {
      ForEach([(0, "Today"), (1, "Tomorrow"), (7, "Next week")], id: \.0) { offset, title in
        Button(title) {
          let day = Calendar.current.date(byAdding: .day, value: offset, to: .now) ?? .now
          inspector.edit(model, immediate: true) { $0.dueDate = TaskCalendarDate.string(day); $0.dueAt = nil }
        }
        .buttonStyle(ThemedButtonStyle(kind: .quiet, compact: true))
      }
    }
  }

  // MARK: - Plan

  private func plan(_ task: WorkspaceTask, _ values: TaskEditorValues) -> some View {
    InspectorSection("Plan") {
      Text("Priority").font(Typeface.callout).foregroundStyle(Palette.muted)
      ChoiceChips(
        options: InspectorModel.priorityNames.enumerated().map { ($0.element, $0.offset) },
        selection: Binding(
          get: { inspector.values?.priority ?? 0 },
          set: { value in inspector.edit(model, immediate: true) { $0.priority = value } }),
        tint: values.priority >= 3 ? Palette.danger : Palette.primary,
        identifier: "inspector.priority")
      InspectorRow("Estimate") {
        HStack(spacing: Metrics.sm) {
          TextField("Minutes", text: binding(\.estimateMinutes))
            .keyboardType(.decimalPad)
            .font(Typeface.numeralBody)
            .focused($focused, equals: .estimate)
            .controlFrame()
            .accessibilityIdentifier("inspector.estimate")
          Text("min").font(Typeface.caption).foregroundStyle(Palette.muted)
        }
      }
      if inspector.progress.subtasks > 0 {
        ProgressLine(done: inspector.progress.subtasksDone, total: inspector.progress.subtasks)
      }
      if inspector.loggedSeconds > 0 {
        Text(loggedLine(task))
          .font(Typeface.numeral)
          .foregroundStyle(Palette.muted)
      }
      conditions(values)
      Toggle("Must finish in one sitting", isOn: Binding(
        get: { inspector.values?.requiresSingleSitting == true },
        set: { on in inspector.edit(model, immediate: true) { $0.requiresSingleSitting = on ? true : nil } }))
        .toggleStyle(ThemedToggleStyle())
      InspectorRow("Min block") {
        HStack(spacing: Metrics.sm) {
          TextField("Minutes", text: Binding(
            get: { inspector.values?.minimumBlockMinutes ?? "" },
            set: { raw in inspector.edit(model) { $0.minimumBlockMinutes = raw.isEmpty ? nil : raw } }))
            .keyboardType(.decimalPad)
            .font(Typeface.numeralBody)
            .focused($focused, equals: .minimumBlock)
            .controlFrame()
          Text("min").font(Typeface.caption).foregroundStyle(Palette.muted)
        }
      }
      Button("Apply conditions and start to subtasks") { inspector.applyPlanningToDescendants(model: model) }
        .buttonStyle(ThemedButtonStyle(kind: .quiet, compact: true))
    }
  }

  private func loggedLine(_ task: WorkspaceTask) -> String {
    let logged = inspector.loggedSeconds
    var line = "Worked \(Format.duration(logged))"
    if let estimate = task.estimateSeconds {
      line += logged >= estimate ? " · estimate used up" : " · about \(Format.duration(estimate - logged)) left"
    }
    return line
  }

  /// The requirement groups: every group must hold (AND), and any one
  /// condition within a group will do (OR) — the Mac's
  /// `WorkspaceTaskPlanningEditor`. Each group is a row of chips with an
  /// "or…" to widen it; "And requires…" adds a group.
  @ViewBuilder
  private func conditions(_ values: TaskEditorValues) -> some View {
    let groups = values.requirementGroups ?? []
    VStack(alignment: .leading, spacing: Metrics.sm) {
      HStack {
        Text("Conditions").font(Typeface.callout).foregroundStyle(Palette.muted)
        Spacer()
        Button("Manage") { showsConditions = true }
          .font(Typeface.caption)
          .foregroundStyle(Palette.primary)
          .accessibilityIdentifier("inspector.manageConditions")
      }
      if groups.isEmpty {
        Text("Anytime, anywhere").font(Typeface.caption).foregroundStyle(Palette.dim)
      }
      ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
        VStack(alignment: .leading, spacing: Metrics.xs) {
          Text(index == 0 ? "Requires" : "And requires")
            .font(Typeface.caption).foregroundStyle(Palette.muted)
          FlowLayout(spacing: Metrics.xs) {
            ForEach(Array(group.enumerated()), id: \.element) { position, id in
              if position > 0 { Text("or").font(Typeface.caption).foregroundStyle(Palette.muted) }
              Button {
                inspector.removeRequirement(id, fromGroup: index, model: model)
              } label: {
                Tag(text: inspector.conditionName(id), tint: Palette.purple, systemImage: "xmark")
              }
              .buttonStyle(.plain)
              .frame(minHeight: 30)
              .accessibilityLabel("Remove \(inspector.conditionName(id))")
            }
            let others = inspector.conditions.filter { !$0.isArchived && !group.contains($0.id) }
            if !others.isEmpty {
              Menu {
                ForEach(others) { condition in
                  Button(condition.name) { inspector.addRequirement(condition.id, toGroup: index, model: model) }
                }
              } label: {
                Text("or…").font(Typeface.caption).foregroundStyle(Palette.primary).frame(minHeight: 30)
              }
              .accessibilityIdentifier("inspector.orCondition.\(index)")
            }
          }
        }
        .padding(Metrics.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Metrics.controlRadius).strokeBorder(Palette.borderMuted, lineWidth: 1))
      }
      Menu {
        ForEach(inspector.conditions.filter { condition in
          !condition.isArchived && !groups.contains([condition.id])
        }) { condition in
          Button(condition.name) { inspector.addRequirement(condition.id, model: model) }
        }
        Divider()
        Button { showsConditions = true } label: { Label("New condition…", systemImage: "plus") }
      } label: {
        ThemedMenuLabel(title: groups.isEmpty ? "Add a required condition" : "And requires…", systemImage: "plus")
      }
      .accessibilityIdentifier("inspector.addCondition")
      if groups.count > 1 || groups.contains(where: { $0.count > 1 }) {
        Text("Every group must hold; any one condition within a group will do.")
          .font(Typeface.footnote).foregroundStyle(Palette.dim)
      }
    }
  }

  // MARK: - Placement

  private var placement: some View {
    InspectorSection("Placement") {
      InspectorRow("Column") {
        Menu {
          Button("None") { inspector.setColumn(nil, model: model) }
          ForEach(inspector.boardColumns) { column in
            Button(column.title) { inspector.setColumn(column.id, model: model) }
          }
        } label: {
          ThemedMenuLabel(title: columnTitle)
        }
        .accessibilityIdentifier("inspector.column")
      }
      Text("Matrix").font(Typeface.callout).foregroundStyle(Palette.muted)
      ChoiceChips(
        options: [("None", MatrixQuadrant?.none)] + MatrixQuadrant.allCases.map { ($0.title, Optional($0)) },
        selection: Binding(get: { inspector.quadrant }, set: { inspector.setQuadrant($0, model: model) }),
        identifier: "inspector.matrix")
    }
  }

  private var columnTitle: String {
    guard let id = inspector.kanbanColumn else { return "None" }
    return inspector.boardColumns.first { $0.id == id }?.title
      ?? WorkspaceKanbanColumn.blitzitDefaults.first { $0.id == id }?.title ?? id
  }

  // MARK: - Filing

  private func filing(_ values: TaskEditorValues) -> some View {
    InspectorSection("Filing") {
      InspectorRow("Tags") {
        TextField("work, launch", text: binding(\.tags))
          .textInputAutocapitalization(.never)
          .focused($focused, equals: .tags)
          .submitLabel(.done)
          .onSubmit { inspector.save(model) }
          .controlFrame()
          .accessibilityIdentifier("inspector.tags")
      }
      VStack(alignment: .leading, spacing: Metrics.xs) {
        Text("Links, one per line").font(Typeface.callout).foregroundStyle(Palette.muted)
        TextField("https://…", text: binding(\.links), axis: .vertical)
          .lineLimit(1...6)
          .keyboardType(.URL)
          .textInputAutocapitalization(.never)
          .focused($focused, equals: .links)
          .controlFrame()
          .accessibilityIdentifier("inspector.links")
        ForEach(linkURLs(values), id: \.self) { url in
          Link(destination: url) {
            Label(url.host() ?? url.absoluteString, systemImage: "arrow.up.right.square")
              .font(Typeface.caption)
              .underline()
          }
        }
      }
    }
  }

  private func linkURLs(_ values: TaskEditorValues) -> [URL] {
    values.links.split(whereSeparator: \.isNewline).compactMap { line in
      URL(string: line.trimmingCharacters(in: .whitespaces)).flatMap {
        ["http", "https", "obsidian"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil
      }
    }
  }

  // MARK: - Actions

  private func actions(_ task: WorkspaceTask) -> some View {
    VStack(spacing: Metrics.sm) {
      if !task.isList && task.status == .open {
        Button {
          inspector.save(model)
          model.navigation.inspectedTaskID = nil
          model.requestFocus(on: task.id, isPad: isPad)
        } label: {
          Label("Start focus", systemImage: "scope").frame(maxWidth: .infinity)
        }
        .buttonStyle(ThemedButtonStyle(kind: .primary))
      }
      HStack(spacing: Metrics.sm) {
        Button {
          model.navigation.movingTaskID = task.id
        } label: {
          Label("Move", systemImage: "folder").frame(maxWidth: .infinity)
        }
        Button {
          model.toggleListKind(task.id)
        } label: {
          Label(task.isList ? "Make task" : "Make list", systemImage: "list.bullet.rectangle").frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(ThemedButtonStyle(kind: .quiet))
      Button(role: .destructive) {
        model.delete(task.id)
        if !isPad { dismiss() }
      } label: {
        Label("Delete", systemImage: "trash").frame(maxWidth: .infinity)
      }
      .buttonStyle(ThemedButtonStyle(kind: .danger))
    }
    .padding(Metrics.lg)
  }

  // MARK: - Bindings

  /// A text binding into the draft. Typing saves after a pause.
  private func binding(_ keyPath: WritableKeyPath<TaskEditorValues, String>) -> Binding<String> {
    Binding(
      get: { inspector.values?[keyPath: keyPath] ?? "" },
      set: { value in inspector.edit(model) { $0[keyPath: keyPath] = value } })
  }
}

/// "3 of 5 subtasks done", with a hairline bar under it — the task's progress
/// as the Mac's inspector shows it.
private struct ProgressLine: View {
  let done: Int
  let total: Int

  var body: some View {
    VStack(alignment: .leading, spacing: Metrics.xs) {
      Text("\(done) of \(total) subtasks done").font(Typeface.numeral).foregroundStyle(Palette.muted)
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Rectangle().fill(Palette.border)
          Rectangle().fill(Palette.success)
            .frame(width: proxy.size.width * CGFloat(done) / CGFloat(max(1, total)))
        }
      }
      .frame(height: 2)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("inspector.progress")
  }
}
