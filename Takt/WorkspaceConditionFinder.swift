import SwiftUI
import TaktCore
import TaktWorkspace

struct WorkspaceConditionFinderRequest: Identifiable {
  enum Purpose: Equatable {
    /// "Say where you are…": the places, then Anywhere.
    case place
    /// `m` in the Conditions tab: the condition to merge `from` into.
    case merge(from: String)
  }

  let id = UUID()
  let purpose: Purpose
}

struct WorkspaceConditionCategoryRenameRequest: Identifiable {
  let id = UUID()
  /// The category, nil for "Other".
  let category: String?
  /// What its heading says.
  let title: String
}

/// One condition chosen from a typed list, for two jobs that are the same
/// gesture: saying which place you are in (`gw`, from anywhere) and choosing
/// what a condition merges into (`m` in the Conditions tab).
struct WorkspaceConditionFinder: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let overlayID: String
  let request: WorkspaceConditionFinderRequest
  @State private var query = ""
  @State private var selection: Int?

  private struct Option: Identifiable, Equatable {
    /// Nil is Anywhere.
    let condition: TaskCondition?
    var id: String { condition?.id ?? "anywhere" }
    var title: String { condition?.name ?? "Anywhere" }
  }

  private var mergingFrom: TaskCondition? {
    guard case .merge(let from) = request.purpose else { return nil }
    return model.focusConditions.first { $0.id == from }
  }

  private var candidates: [Option] {
    switch request.purpose {
    case .place:
      // The places tasks wait on first, as "Available now" offers them, then
      // the rest, so a place nothing needs yet can still be said.
      let places = model.liveConditionSections.first { $0.isExclusive }?.conditions ?? []
      let needed = places.filter { model.requiredConditionIDs.contains($0.id) }
      let others = places.filter { !model.requiredConditionIDs.contains($0.id) }
      return (needed + others).map { Option(condition: $0) } + [Option(condition: nil)]
    case .merge(let from):
      return model.liveConditionSections.flatMap(\.conditions)
        .filter { $0.id != from }
        .map { Option(condition: $0) }
    }
  }

  private var options: [Option] {
    let all = candidates
    let needle = query.trimmingCharacters(in: .whitespaces)
    guard !needle.isEmpty else { return all }
    let scored = all.compactMap { option in
      WorkspaceCommandQuery.fuzzyScore(needle, in: option.title).map { (option, $0) }
    }
    return scored.enumerated()
      .sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
      .map(\.element.0)
  }

  /// Where the cursor starts: on the place you are in, so Return keeps it.
  private var currentIndex: Int {
    guard request.purpose == .place, query.isEmpty else { return 0 }
    let items = options
    if let index = items.firstIndex(where: { $0.condition.map { model.focusContext.conditionIDs.contains($0.id) } ?? false }) {
      return index
    }
    return items.firstIndex { $0.condition == nil } ?? 0
  }

  var body: some View {
    let items = options
    VStack(spacing: 0) {
      WorkspaceOverlayField(
        symbol: request.purpose == .place ? "location" : "arrow.triangle.merge",
        prompt: request.purpose == .place ? "Where are you?" : "Merge into…", text: $query,
        context: mergingFrom.map { "Merge “\($0.name)”" } ?? "Say where you are")
      FocusRule()
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
              Text(request.purpose == .place
                ? "No places yet. File a condition under Location in the Conditions tab."
                : "Nothing to merge into.")
                .font(theme.captionFont)
                .foregroundStyle(theme.muted)
                .padding(theme.space.md)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, option in
              row(option)
                .overlayRow(isSelected: index == (selection ?? currentIndex))
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
        hints: request.purpose == .place ? "↑↓ choose · ↩ I'm here · esc cancel" : "↑↓ choose · ↩ merge · esc cancel",
        trailing: request.purpose == .place
          ? "Anywhere turns places off and keeps the rest"
          : "Its tasks need this one instead; it is archived")
    }
    .onChange(of: query) { _, _ in selection = nil }
    .overlayKeys(model, id: overlayID) { key in
      let rows = options
      if let step = WorkspaceOverlayStep.offset(for: key) {
        selection = WorkspaceOverlayStep.index(from: selection ?? currentIndex, by: step, count: rows.count)
        return true
      }
      guard key == "enter" else { return false }
      let index = selection ?? currentIndex
      if rows.indices.contains(index) { choose(rows[index]) }
      return true
    }
  }

  private func row(_ option: Option) -> some View {
    let isOn = option.condition.map { model.focusContext.conditionIDs.contains($0.id) }
      ?? (request.purpose == .place && !model.focusContext.conditionIDs.contains { id in
        model.focusConditions.contains { $0.id == id && $0.isLocation }
      })
    let waiting = option.condition.map { model.conditionWaitingCounts[$0.id] ?? 0 } ?? 0
    let needed = option.condition.map { model.conditionRequirementCounts[$0.id] ?? 0 } ?? 0
    return HStack(spacing: theme.space.sm) {
      Image(systemName: request.purpose == .place
        ? (isOn ? "largecircle.fill.circle" : "circle")
        : (option.condition?.isLocation == true ? "location" : "checkmark.circle"))
        .foregroundStyle(request.purpose == .place && isOn ? theme.primary : theme.muted)
      Text(option.title)
        .font(theme.bodyFont())
        .foregroundStyle(theme.ink)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: theme.space.sm)
      if request.purpose == .place, waiting > 0 {
        Text("\(waiting) waiting").font(theme.captionFont).foregroundStyle(theme.warning)
      } else if case .merge = request.purpose, let condition = option.condition {
        Text(condition.categoryTitle).font(theme.captionFont).foregroundStyle(theme.muted)
        if needed > 0 {
          Text("\(needed)").font(theme.monoCaptionFont).monospacedDigit().foregroundStyle(theme.dim)
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }

  private func choose(_ option: Option) {
    switch request.purpose {
    case .place:
      model.dismissOverlay(restoringFocus: true)
      model.setFocusPlace(option.condition)
    case .merge:
      guard let from = mergingFrom, let into = option.condition else { return }
      model.dismissOverlay(restoringFocus: true)
      model.mergeCondition(from, into: into)
    }
  }
}
