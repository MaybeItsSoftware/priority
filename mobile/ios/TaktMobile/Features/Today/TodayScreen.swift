import TaktCore
import TaktWorkspace
import SwiftUI

/// The day as a list of cards: what is on today, what it should cost, what it
/// has cost, and the one you are on carrying its own controls. The Mac's
/// `DayView`, for a phone.
struct TodayScreen: View {
  @Environment(\.theme) private var theme
  @Environment(WorkspaceModel.self) private var model
  @Environment(\.isPadLayout) private var isPad
  @State private var today = TodayModel()

  var body: some View {
    @Bindable var navigation = model.navigation
    List(selection: isPad ? $navigation.selectedTaskID : .constant(nil)) {
      Section {
        DayHeader(day: today.day)
          .listRowInsets(EdgeInsets())
          .listRowBackground(theme.paper)
          .listRowSeparator(.hidden)
          .selectionDisabled()
      }
      Section {
        ForEach(Array(today.day.cards.enumerated()), id: \.element.id) { index, card in
          cardRow(card, index: index)
        }
        .onMove { source, destination in today.move(from: source, to: destination, model: model) }
      } header: {
        if !today.day.cards.isEmpty && !today.day.isPlanned {
          Text("Nothing planned — the top of the ranking")
            .font(theme.type.caption).foregroundStyle(theme.muted).textCase(nil)
        }
      }
      if !today.day.dailies.isEmpty {
        Section {
          ForEach(today.day.dailies) { daily in
            DailyRow(daily: daily) { today.toggleDaily(daily, model: model) }
              .listRowBackground(theme.paper)
              .listRowSeparatorTint(theme.borderMuted)
              .moveDisabled(true)
              .selectionDisabled()
          }
        } header: {
          Text("Dailies").font(theme.type.caption).foregroundStyle(theme.muted).textCase(nil)
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(theme.paper)
    .overlay {
      if today.isLoaded && today.day.cards.isEmpty && today.day.dailies.isEmpty {
        EmptyState(
          title: "Nothing planned for today",
          message: "Plan a task for today from its menu, or add one with +.",
          systemImage: "sun.max")
      }
    }
    .navigationTitle("Today")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { WorkspaceToolbar() }
    .task(id: model.revision) { await today.load(model) }
    .task(id: today.day.session?.id) { await refreshWhileRunning() }
    .accessibilityIdentifier("today.list")
  }

  @ViewBuilder
  private func cardRow(_ card: DayCard, index: Int) -> some View {
    let isSelected = model.navigation.selectedTaskID == card.id
    Group {
      if card.isRunning, let session = today.day.session {
        RunningDayCard(
          card: card, index: index + 1, session: session, canSkip: today.day.hasQueuedSuccessor,
          onPause: { today.togglePause(model: model) },
          onSkip: { today.requestCompletion(completeTask: false, model: model) },
          onLog: { today.requestCompletion(completeTask: false, model: model) },
          onDone: { today.requestCompletion(completeTask: true, model: model) })
      } else {
        DayCardRow(
          card: card, index: index + 1, isSelected: isSelected,
          onTick: { today.tickOff(card, model: model) },
          onStart: { today.start(card, model: model) },
          onOpen: { model.navigation.inspect(card.id, isPad: isPad) })
          .equatable()
      }
    }
    .tag(card.id)
    .listRowInsets(EdgeInsets(top: 0, leading: theme.space.lg, bottom: 0, trailing: theme.space.lg))
    .listRowBackground(card.isRunning ? theme.primary.opacity(0.06) : (isSelected ? theme.primary.opacity(0.10) : theme.paper))
    .listRowSeparatorTint(theme.borderMuted)
    .moveDisabled(!card.isPlanned)
    .swipeActions(edge: .leading, allowsFullSwipe: true) {
      Button { today.tickOff(card, model: model) } label: {
        Label(card.dailyID != nil ? "Log today" : "Done", systemImage: "checkmark")
      }
      .tint(theme.success)
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      Button { today.deferToTomorrow(card, model: model) } label: { Label("Tomorrow", systemImage: "sunrise") }
        .tint(theme.warning)
      if card.isPlanned {
        Button { model.togglePlannedToday(card.id) } label: { Label("Take off", systemImage: "sun.max") }
          .tint(theme.muted)
      }
    }
    .contextMenu {
      if card.isPlanned {
        Section {
          Button { today.movePlanned(card.id, by: -1, model: model) } label: {
            Label("Move up in the day", systemImage: "arrow.up")
          }
          Button { today.movePlanned(card.id, by: 1, model: model) } label: {
            Label("Move down in the day", systemImage: "arrow.down")
          }
        }
      }
      Section {
        Button { today.start(card, model: model) } label: {
          Label(card.isRunning ? "Done" : (today.day.session?.phase == .running ? "Queue next" : "Start"),
            systemImage: card.isRunning ? "checkmark" : "play")
        }
        Button { today.deferToTomorrow(card, model: model) } label: { Label("Not today", systemImage: "sunrise") }
      }
      TaskContextMenu(context: card.menuContext)
    }
    .accessibilityIdentifier("today.card.\(card.title)")
  }

  /// While a block runs, a write elsewhere (the Live Activity, an intent)
  /// can end it; re-read every so often so the day does not show a stale
  /// clock forever. Cheap: one read, off the main actor.
  private func refreshWhileRunning() async {
    guard today.day.session != nil else { return }
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(30))
      await today.load(model)
    }
  }
}

// MARK: - Header

/// What the day costs against what it has cost, and when it ends: the Mac
/// pane's tally, with the panel's bar and week line under it.
struct DayHeader: View {
  @Environment(\.theme) private var theme
  let day: DaySnapshot

  var body: some View {
    let isTicking = day.session?.phase == .running && day.session?.pausedAt == nil
    TimelineView(.periodic(from: .now, by: isTicking ? 30 : 60)) { context in
      let forecast = day.forecast(now: context.date)
      VStack(alignment: .leading, spacing: theme.space.sm) {
        HStack(alignment: .firstTextBaseline, spacing: theme.space.sm) {
          Text(Self.spent(forecast))
            .font(theme.type.numeralBody)
            .foregroundStyle(theme.ink)
            .accessibilityIdentifier("today.tally")
          Spacer(minLength: theme.space.sm)
          if let finish = forecast.finishAt {
            Text("done by \(finish.formatted(date: .omitted, time: .shortened))")
              .font(theme.type.numeral)
              .foregroundStyle(theme.primary)
          }
        }
        bar(forecast)
        HStack(spacing: theme.space.sm) {
          Text(Self.remaining(forecast))
          Spacer(minLength: theme.space.sm)
          Text(day.loggedToday > 0 ? "\(Format.duration(day.loggedToday)) logged today" : "Nothing logged yet")
        }
        .font(theme.type.caption)
        .foregroundStyle(theme.muted)
        if day.workProgress.week.seconds > 0 || day.workProgress.week.completed > 0 {
          HStack(spacing: theme.space.sm) {
            Text(day.workProgress.today.completed == 1 ? "1 done today" : "\(day.workProgress.today.completed) done today")
            Spacer(minLength: theme.space.sm)
            Text("\(Format.duration(day.workProgress.week.seconds)) this week · \(Format.duration(day.workProgress.averageSecondsPerDay))/day")
          }
          .font(theme.type.caption)
          .foregroundStyle(theme.muted)
        }
      }
      .padding(.horizontal, theme.space.lg)
      .padding(.vertical, theme.space.md)
    }
    .overlay(alignment: .bottom) { Hairline() }
  }

  /// Square-ended: a bar is a length, not decoration.
  private func bar(_ forecast: DayForecast) -> some View {
    let fraction = forecast.estimatedSeconds > 0
      ? min(1, Double(forecast.loggedSeconds) / Double(forecast.estimatedSeconds)) : 0
    return GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Rectangle().fill(theme.well)
        Rectangle().fill(theme.primary).frame(width: proxy.size.width * fraction)
      }
    }
    .frame(height: 4)
    .accessibilityHidden(true)
  }

  static func spent(_ forecast: DayForecast) -> String {
    let logged = DayForecastText.hoursAndMinutes(forecast.loggedSeconds)
    guard forecast.estimatedSeconds > 0 else { return "\(logged) logged" }
    return "\(logged) of \(DayForecastText.hoursAndMinutes(forecast.estimatedSeconds))"
  }

  static func remaining(_ forecast: DayForecast) -> String {
    guard forecast.estimatedSeconds > 0 else { return "No estimates yet" }
    var text = forecast.finishAt == nil
      ? "Every estimate used up" : "\(DayForecastText.hoursAndMinutes(forecast.remainingSeconds)) left"
    if forecast.unestimatedCount > 0 { text += " · \(forecast.unestimatedCount) unestimated" }
    return text
  }
}

/// The Mac's `DayForecast.hoursAndMinutes`, which lives in the app target.
enum DayForecastText {
  static func hoursAndMinutes(_ seconds: Int) -> String {
    let minutes = max(0, seconds) / 60
    if minutes < 60 { return "\(minutes)m" }
    let remainder = minutes % 60
    return remainder == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(remainder)m"
  }
}

// MARK: - Cards

/// A card that is not running: a tick, the title and why it is here, its
/// cost, and a play button.
struct DayCardRow: View, Equatable {
  @Environment(\.theme) private var theme
  let card: DayCard
  let index: Int
  let isSelected: Bool
  let onTick: () -> Void
  let onStart: () -> Void
  let onOpen: () -> Void

  static func == (lhs: DayCardRow, rhs: DayCardRow) -> Bool {
    lhs.card == rhs.card && lhs.index == rhs.index && lhs.isSelected == rhs.isSelected
  }

  var body: some View {
    HStack(spacing: theme.space.sm) {
      Text("\(index)")
        .font(theme.type.numeral)
        .foregroundStyle(theme.dim)
        .frame(minWidth: 16, alignment: .trailing)
      Button(action: onTick) {
        TaskCheckbox(status: card.isDailyDoneToday ? .completed : .open, isList: card.isList)
          .celebrationIcon(card.id)
          .frame(width: 32, height: theme.touchTarget)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(card.dailyID != nil ? "Log \(card.title) for today" : "Complete \(card.title)")
      .accessibilityIdentifier("today.check.\(card.title)")
      Button(action: onOpen) {
        VStack(alignment: .leading, spacing: theme.space.xxs) {
          Text(card.title)
            .font(theme.type.body)
            .foregroundStyle(theme.ink)
            .lineLimit(2)
            .celebrationStrike(card.id)
            .frame(maxWidth: .infinity, alignment: .leading)
          HStack(spacing: theme.space.xs) {
            if let reason = card.reason, reason != .planned {
              Text(card.detail ?? reason.label).foregroundStyle(tint(for: reason))
            } else if let detail = card.detail {
              Text(detail)
            }
            if card.dailyID != nil {
              Image(systemName: "repeat").imageScale(.small)
            }
            if let list = card.listName {
              Text(list).lineLimit(1)
            }
          }
          .font(theme.type.footnote)
          .foregroundStyle(theme.muted)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      cost
      Button(action: onStart) {
        Image(systemName: "play.fill")
          .font(theme.type.glyph(13))
          .foregroundStyle(theme.primary)
          .frame(width: 36, height: theme.touchTarget)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Start \(card.title)")
      .accessibilityIdentifier("today.start.\(card.title)")
    }
    .celebrationRow(card.id)
  }

  @ViewBuilder
  private var cost: some View {
    if let estimate = card.estimateSeconds, estimate > 0 {
      Text(card.loggedSeconds > 0
        ? "\(Format.duration(card.loggedSeconds))/\(Format.duration(estimate))" : Format.duration(estimate))
        .font(theme.type.numeral)
        .foregroundStyle(card.loggedSeconds > estimate ? theme.warning : theme.muted)
    } else if card.loggedSeconds > 0 {
      Text(Format.duration(card.loggedSeconds)).font(theme.type.numeral).foregroundStyle(theme.muted)
    }
  }

  private func tint(for reason: DayPlanReason) -> Color {
    switch reason {
    case .overdue: theme.danger
    case .dueToday: theme.primary
    case .startsToday: theme.success
    case .running, .planned: theme.muted
    }
  }
}

/// The card you are on: the same card, grown — a live clock, and the
/// controls that only apply to the task actually running.
struct RunningDayCard: View {
  @Environment(\.theme) private var theme
  let card: DayCard
  let index: Int
  let session: FocusSession
  let canSkip: Bool
  let onPause: () -> Void
  let onSkip: () -> Void
  let onLog: () -> Void
  let onDone: () -> Void

  private var isPaused: Bool { session.pausedAt != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.sm) {
      HStack(spacing: theme.space.sm) {
        Text("\(index)").font(theme.type.numeral).foregroundStyle(theme.primary)
        Text(card.title).font(theme.type.title).foregroundStyle(theme.ink).lineLimit(2)
        Spacer(minLength: theme.space.sm)
        if let list = card.listName {
          Text(list).font(theme.type.footnote).foregroundStyle(theme.muted).lineLimit(1)
        }
      }
      HStack(alignment: .firstTextBaseline, spacing: theme.space.sm) {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          let reading = FocusTimerDisplay.reading(
            elapsed: TimeInterval(session.elapsedSeconds(now: context.date)),
            planned: TimeInterval(session.workDurationSeconds))
          Text(reading.text)
            .font(theme.type.display)
            .monospacedDigit()
            .foregroundStyle(isPaused ? theme.muted : (reading.isOverrun ? theme.warning : theme.primary))
            .contentTransition(.numericText())
            .accessibilityIdentifier("today.clock")
        }
        Text(isPaused ? "paused" : "of \(Format.duration(session.workDurationSeconds))")
          .font(theme.type.caption)
          .foregroundStyle(isPaused ? theme.warning : theme.muted)
        Spacer(minLength: 0)
      }
      HStack(spacing: theme.space.sm) {
        control(isPaused ? "play.fill" : "pause.fill", isPaused ? "Resume" : "Pause", action: onPause)
        control("forward.end.fill", "Skip to the next queued task", action: onSkip)
          .disabled(!canSkip)
          .opacity(canSkip ? 1 : 0.4)
        control("clock.arrow.circlepath", "Log the time and keep the task open", action: onLog)
        Spacer(minLength: 0)
        Button(action: onDone) {
          Label("Done", systemImage: "checkmark")
        }
        .buttonStyle(ThemedButtonStyle(kind: .primary, compact: true))
        .accessibilityIdentifier("today.done")
      }
    }
    .padding(.vertical, theme.space.md)
  }

  private func control(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(theme.type.glyph(14))
        .foregroundStyle(theme.ink)
        .frame(width: 44, height: 36)
        .overlay(RoundedRectangle(cornerRadius: theme.radius.control).strokeBorder(theme.inputBorder, lineWidth: theme.stroke))
        .hitTarget()
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }
}

/// A daily expected today, ticked when today's contribution is in.
struct DailyRow: View {
  @Environment(\.theme) private var theme
  let daily: DayDaily
  let onToggle: () -> Void

  var body: some View {
    Button(action: onToggle) {
      HStack(spacing: theme.space.sm) {
        TaskCheckbox(status: daily.isDone ? .completed : .open)
          .frame(width: 32, height: theme.touchTarget)
        Text(daily.title)
          .font(theme.type.body)
          .foregroundStyle(daily.isDone ? theme.muted : theme.ink)
          .strikethrough(daily.isDone, color: theme.dim)
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
        if daily.secondsToday > 0 || daily.targetSeconds != nil {
          Text(progress).font(theme.type.numeral).foregroundStyle(theme.muted)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(daily.isDone ? "Clear \(daily.title) for today" : "Log \(daily.title) for today")
    .accessibilityIdentifier("today.daily.\(daily.title)")
  }

  private var progress: String {
    let logged = Format.duration(daily.secondsToday)
    guard let target = daily.targetSeconds else { return logged }
    return "\(daily.secondsToday > 0 ? logged : "0m")/\(Format.duration(target))"
  }
}
