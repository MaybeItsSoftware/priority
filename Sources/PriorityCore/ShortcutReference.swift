import Foundation

/// The keyboard reference, derived from the bindings themselves.
///
/// It replaces a hand-written table in the settings pane, which had drifted
/// badly enough to be worse than nothing: it listed `u` as undo (undo moved to
/// `Cmd+Z` when `u` became the Daily tab), `t` as the timer (`t` is the Kanban
/// tab; the timer is `p`), and `m` as a filter slot (it is `,`). It also
/// described *default* bindings as though they were facts, so anyone who had
/// customised a shortcut was reading someone else's keyboard.
///
/// Everything here comes from `ConfigurableShortcutAction` and from a caller-
/// supplied lookup of the binding actually in force, so neither kind of drift
/// is expressible. `ShortcutReferenceTests` pins the rest: every action appears
/// exactly once, and no section is empty.
public enum ShortcutReference {

  public struct Entry: Identifiable, Equatable, Sendable {
    /// `nil` for a row that is not a rebindable action — the matrix quadrant
    /// letters, for instance, are sub-forms of one sequence binding rather than
    /// four separate actions.
    public let action: ConfigurableShortcutAction?
    /// Display-ready alternatives — `["⌘↑", "⌘J"]` — in the order the binding
    /// lists them.
    public let keys: [String]
    public let title: String
    /// Context the title alone doesn't carry: a different meaning in one view,
    /// or a Checkvist convention worth naming.
    public let note: String?

    public var id: String { action?.rawValue ?? title }

    public init(
      action: ConfigurableShortcutAction?,
      keys: [String],
      title: String,
      note: String?
    ) {
      self.action = action
      self.keys = keys
      self.title = title
      self.note = note
    }
  }

  public struct Section: Identifiable, Equatable, Sendable {
    public let title: String
    public let entries: [Entry]

    public var id: String { title }

    public init(title: String, entries: [Entry]) {
      self.title = title
      self.entries = entries
    }
  }

  /// Section order. Matches the settings pane's, which is roughly
  /// most-pressed-first.
  public static let sectionOrder = [
    "Navigation", "Task Actions", "Entry & Commands", "Integrations & Timer",
  ]

  /// - Parameter binding: the binding in force for an action — pass
  ///   `PreferencesManager.shortcutBinding(for:)`, so a customised shortcut is
  ///   what the reference shows. Defaults to the shipped binding, which is what
  ///   a test or a headless caller wants.
  public static func sections(
    binding: (ConfigurableShortcutAction) -> String = { $0.defaultBinding }
  ) -> [Section] {
    let grouped = Dictionary(grouping: ConfigurableShortcutAction.allCases, by: \.category)
    return sectionOrder.compactMap { title in
      guard let actions = grouped[title], !actions.isEmpty else { return nil }
      return Section(
        title: title,
        entries: actions.map { action in
          Entry(
            action: action,
            keys: displayKeys(forBinding: binding(action)),
            title: action.title,
            note: notes[action]
          )
        }
      )
    }
  }

  // MARK: - What applies right here

  /// The actions worth naming first for the view currently on screen.
  ///
  /// The reference lists everything, correctly, and everything is a lot to read
  /// when the question is "what can I do to this task, now". This is the answer
  /// to that narrower question, shown above the full list rather than instead
  /// of it.
  ///
  /// Kept separate from `sections(binding:)` on purpose: that function's
  /// contract is that every action appears exactly once, and a contextual
  /// section necessarily repeats some of them.
  public static func contextualSection(
    for view: RootTaskView,
    binding: (ConfigurableShortcutAction) -> String = { $0.defaultBinding }
  ) -> Section? {
    let entries = contextualEntries(for: view, binding: binding)
    guard !entries.isEmpty else { return nil }
    return Section(title: "In \(view.title)", entries: entries)
  }

  private static func contextualEntries(
    for view: RootTaskView,
    binding: (ConfigurableShortcutAction) -> String
  ) -> [Entry] {
    func entry(_ action: ConfigurableShortcutAction) -> Entry {
      Entry(
        action: action,
        keys: displayKeys(forBinding: binding(action)),
        title: action.title,
        note: notes[action]
      )
    }
    /// A literal row for something that is not its own binding.
    func literal(_ keys: String, _ title: String, _ note: String? = nil) -> Entry {
      Entry(action: nil, keys: [display(token: keys)], title: title, note: note)
    }

    switch view {
    case .eisenhower:
      // Derived from the sequence's own binding, so a rebound starter still
      // prints the right letters.
      let starter = displayKeys(forBinding: binding(.sequenceMatrixCoord)).first?
        .prefix(1).uppercased() ?? "M"
      return MatrixQuadrant.allCases.map { quadrant in
        Entry(
          action: nil,
          keys: ["\(starter) \(quadrantLetter(quadrant).uppercased())"],
          title: "Place in \(quadrant.title)",
          note: quadrantNote(quadrant)
        )
      } + [
        // One row, not four: the directions are `nextTask` and its neighbours
        // wearing a different hat here, so none of them has an action of its
        // own to print — and an `Entry` with no action is identified by its
        // title, which four rows called "Move between dots" would collide on.
        Entry(
          action: nil,
          keys: ["up", "down", "left", "right"].map { display(token: $0) },
          title: "Move between dots",
          note: "One coordinate at a time, nearest on the other axis first"
        ),
        // Enter rather than →, which is spent: a plot needs all four arrows
        // to move across, so descending into a dot needs a key of its own.
        Entry(
          action: nil,
          keys: [display(token: "enter")],
          title: "Open the dot",
          note: "Lists everything standing on that point — ← or Esc closes it"
        ),
        literal("m00", "Take off the matrix"),
        entry(.matrixFocusQuadrant),
        entry(.matrixToggleUnplaced),
        entry(.sequenceMatrixCoord),
      ]

    case .kanban:
      return [
        entry(.kanbanMoveLeft), entry(.kanbanMoveRight),
        entry(.kanbanFocusLeft), entry(.kanbanFocusRight),
        entry(.kanbanShowInAll),
      ]

    case .daily:
      return [entry(.markDone), entry(.addSibling), entry(.editTaskAtEnd), entry(.deleteTask)]

    case .priority:
      return [
        entry(.setPriorityRank), entry(.setAbsolutePriorityRank),
        entry(.pushPriorityBack), entry(.clearPriority),
        entry(.clearAbsolutePriority),
      ]

    case .due:
      return [entry(.sequenceDue), entry(.sequenceDueToday), entry(.toggleHideFuture)]

    case .tags:
      return [entry(.sequenceTag), entry(.sequenceUntag)]

    case .all:
      return [
        entry(.enterChildren), entry(.exitToParent),
        entry(.zoomIntoTask), entry(.zoomOutOfTask),
      ]
    }
  }

  private static func quadrantLetter(_ quadrant: MatrixQuadrant) -> String {
    switch quadrant {
    case .doNow: return "d"
    case .schedule: return "s"
    case .delegate: return "g"
    case .eliminate: return "e"
    }
  }

  private static func quadrantNote(_ quadrant: MatrixQuadrant) -> String? {
    switch quadrant {
    case .doNow: return "Urgent and important"
    case .schedule: return "Important, not urgent"
    case .delegate: return "Urgent, not important — G, because D is Do"
    case .eliminate: return "Neither"
    }
  }

  /// Splits a binding on its commas and renders each alternative.
  public static func displayKeys(forBinding binding: String) -> [String] {
    binding
      .split(separator: ",")
      .map { display(token: String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
      .filter { !$0.isEmpty }
  }

  /// One binding token as it should be read on a Mac keyboard.
  ///
  /// Two-key sequences are rendered spaced — `d d`, not `dd` — because the
  /// unspaced form reads as one chord and is the reason people press `d` and
  /// wonder why nothing happened.
  public static func display(token rawToken: String) -> String {
    let token = rawToken.lowercased()
    guard !token.isEmpty else { return "" }

    if !token.contains("+"), token.count > 1, let named = keyName[token] {
      return named
    }
    // A modifier-free multi-character token is a sequence, not a key name.
    if !token.contains("+"), token.count > 1 {
      return token.map(String.init).map { $0.uppercased() }.joined(separator: " ")
    }

    let parts = token.split(separator: "+").map(String.init)
    guard let base = parts.last else { return "" }
    let symbols = parts.dropLast().map { modifierSymbol[$0] ?? $0 }.joined()
    return symbols + (keyName[base] ?? base.uppercased())
  }

  /// In the order macOS writes them, which is not the order the binding format
  /// stores them in.
  private static let modifierSymbol: [String: String] = [
    "ctrl": "⌃", "option": "⌥", "shift": "⇧", "cmd": "⌘",
  ]

  private static let keyName: [String: String] = [
    "up": "↑", "down": "↓", "left": "←", "right": "→",
    "enter": "↩", "tab": "⇥", "escape": "⎋", "delete": "⌫",
    "space": "Space", "comma": ",", "f2": "F2",
  ]

  /// Only where the action's own title leaves something material unsaid.
  /// Deliberately sparse — a note on every row is a note on none.
  private static let notes: [ConfigurableShortcutAction: String] = [
    .nextTask: "In the Daily view, moves through the checklist",
    .previousTask: "In the Daily view, moves through the checklist",
    .markDone: "Ticks a daily in the Daily view",
    .addSibling: "Adds a daily in the Daily view, and stays open",
    .addChild: "Tab indents instead, as in Checkvist",
    .indentTask: "Tab, matching Shift+Tab for unindent",
    .addSiblingAbove: "Checkvist's Alt+Enter",
    .duplicateTask: "Content only — no due date, tags or subtasks",
    .sequenceDue: "Opens the calendar; arrows move, Return applies",
    .sequenceDueToday: "Type a time after the prefilled date",
    .deleteTask: "In the Daily view, deletes the daily — restorable in Preferences",
    .editTaskAtEnd: "Renames a daily in the Daily view",
    .editTaskAtStart: "Renames a daily in the Daily view",
    .moveTaskUp: "Reorders dailies in the Daily view",
    .moveTaskDown: "Reorders dailies in the Daily view",
    .clearPriority: "0 is Checkvist's spelling",
    .zoomIntoTask: "Checkvist calls this hoisting",
    .kanbanFocusMode: "Works from any view",
    .setPriorityRank: "Within the parent, not the whole list",
    .setAbsolutePriorityRank: "Across the whole list",
    .showShortcutReference: "This screen",
    .matrixFocusQuadrant: "Fills the grid with the selected dot's box — Esc or ← leaves",
    // A modifier alone produces no key-down, so ⇧⇧ cannot be a binding — it is
    // a gesture recognised alongside them. Named here so the one place that
    // lists every key does not omit it.
    .openCommandPalette: "Double-tap ⇧ as well, as in Checkvist",
  ]
}
