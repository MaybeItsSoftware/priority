import Foundation
import TaktCore
import TaktWorkspace

/// One condition as the picker draws it: ticked or not, and what is said beside it.
struct ConditionPickerRow: Identifiable, Equatable {
  let condition: TaskCondition
  let isOn: Bool
  /// Under Location, where saying one holds replaces the last: drawn as a radio, not a box.
  let isExclusive: Bool
  /// Its category, shown only while searching, when the rows leave their headings.
  let category: String?
  var id: String { condition.id }
}

/// Rows under one heading; a nil title is the flat list of matches while searching.
struct ConditionPickerSection: Identifiable, Equatable {
  let title: String?
  let rows: [ConditionPickerRow]
  var id: String { title.map { "heading.\($0)" } ?? "matches" }
}

/// What the picker sheet shows for one query.
struct ConditionPickerList: Equatable {
  let sections: [ConditionPickerSection]
  /// The name typed, when no condition — archived ones included — is called
  /// that yet: offered as "New condition".
  let newName: String?
  let isSearching: Bool

  var isEmpty: Bool { sections.isEmpty && newName == nil }
}

/// The conditions picker on the phones: the Mac's `cc` picker
/// (`WorkspaceConditionPicker.swift`) for a thumb. With nothing typed, every
/// condition on offer under its category heading, as the core groups them;
/// typed into, one list ranked by the core's palette scoring — the name,
/// then the category — so a query lands on the same row on Android. A name
/// nothing is called yet is offered as a new condition.
enum ConditionPicker {
  /// From this many conditions on offer the sheet opens tall, with room to
  /// search; fewer fit at a glance.
  static let searchThreshold = 8

  /// - Parameters:
  ///   - offered: the headings shown with nothing typed.
  ///   - searchable: what a query looks through (it may reach beyond `offered`).
  ///   - all: every condition, for "is that name taken?".
  ///   - exclusiveRadio: whether Location rows are drawn as radios — only when
  ///     saying where you are, where a place replaces the last.
  static func list(
    offered: [TaskConditionSection], searchable: [TaskCondition], all: [TaskCondition],
    query: String, isOn: (String) -> Bool, exclusiveRadio: Bool
  ) -> ConditionPickerList {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else {
      let sections = offered.filter { !$0.conditions.isEmpty }.map { section in
        ConditionPickerSection(title: section.title, rows: section.conditions.map {
          ConditionPickerRow(condition: $0, isOn: isOn($0.id), isExclusive: exclusiveRadio && section.isExclusive, category: nil)
        })
      }
      return ConditionPickerList(sections: sections, newName: nil, isSearching: false)
    }
    // Headings come from the core, so a row's category reads as it does
    // unsearched, and ties keep the order the headings give.
    let ordered = TaskConditionSection.sections(searchable).flatMap { section in
      section.conditions.map { (condition: $0, section: section) }
    }
    let ranked = PhonePalette.rank(needle, ordered.map { .init(title: $0.condition.name, detail: $0.section.title) })
    let rows = ranked.map { index in
      let (condition, section) = ordered[index]
      return ConditionPickerRow(
        condition: condition, isOn: isOn(condition.id), isExclusive: exclusiveRadio && section.isExclusive,
        category: section.title)
    }
    let isTaken = all.contains { $0.name.caseInsensitiveCompare(needle) == .orderedSame }
    return ConditionPickerList(
      sections: rows.isEmpty ? [] : [ConditionPickerSection(title: nil, rows: rows)],
      newName: isTaken ? nil : needle,
      isSearching: true)
  }

  /// What a task needs, in one line: "Home or Campus + Floor space", or "Anytime".
  static func requirementSummary(_ groups: [[String]]?, name: (String) -> String) -> String {
    let groups = (groups ?? []).filter { !$0.isEmpty }
    guard !groups.isEmpty else { return "Anytime" }
    return groups.map { $0.map(name).joined(separator: " or ") }.joined(separator: " + ")
  }

  /// The other conditions sharing a group with `id` — "Campus" for Home in
  /// Home-or-Campus — or nil.
  static func alternatives(to id: String, in groups: [[String]]?, name: (String) -> String) -> String? {
    guard let group = (groups ?? []).first(where: { $0.contains(id) && $0.count > 1 }) else { return nil }
    return group.filter { $0 != id }.map(name).joined(separator: " or ")
  }

  /// What holds now, in the order the headings put it: "Home · Laptop", or nil for nothing.
  static func nowSummary(_ conditions: [TaskCondition], selected: Set<String>) -> String? {
    let on = TaskConditionSection.sections(conditions.filter { selected.contains($0.id) }).flatMap(\.conditions)
    return on.isEmpty ? nil : on.map(\.name).joined(separator: " · ")
  }
}
