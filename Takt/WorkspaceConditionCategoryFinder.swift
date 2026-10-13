import SwiftUI
import TaktCore
import TaktWorkspace

struct WorkspaceConditionCategoryRequest: Identifiable {
  let id = UUID()
  /// The condition being filed; nil files the Conditions tab's new-condition
  /// row instead.
  let conditionID: String?
}

/// The category a condition is filed under: `t` in the Conditions tab.
///
/// Every category in use is a row — Location first, since it is the one that
/// is exclusive — then "No category". Type to narrow; a name nothing is
/// filed under yet offers "New category “…”". Return chooses and closes.
struct WorkspaceConditionCategoryFinder: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let overlayID: String
  let request: WorkspaceConditionCategoryRequest
  @State private var query = ""
  @State private var selection: Int?

  private struct Option: Identifiable, Equatable {
    /// The category, nil for none.
    let category: String?
    let title: String
    let isNew: Bool
    var id: String { (isNew ? "new." : "") + (category ?? "none") }
  }

  private var condition: TaskCondition? {
    request.conditionID.flatMap { id in model.focusConditions.first { $0.id == id } }
  }

  private var current: String? { request.conditionID == nil ? model.newConditionCategory : condition?.category }

  private var options: [Option] {
    let all = model.conditionCategories.map { Option(category: $0, title: $0, isNew: false) }
      + [Option(category: nil, title: "No category", isNew: false)]
    let needle = query.trimmingCharacters(in: .whitespaces)
    guard !needle.isEmpty else { return all }
    let scored = all.compactMap { option in
      WorkspaceCommandQuery.fuzzyScore(needle, in: option.title).map { (option, $0) }
    }
    var matches = scored.enumerated()
      .sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
      .map(\.element.0)
    if let typed = TaskConditionSection.normalizedCategory(needle),
      !all.contains(where: { $0.category?.compare(typed, options: .caseInsensitive) == .orderedSame }) {
      matches.append(Option(category: typed, title: "New category “\(typed)”", isNew: true))
    }
    return matches
  }

  var body: some View {
    let items = options
    VStack(spacing: 0) {
      WorkspaceOverlayField(
        symbol: "folder", prompt: "Category… or type a new one", text: $query,
        context: condition?.name ?? "New condition")
      FocusRule()
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, option in
              row(option)
                .overlayRow(isSelected: index == (selection ?? 0))
                .id(option.id)
                .onTapGesture { choose(option) }
            }
          }
        }
        .frame(height: WorkspaceOverlayMetrics.listHeight)
        .onChange(of: selection) { _, index in
          guard let index, items.indices.contains(index) else { return }
          proxy.scrollTo(items[index].id)
        }
      }
      WorkspaceOverlayFooter(
        hints: "↑↓ choose · ↩ file it · esc cancel",
        trailing: "Location is one place at a time")
    }
    .onChange(of: query) { _, _ in selection = nil }
    .overlayKeys(model, id: overlayID) { key in
      let rows = options
      if let step = WorkspaceOverlayStep.offset(for: key) {
        selection = WorkspaceOverlayStep.index(from: selection ?? 0, by: step, count: rows.count)
        return true
      }
      guard key == "enter" else { return false }
      let index = selection ?? 0
      if rows.indices.contains(index) { choose(rows[index]) }
      return true
    }
  }

  private func row(_ option: Option) -> some View {
    let isCurrent = !option.isNew && option.category == current
    return HStack(spacing: theme.space.sm) {
      Image(systemName: option.isNew ? "plus" : isCurrent ? "largecircle.fill.circle" : "circle")
        .foregroundStyle(option.isNew || isCurrent ? theme.primary : theme.muted)
      Text(option.title)
        .font(theme.bodyFont())
        .foregroundStyle(option.isNew ? theme.primary : theme.ink)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: theme.space.sm)
      if option.category == TaskConditionSection.locationCategory {
        Text("One at a time").font(theme.captionFont).foregroundStyle(theme.muted)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isCurrent ? .isSelected : [])
  }

  private func choose(_ option: Option) {
    if let condition {
      model.setConditionCategory(condition, category: option.category)
    } else {
      model.newConditionCategory = option.category
      model.conditionsAddFieldRequest += 1
    }
    model.dismissOverlay(restoringFocus: request.conditionID != nil)
  }
}

/// A condition's category as a menu: every category in use, "No category",
/// and "New category…", which opens the finder to type one.
struct WorkspaceConditionCategoryMenu: View {
  @Environment(WorkspaceViewModel.self) private var model
  /// What the menu shows.
  let category: String?
  /// Files under a category already in use, or none.
  let choose: (String?) -> Void
  /// Opens the finder, where a new category is typed.
  let newCategory: () -> Void

  var body: some View {
    ThemedMenu(category ?? "No category", systemImage: "folder") {
      ForEach(model.conditionCategories, id: \.self) { name in
        Button(name) { choose(name) }
      }
      Button("No category") { choose(nil) }
      Divider()
      Button("New category…", action: newCategory)
    }
    .fixedSize()
    .commandHelp(.conditionsCategory)
  }
}
