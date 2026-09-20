import PriorityCore
import SwiftUI

@MainActor
extension NativeDailyLogPlugin: PluginSettingsPageProviding {
  var settingsIconSystemName: String { "chart.bar.xaxis" }

  func sidebarStatusLabel(manager: AppCoordinator) -> String {
    manager.dailyLog.dailyLogEnabled ? "Enabled" : "Disabled"
  }

  func makeSettingsView(manager: AppCoordinator) -> AnyView {
    AnyView(DailyLogPluginSettingsView(manager: manager))
  }
}

private struct DailyLogPluginSettingsView: View {
  var manager: AppCoordinator

  @State private var fileNameFormat: String = ""
  @State private var folderFormat: String = ""
  @State private var previewDate = Date()
  /// Draft titles, keyed by daily id, for the rows currently being renamed.
  ///
  /// Not bound straight through to the store. Doing that meant `renameDaily`
  /// ran on every keystroke, and the store trims what it is given and ignores
  /// an empty result — correct rules for a finished title, fatal for a draft.
  /// Typing a space at the end of a word stored the trimmed version, the field
  /// re-read it, and the space disappeared as it was typed; multi-word names
  /// could not be entered at all, and clearing the field to retype snapped the
  /// old name straight back. See `DailyTitleEdit`.
  @State private var titleDrafts: [String: String] = [:]
  /// Which title field has focus, so leaving one commits it. `nil` is "none".
  @FocusState private var focusedTitleField: String?

  var body: some View {
    let dailyLog = manager.dailyLog

    Section(header: Text("Daily Log Plugin")) {
      Text(
        "Completions, focus sessions and the day's plan are always recorded locally — "
          + "that's what the Daily view reads. This section controls the Obsidian half."
      )
      .font(.caption)
      .foregroundColor(.secondary)

      dailiesEditor

      Picker("Day starts at", selection: rolloverBinding) {
        ForEach(0..<24, id: \.self) { hour in
          Text(String(format: "%02d:00", hour)).tag(hour)
        }
      }
      Text(
        "Work finished before this hour counts towards the previous day. "
          + "Midnight is rarely the right answer."
      )
      .font(.caption)
      .foregroundColor(.secondary)

      // Configuration comes before the switch that acts on it. Hiding the folder
      // picker behind the enable toggle would mean turning writing on before
      // there is anywhere to write to.
      VStack(alignment: .leading, spacing: 8) {
        Text("Dailies Folder")
        if dailyLog.dailiesFolderPath.isEmpty {
          Text("No folder selected")
            .foregroundColor(.secondary)
            .font(.caption)
        } else {
          Text(dailyLog.dailiesFolderPath)
            .font(.caption)
            .textSelection(.enabled)
        }

        HStack {
          Button("Choose Folder") { dailyLog.chooseDailiesFolder() }
          if !dailyLog.dailiesFolderPath.isEmpty {
            Button("Clear") { dailyLog.clearDailiesFolder() }
          }
          Spacer()
        }
      }
      .padding(.top, 4)

      VStack(alignment: .leading, spacing: 8) {
        Text("Note Naming")
        // Saved as you type rather than on submit: clicking away from a
        // settings field without pressing Return is normal, and silently
        // discarding the format would point the writer at the wrong file.
        TextField("File name format", text: $fileNameFormat)
          .onChange(of: fileNameFormat) { _, _ in saveFormat() }
        TextField("Subfolder format (optional)", text: $folderFormat)
          .onChange(of: folderFormat) { _, _ in saveFormat() }
        Text("Today's note would be: \(previewPath)")
          .font(.caption)
          .foregroundColor(.secondary)
          .textSelection(.enabled)
        Text(
          "Date patterns, e.g. yyyy-MM-dd for the file and yyyy/MM to nest by year and month. "
            + "Leave the subfolder empty for a flat folder."
        )
        .font(.caption)
        .foregroundColor(.secondary)
      }
      .padding(.top, 4)

      Toggle("Create missing notes", isOn: createsMissingNotesBinding)
        .toggleStyle(.switch)
      Text(
        createsMissingNotesBinding.wrappedValue
          ? "Priority will create the note if it doesn't exist yet. Turn this off if a "
            + "template builds your dailies — otherwise a bare stub can win the race."
          : "Priority only writes into notes that already exist, so it can never beat your "
            + "daily-note template to the file."
      )
      .font(.caption)
      .foregroundColor(.secondary)

      // The master switch, last: it acts on everything above it. Unreachable
      // until a folder exists, so it can never be on with nowhere to write.
      Toggle("Write days into Obsidian daily notes", isOn: dailyLogEnabledBinding)
        .toggleStyle(.switch)
        .disabled(dailyLog.dailiesFolderPath.isEmpty)

      if dailyLog.dailiesFolderPath.isEmpty {
        Text("Choose a dailies folder above to turn this on.")
          .font(.caption)
          .foregroundColor(.secondary)
      } else if !dailyLog.dailyLogEnabled {
        Text("Days are still recorded locally; nothing is written to your vault.")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      if dailyLog.dailyLogEnabled {
        Toggle("Write automatically at day rollover", isOn: writesAutomaticallyBinding)
          .toggleStyle(.switch)

        HStack {
          Button("Write Yesterday's Note Now") {
            let yesterday = dailyLog.plugin.boundary.day(offsetBy: -1, from: Date())
            _ = dailyLog.writeNoteNow(for: yesterday)
          }
          Spacer()
        }
      }
    }
    .onAppear {
      fileNameFormat = dailyLog.plugin.noteFormat.fileNameFormat
      folderFormat = dailyLog.plugin.noteFormat.folderFormat
    }
  }

  /// Full editor for the set of dailies — schedules and archiving, the things
  /// the popover's checklist deliberately doesn't carry. Adding and ticking
  /// stay in the Daily view, because that is where you are when you think of
  /// them; this is for the occasional reshuffle.
  @ViewBuilder
  private var dailiesEditor: some View {
    let dailyLog = manager.dailyLog
    // `let _ =`, not `_ =`: inside a ViewBuilder the latter is parsed as a
    // view expression and fails to compile. swiftlint:disable:next redundant_discardable_let
    let _ = dailyLog.revision

    VStack(alignment: .leading, spacing: 8) {
      Text("Dailies")
      Text(
        "Recurring things you intend to do. They reset every rollover — miss one "
          + "and it is simply a gap in the history, never an overdue task."
      )
      .font(.caption)
      .foregroundColor(.secondary)

      ForEach(dailyLog.allDailies) { daily in
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            TextField(
              "Title",
              text: Binding(
                get: { titleDrafts[daily.id] ?? daily.title },
                set: { titleDrafts[daily.id] = $0 }
              )
            )
            .textFieldStyle(.roundedBorder)
            // Return commits; so does clicking away, because abandoning what
            // someone just typed for reaching at the mouse is the wrong
            // default. An empty or unchanged draft commits to nothing.
            .onSubmit { commitTitleDraft(for: daily) }
            .onChange(of: focusedTitleField) { previous, _ in
              if let previous, previous == daily.id { commitTitleDraft(for: daily) }
            }
            .focused($focusedTitleField, equals: daily.id)

            // Which *kind* of schedule. The days or the interval themselves are
            // edited below rather than hidden behind a "Custom…" item, because
            // this is the full editor — a schedule you can read but not change
            // is what the previous picker did, and it is why arbitrary weekday
            // sets could only be made from the MCP server.
            Picker("", selection: scheduleKindBinding(for: daily)) {
              Text("On weekdays").tag(0)
              Text("Every N days").tag(1)
            }
            .labelsHidden()
            .frame(width: 130)

            Button {
              dailyLog.deleteDaily(daily)
            } label: {
              Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete. Past days keep their record of this daily, and it can be restored below.")
          }

          switch daily.schedule {
          case .weekdays(let days):
            weekdayChips(for: daily, days: days)
          case .everyNDays(let interval):
            intervalStepper(for: daily, interval: interval)
          }
        }
        .padding(.vertical, 2)
      }

      if dailyLog.allDailies.isEmpty {
        Text("None yet — add them from the Daily view (u, then Return).")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      archivedDailiesEditor
    }
    .padding(.top, 4)
  }

  /// Where a deleted daily goes, and how it comes back.
  ///
  /// Deleting archives rather than removes, because the day log references
  /// dailies by id and a real deletion would leave every past day that ticked
  /// this one rendering a raw identifier. That trade is only defensible if the
  /// archive is somewhere you can actually see, so: here.
  @ViewBuilder
  private var archivedDailiesEditor: some View {
    let archived = manager.dailyLog.archivedDailies
    if !archived.isEmpty {
      Divider()
        .padding(.vertical, 4)
      Text("Deleted")
        .font(.caption)
        .foregroundColor(.secondary)
      ForEach(archived) { daily in
        HStack(spacing: 8) {
          Text(daily.title)
            .foregroundColor(.secondary)
          Spacer(minLength: 0)
          Button("Restore") { manager.dailyLog.restoreDaily(daily) }
            .buttonStyle(.link)
            .font(.caption)
        }
      }
    }
  }

  /// Writes a finished draft through and drops it, so the row goes back to
  /// reading the stored title.
  private func commitTitleDraft(for daily: Daily) {
    guard let draft = titleDrafts.removeValue(forKey: daily.id) else { return }
    guard let title = DailyTitleEdit.committed(draft: draft, original: daily.title) else { return }
    manager.dailyLog.renameDaily(daily, to: title)
  }

  private func scheduleKindBinding(for daily: Daily) -> Binding<Int> {
    Binding(
      get: {
        if case .everyNDays = daily.schedule { return 1 }
        return 0
      },
      set: { choice in
        let dailyLog = manager.dailyLog
        switch (choice, daily.schedule) {
        case (1, .weekdays):
          // Every other day is the shortest cycle that isn't just "every day",
          // so it is the only sensible thing to land on.
          dailyLog.setDailySchedule(daily, to: .everyNDays(2))
        case (0, .everyNDays):
          // Back to whatever weekday set was stored before the switch — kept
          // for exactly this, so a round trip isn't destructive.
          dailyLog.setDailySchedule(daily, to: .weekdays(daily.activeWeekdays))
        default:
          break
        }
      }
    )
  }

  /// Seven toggles, plus the two presets that would otherwise take four clicks.
  @ViewBuilder
  private func weekdayChips(for daily: Daily, days: Set<Int>) -> some View {
    let names = ["", "S", "M", "T", "W", "T", "F", "S"]
    let accessibleNames = ["", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday",
                           "Saturday"]

    HStack(spacing: 4) {
      ForEach(1...7, id: \.self) { weekday in
        let isOn = days.contains(weekday)
        Button {
          var updated = days
          if isOn {
            updated.remove(weekday)
            // Turning the last day off would make the daily permanently
            // invisible with no row left to click, so it is simply refused.
            guard !updated.isEmpty else { return }
          } else {
            updated.insert(weekday)
          }
          manager.dailyLog.setDailySchedule(daily, to: .weekdays(updated))
        } label: {
          Text(names[weekday])
            .font(.system(size: 11, weight: .medium))
            .frame(width: 20, height: 20)
            .background(
              RoundedRectangle(cornerRadius: 4)
                .fill(isOn ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.15))
            )
            .foregroundColor(isOn ? .white : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibleNames[weekday])
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
      }

      Button("Every day") {
        manager.dailyLog.setDailySchedule(daily, to: .weekdays(Daily.allWeekdays))
      }
      .buttonStyle(.link)
      .font(.caption)
      Button("Weekdays") {
        manager.dailyLog.setDailySchedule(daily, to: .weekdays(Daily.mondayToFriday))
      }
      .buttonStyle(.link)
      .font(.caption)
      Spacer(minLength: 0)
    }
  }

  @ViewBuilder
  private func intervalStepper(for daily: Daily, interval: Int) -> some View {
    HStack(spacing: 8) {
      Stepper(
        value: Binding(
          get: { interval },
          set: { manager.dailyLog.setDailySchedule(daily, to: .everyNDays($0)) }
        ),
        // The model's own range, so a cycle set from the MCP server or a
        // hand-edited file is editable here rather than stuck outside the
        // stepper's bounds.
        in: Daily.intervalRange
      ) {
        Text(daily.scheduleLabel)
          .font(.caption)
      }
      .fixedSize()
      Text("Counted from the day the cycle was set, so it keeps its phase.")
        .font(.caption)
        .foregroundColor(.secondary)
      Spacer(minLength: 0)
    }
  }

  // The plugin's settings are plain stored properties rather than `@Observable`
  // state, so the toggles bind through explicitly instead of via `@Bindable`.

  private var dailyLogEnabledBinding: Binding<Bool> {
    Binding(
      get: { manager.dailyLog.dailyLogEnabled },
      set: { manager.dailyLog.dailyLogEnabled = $0 }
    )
  }

  private var rolloverBinding: Binding<Int> {
    Binding(
      get: { manager.dailyLog.plugin.rolloverHour },
      set: { manager.dailyLog.plugin.rolloverHour = $0 }
    )
  }

  private var createsMissingNotesBinding: Binding<Bool> {
    Binding(
      get: { manager.dailyLog.plugin.createsMissingNotes },
      set: { manager.dailyLog.plugin.createsMissingNotes = $0 }
    )
  }

  private var writesAutomaticallyBinding: Binding<Bool> {
    Binding(
      get: { manager.dailyLog.plugin.writesNotesAutomatically },
      set: { manager.dailyLog.plugin.writesNotesAutomatically = $0 }
    )
  }

  private var previewPath: String {
    DailyNotePath.relativePath(
      for: previewDate,
      format: DailyNoteFormat(fileNameFormat: fileNameFormat, folderFormat: folderFormat)
    )
  }

  private func saveFormat() {
    manager.dailyLog.plugin.noteFormat = DailyNoteFormat(
      fileNameFormat: fileNameFormat,
      folderFormat: folderFormat
    )
  }
}
