import Foundation

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

/// Priority's tasks as an AFFiNE checklist, and the reading of one back.
///
/// `- [ ]` imports as a real todo block — tickable in AFFiNE — and exports as
/// `- [x]` once ticked, which is the whole basis for this being two-way.
///
/// The parsing is deliberately forgiving, because what comes back is not what
/// was sent: AFFiNE's exporter backslash-escapes every ASCII punctuation
/// character in a link label, so `Ship (v1.2)` returns as `Ship \(v1\.2\)`. A
/// comparison against the sent text would report a change on every single sync.
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
    var lines = [heading, ""]

    if tasks.isEmpty && carriedOver.isEmpty {
      lines.append("_Nothing open._")
      return lines.joined(separator: "\n")
    }

    for task in tasks {
      lines.append(line(for: task))
    }

    if !carriedOver.isEmpty {
      if !tasks.isEmpty { lines.append("") }
      lines.append(contentsOf: carriedOver)
    }

    return lines.joined(separator: "\n")
  }

  private static func line(for task: AFFiNEChecklistTask) -> String {
    let indent = String(repeating: "  ", count: max(0, task.depth))
    let label = escapedLabel(task.title)
    guard let permalink = task.permalink,
      !permalink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return "\(indent)- [ ] \(label)"
    }
    return "\(indent)- [ ] [\(label)](\(permalink))"
  }

  /// Only the three characters that would end the link label early. Escaping
  /// the rest would be undone by AFFiNE's own escaping on the way back.
  private static func escapedLabel(_ raw: String) -> String {
    let collapsed = raw
      .replacingOccurrences(of: "\r\n", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !collapsed.isEmpty else { return "(untitled)" }

    return
      collapsed
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "[", with: "\\[")
      .replacingOccurrences(of: "]", with: "\\]")
  }

  // MARK: - Reading

  /// Every todo line in the section, in document order.
  public static func items(in markdown: String, heading: String = heading) -> [AFFiNEChecklistItem] {
    guard let body = AFFiNEDocumentMarkdown.body(under: heading, in: markdown) else { return [] }
    return body.split(separator: "\n", omittingEmptySubsequences: false)
      .compactMap { item(from: String($0)) }
  }

  /// The tasks ticked in AFFiNE since the last sync.
  public static func tickedTaskIds(in markdown: String, heading: String = heading) -> [Int] {
    items(in: markdown, heading: heading).compactMap { $0.isChecked ? $0.taskId : nil }
  }

  /// Lines in the section that Priority did not write: hand-typed items, and
  /// any prose between them.
  public static func unownedLines(in markdown: String, heading: String = heading) -> [String] {
    guard let body = AFFiNEDocumentMarkdown.body(under: heading, in: markdown) else { return [] }
    return body.split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
      .filter { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        // "_Nothing open._" is ours, and putting it back beside real items
        // would be a lie.
        if trimmed == "_Nothing open._" { return false }
        guard let parsed = item(from: line) else { return true }
        return parsed.taskId == nil
      }
  }

  /// Whether what is in the document already says what Priority is about to
  /// say. Compared item by item rather than as text, because the text differs
  /// by escaping every time.
  public static func matches(
    _ items: [AFFiNEChecklistItem],
    tasks: [AFFiNEChecklistTask]
  ) -> Bool {
    let owned = items.filter { $0.taskId != nil }
    guard owned.count == tasks.count else { return false }
    return zip(owned, tasks).allSatisfy { item, task in
      item.taskId == task.id
        && !item.isChecked
        && item.depth == task.depth
        && normalised(item.title) == normalised(task.title)
    }
  }

  static func normalised(_ title: String) -> String {
    unescaped(title).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Line parsing

  static func item(from line: String) -> AFFiNEChecklistItem? {
    var rest = Substring(line)
    var indent = 0
    while let first = rest.first, first == " " || first == "\t" {
      indent += first == "\t" ? 2 : 1
      rest = rest.dropFirst()
    }

    guard let marker = rest.first, "-*+".contains(marker) else { return nil }
    rest = rest.dropFirst()
    guard rest.first == " " else { return nil }
    rest = rest.dropFirst()

    guard rest.hasPrefix("[") else { return nil }
    let box = rest.dropFirst().prefix(1)
    guard rest.dropFirst(2).hasPrefix("]"), box == " " || box.lowercased() == "x" else {
      return nil
    }
    let isChecked = box.lowercased() == "x"
    rest = rest.dropFirst(3)
    if rest.first == " " { rest = rest.dropFirst() }

    let content = String(rest).trimmingCharacters(in: .whitespaces)
    let link = markdownLink(in: content)

    return AFFiNEChecklistItem(
      taskId: link.flatMap { taskId(inPermalink: $0.destination) },
      title: unescaped(link?.label ?? content),
      isChecked: isChecked,
      depth: indent / 2,
      raw: line
    )
  }

  /// A leading `[label](destination)`, honouring backslash escapes so a label
  /// containing `]` does not end it early.
  private static func markdownLink(in content: String) -> (label: String, destination: String)? {
    guard content.hasPrefix("[") else { return nil }

    var label = ""
    var index = content.index(after: content.startIndex)
    var closed = false
    while index < content.endIndex {
      let character = content[index]
      if character == "\\", content.index(after: index) < content.endIndex {
        let next = content.index(after: index)
        label.append("\\")
        label.append(content[next])
        index = content.index(after: next)
        continue
      }
      if character == "]" {
        closed = true
        index = content.index(after: index)
        break
      }
      label.append(character)
      index = content.index(after: index)
    }

    guard closed, index < content.endIndex, content[index] == "(" else { return nil }
    index = content.index(after: index)

    var destination = ""
    while index < content.endIndex, content[index] != ")" {
      destination.append(content[index])
      index = content.index(after: index)
    }
    guard index < content.endIndex else { return nil }

    return (label, destination)
  }

  /// Checkvist task permalinks end `#t<id>`. Matching on that rather than on
  /// the host keeps a self-hosted or rewritten link working.
  static func taskId(inPermalink permalink: String) -> Int? {
    guard let hash = permalink.lastIndex(of: "#") else { return nil }
    var digits = permalink[permalink.index(after: hash)...]
    guard digits.first == "t" else { return nil }
    digits = digits.dropFirst()
    guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
    return Int(digits)
  }

  /// Drops one level of backslash escaping — AFFiNE's on the way out, or ours
  /// on the way in.
  static func unescaped(_ raw: String) -> String {
    var output = ""
    var isEscaped = false
    for character in raw {
      if isEscaped {
        output.append(character)
        isEscaped = false
      } else if character == "\\" {
        isEscaped = true
      } else {
        output.append(character)
      }
    }
    if isEscaped { output.append("\\") }
    return output
  }
}
