import SwiftUI
import TaktCore
import TaktWorkspace

/// The task a link is being found for.
struct WorkspaceLinkRequest: Identifiable {
  let id = UUID()
  let task: WorkspaceTask
}

/// The SF Symbol for the core's icon hint (`links::TaskLink::icon`).
func linkSymbol(_ icon: String) -> String {
  switch icon {
  case "doc": "doc.text"
  case "sheet": "tablecells"
  case "slides": "rectangle.on.rectangle"
  case "form": "list.bullet.rectangle"
  case "pdf": "doc.richtext"
  case "image": "photo"
  case "folder": "folder"
  case "note": "note.text"
  case "file": "doc"
  default: "globe"
  }
}

/// Link…: `pl`. One field: what you type is matched against the notes and
/// folders in your Obsidian vaults and, with Drive search on, the names of
/// your Drive files; a pasted address is offered first. Tab narrows to one
/// source. Return links the selected row; the overlay stays a moment only if
/// linking failed.
struct WorkspaceLinkPicker: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let overlayID: String
  let request: WorkspaceLinkRequest

  /// Which sources the rows come from; Tab steps through them.
  private enum Scope: CaseIterable {
    case everything, obsidian, drive

    var label: String {
      switch self {
      case .everything: "All"
      case .obsidian: "Obsidian"
      case .drive: "Drive"
      }
    }
  }

  private enum Row: Identifiable {
    case address(String)
    case candidate(LinkCandidate)

    var id: String {
      switch self {
      case .address(let url): "address:\(url)"
      case .candidate(let candidate): candidate.id
      }
    }
  }

  @State private var query = ""
  @State private var scope: Scope = .everything
  @State private var driveResults: [LinkCandidate] = []
  /// The vault matches for `query`, worked out when it or the index changes
  /// rather than on every draw: a vault can hold thousands of notes.
  @State private var obsidianMatches: [LinkCandidate] = []
  @State private var driveError: String?
  @State private var isSearchingDrive = false
  @State private var selection: Int?
  @State private var error: String?
  /// What the task links to already, not worth offering again.
  @State private var existing: Set<String> = []

  private static let obsidianLimit = 40

  var body: some View {
    VStack(spacing: 0) {
      WorkspaceOverlayField(
        symbol: "link", prompt: "Link… find a note or a Drive file, or paste an address", text: $query,
        context: request.task.title)
      FocusRule()
      scopeStrip
      Group {
        if rows.isEmpty {
          WorkspaceOverlayHint(text: hint)
        } else {
          list
        }
      }
      .frame(height: WorkspaceOverlayMetrics.listHeight)
      if let message = error ?? driveError {
        Text(message)
          .font(theme.captionFont)
          .foregroundStyle(theme.danger)
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, theme.listGutter)
          .padding(.vertical, theme.space.xxs)
      }
      WorkspaceOverlayFooter(
        hints: "↑↓ choose · ↩ link · tab source · esc cancel",
        trailing: isSearchingDrive ? "searching Drive…" : (rows.isEmpty ? nil : "\(rows.count)"))
    }
    .onAppear {
      existing = Set(model.links(of: request.task).map(\.url))
    }
    .task {
      await model.linkSources?.reloadObsidianIndex()
    }
    .task(id: DriveQuery(text: query, scope: scope)) {
      await searchDrive()
    }
    .onChange(of: query, initial: true) { _, _ in
      selection = nil
      error = nil
      obsidianMatches = matchVaults()
    }
    .onChange(of: model.linkSources?.obsidianEntries.count) { _, _ in
      obsidianMatches = matchVaults()
    }
    .overlayKeys(model, id: overlayID) { key in
      if let step = WorkspaceOverlayStep.offset(for: key) {
        selection = WorkspaceOverlayStep.index(from: selection ?? 0, by: step, count: rows.count)
        return true
      }
      switch key {
      case "enter":
        let index = selection ?? 0
        if rows.indices.contains(index) { choose(rows[index]) }
        return true
      case "tab", "shift+tab":
        let all = Scope.allCases
        let current = all.firstIndex(of: scope) ?? 0
        scope = all[(current + (key == "tab" ? 1 : all.count - 1)) % all.count]
        selection = nil
        return true
      default:
        return false
      }
    }
  }

  private struct DriveQuery: Hashable {
    let text: String
    let scope: Scope
  }

  private var canSearchDrive: Bool { model.linkSources?.canSearchDrive ?? false }

  private var hint: String {
    if query.trimmingCharacters(in: .whitespaces).isEmpty {
      switch scope {
      case .drive where !canSearchDrive:
        return "Drive search is off: switch it on in Settings → Links, or paste a Drive address."
      case .drive: return "Type part of a Drive file's name."
      case .obsidian: return "Type part of a note's or a folder's name."
      case .everything:
        return canSearchDrive
          ? "Type to find a note or a Drive file, or paste any address."
          : "Type to find a note in your vaults, or paste any address — a Drive file, a page."
      }
    }
    return isSearchingDrive ? "Searching…" : "Nothing matches. Paste an address to link it as it is."
  }

  private var rows: [Row] {
    var rows: [Row] = []
    if let url = WorkspaceTaskLink.address(in: query), !existing.contains(url) { rows.append(.address(url)) }
    if scope != .drive { rows += obsidianMatches.map(Row.candidate) }
    if scope != .obsidian { rows += driveResults.filter { !existing.contains($0.url) }.map(Row.candidate) }
    return rows
  }

  /// The vault entries that match what is typed, best first: by title, then
  /// by the path inside the vault.
  private func matchVaults() -> [LinkCandidate] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty, WorkspaceTaskLink.address(in: needle) == nil, let entries = model.linkSources?.obsidianEntries else {
      return []
    }
    var scored: [(LinkCandidate, Int)] = []
    for entry in entries where !existing.contains(entry.url) {
      let byTitle = WorkspaceCommandQuery.fuzzyScore(needle, in: entry.title).map { $0 + 200 }
      let byPath = WorkspaceCommandQuery.fuzzyScore(needle, in: entry.searchText)
      guard let score = [byTitle, byPath].compactMap({ $0 }).max() else { continue }
      scored.append((entry, score - entry.searchText.count / 8))
    }
    return scored.sorted { $0.1 > $1.1 }.prefix(Self.obsidianLimit).map(\.0)
  }

  private func searchDrive() async {
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard scope != .obsidian, canSearchDrive, text.count >= 2, WorkspaceTaskLink.address(in: text) == nil,
      let sources = model.linkSources
    else {
      driveResults = []
      driveError = nil
      return
    }
    // Typing pauses before Drive is asked, so a word is one request, not five.
    try? await Task.sleep(for: .milliseconds(300))
    guard !Task.isCancelled else { return }
    isSearchingDrive = true
    defer { isSearchingDrive = false }
    do {
      let found = try await sources.searchDrive(matching: text)
      guard !Task.isCancelled else { return }
      driveResults = found
      driveError = nil
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled else { return }
      driveResults = []
      driveError = "Drive: \(error.localizedDescription)"
    }
  }

  private var scopeStrip: some View {
    HStack(spacing: theme.space.sm) {
      ForEach(Scope.allCases, id: \.self) { option in
        Button(option.label) {
          scope = option
          selection = nil
        }
        .buttonStyle(.plain)
        .font(theme.captionFont)
        .foregroundStyle(option == scope ? theme.ink : theme.muted)
        .underline(option == scope)
      }
      Spacer()
    }
    .padding(.horizontal, theme.listGutter)
    .padding(.vertical, theme.space.xxs)
  }

  private var list: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            rowView(row, isSelected: index == (selection ?? 0))
              .id(row.id)
              .onTapGesture { choose(row) }
          }
        }
      }
      .onChange(of: selection) { _, index in
        guard let index, rows.indices.contains(index) else { return }
        proxy.scrollTo(rows[index].id)
      }
    }
  }

  @ViewBuilder
  private func rowView(_ row: Row, isSelected: Bool) -> some View {
    switch row {
    case .address(let url):
      let described = WorkspaceTaskLink.describe(url)
      HStack(spacing: theme.space.sm) {
        Image(systemName: "plus")
          .foregroundStyle(theme.primary)
        Text("Link \(described.title)")
          .font(theme.bodyFont())
          .foregroundStyle(theme.ink)
          .lineLimit(1)
        Spacer(minLength: theme.space.md)
        Text(url)
          .font(theme.monoFont(size: theme.scale.caption))
          .foregroundStyle(theme.muted)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .overlayRow(isSelected: isSelected)
    case .candidate(let candidate):
      HStack(alignment: isSelected ? .firstTextBaseline : .center, spacing: theme.space.sm) {
        Image(systemName: candidateSymbol(candidate))
          .foregroundStyle(theme.muted)
          .frame(width: theme.scale.body)
        Text(candidate.title)
          .font(theme.bodyFont())
          .foregroundStyle(theme.ink)
          .expandsWhenSelected(isSelected)
        Spacer(minLength: theme.space.md)
        MicroLabel(candidate.source == .drive ? "Drive · \(candidate.subtitle)" : candidate.subtitle)
          .lineLimit(1)
          .fixedSize(horizontal: isSelected, vertical: false)
      }
      .overlayRow(isSelected: isSelected)
    }
  }

  private func candidateSymbol(_ candidate: LinkCandidate) -> String {
    linkSymbol(WorkspaceTaskLink.describe(candidate.url, title: candidate.title, mimeType: candidate.mimeType).icon)
  }

  private func choose(_ row: Row) {
    let failure: String?
    switch row {
    case .address(let url):
      failure = model.addLink(url, to: request.task)
    case .candidate(let candidate):
      failure = model.addLink(
        candidate.url, title: candidate.source == .drive ? candidate.title : nil, mimeType: candidate.mimeType,
        to: request.task)
    }
    if let failure {
      error = failure
      return
    }
    model.dismissOverlay()
  }
}

/// The inspector's Links row: each link with what it is, opened by a click
/// or Return and taken off by its ×; the picker for another; and the raw
/// addresses, still editable as text, folded away beneath.
struct WorkspaceLinksInspectorSection: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let task: WorkspaceTask
  /// The editor's text of the addresses, one per line.
  let addresses: Binding<String>
  @State private var links: [WorkspaceTaskLink] = []
  @State private var editsAddresses = false

  private struct ReloadKey: Hashable {
    let taskID: String
    let revision: Int
  }

  var body: some View {
    InspectorRow("Links") {
      ForEach(Array(links.enumerated()), id: \.element.url) { index, link in
        HStack(alignment: .firstTextBaseline, spacing: theme.space.xxs) {
          Button { model.openLink(link.url) } label: {
            HStack(spacing: theme.space.xs) {
              Image(systemName: linkSymbol(link.icon))
                .font(theme.captionFont)
                .foregroundStyle(theme.muted)
              Text(link.title)
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
              Text(link.subtitle)
                .foregroundStyle(theme.dim)
                .lineLimit(1)
                .truncationMode(.middle)
              Spacer(minLength: 0)
            }
          }
          .buttonStyle(InspectorValueButtonStyle())
          .inspectorStop("link.\(index)", press: { model.openLink(link.url) })
          .help(link.url)
          InspectorClearButton(label: "Remove the link to \(link.title)", stop: "link.\(index).remove") {
            model.removeLink(link.url, from: task)
          }
        }
      }
      HStack(spacing: theme.space.sm) {
        Button(links.isEmpty ? "Add link…" : "Add another…") { model.presentLinkPicker() }
          .buttonStyle(InspectorValueButtonStyle(tone: .dim))
          .inspectorStop("link.add", press: { model.presentLinkPicker() })
          .commandHelp(.taskAddLink, note: "A note in your vaults, a file in Drive, or any address")
        if !links.isEmpty {
          Button(editsAddresses ? "Done" : "Edit addresses") { editsAddresses.toggle() }
            .buttonStyle(InspectorValueButtonStyle(tone: .dim))
            .commandHelp(.taskOpenLink, note: "One address per line; the first opens")
        }
      }
      if editsAddresses || links.isEmpty && !addresses.wrappedValue.isEmpty {
        InspectorTextEditor(add: "Add links", text: addresses, stop: "links", minHeight: 44, maxHeight: 90)
      }
    }
    .task(id: ReloadKey(taskID: task.id, revision: model.taskContentRevision)) {
      links = model.links(of: task)
    }
  }
}

/// The small link mark on a row whose task links somewhere.
struct WorkspaceLinkMark: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let taskID: String

  var body: some View {
    if model.linkedTaskIDs.contains(taskID) {
      Image(systemName: "link")
        .font(.system(size: theme.scale.caption - 1, weight: .medium))
        .foregroundStyle(theme.muted)
        .help("Has links — gx opens the first")
        .accessibilityLabel("Has links")
    }
  }
}
