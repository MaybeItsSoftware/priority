import PriorityCore
import PriorityWorkspace
import SwiftUI

/// Focus: say where you are and how long you have, pick a rung of the
/// ranked ladder, decide the estimate, begin — then the running block, and
/// the question of how it went.
struct FocusScreen: View {
  @Environment(WorkspaceModel.self) private var model
  @State private var focus: FocusModel?

  var body: some View {
    Group {
      if let focus {
        FocusContent(focus: focus)
      } else {
        Color.clear
      }
    }
    .background(Palette.paper)
    .navigationTitle("Focus")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { WorkspaceToolbar() }
    .onAppear {
      if focus == nil { focus = FocusModel(model: model) }
    }
  }
}

private struct FocusContent: View {
  @Environment(WorkspaceModel.self) private var model
  @Bindable var focus: FocusModel

  var body: some View {
    Group {
      if focus.session != nil {
        FocusRunningView(focus: focus)
      } else {
        FocusPlanningView(focus: focus)
      }
    }
    .task(id: QueryKey(revision: model.revision, scope: focus.contextVersion)) {
      await focus.load()
    }
    .onAppear { focus.takeRequest() }
    .onChange(of: model.focusRequestTaskID) { _, _ in focus.takeRequest() }
    .sheet(item: $focus.pendingCompletion) { pending in
      FocusQualityPrompt(focus: focus, pending: pending)
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
    }
    .confirmationDialog(
      "Start anyway?", isPresented: overrideBinding, titleVisibility: .visible, presenting: focus.startOverride
    ) { _ in
      Button("Start anyway") { focus.confirmOverride() }
      Button("Cancel", role: .cancel) { focus.startOverride = nil }
    } message: { pending in
      Text(pending.explanation)
    }
  }

  private var overrideBinding: Binding<Bool> {
    Binding(get: { focus.startOverride != nil }, set: { if !$0 { focus.startOverride = nil } })
  }
}

// MARK: - Planning

private struct FocusPlanningView: View {
  @Environment(WorkspaceModel.self) private var model
  @Bindable var focus: FocusModel
  @State private var showsBlocked = false

  var body: some View {
    List {
      Section {
        FocusPointsStrip(points: focus.snapshot.points, award: focus.lastAward, outcome: focus.lastOutcome) {
          focus.dismissAward()
        }
        FocusContextControls(focus: focus)
      }
      .listRowBackground(Palette.paper)
      .listRowSeparator(.hidden)

      if focus.stagedTaskID != nil {
        Section {
          FocusStagedCard(focus: focus)
        } header: {
          header("Staged")
        }
        .listRowBackground(Palette.paper)
        .listRowSeparator(.hidden)
      }

      Section {
        if focus.ladder.isEmpty, focus.isLoaded {
          EmptyState(
            title: "Nothing to do here", message: "Nothing fits this context and time. Change them, or add a task.",
            systemImage: "scope")
          .listRowBackground(Palette.paper)
        }
        ForEach(Array(focus.ladder.enumerated()), id: \.element.id) { index, rung in
          FocusRungRow(focus: focus, rung: rung, index: index)
        }
        .onMove { focus.moveRungs(from: $0, to: $1) }
      } header: {
        HStack {
          header("Ladder")
          Spacer()
          if focus.snapshot.hasManualOrder {
            Button("Reset order") { focus.resetOrder() }
              .font(Typeface.caption)
              .accessibilityIdentifier("focus.resetOrder")
          }
        }
      }

      if !focus.snapshot.blocked.isEmpty {
        Section {
          DisclosureGroup(isExpanded: $showsBlocked) {
            ForEach(focus.snapshot.blocked) { blocked in
              VStack(alignment: .leading, spacing: 2) {
                Text(blocked.candidate.title).font(Typeface.body).foregroundStyle(Palette.muted)
                Text(blocked.reasons.map(focus.unavailableDescription).joined(separator: " · "))
                  .font(Typeface.footnote).foregroundStyle(Palette.dim)
              }
              .contextMenu {
                Button { focus.stage(blocked.id) } label: { Label("Stage anyway", systemImage: "target") }
              }
            }
          } label: {
            Text("Not available now · \(focus.snapshot.blocked.count)")
              .font(Typeface.callout).foregroundStyle(Palette.muted)
          }
        }
        .listRowBackground(Palette.paper)
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .accessibilityIdentifier("focus.ladder")
  }

  private func header(_ text: String) -> some View {
    Text(text).font(Typeface.caption).foregroundStyle(Palette.muted).textCase(nil)
  }
}

/// Points today, this week and ever, and what the last block earned.
private struct FocusPointsStrip: View {
  let points: FocusPointsSummary
  let award: FocusAward?
  let outcome: WorkspaceStore.FocusCompletionOutcome?
  let onDismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Metrics.sm) {
      if let award {
        HStack(spacing: Metrics.sm) {
          Image(systemName: "sparkles").foregroundStyle(Palette.warning)
          Text("+\(FocusPoints.formatted(award.points)) points")
            .font(Typeface.numeralBody).foregroundStyle(Palette.ink)
          Text(outcomeText).font(Typeface.caption).foregroundStyle(Palette.muted)
          Spacer()
          Button(action: onDismiss) { Image(systemName: "xmark").foregroundStyle(Palette.dim) }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(Metrics.md)
        .background(Palette.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Palette.warning.opacity(0.4), lineWidth: 1))
      }
      HStack(spacing: Metrics.lg) {
        stat("Today", FocusPoints.formatted(points.today))
        stat("7 days", FocusPoints.formatted(points.last7Days))
        stat("All time", FocusPoints.formatted(points.allTime))
        stat("Blocks", "\(points.blocksToday)")
      }
    }
    .accessibilityIdentifier("focus.points")
  }

  private var outcomeText: String {
    switch outcome {
    case .taskCompleted: "Task done"
    case .progressLogged(let seconds): "Logged \(Format.duration(seconds))"
    case .contributionLogged(let seconds): "Daily +\(Format.duration(seconds))"
    case nil: ""
    }
  }

  private func stat(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(value).font(Typeface.numeralBody).foregroundStyle(Palette.ink)
      Text(label).font(Typeface.footnote).foregroundStyle(Palette.muted)
    }
  }
}

/// Where you are (condition chips), how long you have, and whether you want
/// to make progress or finish something.
private struct FocusContextControls: View {
  @Bindable var focus: FocusModel
  @State private var isAddingCondition = false
  @State private var newCondition = ""
  @State private var newIsLocation = false
  @State private var customMinutes = 45

  var body: some View {
    VStack(alignment: .leading, spacing: Metrics.md) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: Metrics.sm) {
          ForEach(focus.visibleConditions) { condition in
            let isOn = focus.conditionIDs.contains(condition.id)
            Button {
              focus.toggleCondition(condition)
            } label: {
              HStack(spacing: 4) {
                if condition.isLocation { Image(systemName: "mappin").imageScale(.small) }
                Text(condition.name)
              }
              .font(Typeface.callout)
              .foregroundStyle(isOn ? Palette.primary : Palette.ink)
              .padding(.horizontal, Metrics.md)
              .frame(minHeight: 34)
              .background(isOn ? Palette.primary.opacity(0.10) : Palette.raised,
                in: RoundedRectangle(cornerRadius: Metrics.controlRadius))
              .overlay(RoundedRectangle(cornerRadius: Metrics.controlRadius)
                .strokeBorder(isOn ? Palette.primary.opacity(0.5) : Palette.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isOn ? .isSelected : [])
            .accessibilityIdentifier("focus.condition.\(condition.name)")
          }
          Button {
            isAddingCondition = true
          } label: {
            Image(systemName: "plus")
              .foregroundStyle(Palette.muted)
              .frame(width: 34, height: 34)
              .overlay(RoundedRectangle(cornerRadius: Metrics.controlRadius).strokeBorder(Palette.border, lineWidth: 1))
          }
          .buttonStyle(.plain)
          .accessibilityLabel("New condition")
        }
        .padding(.vertical, 1)
      }
      HStack(spacing: Metrics.sm) {
        Menu {
          Button("No time limit") { focus.setAvailable(minutes: nil) }
          ForEach([15, 30, 60], id: \.self) { minutes in
            Button("\(minutes) minutes") { focus.setAvailable(minutes: minutes) }
          }
          Menu("Custom") {
            ForEach([10, 20, 45, 90, 120], id: \.self) { minutes in
              Button("\(minutes) minutes") { focus.setAvailable(minutes: minutes) }
            }
          }
          Button("Until…") {
            focus.availableUntil = focus.availableUntil ?? Date.now.addingTimeInterval(3_600)
          }
        } label: {
          Label(timeTitle, systemImage: "clock")
            .font(Typeface.callout)
            .controlFrame(expands: false)
        }
        .accessibilityIdentifier("focus.time")
        if let until = focus.availableUntil {
          DatePicker("Until", selection: Binding(get: { until }, set: { focus.availableUntil = $0 }),
                     in: Date.now..., displayedComponents: .hourAndMinute)
            .labelsHidden()
        }
        Spacer(minLength: 0)
      }
      Picker("Mode", selection: $focus.mode) {
        Text("Make progress").tag(FocusTimeMode.progress)
        Text("Finish something").tag(FocusTimeMode.finish)
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("focus.mode")
    }
    .alert("New condition", isPresented: $isAddingCondition) {
      TextField("Name", text: $newCondition)
      Button("Cancel", role: .cancel) { newCondition = "" }
      Button("Add place") { add(location: true) }
      Button("Add") { add(location: false) }
    } message: {
      Text("A place, a tool or a state you need to be in for some tasks.")
    }
  }

  private var timeTitle: String {
    guard let until = focus.availableUntil else { return "Any length" }
    let minutes = max(0, Int(until.timeIntervalSinceNow / 60))
    return "\(minutes)m · until \(Format.time(until))"
  }

  private func add(location: Bool) {
    let name = newCondition.trimmingCharacters(in: .whitespacesAndNewlines)
    newCondition = ""
    guard !name.isEmpty else { return }
    focus.createCondition(named: name, isLocation: location)
  }
}

/// The task about to be started and the estimate it is started with.
private struct FocusStagedCard: View {
  @Bindable var focus: FocusModel

  var body: some View {
    VStack(alignment: .leading, spacing: Metrics.md) {
      Text(focus.stagedTitle ?? "")
        .font(Typeface.title)
        .foregroundStyle(Palette.ink)
      if let rung = focus.stagedRung {
        Text(focus.explanation(for: rung).capitalizedFirst)
          .font(Typeface.caption).foregroundStyle(Palette.muted)
      }
      HStack(spacing: Metrics.md) {
        Text(Format.duration(Int(focus.estimateMinutes * 60)))
          .font(Typeface.numeralBody)
          .foregroundStyle(Palette.ink)
          .frame(minWidth: 64, alignment: .leading)
        Stepper("Estimate", value: $focus.estimateMinutes, in: 1...480, step: 5)
          .labelsHidden()
          .accessibilityIdentifier("focus.estimate")
        Spacer(minLength: 0)
      }
      HStack(spacing: Metrics.sm) {
        ForEach([15, 25, 45, 60, 90], id: \.self) { minutes in
          Button("\(minutes)m") { focus.estimateMinutes = Double(minutes) }
            .buttonStyle(ThemedButtonStyle(kind: Int(focus.estimateMinutes) == minutes ? .primary : .quiet, compact: true))
            .font(Typeface.numeral)
        }
      }
      HStack(spacing: Metrics.sm) {
        Button {
          focus.beginStaged()
        } label: {
          Label("Begin", systemImage: "play.fill").frame(maxWidth: .infinity)
        }
        .buttonStyle(ThemedButtonStyle(kind: .primary))
        .accessibilityIdentifier("focus.begin")
        Button("Back") { focus.unstage() }
          .buttonStyle(ThemedButtonStyle(kind: .quiet))
      }
    }
    .padding(Metrics.lg)
    .cardSurface(selected: true)
  }
}

private struct FocusRungRow: View {
  @Bindable var focus: FocusModel
  let rung: ScoredNextUp
  let index: Int

  var body: some View {
    let isStaged = focus.stagedTaskID == rung.id
    Button {
      focus.stage(rung.id)
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: Metrics.md) {
        Text("\(index + 1)")
          .font(Typeface.numeral)
          .foregroundStyle(index == 0 ? Palette.primary : Palette.dim)
          .frame(width: 22, alignment: .trailing)
        VStack(alignment: .leading, spacing: 2) {
          Text(rung.candidate.title)
            .font(index == 0 ? Typeface.bodyMedium : Typeface.body)
            .foregroundStyle(Palette.ink)
            .lineLimit(2)
          Text(focus.explanation(for: rung).capitalizedFirst)
            .font(Typeface.footnote)
            .foregroundStyle(Palette.muted)
            .lineLimit(2)
        }
        Spacer(minLength: Metrics.sm)
        if rung.candidate.isDailyDueToday {
          Image(systemName: "repeat").font(.system(size: 11)).foregroundStyle(Palette.purple)
            .accessibilityLabel("Daily")
        }
        if let remaining = rung.candidate.remainingSeconds, remaining > 0 {
          Text(Format.duration(remaining)).font(Typeface.numeral).foregroundStyle(Palette.muted)
        }
      }
      .padding(.vertical, 6)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowBackground(isStaged ? Palette.primary.opacity(0.10) : Palette.paper)
    .listRowSeparatorTint(Palette.borderMuted)
    .accessibilityIdentifier("focus.rung.\(rung.candidate.title)")
    .swipeActions(edge: .leading, allowsFullSwipe: true) {
      Button { focus.completeWithoutSession(rung.id) } label: { Label("Tick off", systemImage: "checkmark") }
        .tint(Palette.success)
    }
    .swipeActions(edge: .trailing) {
      Button { focus.deferTask(rung.id, .tomorrow) } label: { Label("Tomorrow", systemImage: "sunrise") }
        .tint(Palette.warning)
      Button { focus.deferTask(rung.id, .anHour) } label: { Label("An hour", systemImage: "clock") }
        .tint(Palette.muted)
    }
    .contextMenu {
      Button { focus.stage(rung.id) } label: { Label("Stage this", systemImage: "target") }
      Button { focus.completeWithoutSession(rung.id) } label: { Label("Tick off", systemImage: "checkmark") }
      Menu {
        ForEach(FocusDeferral.allCases) { deferral in
          Button(deferral.title) { focus.deferTask(rung.id, deferral) }
        }
      } label: { Label("Later", systemImage: "clock") }
      Divider()
      Button { focus.moveRung(rung.id, by: -1) } label: { Label("Move up", systemImage: "arrow.up") }
        .disabled(index == 0)
      Button { focus.moveRung(rung.id, by: 1) } label: { Label("Move down", systemImage: "arrow.down") }
        .disabled(index == focus.ladder.count - 1)
    }
  }
}

// MARK: - Running

private struct FocusRunningView: View {
  @Environment(WorkspaceModel.self) private var model
  @Bindable var focus: FocusModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Metrics.xl) {
        if let session = focus.session, let task = focus.activeTask {
          VStack(alignment: .leading, spacing: Metrics.sm) {
            Text(session.pausedAt == nil ? "Focusing" : "Paused")
              .font(Typeface.caption)
              .foregroundStyle(session.pausedAt == nil ? Palette.primary : Palette.warning)
            Text(task.title)
              .font(Typeface.largeTitle)
              .foregroundStyle(Palette.ink)
              .accessibilityIdentifier("focus.running.title")
          }
          TimelineView(.periodic(from: .now, by: 1)) { context in
            clock(session: session, now: context.date)
          }
          controls(session: session)
          if focus.snapshot.queue.contains(where: { $0.item.state == .queued && $0.task.id != task.id }) {
            queue(activeID: task.id)
          }
        } else {
          EmptyState(
            title: "Nothing in the queue can run now",
            message: "The rest of this session's queue doesn't fit the current context.", systemImage: "pause.circle")
          Button("End session") { focus.finish() }
            .buttonStyle(ThemedButtonStyle(kind: .quiet))
        }
      }
      .padding(Metrics.lg)
      .frame(maxWidth: 640, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .task(id: focus.session?.activeBlockId) {
      while !Task.isCancelled {
        focus.tick()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private func clock(session: FocusSession, now: Date) -> some View {
    let elapsed = session.elapsedSeconds(now: now)
    let planned = max(60, session.workDurationSeconds)
    let fraction = min(1, Double(elapsed) / Double(planned))
    return VStack(alignment: .leading, spacing: Metrics.sm) {
      Text(Format.clock(elapsed))
        .font(Typeface.hero)
        .monospacedDigit()
        .foregroundStyle(Palette.ink)
        .accessibilityIdentifier("focus.clock")
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Rectangle().fill(Palette.well)
          Rectangle().fill(elapsed > planned ? Palette.warning : Palette.primary)
            .frame(width: proxy.size.width * fraction)
        }
      }
      .frame(height: 4)
      .clipShape(RoundedRectangle(cornerRadius: 2))
      Text("of \(Format.duration(planned)) planned")
        .font(Typeface.caption).foregroundStyle(Palette.muted)
    }
  }

  private func controls(session: FocusSession) -> some View {
    VStack(spacing: Metrics.sm) {
      Button {
        focus.requestCompletion(completeTask: true)
      } label: {
        Label("Done", systemImage: "checkmark").frame(maxWidth: .infinity)
      }
      .buttonStyle(ThemedButtonStyle(kind: .primary))
      .accessibilityIdentifier("focus.done")
      HStack(spacing: Metrics.sm) {
        Button {
          focus.togglePause()
        } label: {
          Label(session.pausedAt == nil ? "Pause" : "Resume",
                systemImage: session.pausedAt == nil ? "pause.fill" : "play.fill")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ThemedButtonStyle(kind: .quiet))
        .accessibilityIdentifier("focus.pause")
        Button {
          focus.requestCompletion(completeTask: false)
        } label: {
          Label("Log and keep", systemImage: "tray.and.arrow.down").frame(maxWidth: .infinity)
        }
        .buttonStyle(ThemedButtonStyle(kind: .quiet))
        .accessibilityIdentifier("focus.logKeep")
      }
      Button("End session") { focus.finish() }
        .font(Typeface.callout)
        .foregroundStyle(Palette.muted)
        .padding(.top, Metrics.xs)
        .accessibilityIdentifier("focus.end")
    }
  }

  private func queue(activeID: String) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Up next in this session").font(Typeface.caption).foregroundStyle(Palette.muted)
        .padding(.bottom, Metrics.sm)
      ForEach(focus.snapshot.queue.filter { $0.item.state == .queued && $0.task.id != activeID }) { entry in
        HStack {
          Text(entry.task.title).font(Typeface.body).foregroundStyle(Palette.ink)
          Spacer()
          if let planned = entry.item.plannedSeconds {
            Text(Format.duration(planned)).font(Typeface.numeral).foregroundStyle(Palette.muted)
          }
        }
        .padding(.vertical, Metrics.sm)
        Hairline(color: Palette.borderMuted)
      }
    }
  }
}

// MARK: - Quality

/// How did that go? The answer scales the block's points, ×0.5 to ×5.
struct FocusQualityPrompt: View {
  @Bindable var focus: FocusModel
  let pending: PendingFocusCompletion
  @State private var multiplier: Double = 1

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: Metrics.lg) {
          VStack(alignment: .leading, spacing: Metrics.xs) {
            Text(pending.title).font(Typeface.title).foregroundStyle(Palette.ink)
            Text("\(Format.duration(pending.seconds)) \(pending.completeTask ? "· finishes the task" : "· task stays open")")
              .font(Typeface.caption).foregroundStyle(Palette.muted)
          }
          VStack(spacing: 0) {
            ForEach(FocusQuality.allCases) { quality in
              Button {
                multiplier = quality.multiplier
              } label: {
                HStack {
                  VStack(alignment: .leading, spacing: 1) {
                    Text(quality.title).font(Typeface.body).foregroundStyle(Palette.ink)
                    Text(quality.detail).font(Typeface.footnote).foregroundStyle(Palette.muted)
                  }
                  Spacer()
                  Text("×\(Self.format(quality.multiplier))").font(Typeface.numeral)
                    .foregroundStyle(multiplier == quality.multiplier ? Palette.primary : Palette.muted)
                  Image(systemName: multiplier == quality.multiplier ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(multiplier == quality.multiplier ? Palette.primary : Palette.dim)
                }
                .padding(.vertical, Metrics.sm + 2)
                .padding(.horizontal, Metrics.md)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("focus.quality.\(quality.rawValue)")
              Hairline(color: Palette.borderMuted)
            }
          }
          .cardSurface()
          VStack(alignment: .leading, spacing: Metrics.xs) {
            HStack {
              Text("Multiplier").font(Typeface.caption).foregroundStyle(Palette.muted)
              Spacer()
              Text("×\(Self.format(multiplier))").font(Typeface.numeralBody).foregroundStyle(Palette.ink)
            }
            Slider(value: $multiplier, in: 0.5...5, step: 0.25)
              .tint(Palette.primary)
            Text("\(FocusPoints.formatted(FocusPoints.score(seconds: pending.seconds, multiplier: multiplier))) points")
              .font(Typeface.numeral).foregroundStyle(Palette.muted)
          }
        }
        .padding(Metrics.lg)
      }
      .background(Palette.paper)
      .navigationTitle("How did that go?")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Keep working") { focus.cancelCompletion() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Log it") { focus.confirmCompletion(multiplier: multiplier) }
            .accessibilityIdentifier("focus.logIt")
        }
      }
    }
  }

  static func format(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
  }
}

extension String {
  /// "it is due today" → "It is due today".
  var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
