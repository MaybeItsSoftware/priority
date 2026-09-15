import PriorityCore
import PriorityWorkspace
import SwiftUI

/// The way into the focus screen, sitting above the lists.
///
/// It shows what it would start on, because a button that hides its own
/// consequence gets pressed once and then avoided. When a session is already
/// running it becomes the way back to it rather than a second start.
struct WorkspaceFocusLauncher: View {
  @Environment(WorkspaceViewModel.self) private var model
  @State private var isHovering = false

  var body: some View {
    Button {
      if model.activeFocusSession != nil {
        model.showsFocusPanel = true
      } else {
        model.presentFocusScreen()
      }
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Image(systemName: model.activeFocusSession == nil ? "target" : "timer")
          Text(model.activeFocusSession == nil ? "FOCUS" : "IN SESSION")
            .font(.caption2.weight(.bold))
            .tracking(1.2)
          Spacer(minLength: 0)
          Text("⌘8")
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
        }
        .foregroundStyle(model.activeFocusSession == nil ? .secondary : Color.accentColor)

        Text(headline)
          .font(.callout.weight(.medium))
          .lineLimit(2)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
          .foregroundStyle(.primary)

        if let detail {
          Text(detail)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(
        isHovering ? Color.primary.opacity(0.07) : Color.primary.opacity(0.03),
        in: RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
      .contentShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .focusable()
    .onHover { isHovering = $0 }
    .help(model.activeFocusSession == nil ? "Start a focus session on your next task" : "Return to the running session")
    .accessibilityLabel(model.activeFocusSession == nil ? "Start focus. Next up: \(headline)" : "Return to focus session")
  }

  private var headline: String {
    if let active = model.activeFocusTask { return active.title }
    return model.nextUp?.candidate.title ?? "Nothing to pick up"
  }

  private var detail: String? {
    if model.activeFocusSession != nil { return "Session running" }
    guard let reason = model.nextUp?.reason else { return "Add a task or a daily to get started" }
    return reason.explanation.localizedCapitalized
  }
}

/// One task, an estimate, and a way out.
///
/// Deliberately shows nothing else. The screen exists to end the deciding, so
/// putting the rest of the queue on it would reopen exactly the question it is
/// meant to close; the alternatives sit behind a disclosure for the case where
/// the suggestion is genuinely wrong.
struct WorkspaceFocusScreen: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var showsAlternatives = false

  private let estimateChoices = [5, 10, 15, 25, 45, 60, 90]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      if let next = model.nextUp {
        content(for: next)
      } else {
        ContentUnavailableView(
          "Nothing waiting",
          systemImage: "checkmark.circle",
          description: Text("Every daily is done and no task is due. Add something, or take the time back."))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(width: 520, height: 560)
    .onAppear { model.reloadNextUp() }
  }

  private var header: some View {
    HStack {
      Text("NEXT UP")
        .font(.caption2.weight(.bold))
        .tracking(1.2)
        .foregroundStyle(.secondary)
      Spacer()
      Button("Close") { dismiss() }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .focusable()
        .keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 16)
  }

  @ViewBuilder
  private func content(for next: ScoredNextUp) -> some View {
    let task = model.nextUpTask()

    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        VStack(alignment: .leading, spacing: 10) {
          Text(next.candidate.title)
            .font(.title.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)

          Label("Suggested because \(next.reason.explanation).", systemImage: "sparkles")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

          if let task, let list = model.list(for: task) {
            Text(list.name)
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
        }

        VStack(alignment: .leading, spacing: 10) {
          Text("HOW LONG WILL YOU GIVE IT?")
            .font(.caption2.weight(.bold))
            .tracking(1.2)
            .foregroundStyle(.secondary)

          estimatePicker

          if let task, model.isDailyProgressTask(task) {
            Label(
              "This is a daily. Finishing logs today's contribution — the task itself stays open.",
              systemImage: "arrow.triangle.2.circlepath")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        actions(for: task)

        if !model.nextUpAlternatives.isEmpty {
          alternatives
        }
      }
      .padding(.horizontal, 22)
      .padding(.vertical, 20)
    }
  }

  private var estimatePicker: some View {
    @Bindable var model = model
    return VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        ForEach(estimateChoices, id: \.self) { minutes in
          Button {
            model.focusEstimateMinutes = minutes
          } label: {
            Text("\(minutes)m")
              .font(.callout.monospacedDigit())
              .frame(minWidth: 42)
              .padding(.vertical, 7)
              .background(
                model.focusEstimateMinutes == minutes ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 6))
              .overlay(
                RoundedRectangle(cornerRadius: 6)
                  .strokeBorder(
                    model.focusEstimateMinutes == minutes ? Color.accentColor : Color.primary.opacity(0.12),
                    lineWidth: 1))
          }
          .buttonStyle(.plain)
          .focusable()
          .accessibilityLabel("\(minutes) minutes")
        }
      }

      Stepper(value: $model.focusEstimateMinutes, in: 1...480, step: 5) {
        Text("\(model.focusEstimateMinutes) minutes")
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .focusable()
    }
  }

  @ViewBuilder
  private func actions(for task: WorkspaceTask?) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Button {
        model.startFocusOnNextUp()
        dismiss()
      } label: {
        Label("Start \(model.focusEstimateMinutes) minutes", systemImage: "play.fill")
          .frame(maxWidth: .infinity)
          .padding(.vertical, 5)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .focusable()
      .keyboardShortcut(.defaultAction)
      .disabled(task == nil)

      HStack(spacing: 10) {
        if let task {
          Menu {
            ForEach(WorkspaceDeferral.allCases) { deferral in
              Button(deferral.title) {
                model.scheduleForLater(task, until: deferral.date(from: .now))
                dismiss()
              }
            }
          } label: {
            Label("Schedule for later", systemImage: "clock")
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
          .focusable()
          .help("Stop offering this until the time you choose")
        }

        Button("Not this one") {
          model.skipNextUp()
        }
        .buttonStyle(.bordered)
        .focusable()
        .help("Pass over it for now; it comes back next launch")

        Spacer()
      }

      // The other way to start: everything you already put in Today, queued in
      // board order. Kept here rather than on its own shortcut, so there is one
      // place that starts a session.
      if model.todayTasks.count > 1 {
        Button {
          model.startFocusFromToday(plannedSeconds: max(1, model.focusEstimateMinutes) * 60)
          dismiss()
        } label: {
          Label("Run all \(model.todayTasks.count) Today tasks as a queue", systemImage: "list.number")
            .font(.callout)
        }
        .buttonStyle(.link)
        .focusable()
      }
    }
  }

  private var alternatives: some View {
    DisclosureGroup(isExpanded: $showsAlternatives) {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(model.nextUpAlternatives) { alternative in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
              Text(alternative.candidate.title)
                .lineLimit(1)
              Text(alternative.reason.explanation.localizedCapitalized)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Start") {
              guard let task = model.task(withID: alternative.candidate.id) else { return }
              model.startFocus(on: task, plannedSeconds: max(1, model.focusEstimateMinutes) * 60)
              dismiss()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .focusable()
          }
          .padding(.vertical, 2)
        }
      }
      .padding(.top, 8)
    } label: {
      Text("Something else")
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }
    .focusable()
  }
}

/// The deferrals the focus screen offers. Fixed rather than a date picker,
/// because "later" is a mood and picking a timestamp for it is a second
/// decision at the exact moment you were trying to avoid making one.
enum WorkspaceDeferral: String, CaseIterable, Identifiable {
  case anHour
  case thisAfternoon
  case tomorrow
  case nextWeek

  var id: String { rawValue }

  var title: String {
    switch self {
    case .anHour: return "In an hour"
    case .thisAfternoon: return "This afternoon"
    case .tomorrow: return "Tomorrow morning"
    case .nextWeek: return "Next week"
    }
  }

  func date(from now: Date, calendar: Calendar = .current) -> Date {
    switch self {
    case .anHour:
      return now.addingTimeInterval(3_600)
    case .thisAfternoon:
      let afternoon = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: now) ?? now
      // Already past two o'clock: an hour from now is the honest reading.
      return afternoon > now ? afternoon : now.addingTimeInterval(3_600)
    case .tomorrow:
      let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
      return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    case .nextWeek:
      let week = calendar.date(byAdding: .day, value: 7, to: now) ?? now
      return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: week) ?? week
    }
  }
}
