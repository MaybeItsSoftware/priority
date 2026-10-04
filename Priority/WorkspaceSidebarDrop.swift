import SwiftUI

/// Where a drop on a sidebar row would put the thing being dragged.
enum WorkspaceSidebarDropPlacement: Equatable {
  /// Above this row, in this row's group.
  case before
  /// Inside this row — nested in the list, or moved into the folder.
  case into
  /// At the end of this row's group. Offered by the last row of a group only,
  /// because every other row's "after" is the next row's "before".
  case after
}

extension View {
  /// Makes the whole row a drop target: its top edge places the dragged item
  /// above it, its middle puts the item inside it, and the last row of a group
  /// offers its bottom edge as "at the end".
  ///
  /// This replaces a dedicated separator row in every gap between two sidebar
  /// rows. Those worked, but each gap cost a whole `List` row — a row standing
  /// there at all times to be a target for the second a drag is over it — so
  /// the sidebar read as double-spaced and the rows that hold the actual lists
  /// were a smaller part of it than they looked.
  func workspaceSidebarDrop(
    isLastInGroup: Bool = false,
    onDrop: @escaping @MainActor (String, WorkspaceSidebarDropPlacement) -> Void
  ) -> some View {
    modifier(WorkspaceSidebarDropRow(isLastInGroup: isLastInGroup, onDrop: onDrop))
  }
}

private struct WorkspaceSidebarDropRow: ViewModifier {
  @Environment(\.theme) private var theme
  let isLastInGroup: Bool
  let onDrop: @MainActor (String, WorkspaceSidebarDropPlacement) -> Void

  @State private var placement: WorkspaceSidebarDropPlacement?
  @State private var height: CGFloat = 0

  func body(content: Content) -> some View {
    content
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
      .background(
        placement == .into ? theme.selectionFill : .clear,
        in: RoundedRectangle(cornerRadius: theme.rowRadius))
      .overlay(alignment: .top) { edge(.before) }
      .overlay(alignment: .bottom) { edge(.after) }
      .onDrop(
        of: [WorkspaceTaskDrag.typeIdentifier],
        delegate: WorkspaceSidebarDropDelegate(
          height: height,
          offersEnd: isLastInGroup,
          hover: { placement = $0 },
          drop: onDrop))
  }

  /// The insertion line. Drawn as an overlay rather than a row of its own, and
  /// never hit-tested, so it cannot take a click meant for the row under it.
  private func edge(_ target: WorkspaceSidebarDropPlacement) -> some View {
    Rectangle()
      .fill(placement == target ? theme.primary : .clear)
      .frame(height: theme.emphasisBorder)
      .allowsHitTesting(false)
  }
}

/// Reads the drop's position within the row, which is the whole reason this is
/// a delegate rather than the closure form of `onDrop`: the closure form is told
/// what was dropped but not where.
private struct WorkspaceSidebarDropDelegate: DropDelegate {
  let height: CGFloat
  let offersEnd: Bool
  let hover: @MainActor (WorkspaceSidebarDropPlacement?) -> Void
  let drop: @MainActor (String, WorkspaceSidebarDropPlacement) -> Void

  func validateDrop(info: DropInfo) -> Bool {
    info.hasItemsConforming(to: [WorkspaceTaskDrag.typeIdentifier])
  }

  func dropEntered(info: DropInfo) {
    report(placement(at: info.location.y))
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    report(placement(at: info.location.y))
    return DropProposal(operation: .move)
  }

  func dropExited(info: DropInfo) {
    report(nil)
  }

  func performDrop(info: DropInfo) -> Bool {
    let placement = placement(at: info.location.y)
    report(nil)
    let providers = info.itemProviders(for: [WorkspaceTaskDrag.typeIdentifier])
    return WorkspaceTaskDrag.readItemID(from: providers) { payload in
      // Placement is for lists and folders. A task has nowhere to go between
      // two rows, so wherever on the row it lands it goes into it — it used
      // to be dropped on the floor at the edges, which on the last row of a
      // group, or a row not yet measured, was most of the row.
      drop(payload, WorkspaceTaskDrag.sidebarItemID(from: payload) == nil ? .into : placement)
    }
  }

  /// The edges reorder and the middle nests. A third of a row, capped at six
  /// points: enough to aim at, not enough to make nesting hard to hit.
  private func placement(at offset: CGFloat) -> WorkspaceSidebarDropPlacement {
    let edge = max(3, min(6, height / 3))
    if offset < edge { return .before }
    if offersEnd, offset > height - edge { return .after }
    return .into
  }

  /// `DropDelegate` is not main-actor bound, but AppKit calls every one of
  /// these on the main thread while it tracks the drag.
  private func report(_ placement: WorkspaceSidebarDropPlacement?) {
    MainActor.assumeIsolated { hover(placement) }
  }
}
