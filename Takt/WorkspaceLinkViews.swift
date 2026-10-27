import SwiftUI
import TaktCore
import TaktWorkspace
import UniformTypeIdentifiers

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
    case everything, files, obsidian, drive

    var label: String {
      switch self {
      case .everything: "All"
      case .files: "Files"
      case .obsidian: "Obsidian"
      case .drive: "Drive"
      }
    }
  }

  private enum Row: Identifiable {
    case address(String)
    case chooseFile
    case candidate(LinkCandidate)

    var id: String {
      switch self {
      case .address(let url): "address:\(url)"
      case .chooseFile: "choose-file"
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
        symbol: "link", prompt: "Link… note, Drive file, local file/folder, or address", text: $query,
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
    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
      WorkspaceFileDrop.handleFileDrop(providers: providers) { url in
        model.linkDroppedURL(url, to: request.task)
        model.dismissOverlay()
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
      case .files: return "Browse files and folders in Finder or paste a file path."
      case .everything:
        return canSearchDrive
          ? "Type to find a note, browse files, or paste any address."
          : "Type to find a note, browse files, or paste any address — Drive, web, local file."
      }
    }
    return isSearchingDrive ? "Searching…" : "Nothing matches. Paste an address or file path to link it."
  }

  private var rows: [Row] {
    var rows: [Row] = []
    if let url = WorkspaceTaskLink.address(in: query), !existing.contains(url) { rows.append(.address(url)) }
    if scope == .everything || scope == .files {
      let q = query.lowercased().trimmingCharacters(in: .whitespaces)
      if q.isEmpty || "choose file or folder browse local".contains(q) || "files".contains(q) {
        rows.append(.chooseFile)
      }
    }
    if scope != .drive && scope != .files { rows += obsidianMatches.map(Row.candidate) }
    if scope != .obsidian && scope != .files { rows += driveResults.filter { !existing.contains($0.url) }.map(Row.candidate) }
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
    case .chooseFile:
      HStack(spacing: theme.space.sm) {
        Image(systemName: "folder.badge.plus")
          .foregroundStyle(theme.primary)
        Text("Choose file or folder from file system…")
          .font(theme.bodyFont())
          .foregroundStyle(theme.ink)
        Spacer()
        Text("Browse")
          .font(theme.captionFont)
          .foregroundStyle(theme.muted)
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
    case .chooseFile:
      pickFileOrFolder()
      return
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

  private func pickFileOrFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Link"
    panel.message = "Choose a file or folder to link to this task"
    if panel.runModal() == .OK, let url = panel.url {
      let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
      var finalURL = url
      if isDir && !finalURL.path.hasSuffix("/") {
        finalURL.appendPathComponent("")
      }
      let err = model.addLink(finalURL.absoluteString, title: url.lastPathComponent, to: request.task)
      if let err {
        error = err
      } else {
        model.dismissOverlay()
      }
    }
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
  @State private var isDropTargeted = false

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
          .houseContextMenu {
            makeLinkContextMenu(link: link, task: task, model: model)
          }
          LinkMenuButton(link: link, task: task, index: index)
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
        Button("Choose file…") { model.pickFileLink(for: task) }
          .buttonStyle(InspectorValueButtonStyle(tone: .dim))
          .inspectorStop("link.file", press: { model.pickFileLink(for: task) })
          .help("Link a file or folder from the file system")
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
    .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
      WorkspaceFileDrop.handleFileDrop(providers: providers) { url in
        model.linkDroppedURL(url, to: task)
      }
    }
    .overlay(
      RoundedRectangle(cornerRadius: theme.panelRadius)
        .strokeBorder(isDropTargeted ? theme.primary : Color.clear, lineWidth: theme.borders.emphasis)
    )
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

/// The options button (•••) beside a link row presenting the link's actions menu.
private struct LinkMenuButton: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let link: WorkspaceTaskLink
  let task: WorkspaceTask
  let index: Int

  var body: some View {
    GeometryReader { geo in
      Button {
        presentMenu(at: geo)
      } label: {
        Image(systemName: "ellipsis")
          .font(theme.captionFont)
          .frame(width: theme.scale.body, height: theme.scale.body)
      }
      .buttonStyle(InspectorValueButtonStyle(tone: .dim))
      .inspectorStop("link.\(index).options", press: { presentMenu(at: geo) })
      .help("Link options")
    }
    .frame(width: theme.scale.body, height: theme.scale.body)
  }

  private func presentMenu(at geo: GeometryProxy) {
    let frame = geo.frame(in: .global)
    let pt = CGPoint(x: frame.minX - 100, y: frame.maxY + 2)
    let items = makeLinkContextMenu(link: link, task: task, model: model)
    model.presentContextMenu(at: pt, items: items)
  }
}
