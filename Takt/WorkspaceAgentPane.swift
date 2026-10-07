import AppKit
import TaktCore
import TaktWorkspace
import SwiftUI

/// The agent panel: a conversation with the user's own Claude Code about their
/// tasks, in the left dock.
///
/// Zed's agent panel is the model — a transcript that reads top to bottom, the
/// assistant's tool calls as quiet one-line entries in it, and a message field
/// pinned to the foot. What is Priority's own is the approval card: every
/// change the assistant wants to make stops in the transcript as a card that
/// says what it will do, and runs only when Approve is clicked (or Return is
/// pressed with the card holding the keyboard). Nothing approves itself. See
/// `WorkspaceAgentSession` and `docs/agent-panel.md`.
struct WorkspaceAgentPane: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  @State private var draft = ""
  @State private var inputHasFocus = false
  @FocusState private var focusedCard: UUID?

  private var agent: WorkspaceAgentSession { model.agent }

  var body: some View {
    VStack(spacing: 0) {
      if agent.items.isEmpty && agent.executablePath == nil {
        WorkspaceAgentSetup()
      } else if agent.items.isEmpty {
        emptyState
      } else {
        transcript
      }
      inputBar
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(theme.paper)
    .onChange(of: inputHasFocus) { _, _ in reportKeyboard() }
    .onChange(of: focusedCard) { _, _ in reportKeyboard() }
    .onChange(of: agent.finishedTurns) { _, _ in model.agentTurnFinished() }
    .onDisappear { model.agentHoldsKeyboard = false }
  }

  /// Said in the middle of the panel, the way every empty pane says it.
  private var emptyState: some View {
    WorkspaceEmptyMessage(
      "Ask about your tasks…",
      detail: "It can read your lists freely. Every change it wants to make is shown here first, and runs only if you approve it."
    ) {
      HStack(spacing: theme.space.xs) {
        KeyCap(WorkspaceCommandHelpText.firstKey(for: .windowToggleAgentPanel))
        Text("opens and closes this panel")
          .font(theme.captionFont)
          .foregroundStyle(theme.dim)
      }
    }
  }

  private var transcript: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: theme.space.md) {
          ForEach(agent.items) { item in
            row(item)
              .id(item.id)
          }
          if agent.isWorking && agent.pendingApproval == nil {
            Text("Working…")
              .font(theme.monoCaptionFont)
              .foregroundStyle(theme.dim)
              .id("working")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, theme.listGutter)
        .padding(.vertical, theme.space.md)
      }
      .onChange(of: agent.items.count) { _, _ in
        guard let last = agent.items.last else { return }
        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(last.id, anchor: .bottom) }
      }
    }
  }

  @ViewBuilder
  private func row(_ item: WorkspaceAgentSession.Item) -> some View {
    switch item.entry {
    case .user(let text):
      // A plain block with a rule down its left edge: what you said, set
      // apart from the answer without a bubble.
      Text(text)
        .font(theme.bodyFont())
        .foregroundStyle(theme.ink)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, theme.space.sm)
        .overlay(alignment: .leading) {
          Rectangle().fill(theme.border).frame(width: theme.hairline)
        }
    case .assistant(let text):
      Text(Self.markdown(text))
        .font(theme.bodyFont())
        .foregroundStyle(theme.ink)
        .tint(theme.primary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .read(let use, let failed):
      HStack(spacing: theme.space.xs) {
        Text(AgentToolSummary.readLine(tool: use.name, input: use.input, name: model.agentDisplayName(for:)))
          .lineLimit(1)
          .truncationMode(.tail)
        if failed == true {
          Text("failed").foregroundStyle(theme.danger)
        }
      }
      .font(theme.monoCaptionFont)
      .foregroundStyle(theme.muted)
      .help(use.input.jsonString(pretty: true))
    case .write(let approval):
      WorkspaceAgentApprovalCard(
        itemID: item.id, approval: approval, focusedCard: $focusedCard,
        approve: { model.agent.approve(item.id); model.focusAgentInput() },
        deny: { model.agent.deny(item.id); model.focusAgentInput() })
    case .notice(let text, let isError):
      Text(text)
        .font(theme.captionFont)
        .foregroundStyle(isError ? theme.danger : theme.muted)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// The field and what Return will do, pinned under the transcript.
  private var inputBar: some View {
    VStack(alignment: .leading, spacing: theme.space.xs) {
      ZStack(alignment: .topLeading) {
        WorkspaceAgentInputField(
          text: $draft,
          focusRequest: model.agentInputFocusRequest,
          font: WorkspaceTitleBarAddField.fieldFont(theme),
          textColor: NSColor(theme.ink),
          insertionColor: NSColor(theme.primary),
          onSubmit: send,
          onCancel: { model.requestKeyboardFocus(.tasks) },
          onTab: focusPendingCard,
          onFocusChange: { inputHasFocus = $0 })
        if draft.isEmpty {
          Text(placeholder)
            .font(theme.bodyFont())
            .foregroundStyle(theme.dim)
            .allowsHitTesting(false)
        }
      }
      .frame(height: Self.inputHeight)
      .padding(theme.space.sm)
      .overlay(
        RoundedRectangle(cornerRadius: theme.controlRadius)
          .strokeBorder(
            inputHasFocus ? theme.focusRing : theme.inputBorder,
            lineWidth: inputHasFocus ? theme.focusRingWidth : theme.hairline))
      Text(hint)
        .font(theme.monoCaptionFont)
        .foregroundStyle(theme.dim)
        .lineLimit(1)
    }
    .padding(theme.space.sm)
    .overlay(alignment: .top) { FocusRule() }
  }

  /// Room for about four lines before the field scrolls.
  static let inputHeight: CGFloat = 72

  private var placeholder: String {
    if agent.pendingApproval != nil { return "Approve or deny the change above first" }
    if agent.isWorking { return "Working…" }
    return "Ask about your tasks…"
  }

  private var hint: String {
    if agent.pendingApproval != nil { return "tab to the card · return approves · esc denies" }
    return "return sends · shift-return new line · esc back to tasks"
  }

  private func send() {
    guard !agent.isWorking, agent.pendingApproval == nil else { return }
    let text = draft
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    // Kept when there is nothing to send it to, so it survives setting the
    // path and pressing Return again.
    if agent.isRunning || agent.executablePath != nil { draft = "" }
    model.sendAgentMessage(text)
  }

  private func focusPendingCard() -> Bool {
    guard let pending = agent.pendingApproval else { return false }
    focusedCard = pending.id
    return true
  }

  private func reportKeyboard() {
    model.agentHoldsKeyboard = inputHasFocus || focusedCard != nil
  }

  /// Inline markdown — bold, italics, code, links — with the line breaks
  /// kept, so lists and paragraphs still read as lists and paragraphs.
  /// `Text` draws no block elements, and full parsing folded them into one
  /// run of text.
  static func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(
      markdown: text,
      options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
  }
}

/// A change the assistant wants to make, stopped until someone answers.
///
/// It says what will happen in the app's words — "Add a task", the title, the
/// list by name — with the raw input behind a disclosure for anyone who wants
/// to check it. Approve is a button, and Return only while the card itself
/// holds the keyboard; there is no timer, no default and no "always".
struct WorkspaceAgentApprovalCard: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let itemID: UUID
  let approval: WorkspaceAgentSession.Approval
  var focusedCard: FocusState<UUID?>.Binding
  let approve: () -> Void
  let deny: () -> Void
  @State private var showsInput = false

  private var isPending: Bool { approval.state == .pending }
  private var isFocused: Bool { focusedCard.wrappedValue == itemID }

  var body: some View {
    let summary = AgentToolSummary.describe(
      tool: approval.request.toolName, input: approval.request.input, name: model.agentDisplayName(for:))
    return VStack(alignment: .leading, spacing: theme.space.sm) {
      HStack(alignment: .firstTextBaseline, spacing: theme.space.xs) {
        MicroLabel(isPending ? "Wants to" : "Asked to")
        Text(summary.title)
          .font(theme.bodyFont())
          .foregroundStyle(summary.isDestructive ? theme.danger : theme.ink)
      }
      if !summary.fields.isEmpty {
        Grid(alignment: .leading, horizontalSpacing: theme.space.sm, verticalSpacing: theme.space.xxs) {
          ForEach(Array(summary.fields.enumerated()), id: \.offset) { _, field in
            GridRow(alignment: .firstTextBaseline) {
              Text(field.label)
                .font(theme.captionFont)
                .foregroundStyle(theme.muted)
              Text(field.value)
                .font(theme.bodyFont())
                .foregroundStyle(theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }
      DisclosureGroup(isExpanded: $showsInput) {
        Text(approval.request.input.jsonString(pretty: true))
          .font(theme.monoCaptionFont)
          .foregroundStyle(theme.muted)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      } label: {
        Text(AgentToolPolicy.priorityToolName(approval.request.toolName) ?? approval.request.toolName)
          .font(theme.monoCaptionFont)
          .foregroundStyle(theme.dim)
      }
      footer(isDestructive: summary.isDestructive)
    }
    .padding(theme.space.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.raised)
    .overlay(
      Rectangle()
        .strokeBorder(borderColor, lineWidth: isFocused ? theme.focusRingWidth : theme.hairline))
    .focusable(isPending)
    .focused(focusedCard, equals: itemID)
    .focusEffectDisabled()
    .onKeyPress(.return) {
      guard isPending else { return .ignored }
      approve()
      return .handled
    }
    .onKeyPress(.escape) {
      guard isPending else { return .ignored }
      deny()
      return .handled
    }
  }

  private var borderColor: Color {
    if isFocused { return theme.focusRing }
    switch approval.state {
    case .pending: return theme.warning.opacity(Theme.statusBorderOpacity)
    case .approved:
      switch approval.outcome {
      case nil: return theme.border
      case .applied: return theme.success.opacity(Theme.statusBorderOpacity)
      case .failed: return theme.danger.opacity(Theme.statusBorderOpacity)
      }
    case .denied, .withdrawn: return theme.border
    }
  }

  /// A delete's Approve is in the danger hue, so approving one never looks
  /// like approving an add.
  @ViewBuilder
  private func footer(isDestructive: Bool) -> some View {
    switch approval.state {
    case .pending:
      HStack(spacing: theme.space.sm) {
        Button("Approve", action: approve)
          .buttonStyle(WorkspaceAgentCardButtonStyle(tint: isDestructive ? theme.danger : theme.primary))
        Button("Deny", action: deny)
          .buttonStyle(WorkspaceAgentCardButtonStyle(tint: nil))
        Spacer(minLength: 0)
        if isFocused {
          Text("return approves · esc denies")
            .font(theme.monoCaptionFont)
            .foregroundStyle(theme.dim)
            .lineLimit(1)
        }
      }
    case .approved:
      switch approval.outcome {
      case nil: status("Approved · running…", theme.muted)
      case .applied: status("Approved · done", theme.success)
      case .failed(let message): status("Approved · failed: \(message)", theme.danger)
      }
    case .denied:
      status("Denied · nothing changed", theme.muted)
    case .withdrawn:
      status("Not answered before the thread ended · nothing changed", theme.muted)
    }
  }

  private func status(_ text: String, _ color: Color) -> some View {
    Text(text)
      .font(theme.monoCaptionFont)
      .foregroundStyle(color)
      .lineLimit(3)
      .textSelection(.enabled)
  }
}

/// The card's two buttons: flat and bordered at the control radius, regular
/// weight. `tint` is the status convention — a tinted fill, a border and text
/// of the same hue — for the one action the card is asking about; nil is the
/// plain bordered button beside it.
struct WorkspaceAgentCardButtonStyle: ButtonStyle {
  let tint: Color?

  func makeBody(configuration: Configuration) -> some View {
    WorkspaceAgentCardButtonBody(configuration: configuration, tint: tint)
  }
}

private struct WorkspaceAgentCardButtonBody: View {
  @Environment(\.theme) private var theme
  let configuration: ButtonStyleConfiguration
  let tint: Color?
  @State private var isHovering = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
    let lit = isHovering || configuration.isPressed
    return configuration.label
      .font(theme.bodyFont())
      .foregroundStyle(tint ?? theme.ink)
      .padding(.horizontal, theme.space.sm)
      .padding(.vertical, theme.space.xxs)
      .background(
        tint.map { $0.opacity(lit ? Theme.statusFillOpacity * 2 : Theme.statusFillOpacity) }
          ?? (lit ? theme.hover : Color.clear), in: shape
      )
      .overlay(
        shape.strokeBorder(
          tint.map { $0.opacity(Theme.statusBorderOpacity) } ?? theme.inputBorder, lineWidth: theme.hairline))
      .contentShape(shape)
      .onHover { isHovering = $0 }
  }
}

/// Shown when no `claude` could be found: what the panel needs and how to
/// give it one.
struct WorkspaceAgentSetup: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  @State private var path = ""

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.md) {
      Text("The agent panel runs Claude Code, which isn't installed where Takt looked.")
        .font(theme.bodyFont())
        .foregroundStyle(theme.ink)
      Text("Install it from claude.com/claude-code and sign in once in a terminal (`claude`), or give the path to an existing `claude` binary below. No API key is needed; it uses your Claude Code login.")
        .font(theme.captionFont)
        .foregroundStyle(theme.muted)
      VStack(alignment: .leading, spacing: theme.space.xxs) {
        MicroLabel("Looked in")
        ForEach(model.agent.executableCandidates, id: \.self) { candidate in
          Text(candidate)
            .font(theme.monoCaptionFont)
            .foregroundStyle(theme.dim)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      HStack(spacing: theme.space.xs) {
        TextField("/path/to/claude", text: $path)
          .textFieldStyle(.plain)
          .font(theme.monoFont(size: theme.scale.caption))
          .padding(.horizontal, theme.space.sm)
          .padding(.vertical, theme.space.xxs)
          .overlay(
            RoundedRectangle(cornerRadius: theme.controlRadius)
              .strokeBorder(theme.inputBorder, lineWidth: theme.hairline))
          .onSubmit(usePath)
        Button("Use", action: usePath)
          .buttonStyle(WorkspaceAgentCardButtonStyle(tint: nil))
      }
      if !model.agent.userExecutablePath.isEmpty {
        Text("\(model.agent.userExecutablePath) is not an executable file.")
          .font(theme.captionFont)
          .foregroundStyle(theme.danger)
      }
    }
    .padding(theme.listGutter)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .onAppear { path = model.agent.userExecutablePath }
  }

  private func usePath() {
    model.agent.userExecutablePath = (path as NSString).expandingTildeInPath
  }
}
