import TaktCore
import TaktWorkspace
import SwiftUI

/// What is available now, in full: the conditions that hold, the time you
/// have, what you want from it, and when to stop trusting the answer.
///
/// Shown in a popover from the status bar and from the focus panel's context
/// line. ⌥⌘8 reaches the conditions alone, as a keyboard picker.
struct WorkspaceFocusContextControls: View {
  @Environment(\.theme) private var theme
  @Environment(WorkspaceViewModel.self) private var model
  /// Opens the conditions manager. The status bar presents the window's
  /// overlay; the panel has to bring the window forward first.
  let onManage: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.md) {
      HStack(spacing: theme.space.sm) {
        MicroLabel("Available now")
        Spacer(minLength: theme.space.sm)
        if !model.focusContext.conditionIDs.isEmpty {
          Button("Clear") { model.clearFocusConditions() }
            .buttonStyle(.plain)
            .font(theme.captionFont)
            .foregroundStyle(theme.muted)
            .help("Nothing beyond the laptop: only tasks with no conditions are offered")
        }
        Button("Manage…") { onManage() }
          .buttonStyle(.plain)
          .font(theme.captionFont)
          .foregroundStyle(theme.primary)
          .commandHelp(.focusManageConditions, note: "Add, rename or archive conditions")
      }
      if model.focusConditions.isEmpty {
        Text(WorkspaceConditionCopy.explanation + " None yet: add one with Manage.")
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        WorkspaceConditionChips()
      }
      if !model.suggestedContextIDs.isEmpty {
        HStack(spacing: theme.space.sm) {
          Text("Last context: " + model.suggestedContextIDs.sorted().map { id in
            model.focusConditions.first(where: { $0.id == id })?.name ?? ""
          }.joined(separator: ", ")).foregroundStyle(theme.muted)
          Button("Use again") { model.confirmSuggestedContext() }
            .buttonStyle(.plain)
            .foregroundStyle(theme.primary)
          Button("Dismiss") { model.suggestedContextIDs = [] }
            .buttonStyle(.plain)
            .foregroundStyle(theme.muted)
        }
        .font(theme.captionFont)
      }
      FocusRule()
      HStack(spacing: theme.space.sm) {
        ThemedMenu(model.availableUntil.map { "Until \($0.formatted(date: .omitted, time: .shortened))" } ?? "Available time") {
          Button("No time limit") { model.availableUntil = nil; model.focusContextChanged() }
          ForEach([15, 30, 60, 90], id: \.self) { minutes in
            Button("\(minutes) minutes") { model.availableUntil = Date.now.addingTimeInterval(Double(minutes * 60)); model.focusContextChanged() }
          }
          Button("Choose end time") { model.availableUntil = Date.now.addingTimeInterval(1800); model.focusContextChanged() }
        }
        if let end = model.availableUntil {
          ThemedDateField(
            selection: Binding(get: { model.availableUntil ?? end }, set: { model.availableUntil = $0; model.focusContextChanged() }),
            includesTime: true)
        }
      }
      ThemedSegmentedPicker(
        selection: Binding(get: { model.focusContext.mode }, set: { model.focusContext.mode = $0; model.focusContextChanged() }),
        options: [
          ThemedPickerOption("Make progress", value: FocusTimeMode.progress),
          ThemedPickerOption("Finish something", value: FocusTimeMode.finish),
        ])
      .accessibilityLabel("Goal")
      HStack(spacing: theme.space.sm) {
        Toggle("Context expires", isOn: Binding(get: { model.contextExpiresAt != nil }, set: {
          model.contextExpiresAt = $0 ? Date.now.addingTimeInterval(3600) : nil; model.focusContextChanged()
        })).toggleStyle(.themedSwitch).fixedSize()
        if let end = model.contextExpiresAt {
          ThemedDateField(
            selection: Binding(get: { model.contextExpiresAt ?? end }, set: { model.contextExpiresAt = $0; model.focusContextChanged() }),
            includesTime: true)
        }
      }.font(theme.captionFont)
    }
  }
}

/// The selectable conditions as chips: on in the accent, off on a hairline.
/// A location replaces the last location; anything else adds.
struct WorkspaceConditionChips: View {
  @Environment(\.theme) private var theme
  @Environment(WorkspaceViewModel.self) private var model

  var body: some View {
    // Wraps rather than scrolls: a popover is narrow, and a chip scrolled out
    // of sight is a condition you cannot see is on.
    WorkspaceChipFlow(spacing: theme.space.xs) {
      ForEach(model.selectableFocusConditions) { condition in
        Button { model.toggleFocusCondition(condition) } label: {
          Label(condition.name, systemImage: condition.isLocation ? "location" : "checkmark.circle")
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(FocusChipButtonStyle(isOn: model.focusContext.conditionIDs.contains(condition.id)))
        .help(condition.isLocation ? "A place: choosing it replaces the last one" : "A circumstance: combines with the rest")
      }
    }
  }
}

/// Lays chips out left to right, onto a new line when the row is full.
struct WorkspaceChipFlow: Layout {
  var spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(subviews, width: proposal.width ?? .infinity)
    let width = rows.map(\.width).max() ?? 0
    let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
    return CGSize(width: width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var originY = bounds.minY
    for row in arrange(subviews, width: bounds.width) {
      var originX = bounds.minX
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(at: CGPoint(x: originX, y: originY), proposal: ProposedViewSize(size))
        originX += size.width + spacing
      }
      originY += row.height + spacing
    }
  }

  private struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
    var rows: [Row] = []
    var current = Row()
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      if !current.indices.isEmpty, current.width + spacing + size.width > width {
        rows.append(current)
        current = Row()
      }
      current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      current.height = max(current.height, size.height)
      current.indices.append(index)
    }
    if !current.indices.isEmpty { rows.append(current) }
    return rows
  }
}

/// The words conditions are explained in, once, so the inspector, the
/// popover and the overlays say the same thing.
enum WorkspaceConditionCopy {
  static let explanation = "Conditions are places or circumstances a task needs — Home, Campus, Floor space."
  static let none = "No conditions — available whenever"
}

/// The status bar's word on where you are: the conditions on, or "Anywhere".
/// Click for the full controls; ⌥⌘8 for the keyboard picker.
struct WorkspaceFocusContextIndicator: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  @State private var showsControls = false

  var body: some View {
    let summary = model.focusContextSummary
    Button { showsControls.toggle() } label: {
      HStack(spacing: theme.space.xs) {
        Image(systemName: summary == nil ? "location.slash" : "location.fill")
          .foregroundStyle(summary == nil ? theme.dim : theme.primary)
        if !model.focusConditions.isEmpty {
          Text(summary ?? "Anywhere")
            .foregroundStyle(summary == nil ? theme.dim : theme.ink)
            .truncationMode(.tail)
            .frame(maxWidth: 200, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusable(false)
    .commandHelp(
      .focusSetAvailable,
      note: summary.map { "Available now: \($0). Click to change" }
        ?? "Nothing set as available: only tasks with no conditions are offered. Click to change")
    .accessibilityLabel(summary.map { "Available now: \($0)" } ?? "No conditions available")
    .popover(isPresented: $showsControls, arrowEdge: .top) {
      WorkspaceFocusContextControls {
        showsControls = false
        model.presentOverlay(.conditions)
      }
      .environment(model)
      .padding(theme.space.lg)
      .frame(width: 420)
      .background(theme.raised)
    }
  }
}

/// The focus panel's one line about where you are, above its field. Quiet
/// until there are conditions to talk about: a workspace without any has
/// nothing for it to say.
struct FocusPanelContextLine: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  /// Hands the panel back so the window can take over, for Manage.
  let onOpenWindow: () -> Void
  @State private var showsControls = false

  var body: some View {
    if !model.focusConditions.isEmpty {
      let summary = model.focusContextSummary
      Button { showsControls.toggle() } label: {
        HStack(spacing: theme.space.xs) {
          Image(systemName: summary == nil ? "location.slash" : "location.fill")
            .foregroundStyle(summary == nil ? theme.dim : theme.primary)
          Text(summary ?? "Anywhere — only tasks with no conditions")
            .foregroundStyle(summary == nil ? theme.muted : theme.ink)
            .lineLimit(1)
            .truncationMode(.tail)
          if !model.suggestedContextIDs.isEmpty {
            Text("· last context waiting").foregroundStyle(theme.warning)
          }
          Spacer(minLength: theme.space.sm)
          Text(WorkspaceCommandHelpText.firstKey(for: .focusSetAvailable))
            .font(theme.monoCaptionFont)
            .foregroundStyle(theme.dim)
        }
        .font(theme.captionFont)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focusable(false)
      .commandHelp(.focusSetAvailable, note: "What is available now: decides which tasks the day offers")
      .padding(.horizontal, theme.space.lg)
      .padding(.bottom, theme.space.sm)
      .onChange(of: model.panelContextRequest) { _, _ in showsControls.toggle() }
      .popover(isPresented: $showsControls, arrowEdge: .bottom) {
        WorkspaceFocusContextControls {
          showsControls = false
          onOpenWindow()
          model.presentOverlay(.conditions)
        }
        .environment(model)
        .padding(theme.space.lg)
        .frame(width: 420)
        .background(theme.raised)
      }
    }
  }
}

struct WorkspaceTaskPlanningEditor: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let task: WorkspaceTask
  let values: TaskEditorValues
  @State private var isAddingCondition = false
  @State private var newConditionName = ""
  @State private var newConditionIsLocation = false
  @FocusState private var isNewConditionFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.sm) {
      ThemedOptionalRow(
        "Start", isSet: values.startAt != nil, stop: "start",
        add: { edit { $0.startAt = $0.startAt ?? .now } },
        clear: { edit { $0.startAt = nil } },
        value: {
          if let start = values.startAt {
            ThemedDateField(
              selection: Binding(get: { current.startAt ?? start }, set: { date in edit { $0.startAt = date } }),
              includesTime: true, stop: "start.date")
            .commandHelp(.taskEditStart)
          }
      })
      .commandHelp(.taskEditStart)
      MicroLabel("Conditions")
      if (values.requirementGroups ?? []).isEmpty {
        Text(WorkspaceConditionCopy.none).font(theme.captionFont).foregroundStyle(theme.muted)
        if model.focusConditions.isEmpty {
          Text(WorkspaceConditionCopy.explanation)
            .font(theme.captionFont).foregroundStyle(theme.dim)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      ForEach(Array((values.requirementGroups ?? []).enumerated()), id: \.offset) { index, group in
        VStack(alignment: .leading, spacing: theme.space.xs) {
          Text(index == 0 ? "Requires" : "And requires").font(theme.captionFont).foregroundStyle(theme.muted)
          ForEach(group, id: \.self) { id in
            HStack(spacing: theme.space.xs) {
              Text(model.focusConditions.first(where: { $0.id == id })?.name ?? "Missing condition")
                .foregroundStyle(theme.ink)
              if group.count > 1 { Text("(either)").foregroundStyle(theme.muted) }
              Spacer()
              Button { remove(id, from: index) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain).foregroundStyle(theme.muted).inspectorStop("condition.\(index).\(id)")
                .help("Remove requirement")
                .accessibilityLabel("Remove requirement")
            }.font(theme.captionFont)
          }
          ThemedMenu("Or…") {
            ForEach(model.focusConditions.filter { !$0.isArchived && !group.contains($0.id) }) { condition in
              Button(condition.name) { edit { $0.requirementGroups?[index].append(condition.id) } }
            }
          }.font(theme.captionFont).inspectorStop("condition.\(index).or")
        }
      }
      ThemedMenu("Add required condition", systemImage: "plus", expands: true) {
        ForEach(model.focusConditions.filter { condition in
          !condition.isArchived && !(values.requirementGroups ?? []).contains([condition.id])
        }) { condition in
          Button(condition.name) { require(condition.id) }
        }
        if model.focusConditions.contains(where: { !$0.isArchived }) { Divider() }
        Button("New condition…") {
          newConditionName = ""
          newConditionIsLocation = false
          isAddingCondition = true
        }
      }
      .inspectorStop("condition.add")
      if isAddingCondition {
        HStack(spacing: theme.space.sm) {
          TextField("New condition", text: $newConditionName, prompt: Text("Home, Floor space…"))
            .themedTextField()
            .inspectorField("condition.new")
            .focused($isNewConditionFocused)
            .onSubmit(addNewCondition)
            .onExitCommand { isAddingCondition = false }
          Toggle("Place", isOn: $newConditionIsLocation)
            .toggleStyle(.themedSwitch)
            .fixedSize()
            .help("A place replaces the last place when you say where you are; anything else combines")
          Button("Add", action: addNewCondition)
            .buttonStyle(FocusActionButtonStyle())
            .disabled(newConditionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .font(theme.captionFont)
        .onAppear { DispatchQueue.main.async { isNewConditionFocused = true } }
      }
      Toggle("Must finish in one sitting", isOn: Binding(get: { current.requiresSingleSitting == true }, set: { enabled in
        edit { $0.requiresSingleSitting = enabled ? true : nil }
      }))
        .toggleStyle(.themedSwitch)
        .inspectorStop("single-sitting")
      ThemedControlRow("Minimum block") {
        TextField("Minimum useful block (minutes)", text: Binding(get: { current.minimumBlockMinutes ?? "" }, set: { raw in
          edit { $0.minimumBlockMinutes = raw.isEmpty ? nil : raw }
        }), prompt: Text("Minutes"))
        .themedTextField()
        .inspectorField("minimum-block")
      }
      if let unavailable = model.blockedFocusTasks.first(where: { $0.id == task.id }) {
        Text(unavailable.reasons.map { model.unavailableDescription($0) }.joined(separator: " · "))
          .font(theme.captionFont).foregroundStyle(theme.warning)
      }
      Button("Apply saved requirements and start to subtasks") { model.applyPlanningToDescendants(of: task) }
        .buttonStyle(FocusActionButtonStyle())
        .inspectorStop("apply-planning")
        .font(theme.captionFont).help("Copies saved conditions, start and block rules; keeps each subtask's own estimate and deadline")
    }
  }

  private var current: TaskEditorValues { model.taskEditor.draft(for: task.id)?.values ?? values }
  private func edit(_ change: (inout TaskEditorValues) -> Void) { model.taskEditor.edit(task.id, change) }
  private func require(_ id: String) { edit { $0.requirementGroups = ($0.requirementGroups ?? []) + [[id]] } }

  /// Makes the condition and requires it in one go: the menu that offers
  /// conditions is where you find out you need one that does not exist yet.
  private func addNewCondition() {
    let name = newConditionName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, let created = model.createCondition(name: name, isLocation: newConditionIsLocation) else { return }
    require(created.id)
    isAddingCondition = false
    newConditionName = ""
  }
  private func remove(_ id: String, from index: Int) {
    edit { values in
      var groups = values.requirementGroups ?? []
      guard groups.indices.contains(index) else { return }
      groups[index].removeAll { $0 == id }
      groups.removeAll( where: \.isEmpty)
      values.requirementGroups = groups.isEmpty ? nil : groups
    }
  }
}

struct WorkspaceTaskPlanningBadges: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let task: WorkspaceTask
  /// The selected row's badges show in full; the rest stop at two lines.
  var isExpanded = false

  var body: some View {
    let planning = model.taskPlanningByID[task.id]
    VStack(alignment: .leading, spacing: theme.space.xxs) {
      if let due = planning?.dueDate {
        Label("Due \(due)", systemImage: "calendar")
      }
      if let start = planning?.startAt {
        // In the warning colour while it holds the task back.
        Label("Start \(start.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
          .foregroundStyle(start > .now ? theme.warning : theme.muted)
      }
      if let groups = planning?.requirementGroups, !groups.isEmpty {
        Label(groups.map { group in
          group.map { id in model.focusConditions.first(where: { $0.id == id })?.name ?? "Missing condition" }
            .joined(separator: " or ")
        }.joined(separator: " + "), systemImage: "location")
      }
      // A start still to come is already the line above, so it is not said
      // twice; only the other reasons are.
      if let blocked = model.blockedFocusTasks.first(where: { $0.id == task.id }) {
        let reasons = blocked.reasons.filter { reason in
          if case .startsLater = reason { return planning?.startAt == nil }
          return true
        }
        if !reasons.isEmpty {
          Text(reasons.map { model.unavailableDescription($0) }.joined(separator: " · "))
            .foregroundStyle(theme.warning)
        }
      }
    }.font(theme.captionFont).foregroundStyle(theme.muted).expandsWhenSelected(isExpanded, lineLimit: 2)
  }
}
