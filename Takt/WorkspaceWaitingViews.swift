import SwiftUI
import TaktCore
import TaktWorkspace

struct WorkspaceWaitingRequest: Identifiable {
  let id = UUID()
  let task: WorkspaceTask
  let details: TaskWaitingDetails?
}

/// The Waiting on form: `ww`. Who or what the task waits on, and when to
/// follow up. Saving files the task in Waiting on; at the follow-up time, if
/// it is still there and still open, "Follow up with Sam: …" lands in Today.
///
/// Tab, ⇧Tab, ↑ and ↓ move between the two fields; Return saves; Escape is the
/// host's and cancels.
struct WorkspaceWaitingOverlay: View {
  let overlayID: String
  let request: WorkspaceWaitingRequest
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  @State private var tag = ""
  @State private var followUp = ""
  @State private var error: String?
  @FocusState private var field: Field?

  enum Field: Hashable { case tag, followUp }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      FocusRule()
      VStack(alignment: .leading, spacing: 0) {
        row(.tag, label: "Waiting on") {
          textField("Sam, Legal, invoice", text: $tag, field: .tag)
        }
        row(.followUp, label: "Follow up") {
          VStack(alignment: .leading, spacing: theme.space.xxs) {
            textField("tomorrow 9am, @fri, 3d, 2026-10-08 14:00", text: $followUp, field: .followUp)
            Text(preview)
              .font(theme.captionFont)
              .foregroundStyle(parsedFollowUp == nil && !followUpIsEmpty ? theme.danger : theme.muted)
          }
        }
        if let error {
          Text(error)
            .font(theme.captionFont)
            .foregroundStyle(theme.danger)
            .padding(.horizontal, theme.space.md)
            .padding(.vertical, theme.space.xs)
        }
      }
      .padding(.vertical, theme.space.xs)
      WorkspaceOverlayFooter(hints: "tab ↑↓ fields · empty clears", trailing: "↩ save · esc cancel")
    }
    .onAppear {
      tag = request.details?.waitingOn ?? ""
      followUp = request.details?.followUpAt.map { WaitingFollowUp.editableText($0) } ?? ""
      DispatchQueue.main.async { field = .tag }
    }
    .overlayKeys(model, id: overlayID) { key in handle(key) }
  }

  private var header: some View {
    HStack(spacing: theme.space.sm) {
      MicroLabel("Waiting on")
      Text(request.task.title)
        .font(theme.bodyFont())
        .foregroundStyle(theme.muted)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
      Button("Save") { save() }
        .buttonStyle(.plain)
        .foregroundStyle(theme.primary)
        .help("Save · ↩")
    }
    .font(theme.bodyFont())
    .padding(.horizontal, theme.space.md)
    .padding(.vertical, theme.space.sm)
  }

  private func row<Content: View>(_ target: Field, label: String, @ViewBuilder content: () -> Content) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: theme.space.sm) {
      MicroLabel(label)
        .frame(width: 92, alignment: .leading)
      content()
      Spacer(minLength: 0)
    }
    .padding(.horizontal, theme.space.md)
    .padding(.vertical, theme.space.xs)
    .contentShape(Rectangle())
    .workspaceSelection(isSelected: field == target, hasKeyboard: false)
    .onTapGesture { field = target }
  }

  private func textField(_ prompt: String, text: Binding<String>, field target: Field) -> some View {
    TextField(prompt, text: text)
      .textFieldStyle(.plain)
      .font(theme.bodyFont())
      .focused($field, equals: target)
      .padding(theme.space.xs)
      .overlay(
        RoundedRectangle(cornerRadius: theme.controlRadius)
          .strokeBorder(field == target ? theme.focusRing : theme.inputBorder, lineWidth: theme.hairline))
  }

  private var followUpIsEmpty: Bool {
    followUp.trimmingCharacters(in: .whitespaces).isEmpty
  }

  private var parsedFollowUp: Date? {
    TaskCapture.dateTime(from: followUp)
  }

  private var preview: String {
    if followUpIsEmpty { return "No follow-up" }
    guard let date = parsedFollowUp else { return "Not a date and time yet" }
    return WaitingFollowUp.label(date) + (date <= .now ? " — lands in Today now" : "")
  }

  private func handle(_ key: String) -> Bool {
    switch key {
    case "enter", "cmd+enter":
      save()
      return true
    case "tab", "down", "shift+tab", "up":
      field = field == .tag ? .followUp : .tag
      return true
    default:
      return false
    }
  }

  private func save() {
    var date: Date?
    if !followUpIsEmpty {
      guard let parsed = parsedFollowUp else {
        error = "Write the follow-up as tomorrow 9am, @fri, 3d or 2026-10-08 14:00."
        field = .followUp
        return
      }
      date = parsed
    }
    if let failure = model.setWaiting(request.task, waitingOn: tag, followUpAt: date) {
      error = failure
      return
    }
    model.dismissOverlay()
  }
}

/// The tag chip and the follow-up time, on a card or an outline row. Nothing
/// for a task with neither. A follow-up time is shown only while the task is
/// open: on a closed one it will never fire.
struct WorkspaceWaitingBadges: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let task: WorkspaceTask

  var body: some View {
    if let details = model.waitingDetails[task.id], details.waitingOn != nil || details.followUpAt != nil {
      HStack(spacing: theme.space.xs) {
        if let tag = details.waitingOn {
          // "Sam": a squarish, muted tag — a status-tag rectangle, not a capsule.
          ThemedTag(tag)
            .help("Waiting on \(tag)")
            .accessibilityLabel("Waiting on \(tag)")
        }
        if let at = details.followUpAt, task.status == .open {
          Text(WaitingFollowUp.label(at))
            .font(theme.captionFont)
            .monospacedDigit()
            .foregroundStyle(theme.muted)
            .lineLimit(1)
            .help("Follow up \(WaitingFollowUp.dateTimeText(at)) if it is still waiting")
        }
      }
      .accessibilityElement(children: .combine)
    }
  }
}

/// The inspector's Waiting on section: the tag and the follow-up time,
/// edited in place. Either one files the task in Waiting on.
struct WorkspaceWaitingInspectorSection: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let task: WorkspaceTask
  @State private var tag = ""
  @FocusState private var tagFocused: Bool

  private var details: TaskWaitingDetails? { model.waitingDetails[task.id] }

  private var isWaiting: Bool {
    details?.waitingOn != nil || details?.followUpAt != nil
      || model.kanbanColumnID(ofTaskID: task.id) == WaitingFollowUp.waitingColumnID
  }

  var body: some View {
    InspectorSection("Waiting on") {
      if isWaiting {
        ThemedControlRow("Who or what") {
          TextField("Waiting on", text: $tag, prompt: Text("Sam, Legal, invoice"))
            .themedTextField()
            .focused($tagFocused)
            .onSubmit { saveTag() }
            .help("↩ saves")
            .onChange(of: tagFocused) { _, focused in if !focused { saveTag() } }
        }
        ThemedOptionalRow(
          "Follow up", isSet: details?.followUpAt != nil,
          add: { save(followUpAt: Self.defaultFollowUp()) },
          clear: { save(followUpAt: nil) },
          value: {
            if let at = details?.followUpAt {
              ThemedDateField(
                selection: Binding(get: { at }, set: { save(followUpAt: $0) }), includesTime: true)
            }
          })
        .commandHelp(.taskWaiting, note: "Edit who and when to follow up in the Waiting on form")
      } else {
        Button { model.presentWaitingForm() } label: {
          Label("Waiting on…", systemImage: "hourglass")
        }
        .buttonStyle(FocusActionButtonStyle())
        .keyboardFocusable()
        .commandHelp(.taskWaiting, note: "Move it to Waiting on, with who and when to follow up")
      }
      if let sourceId = details?.followUpOfTaskId, let source = model.task(withID: sourceId) {
        Button { model.selectTask(source) } label: {
          Label("Follows up \(source.title)", systemImage: "arrow.uturn.backward")
            .lineLimit(1)
        }
        .buttonStyle(.plain)
        .font(theme.captionFont)
        .foregroundStyle(theme.muted)
        .keyboardFocusable()
      }
    }
    .onAppear { tag = details?.waitingOn ?? "" }
    .onChange(of: task.id) { _, _ in tag = details?.waitingOn ?? "" }
    .onChange(of: details?.waitingOn) { _, saved in if !tagFocused { tag = saved ?? "" } }
  }

  /// Tomorrow at nine: the follow-up you would most often have typed.
  static func defaultFollowUp(now: Date = .now) -> Date {
    TaskCapture.dateTime(from: "tomorrow", now: now) ?? now.addingTimeInterval(86_400)
  }

  private func saveTag() {
    let trimmed = WaitingFollowUp.normalizedTag(tag)
    guard trimmed != details?.waitingOn else { return }
    model.setWaiting(task, waitingOn: trimmed, followUpAt: details?.followUpAt)
  }

  private func save(followUpAt: Date?) {
    model.setWaiting(task, waitingOn: WaitingFollowUp.normalizedTag(tag), followUpAt: followUpAt)
  }
}
