import TaktCore
import SwiftUI
import UniformTypeIdentifiers

/// Preferences pane for `SettingsView` plus its Checkvist workspace summary
/// helpers and the auto/manual list-loading routines. Pulled out of the main
/// file as part of the Phase-4 settings split.
///
/// `fileprivate` is used on members that no other pane needs to reach into
/// (the connection-state summary subviews, the list-loading async helpers);
/// the pane itself stays `internal` so `SettingsView.selectedPaneContent` can
/// dispatch to it.
extension SettingsView {
  var preferencesPane: some View {
    Group {
      Section(header: MicroLabel("Tools")) {
        VStack(alignment: .leading, spacing: theme.space.sm) {
          Text("Export tasks")
            .font(theme.bodyFont(weight: .medium))
          Text("Save your current task list to a file for backup or use in other apps.")
            .font(theme.captionFont)
            .foregroundStyle(theme.muted)

          HStack(spacing: theme.space.sm) {
            Button("Export to Markdown...") {
              exportTasks(format: .markdown)
            }
            Button("Export to JSON...") {
              exportTasks(format: .json)
            }
          }
          .disabled(checkvistManager.repository.tasks.isEmpty)
          
          if checkvistManager.repository.tasks.isEmpty {
            Text("No tasks available to export.")
              .font(theme.captionFont)
              .foregroundStyle(theme.muted)
          }
        }
        .padding(.top, theme.space.xs)

        if checkvistManager.repository.checkvistIntegrationEnabled {
          VStack(alignment: .leading, spacing: theme.space.sm) {
            Divider()
              .padding(.vertical, theme.space.sm)
            
            Text("Merge lists")
              .font(theme.bodyFont(weight: .medium))
            Text("Copy open tasks from one Checkvist list into another.")
              .font(theme.captionFont)
              .foregroundStyle(theme.muted)

            if checkvistManager.repository.availableLists.count >= 2 {
              Picker("From", selection: $mergeSourceListId) {
                ForEach(checkvistManager.repository.availableLists) { list in
                  Text("\(list.name) (\(list.id))").tag(String(list.id))
                }
              }
              .pickerStyle(.menu)

              Picker("Into", selection: $mergeDestinationListId) {
                ForEach(checkvistManager.repository.availableLists) { list in
                  Text("\(list.name) (\(list.id))").tag(String(list.id))
                }
              }
              .pickerStyle(.menu)

              HStack {
                Button("Use Active List as Destination") {
                  mergeDestinationListId = checkvistManager.repository.listId
                }
                .disabled(checkvistManager.repository.listId.isEmpty)

                Button("Merge Open Tasks") {
                  Task {
                    _ = await checkvistManager.syncService.mergeOpenTasksBetweenLists(
                      sourceListId: mergeSourceListId,
                      destinationListId: mergeDestinationListId
                    )
                  }
                }
                .disabled(
                  checkvistManager.repository.isLoading || isLoadingCheckvistLists || mergeSourceListId.isEmpty
                    || mergeDestinationListId.isEmpty
                    || mergeSourceListId == mergeDestinationListId
                    || !checkvistManager.repository.canAttemptLogin
                )
              }
            } else if checkvistManager.repository.canAttemptLogin {
              Text("Connect and load at least two Checkvist lists to enable merging.")
                .font(theme.captionFont)
                .foregroundStyle(theme.muted)
            } else {
              Text("Add your Checkvist account in Plugins settings, then load lists to enable merging.")
                .font(theme.captionFont)
                .foregroundStyle(theme.muted)
            }
          }
          .padding(.top, theme.space.xs)
        }
      }

      Section(header: MicroLabel("Preferences")) {
        Toggle("Confirm before deleting tasks", isOn: preferenceBinding(\.confirmBeforeDelete))
          .toggleStyle(.switch)
        VStack(alignment: .leading, spacing: theme.space.xxs) {
          Toggle("Open on the focus screen", isOn: preferenceBinding(\.opensOnFocusScreen))
            .toggleStyle(.switch)
          Text("The window comes up on Today. Turn this on to land on the focus ladder instead, with its conditions and available time. A running session is shown either way.")
            .font(theme.captionFont)
            .foregroundStyle(theme.muted)
        }
        VStack(alignment: .leading, spacing: theme.space.xxs) {
          Toggle("Ask how each focus block went", isOn: preferenceBinding(\.scoresEachFocusBlock))
            .toggleStyle(.switch)
          Text("Finishing a block asks for a quality multiplier, which is what turns minutes into points. Turn this off to log every block at ×1 and keep moving.")
            .font(theme.captionFont)
            .foregroundStyle(theme.muted)
        }
        VStack(alignment: .leading, spacing: theme.space.xxs) {
          Picker("Run focus blocks in", selection: preferenceBinding(\.focusRunSurface)) {
            Text("Floating panel").tag(FocusRunSurface.panel)
            Text("Menu bar").tag(FocusRunSurface.menuBar)
            Text("Both").tag(FocusRunSurface.both)
          }
          .pickerStyle(.segmented)
          Text("Starting a block puts the window away. The floating panel stays up over your work, shrunk to the task and its clock; the menu bar shows the same in the status item and hands the keyboard straight back. Both does both.")
            .font(theme.captionFont)
            .foregroundStyle(theme.muted)
        }
        if #available(macOS 13.0, *) {
          Toggle("Launch at login", isOn: preferenceBinding(\.launchAtLogin))
            .toggleStyle(.switch)
        }

        VStack(alignment: .leading) {
          Text("Max Menu Bar Width: \(Int(preferences.maxTitleWidth))px")
          Slider(value: preferenceBinding(\.maxTitleWidth), in: 50...800, step: 10)
        }
        .padding(.top, theme.space.xs)

        VStack(alignment: .leading, spacing: theme.space.xs) {
          Text("Timer position in menu bar")
          Picker(
            "",
            selection: Binding(
              get: { checkvistManager.timer.timerBarLeading },
              set: { checkvistManager.timer.timerBarLeading = $0 }
            )
          ) {
            Text("After task").tag(false)
            Text("Before task").tag(true)
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .disabled(checkvistManager.timer.timerMode != .visible)
        }
        .padding(.top, theme.space.xs)

        VStack(alignment: .leading, spacing: theme.space.xs) {
          Text("Timer mode")
          Picker(
            "",
            selection: Binding(
              get: { checkvistManager.timer.timerMode },
              set: { checkvistManager.timer.timerMode = $0 }
            )
          ) {
            Text("Visible").tag(TimerMode.visible)
            Text("Hidden").tag(TimerMode.hidden)
            Text("Disabled").tag(TimerMode.disabled)
          }
          .labelsHidden()
          .pickerStyle(.segmented)
        }
        .padding(.top, theme.space.xs)
      }
      
      Section(header: MicroLabel("Named times")) {
        VStack(alignment: .leading, spacing: theme.space.sm) {
          Text("Customize what hour named times resolve to when scheduling tasks.")
            .font(theme.captionFont)
            .foregroundStyle(theme.muted)

          NamedTimePickerRow(
            label: "Morning",
            hour: preferenceBinding(\.namedTimeMorningHour)
          )
          NamedTimePickerRow(
            label: "Afternoon",
            hour: preferenceBinding(\.namedTimeAfternoonHour)
          )
          NamedTimePickerRow(
            label: "Evening",
            hour: preferenceBinding(\.namedTimeEveningHour)
          )
          NamedTimePickerRow(
            label: "EOD / COB",
            hour: preferenceBinding(\.namedTimeEodHour)
          )
        }
        .padding(.top, theme.space.xs)
      }
    }
  }

  enum ExportFormat {
    case markdown
    case json
  }

  private func exportTasks(format: ExportFormat) {
    let savePanel = NSSavePanel()
    savePanel.allowedContentTypes = format == .markdown ? [UTType(filenameExtension: "md") ?? .plainText] : [.json]
    savePanel.canCreateDirectories = true
    savePanel.nameFieldStringValue = format == .markdown ? "tasks.md" : "tasks.json"
    
    savePanel.begin { response in
      guard response == .OK, let url = savePanel.url else { return }
      
      let tasks = checkvistManager.repository.tasks
      let content: String
      switch format {
      case .markdown:
        content = exportTasksToMarkdown(tasks)
      case .json:
        do {
          let encoder = JSONEncoder()
          encoder.outputFormatting = .prettyPrinted
          let data = try encoder.encode(tasks)
          content = String(data: data, encoding: .utf8) ?? ""
        } catch {
          checkvistManager.repository.errorMessage = "Failed to export JSON: \(error.localizedDescription)"
          return
        }
      }
      
      do {
        try content.write(to: url, atomically: true, encoding: .utf8)
      } catch {
        checkvistManager.repository.errorMessage = "Failed to save file: \(error.localizedDescription)"
      }
    }
  }

  private func exportTasksToMarkdown(_ tasks: [CheckvistTask]) -> String {
    TaskTreeFormatter.formatAsMarkdown(tasks)
  }

  @MainActor
  func autoloadCheckvistListsIfNeeded() async {
    guard !didAutoloadCheckvistLists else { return }
    didAutoloadCheckvistLists = true

    if checkvistManager.repository.checkvistIntegrationEnabled, checkvistManager.repository.canAttemptLogin,
      checkvistManager.repository.availableLists.isEmpty
    {
      await loadCheckvistLists(assignFirstIfMissing: false)
    } else {
      seedMergeSelectionsIfNeeded()
    }
  }

  @MainActor
  fileprivate func loadCheckvistLists(assignFirstIfMissing: Bool) async {
    isLoadingCheckvistLists = true
    defer { isLoadingCheckvistLists = false }
    _ = await checkvistManager.syncService.loadCheckvistLists(assignFirstIfMissing: assignFirstIfMissing)
    seedMergeSelectionsIfNeeded()
  }

  func seedMergeSelectionsIfNeeded() {
    guard !checkvistManager.repository.availableLists.isEmpty else {
      mergeSourceListId = ""
      mergeDestinationListId = ""
      return
    }

    let listIDs = Set(checkvistManager.repository.availableLists.map { String($0.id) })

    if !mergeDestinationListId.isEmpty, !listIDs.contains(mergeDestinationListId) {
      mergeDestinationListId = ""
    }
    if !mergeSourceListId.isEmpty, !listIDs.contains(mergeSourceListId) {
      mergeSourceListId = ""
    }

    if mergeDestinationListId.isEmpty {
      if listIDs.contains(checkvistManager.repository.listId) {
        mergeDestinationListId = checkvistManager.repository.listId
      } else if let first = checkvistManager.repository.availableLists.first {
        mergeDestinationListId = String(first.id)
      }
    }

    if mergeSourceListId.isEmpty || mergeSourceListId == mergeDestinationListId {
      if let source = checkvistManager.repository.availableLists.first(where: {
        String($0.id) != mergeDestinationListId
      }) {
        mergeSourceListId = String(source.id)
      }
    }
  }
}
