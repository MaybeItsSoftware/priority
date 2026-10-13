import SwiftUI
import TaktCore
import TaktWorkspace

/// Quick ask: `aa`. One line to tell the agent what to do to the selected
/// task — "make it due friday", "split this into steps" — with the task named
/// as the subject, so it needs no looking up.
///
/// It is the finders' panel (`cc`, `bb`, `mm`): the field with the caret, the
/// task as its micro-label, a footer of keys. Return sends. Then the panel
/// shows the work as it happens — what the agent read, its short reply, and a
/// card for every change with its Undo and the keys that would have done the
/// same — and stays up until it is put away: Esc closes it at any point and
/// stops nothing, and the exchange stays in the agent panel to come back to.
///
/// The keyboard stays in the field. Tab and ↓ select the next card that has a
/// button, ⇧Tab and ↑ go back towards the field, and Return presses the
/// selected card's button — Approve, Undo or Redo. A card waiting for Approve
/// (with "Ask before changing tasks" on) is never selected for you, so a
/// Return meant for the field cannot approve it; ⌫ on it denies.
struct WorkspaceQuickAskOverlay: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let overlayID: String
  let request: WorkspaceQuickAskRequest
  @State private var draft = ""
  @State private var selectedCard: UUID?

  private var session: WorkspaceAgentSession { model.quickAgent }
  private var showsTranscript: Bool { model.quickAskShowsTranscript(for: request.task) }
  private var isBusy: Bool { session.isWorking || session.pendingApproval != nil }

  var body: some View {
    VStack(spacing: 0) {
      WorkspaceOverlayField(
        symbol: "sparkles", prompt: isBusy ? "Working…" : "Tell the agent…", text: $draft,
        context: request.task.title)
      FocusRule()
      Group {
        if session.executablePath == nil && !session.isRunning {
          WorkspaceOverlayHint(
            text: "Claude Code isn't installed where Takt looked. The agent panel (\(panelKey)) sets it up.")
        } else if showsTranscript {
          transcript
        } else {
          WorkspaceOverlayHint(text: "Say what to do to this task: “due friday”, “split it into steps”.")
        }
      }
      .frame(height: showsTranscript ? WorkspaceOverlayMetrics.listHeight : Self.emptyHeight)
      WorkspaceOverlayFooter(hints: footerHints, trailing: isBusy ? "working" : nil)
    }
    .onChange(of: session.items.count) { _, _ in
      if let selectedCard, !actionableCards.contains(selectedCard) { self.selectedCard = nil }
    }
    .overlayKeys(model, id: overlayID, handle: handle)
  }

  /// Room for the one line said before anything is sent.
  private static let emptyHeight: CGFloat = 72

  private var panelKey: String {
    ShortcutReference.displayKeys(forBinding: WorkspaceCommandCatalog[.windowToggleAgentPanel].keys.first ?? "")
      .first ?? "the agent panel"
  }

  private var footerHints: String {
    if let selectedCard, let approval = approval(selectedCard), approval.state == .pending {
      return "↩ approve · ⌫ deny · ⇧⇥ back · esc close"
    }
    if selectedCard != nil { return "↩ undo or redo · ⇧⇥ back · esc close" }
    if session.pendingApproval != nil { return "⇥ to the change to approve it · esc close, it waits" }
    if isBusy { return "esc close · the work carries on" }
    return actionableCards.isEmpty ? "↩ send · esc close" : "↩ send · ⇥ to a change · esc close"
  }

  private var transcript: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: theme.space.sm) {
          ForEach(session.items) { item in
            row(item).id(item.id)
          }
          if session.isWorking && session.pendingApproval == nil {
            Text("Working…")
              .font(theme.monoCaptionFont)
              .foregroundStyle(theme.dim)
              .id("working")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, theme.listGutter)
        .padding(.vertical, theme.space.sm)
      }
      .onChange(of: session.items.count) { _, _ in
        guard let last = session.items.last else { return }
        proxy.scrollTo(last.id, anchor: .bottom)
      }
      .onChange(of: selectedCard) { _, card in
        if let card { proxy.scrollTo(card) }
      }
    }
  }

  @ViewBuilder
  private func row(_ item: WorkspaceAgentSession.Item) -> some View {
    switch item.entry {
    case .write(let approval):
      WorkspaceAgentApprovalCard(
        itemID: item.id, approval: approval, focusedCard: nil, isSelected: selectedCard == item.id,
        approve: { session.approve(item.id) },
        deny: { session.deny(item.id) },
        undo: { model.undoAgentChange(item.id) },
        redo: { model.redoAgentChange(item.id) },
        leave: { selectedCard = nil })
    default:
      WorkspaceAgentTranscriptLine(entry: item.entry)
    }
  }

  /// The cards a key can press, top to bottom: one waiting for an answer, or
  /// a change made with an undo step.
  private var actionableCards: [UUID] {
    session.items.compactMap { item in
      guard case .write(let approval) = item.entry else { return nil }
      if approval.state == .pending { return item.id }
      return approval.outcome == .applied && approval.undoStep != nil ? item.id : nil
    }
  }

  private func approval(_ id: UUID) -> WorkspaceAgentSession.Approval? {
    guard let item = session.items.first(where: { $0.id == id }), case .write(let approval) = item.entry else {
      return nil
    }
    return approval
  }

  private func handle(_ key: String) -> Bool {
    let cards = actionableCards
    switch key {
    case "tab", "down":
      guard !cards.isEmpty else { return key == "tab" }
      let index = selectedCard.flatMap(cards.firstIndex(of:)).map { $0 + 1 } ?? 0
      selectedCard = cards[min(index, cards.count - 1)]
      return true
    case "shift+tab", "up":
      guard let selectedCard, let index = cards.firstIndex(of: selectedCard) else { return key == "shift+tab" }
      self.selectedCard = index == 0 ? nil : cards[index - 1]
      return true
    case "enter":
      if let selectedCard {
        model.pressAgentCard(selectedCard)
        return true
      }
      send()
      return true
    case "delete":
      guard let selectedCard, approval(selectedCard)?.state == .pending else { return false }
      session.deny(selectedCard)
      self.selectedCard = nil
      return true
    default:
      return false
    }
  }

  private func send() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !isBusy else { return }
    // Kept when there is no `claude` to send it to.
    guard session.executablePath != nil else { return }
    draft = ""
    selectedCard = nil
    model.sendQuickAsk(text, about: request.task)
  }
}

/// Everything in an agent transcript but a change card: what you said, the
/// assistant's reply, a read, a notice. The panel's and the quick ask's.
struct WorkspaceAgentTranscriptLine: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let entry: WorkspaceAgentSession.Entry

  var body: some View {
    switch entry {
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
      Text(WorkspaceAgentPane.markdown(text))
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
    case .notice(let text, let isError):
      // Markdown, so a fix's `claude` reads as something to type.
      Text(WorkspaceAgentPane.markdown(text))
        .font(theme.captionFont)
        .foregroundStyle(isError ? theme.danger : theme.muted)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .write:
      EmptyView()
    }
  }
}
