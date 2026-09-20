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
      Section(header: Text("Tools")) {
        VStack(alignment: .leading, spacing: 10) {
          Text("Export Tasks")
            .font(.headline)
          Text("Save your current task list to a file for backup or use in other apps.")
            .font(.caption)
            .foregroundColor(themeColor(.textSecondary))

          HStack(spacing: 8) {
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
              .font(.caption)
              .foregroundColor(themeColor(.textSecondary))
          }
        }
        .padding(.top, 4)

        if checkvistManager.repository.checkvistIntegrationEnabled {
          VStack(alignment: .leading, spacing: 10) {
            Divider()
              .padding(.vertical, 8)
            
            Text("Merge Lists")
              .font(.headline)
            Text("Copy open tasks from one Checkvist list into another.")
              .font(.caption)
              .foregroundColor(themeColor(.textSecondary))

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
                .font(.caption)
                .foregroundColor(themeColor(.textSecondary))
            } else {
              Text("Add your Checkvist account in Plugins settings, then load lists to enable merging.")
                .font(.caption)
                .foregroundColor(themeColor(.textSecondary))
            }
          }
          .padding(.top, 4)
        }
      }

      Section(header: Text("Preferences")) {
        Toggle("Confirm before deleting tasks", isOn: preferenceBinding(\.confirmBeforeDelete))
          .toggleStyle(.switch)
        if #available(macOS 13.0, *) {
          Toggle("Launch at login", isOn: preferenceBinding(\.launchAtLogin))
            .toggleStyle(.switch)
        }

        VStack(alignment: .leading) {
          Text("Max Menu Bar Width: \(Int(preferences.maxTitleWidth))px")
          Slider(value: preferenceBinding(\.maxTitleWidth), in: 50...800, step: 10)
        }
        .padding(.top, 4)

        VStack(alignment: .leading, spacing: 6) {
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
        .padding(.top, 4)

        VStack(alignment: .leading, spacing: 6) {
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
        .padding(.top, 4)
      }
      
      Section(header: Text("View Modes Order")) {
        VStack(alignment: .leading, spacing: 10) {
          Text("Drag to reorder the view mode tabs")
            .font(.caption)
            .foregroundColor(themeColor(.textSecondary))
          
          ModeOrderList(manager: checkvistManager)
        }
        .padding(.top, 4)
      }

      Section(header: Text("Named Times")) {
        VStack(alignment: .leading, spacing: 10) {
          Text("Customize what hour named times resolve to when scheduling tasks.")
            .font(.caption)
            .foregroundColor(themeColor(.textSecondary))

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
        .padding(.top, 4)
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
