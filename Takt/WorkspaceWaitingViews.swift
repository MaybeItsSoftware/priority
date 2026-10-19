import SwiftUI
import TaktCore
import TaktWorkspace

struct WorkspaceWaitingRequest: Identifiable {
  let id = UUID()
  let task: WorkspaceTask
  let details: TaskWaitingDetails?
}

/// The Waiting on form: `ww`. Who or what the task waits on, when to follow
/// up, and every how many days to follow up again. Saving files the task in
/// Waiting on; at the follow-up time, if it is still there and still open,
/// "Follow up with Sam: …" lands in Today. With a repeat, completing that
/// follow-up sets the next, "Follow up #2 with Sam: …".
///
/// Tab, ⇧Tab, ↑ and ↓ move between the three fields; Return saves; Escape is
/// the host's and cancels.
struct WorkspaceWaitingOverlay: View {
  let overlayID: String
  let request: WorkspaceWaitingRequest
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  @State private var tag = ""
  @State private var followUp = ""
  @State private var every = ""
  @State private var error: String?
  @FocusState private var field: Field?

  enum Field: Hashable, CaseIterable { case tag, followUp, every }

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
        row(.every, label: "Repeat") {
          VStack(alignment: .leading, spacing: theme.space.xxs) {
            textField("once, or every 3d", text: $every, field: .every)
            Text(repeatPreview)
              .font(theme.captionFont)
              .foregroundStyle(parsedEvery == nil ? theme.danger : theme.muted)
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
      every = WaitingFollowUp.editableRepeatText(request.details?.followUpEveryDays)
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

  /// 0 for once, the days for a repeat, nil for a field that is neither.
  private var parsedEvery: Int? {
    WaitingFollowUp.everyDays(from: every)
  }

  private var repeatPreview: String {
    guard let days = parsedEvery else { return "1 to 365 days, or once" }
    if days > 0, followUpIsEmpty { return "Needs a follow-up time" }
    return days == 0 ? "Once" : WaitingFollowUp.repeatText(days) + ", from when each follow-up is done"
  }

  private func handle(_ key: String) -> Bool {
    switch key {
    case "enter", "cmd+enter":
      save()
      return true
    case "tab", "down", "shift+tab", "up":
      let fields = Field.allCases
      let index = field.flatMap { fields.firstIndex(of: $0) } ?? 0
      let step = key == "tab" || key == "down" ? 1 : fields.count - 1
      field = fields[(index + step) % fields.count]
      return true
    default:
      return false
    }
  }

  private func save() {
    var date: Date?
    if !followUpIsEmpty {
      guard let parsed = parsedFollowUp else {
        error = "Write the follow-up as tmrw 9am, fri afternoon, in 2h, next week or 2026-10-08 14:00."
        field = .followUp
        return
      }
      date = parsed
    }
    guard let days = parsedEvery else {
      error = "Write the repeat as once, 3, 3d or every 3 days, from 1 to 365."
      field = .every
      return
    }
    if let failure = model.setWaiting(request.task, waitingOn: tag, followUpAt: date, everyDays: days == 0 ? nil : days) {
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
          Text(WaitingFollowUp.label(at, chase: details.chase))
            .font(theme.captionFont)
            .monospacedDigit()
            .foregroundStyle(theme.muted)
            .lineLimit(1)
            .help(followUpHelp(at, details))
        }
      }
      .accessibilityElement(children: .combine)
    }
  }

  private func followUpHelp(_ at: Date, _ details: TaskWaitingDetails) -> String {
    var help = "Follow up \(WaitingFollowUp.dateTimeText(at)) if it is still waiting"
    if let days = details.followUpEveryDays {
      help += "; then \(WaitingFollowUp.repeatText(days).lowercased()) after each follow-up is done"
    }
    return help
  }
}

/// The inspector's Waiting on section: the tag and the follow-up time,
/// edited in place. Either one files the task in Waiting on.
struct WorkspaceWaitingInspectorSection: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let task: WorkspaceTask
  @Environment(\.inspectorFocus) private var inspectorFocus
  @State private var tag = ""

  private static let tagStop = "waiting.tag"
  private var tagFocused: Bool { inspectorFocus?.wrappedValue == Self.tagStop }

  private var details: TaskWaitingDetails? { model.waitingDetails[task.id] }

  private var isWaiting: Bool {
    details?.waitingOn != nil || details?.followUpAt != nil
      || model.kanbanColumnID(ofTaskID: task.id) == WaitingFollowUp.waitingColumnID
  }

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.xxs) {
      if isWaiting {
        InspectorRow("Waiting on") {
          InspectorTextField(
            add: "Add who or what", hint: "Sam, Legal, invoice", text: $tag, stop: Self.tagStop,
            onSubmit: saveTag)
          .help("↩ saves")
          .onChange(of: tagFocused) { _, focused in if !focused { saveTag() } }
        }
        InspectorOptionalRow(
          "Follow up", add: "Add follow-up", isSet: details?.followUpAt != nil, stop: "waiting.follow-up",
          add: { save(followUpAt: Self.defaultFollowUp()) },
          clear: { save(followUpAt: nil) },
          value: {
            if let at = details?.followUpAt {
              ThemedDateField(
                selection: Binding(get: { at }, set: { save(followUpAt: $0) }), includesTime: true,
                stop: "waiting.follow-up.date", framed: false)
            }
          })
        .commandHelp(.taskWaiting, note: "Edit who and when to follow up in the Waiting on form")
        if details?.followUpAt != nil {
          InspectorRow("Repeat") { repeatMenu }
        }
      } else {
        InspectorRow("Waiting on") {
          Button("Add who or what") { model.presentWaitingForm() }
            .buttonStyle(InspectorValueButtonStyle(tone: .dim))
            .inspectorStop("waiting.start", press: { model.presentWaitingForm() })
            .commandHelp(.taskWaiting, note: "Move it to Waiting on, with who and when to follow up")
        }
      }
      if let sourceId = details?.followUpOfTaskId, let source = model.task(withID: sourceId) {
        InspectorRow("Follows up") {
          Button(source.title) { model.selectTask(source) }
            .buttonStyle(InspectorValueButtonStyle(tone: .muted))
            .inspectorStop("waiting.source", press: { model.selectTask(source) })
            .help("Go to \(source.title)")
        }
      }
    }
    .onAppear { tag = details?.waitingOn ?? "" }
    .onChange(of: task.id) { _, _ in tag = details?.waitingOn ?? "" }
    .onChange(of: details?.waitingOn) { _, saved in if !tagFocused { tag = saved ?? "" } }
  }

  /// Once, or every so many days: the presets, and the task's own repeat if
  /// it is none of them. Arrow keys step through them.
  private var repeatMenu: some View {
    let current = details?.followUpEveryDays ?? 0
    let values = (WaitingFollowUp.everyDaysPresets + (WaitingFollowUp.everyDaysPresets.contains(current) ? [] : [current]))
      .sorted()
    let options = values.map { ThemedPickerOption(WaitingFollowUp.repeatText($0), value: $0) }
    let selection = Binding(get: { current }, set: { saveRepeat($0) })
    return InspectorMenu(WaitingFollowUp.repeatText(current), tone: current == 0 ? .dim : .ink) {
      Picker("Repeat", selection: selection) {
        ForEach(options) { Text($0.title).tag($0.value) }
      }
      .pickerStyle(.inline)
      .labelsHidden()
    }
    .inspectorStop("waiting.repeat") { selection.step(by: $0, through: options) }
    .help("After each follow-up is done, follow up again this many days later. ww sets any number of days.")
    .accessibilityLabel("Repeat follow-up")
  }

  /// Tomorrow at nine: the follow-up you would most often have typed.
  static func defaultFollowUp(now: Date = .now) -> Date {
    TaskCapture.dateTime(from: "tomorrow", now: now) ?? now.addingTimeInterval(86_400)
  }

  private func saveTag() {
    let trimmed = WaitingFollowUp.normalizedTag(tag)
    guard trimmed != details?.waitingOn else { return }
    model.setWaiting(
      task, waitingOn: trimmed, followUpAt: details?.followUpAt, everyDays: details?.followUpEveryDays)
  }

  private func save(followUpAt: Date?) {
    model.setWaiting(
      task, waitingOn: WaitingFollowUp.normalizedTag(tag), followUpAt: followUpAt,
      everyDays: details?.followUpEveryDays)
  }

  private func saveRepeat(_ days: Int) {
    guard days != (details?.followUpEveryDays ?? 0) else { return }
    model.setWaiting(
      task, waitingOn: details?.waitingOn, followUpAt: details?.followUpAt, everyDays: days == 0 ? nil : days)
  }
}
