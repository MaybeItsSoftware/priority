import Foundation
import TaktRustCore

/// A task as it appears in an AFFiNE checklist.
public struct AFFiNEChecklistTask: Sendable, Equatable {
  public let id: Int
  public let title: String
  /// The Checkvist permalink. It is what makes the checklist two-way: the link
  /// survives being reworded in AFFiNE, so a ticked box can still be traced
  /// back to a task id.
  public let permalink: String?
  public let depth: Int

  public init(id: Int, title: String, permalink: String?, depth: Int = 0) {
    self.id = id
    self.title = title
    self.permalink = permalink
    self.depth = depth
  }
}

/// A line read back out of a checklist.
public struct AFFiNEChecklistItem: Sendable, Equatable {
  /// `nil` for an item Priority did not write — someone typed it into the
  /// section by hand.
  public let taskId: Int?
  public let title: String
  public let isChecked: Bool
  public let depth: Int
  /// The line exactly as it was read, so an item Priority does not own can be
  /// put back the way it was found.
  public let raw: String

  public init(taskId: Int?, title: String, isChecked: Bool, depth: Int, raw: String) {
    self.taskId = taskId
    self.title = title
    self.isChecked = isChecked
    self.depth = depth
    self.raw = raw
  }
}

/// What a sync reads out of a checklist, in one pass over the document.
public struct AFFiNEChecklistReading: Sendable, Equatable {
  /// Every todo line in the section, in document order.
  public let items: [AFFiNEChecklistItem]
  /// Lines in the section that Priority did not write.
  public let unownedLines: [String]

  /// The tasks ticked in AFFiNE since the last sync.
  public var tickedTaskIds: [Int] { items.compactMap { $0.isChecked ? $0.taskId : nil } }

  public init(items: [AFFiNEChecklistItem], unownedLines: [String]) {
    self.items = items
    self.unownedLines = unownedLines
  }
}

/// Priority's tasks as an AFFiNE checklist, and the reading of one back.
///
/// `- [ ]` imports as a real todo block — tickable in AFFiNE — and exports as
/// `- [x]` once ticked, which is the whole basis for this being two-way.
///
/// The parsing is deliberately forgiving, because what comes back is not what
/// was sent: AFFiNE's exporter backslash-escapes every ASCII punctuation
/// character in a link label, so `Ship (v1.2)` returns as `Ship \(v1\.2\)`. A
/// comparison against the sent text would report a change on every single sync.
///
/// The rendering and the reading are the Rust core's (`core/src/affine.rs`);
/// a sync makes one call to read a document and one to rewrite it.
public enum AFFiNEChecklistMarkdown {

  public static let heading = "## Tasks"

  // MARK: - Rendering

  /// - Parameter carriedOver: lines found in the section that Priority did not
  ///   write. They are put back rather than dropped: the section is Priority's
  ///   to rewrite, but a note someone typed into it is not Priority's to
  ///   delete.
  public static func section(
    tasks: [AFFiNEChecklistTask],
    carriedOver: [String] = [],
    heading: String = heading
  ) -> String {
    affineChecklistSection(tasks: tasks.map(\.core), carriedOver: carriedOver, heading: heading)
  }

  /// The document with its checklist rewritten to `tasks`, keeping the lines
  /// Priority does not own, or `nil` when nothing was ticked and the checklist
  /// already says the same — rewriting it then would churn the document's
  /// history for no change anyone made.
  public static func rewritten(
    _ existing: String,
    tasks: [AFFiNEChecklistTask],
    tickedAny: Bool,
    heading: String = heading
  ) -> String? {
    affineChecklistRewrite(
      existing: existing, tasks: tasks.map(\.core), heading: heading, tickedAny: tickedAny)
  }

  // MARK: - Reading

  /// The section's items and the lines Priority does not own, in one call.
  public static func reading(_ markdown: String, heading: String = heading)
    -> AFFiNEChecklistReading
  {
    let read = affineChecklistRead(markdown: markdown, heading: heading)
    return AFFiNEChecklistReading(
      items: read.items.map(AFFiNEChecklistItem.init), unownedLines: read.unownedLines)
  }

  /// Every todo line in the section, in document order.
  public static func items(in markdown: String, heading: String = heading) -> [AFFiNEChecklistItem] {
    reading(markdown, heading: heading).items
  }

  /// The tasks ticked in AFFiNE since the last sync.
  public static func tickedTaskIds(in markdown: String, heading: String = heading) -> [Int] {
    reading(markdown, heading: heading).tickedTaskIds
  }

  /// Lines in the section that Priority did not write: hand-typed items, and
  /// any prose between them.
  public static func unownedLines(in markdown: String, heading: String = heading) -> [String] {
    reading(markdown, heading: heading).unownedLines
  }

  /// Whether what is in the document already says what Priority is about to
  /// say. Compared item by item rather than as text, because the text differs
  /// by escaping every time.
  public static func matches(
    _ items: [AFFiNEChecklistItem],
    tasks: [AFFiNEChecklistTask]
  ) -> Bool {
    affineChecklistMatches(items: items.map(\.core), tasks: tasks.map(\.core))
  }

  /// Checkvist task permalinks end `#t<id>`. Matching on that rather than on
  /// the host keeps a self-hosted or rewritten link working.
  static func taskId(inPermalink permalink: String) -> Int? {
    affineTaskIdInPermalink(permalink: permalink).map { Int($0) }
  }
}

// MARK: - To and from the core

extension AFFiNEChecklistTask {
  var core: AffineChecklistTask {
    AffineChecklistTask(id: Int64(id), title: title, permalink: permalink, depth: Int64(depth))
  }
}

extension AFFiNEChecklistItem {
  init(_ core: AffineChecklistItem) {
    self.init(
      taskId: core.taskId.map { Int($0) }, title: core.title, isChecked: core.isChecked,
      depth: Int(core.depth), raw: core.raw)
  }

  var core: AffineChecklistItem {
    AffineChecklistItem(
      taskId: taskId.map { Int64($0) }, title: title, isChecked: isChecked, depth: Int64(depth),
      raw: raw)
  }
}
