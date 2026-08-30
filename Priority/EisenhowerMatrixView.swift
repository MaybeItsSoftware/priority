import PriorityCore
import SwiftUI

/// A dot: one cluster, and where on the plot it sits.
///
/// `Equatable` by what the dot actually draws — the pile's identity, its size,
/// its place, and whether the coordinate is its own. The tasks' text never
/// reaches the plot, so comparing it would only cost a string compare per dot
/// per pointer move.
private struct MatrixPlotPoint: Equatable {
  let cluster: MatrixCluster<CheckvistTask>
  let position: CGPoint

  var task: CheckvistTask { cluster.representative }
  var count: Int { cluster.count }
  var isInherited: Bool { cluster.isInherited }

  /// A pile is the selected dot when the selection is anywhere inside it —
  /// otherwise selecting a descendant would light up nothing at all.
  func taskIdsContain(_ taskId: Int?) -> Bool {
    guard let taskId else { return false }
    return cluster.taskIds.contains(taskId)
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.cluster.representative.id == rhs.cluster.representative.id
      && lhs.cluster.taskIds == rhs.cluster.taskIds
      && lhs.position == rhs.position
      && lhs.cluster.isInherited == rhs.cluster.isInherited
  }
}

struct EisenhowerMatrixView: View {
  @Environment(AppCoordinator.self) var manager
  @Environment(TaskListViewModel.self) var taskListViewModel
  @Environment(TaskRepository.self) var repository
  @State private var hoveredTaskId: Int?
  @State private var isPlotTargeted = false

  private func themeColor(_ token: AppThemeColorToken) -> Color {
    manager.preferences.themeColor(for: token)
  }

  /// Commit a coordinate. Both axes are written together because a drop names
  /// a point, not an axis — writing one at a time would leave a card briefly
  /// sitting in a quadrant nobody chose.
  private func place(taskId: Int, urgency: Double, importance: Double) {
    repository.setUrgency(taskId: taskId, level: urgency)
    repository.setImportance(taskId: taskId, level: importance)
    repository.errorMessage = nil
    manager.statusMessage =
      "Matrix: (\(Int(urgency)), \(Int(importance))) — "
      + MatrixGeometry.quadrant(urgency: urgency, importance: importance).title
  }

  /// Show a pile in the drawer, and put the selection inside it.
  ///
  /// Selecting as well as opening matters: the drawer's rows are the app's
  /// ordinary selection, so landing on the goal means the next key you press —
  /// done, due, a tag — lands on something rather than on whatever was
  /// selected before you looked.
  private func openPile(_ cluster: MatrixCluster<CheckvistTask>) {
    manager.popoverChrome.openMatrixPile = cluster.key
    manager.taskNavigationService.selectOnMatrix(cluster.representative)
    manager.statusMessage =
      "\(cluster.count) at (\(formatCoordinate(cluster.urgency)), "
      + "\(formatCoordinate(cluster.importance))) — Esc closes"
  }

  /// Both halves — the plot and the unplaced drawer — come pre-resolved from
  /// `TaskListViewModel.cache`.
  ///
  /// They used to be computed right here: four scope passes and two
  /// inheritance resolutions, each walking every task's ancestor chain. And
  /// `onContinuousHover` re-runs `body` on every pointer move, so the whole
  /// lot ran at mouse-move frequency. That was the lag. The cache rebuilds on
  /// the inputs that actually change them — the task list, the stored
  /// coordinates, the scope — and on nothing else.
  var body: some View {
    let cache = taskListViewModel.cache
    return VStack(spacing: 0) {
      plot(cache)
        .frame(maxHeight: .infinity)
      // Under the plot rather than beside it, and only when asked for. As a
      // permanent rail it took 190 of the panel's 400 points, which left the
      // grid — the thing the view is for — as the narrower half of its own
      // screen. Opening it lengthens the panel by exactly its own height, so
      // the plot stays the square it was.
      if manager.popoverChrome.showsMatrixDrawer {
        Divider()
        drawer(cache)
          .frame(height: PopoverLayout.matrixUnplacedDrawerHeight)
      }
    }
    .background(themeColor(.panelSurface))
  }

  // MARK: - The plot

  private func plot(_ cache: CacheState) -> some View {
    let focused = manager.popoverChrome.focusedMatrixQuadrant
    let viewport = MatrixViewport.viewport(for: focused)
    // Zoomed in, only the box's own dots are drawn. The others are not off the
    // edge, they are outside the window entirely.
    let clusters = cache.matrixClusters.filter { cluster in
      guard let focused else { return true }
      return MatrixGeometry.quadrant(urgency: cluster.urgency, importance: cluster.importance)
        == focused
    }
    let currentSelectedId = taskListViewModel.currentTask?.id

    return GeometryReader { proxy in
      let size = min(proxy.size.width, proxy.size.height) - 40
      let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
      let plotPoints = clusters.map { cluster -> MatrixPlotPoint in
        let offset = viewport.offset(
          urgency: cluster.urgency, importance: cluster.importance, plotSize: size)
        return MatrixPlotPoint(
          cluster: cluster,
          position: CGPoint(x: center.x + offset.x, y: center.y + offset.y)
        )
      }

      ZStack {
        Group {
          if let focused {
            // One name, centred, and no crosshair: the axes of a zoomed box are
            // its edges, so a cross through the middle would draw a division
            // that is not there.
            Text(focused.title.uppercased())
              .font(.system(size: 24, weight: .black))
              .foregroundColor(themeColor(.link).opacity(0.14))
              .padding(.top, 24)
              // The way back out for the pointer, since clicking the name is
              // the way in. Esc and ← do the same from the keyboard.
              .contentShape(Rectangle())
              .onTapGesture {
                manager.popoverChrome.focusedMatrixQuadrant = nil
                manager.statusMessage = "Whole matrix."
              }
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          } else {
            quadrantLabel(MatrixQuadrant.doNow, alignment: .topTrailing)
            quadrantLabel(MatrixQuadrant.schedule, alignment: .topLeading)
            quadrantLabel(MatrixQuadrant.delegate, alignment: .bottomTrailing)
            quadrantLabel(MatrixQuadrant.eliminate, alignment: .bottomLeading)

            Path { path in
              path.move(to: CGPoint(x: 20, y: center.y))
              path.addLine(to: CGPoint(x: proxy.size.width - 20, y: center.y))
              path.move(to: CGPoint(x: center.x, y: 20))
              path.addLine(to: CGPoint(x: center.x, y: proxy.size.height - 20))
            }
            .stroke(themeColor(.panelDivider), lineWidth: 1)
          }
        }

        Group {
          Text("URGENT")
            .font(.system(size: 10, weight: .bold))
            .tracking(1.5)
            .foregroundColor(themeColor(.textSecondary))
            .position(x: proxy.size.width - 40, y: center.y + 12)

          Text("IMPORTANT")
            .font(.system(size: 10, weight: .bold))
            .tracking(1.5)
            .foregroundColor(themeColor(.textSecondary))
            .rotationEffect(.degrees(-90))
            .position(x: center.x - 12, y: 40)
        }

        MatrixDotLayer(
          points: plotPoints,
          selectedTaskId: currentSelectedId,
          onTap: { manager.taskNavigationService.selectOnMatrix($0) },
          onOpen: openPile
        )
        .equatable()

        // With the drawer closed there is nothing else on screen to explain an
        // empty grid, and "no dots" and "nothing placed yet" look identical.
        if plotPoints.isEmpty {
          Text(
            focused != nil
              ? "Nothing in \(focused?.title ?? "") — Esc for the whole matrix"
              : cache.matrixUnplacedTasks.isEmpty
                ? "Nothing here to place."
                : "\(cache.matrixUnplacedTasks.count) unplaced — press m l to list them"
          )
          .font(.system(size: 11))
          .foregroundColor(themeColor(.textSecondary))
          .allowsHitTesting(false)
        }

        // The pointer's mark is drawn here rather than inside the dot, so that
        // moving it changes this overlay instead of every dot on the plot.
        if let point = plotPoints.first(where: { $0.task.id == hoveredTaskId }) {
          // The ring *is* the catchment, drawn: what lights up is exactly the
          // area that answers to the pointer.
          let ring = MatrixClustering.hitRadius(count: point.count) * 2
          Circle()
            .stroke(themeColor(.link), lineWidth: 1.5)
            .frame(width: ring, height: ring)
            .position(point.position)
            .allowsHitTesting(false)
        }

        // Whatever the pointer is on, or — with the pointer off the plot — the
        // dot the keyboard is on, so arrow navigation is not a silent move
        // between identical grey circles.
        if let described = plotPoints.first(where: { $0.task.id == hoveredTaskId })
          ?? plotPoints.first(where: { $0.taskIdsContain(currentSelectedId) })
        {
          detailCard(described)
            .position(x: center.x, y: proxy.size.height - 40)
            // It sits over the plot; without this it would take the hover it
            // exists to report, and flicker itself away.
            .allowsHitTesting(false)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
      .onContinuousHover { phase in
        switch phase {
        case .active(let location):
          // Only when the answer actually changes. Writing the same id back on
          // every pointer move re-renders the view for no visible difference,
          // which is most of what the pointer does inside one dot's catchment.
          let nearest = dotUnderPointer(at: location, in: plotPoints)
          if nearest != hoveredTaskId { hoveredTaskId = nearest }
        case .ended:
          if hoveredTaskId != nil { hoveredTaskId = nil }
        }
      }
      // The whole point of the rewrite: where you drop a card *is* its
      // coordinate. `location` arrives in this view's own space, so the offset
      // from the centre is what `MatrixGeometry` inverts.
      .dropDestination(for: TaskDragPayload.self) { payloads, location in
        guard let payload = payloads.first else { return false }
        // Snapping, the window's bounds and the "not the unplaced sentinel"
        // rule all live in `MatrixViewport` — zooming gave the view a second
        // mapping to get right, and one of the two would have drifted.
        let coordinate = viewport.placement(
          offsetX: location.x - center.x,
          offsetY: location.y - center.y,
          plotSize: size
        )
        place(taskId: payload.taskId, urgency: coordinate.urgency, importance: coordinate.importance)
        return true
      } isTargeted: { isPlotTargeted = $0 }
      .overlay(
        Rectangle()
          .stroke(
            isPlotTargeted ? themeColor(.link) : Color.clear,
            lineWidth: 2
          )
          .animation(.easeOut(duration: 0.12), value: isPlotTargeted)
      )
    }
  }

  // MARK: - The drawer

  /// One drawer, two things to put in it: the pile you have opened, or what is
  /// still unsorted.
  ///
  /// An open pile wins because it is the more specific question — you asked for
  /// it, and the unplaced list is where the drawer sits the rest of the time.
  /// A remembered pile whose point no longer has a cluster on it has been
  /// emptied or moved away underneath you, and falls back rather than showing
  /// an empty box that claims to be somewhere.
  @ViewBuilder
  private func drawer(_ cache: CacheState) -> some View {
    if let key = manager.popoverChrome.openMatrixPile,
      let pile = MatrixNavigation.pile(at: key, in: cache.matrixClusters)
    {
      pileDrawer(pile, cache)
    } else {
      unplacedDrawer(cache)
    }
  }

  /// Everything standing on one point.
  ///
  /// The plot cannot draw these apart — inheritance gives a goal and all of its
  /// descendants the *same* coordinate, so forty tasks are one dot and "+39
  /// MORE HERE" was the whole of what the view could say about thirty-nine of
  /// them. This is the list that dot was standing for, with the tasks in it
  /// reachable: selecting one here selects it everywhere, so the ordinary keys
  /// — done, due, tag, timer — apply to it without leaving the matrix.
  private func pileDrawer(_ pile: MatrixCluster<CheckvistTask>, _ cache: CacheState) -> some View {
    let quadrant = MatrixGeometry.quadrant(urgency: pile.urgency, importance: pile.importance)
    let members = pile.taskIds.compactMap { cache.taskById[$0] }

    return VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Text(quadrant.title.uppercased())
          .font(.system(size: 10, weight: .bold))
          .tracking(1.5)
          .foregroundColor(themeColor(.link))
        Text(
          "(\(formatCoordinate(pile.urgency)), \(formatCoordinate(pile.importance)))"
        )
        .font(.system(size: 10, weight: .bold, design: .monospaced))
        .foregroundColor(themeColor(.textSecondary))
        Spacer()
        Text("\(pile.count)")
          .font(.system(size: 10, weight: .bold, design: .monospaced))
          .foregroundColor(themeColor(.textSecondary))
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)

      Divider()

      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(members, id: \.id) { task in
            // The one task in the pile that chose the coordinate is worth
            // marking: it is the one dragging the dot moves, and the reason
            // every other row is here at all.
            drawerRow(task, isSource: task.id == pile.representative.id && !pile.isInherited)
            Divider()
          }
        }
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .background(themeColor(.panelBackground))
  }

  // MARK: - The unplaced drawer

  /// What is left to sort, and the thing you drag from. Also the honest answer
  /// to "is this view doing anything" — an empty matrix with 200 unplaced
  /// tasks says so, rather than rendering a blank grid.
  private func unplacedDrawer(_ cache: CacheState) -> some View {
    // Inherited counts as placed. Place the seven goals and this empties,
    // which is the honest report: everything below them is now classified.
    let unplaced = cache.matrixUnplacedTasks

    return VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Text("UNPLACED")
          .font(.system(size: 10, weight: .bold))
          .tracking(1.5)
          .foregroundColor(themeColor(.textSecondary))
        Spacer()
        Text("\(unplaced.count)")
          .font(.system(size: 10, weight: .bold, design: .monospaced))
          .foregroundColor(themeColor(.textSecondary))
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)

      Divider()

      if unplaced.isEmpty {
        VStack {
          Spacer()
          Text("Everything here is placed.")
            .font(.system(size: 11))
            .foregroundColor(themeColor(.textSecondary))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
          Spacer()
        }
        .frame(maxWidth: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(unplaced, id: \.id) { task in
              drawerRow(task, isSource: false)
              Divider()
            }
          }
        }
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .background(themeColor(.panelBackground))
    // Dropping a placed card back into the drawer unplaces it, which is the
    // only way to undo a placement without knowing the clear-coordinate
    // command.
    .dropDestination(for: TaskDragPayload.self) { payloads, _ in
      guard let payload = payloads.first else { return false }
      repository.setUrgency(taskId: payload.taskId, level: 0)
      repository.setImportance(taskId: payload.taskId, level: 0)
      manager.statusMessage = "Removed from the matrix."
      return true
    }
  }

  /// - Parameter isSource: this row set the coordinate the rest of its pile is
  ///   borrowing. Only ever true in the pile drawer.
  private func drawerRow(_ task: CheckvistTask, isSource: Bool) -> some View {
    let isSelected = task.id == taskListViewModel.currentTask?.id
    return HStack(spacing: 6) {
      Text(task.content.strippingTags)
        .font(.system(size: 11))
        .foregroundColor(
          isSelected ? themeColor(.selectionForeground) : themeColor(.textPrimary)
        )
        .lineLimit(1)
      if isSource {
        Text("GOAL")
          .font(.system(size: 9, weight: .bold))
          .tracking(1)
          .foregroundColor(themeColor(.link))
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      isSelected ? themeColor(.selectionBackground).opacity(0.18) : Color.clear
    )
    .contentShape(Rectangle())
    .onTapGesture { manager.taskNavigationService.selectOnMatrix(task) }
    .draggable(TaskDragPayload(taskId: task.id))
  }

  // MARK: - Chrome

  /// The watermark, and the pointer's way into a zoom — clicking a box's name
  /// is the obvious gesture for "show me that box", and `mz` is its keyboard
  /// half.
  private func quadrantLabel(_ quadrant: MatrixQuadrant, alignment: Alignment) -> some View {
    Text(quadrant.title.uppercased())
      .font(.system(size: 24, weight: .black))
      .foregroundColor(themeColor(.textSecondary).opacity(0.12))
      // Padded and given its hit area *before* the frame expands it. The other
      // way round, each of the four labels claims the whole plot and the last
      // one drawn answers for every click on the grid.
      .padding(30)
      .contentShape(Rectangle())
      .onTapGesture {
        manager.popoverChrome.focusedMatrixQuadrant = quadrant
        manager.statusMessage = "\(quadrant.title) — Esc leaves"
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
  }

  /// Names the pile, not just its representative — a dot standing for thirty
  /// tasks that says only one of their titles is a dot that lies about what it
  /// is.
  private func detailCard(_ point: MatrixPlotPoint) -> some View {
    VStack(spacing: 4) {
      Text(point.task.content.strippingTags)
        .font(.system(size: 11, weight: .semibold))
        .lineLimit(1)
      HStack(spacing: 12) {
        Text("Urgency: \(formatCoordinate(point.cluster.urgency))")
        Text("Importance: \(formatCoordinate(point.cluster.importance))")
        if point.count > 1 {
          // Says what to press rather than only how many there are. The count
          // on its own was a dead end for as long as there was nothing to do
          // about it; now there is, and this is where you would be looking.
          Text("+\(point.count - 1) MORE — ⏎ OPENS")
            .font(.system(size: 9, weight: .bold))
            .tracking(1)
        }
        if point.isInherited {
          Text("INHERITED")
            .font(.system(size: 9, weight: .bold))
            .tracking(1)
            .foregroundColor(themeColor(.link))
        }
      }
      .font(.system(size: 9, design: .monospaced))
      .foregroundColor(themeColor(.textSecondary))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(themeColor(.panelSurfaceElevated))
    .cornerRadius(8)
    // Separation here is a hairline, not elevation — the shadow this replaces
    // was the only one in the app.
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(themeColor(.panelDivider), lineWidth: 1)
    )
  }

  private func formatCoordinate(_ value: Double) -> String {
    if value.rounded() == value {
      return String(Int(value))
    }
    return String(format: "%.1f", value)
  }

  /// The dot under the pointer, or nothing.
  ///
  /// Nearest-dot, but only within the dot's own catchment. Unbounded, this
  /// named a task wherever the pointer went — including across an empty
  /// quadrant — so the plot appeared to be reporting on something the pointer
  /// was nowhere near.
  private func dotUnderPointer(at location: CGPoint, in points: [MatrixPlotPoint]) -> Int? {
    guard let nearest = points.min(by: {
      squaredDistance($0.position, location) < squaredDistance($1.position, location)
    }) else { return nil }
    let radius = MatrixClustering.hitRadius(count: nearest.count)
    guard squaredDistance(nearest.position, location) <= radius * radius else { return nil }
    return nearest.task.id
  }

  private func squaredDistance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = a.x - b.x
    let dy = a.y - b.y
    return dx * dx + dy * dy
  }
}

/// Every dot on the plot, and nothing that changes when the pointer moves.
///
/// The `Equatable` conformance is the whole point of the type. Hovering writes
/// `hoveredTaskId` on the parent, which re-runs its `body`; without a
/// comparison to skip on, that rebuilt two hundred dots — each carrying a drag
/// source and two animations — at pointer-move frequency.
private struct MatrixDotLayer: View, Equatable {
  let points: [MatrixPlotPoint]
  let selectedTaskId: Int?
  let onTap: (CheckvistTask) -> Void
  let onOpen: (MatrixCluster<CheckvistTask>) -> Void

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.selectedTaskId == rhs.selectedTaskId && lhs.points == rhs.points
  }

  /// The `ZStack` is load-bearing. A custom view whose body is a bare `ForEach`
  /// is not flattened into the enclosing stack — it is laid out as one element,
  /// and a multi-view body with no container of its own stacks *vertically*. So
  /// every dot kept its correct x and was pushed down by its own index times a
  /// seventh of the plot: the coordinates were right, the drawing was not, and
  /// the hover ring — an ordinary child of the real ZStack — sat at the true
  /// position with no dot under it.
  var body: some View {
    ZStack {
      ForEach(points, id: \.task.id) { point in
        TaskDotView(
          task: point.task,
          isSelected: point.taskIdsContain(selectedTaskId),
          isInherited: point.isInherited,
          count: point.count
        )
        .position(point.position)
        // Double-click before single, or the double never fires. Opening is the
        // pointer's half of ⏎: a dot standing for forty tasks has to be
        // reachable by the thing you are already holding.
        .onTapGesture(count: 2) { onOpen(point.cluster) }
        .onTapGesture { onTap(point.task) }
        // A placed dot is draggable too, so refining a coordinate is the same
        // gesture as setting one. Dragging an inherited dot gives that task a
        // coordinate of its own, which is how you overrule a position the plot
        // derived; dragging a pile drags the task that put it there, and
        // everything still inheriting from it follows.
        .draggable(TaskDragPayload(taskId: point.task.id))
      }
    }
  }
}

struct TaskDotView: View {
  let task: CheckvistTask
  let isSelected: Bool
  /// A coordinate taken from an ancestor rather than chosen for this task.
  /// Drawn hollow: it is a real position, but not one anybody decided on, and
  /// it moves the moment its goal does.
  var isInherited: Bool = false
  /// How many tasks share this exact coordinate, this one included. The dot
  /// grows with it and carries the number, because inheritance puts whole
  /// subtrees on one point and a plain dot would claim to be a single task.
  var count: Int = 1
  @Environment(AppCoordinator.self) var manager

  private func themeColor(_ token: AppThemeColorToken) -> Color {
    manager.preferences.themeColor(for: token)
  }

  /// The matrix is the one root view that used to show nothing at all when a
  /// task was completed — the dot simply vanished on the next redraw, because
  /// giving it a celebration meant copying the task row's twenty lines of
  /// treatment plumbing a fourth time.
  ///
  /// It gets the preset's *small-shape* half rather than the row modifier: a
  /// 6pt dot has no room for a tint wash or a 3pt leading bar, but `iconPop`
  /// was written for exactly this case — a small mark the eye is already fixed
  /// on, where a proportional change reads as a pop. Same treatment, same
  /// curve, expressed in the vocabulary this surface has.
  var body: some View {
    let kind = CompletionKind.task(id: task.id)
    let treatment = manager.celebration.rowTreatment
    let phase = manager.celebration.phase(for: kind)
    let reduceMotion = manager.celebration.prefersReducedMotion
    let isCelebrating = phase == .celebrating
    // Hover is not in here deliberately: it is drawn as a ring by the plot, so
    // that the pointer moving does not invalidate every dot. See
    // `MatrixDotLayer`.
    let emphasised = isSelected

    let tint =
      isCelebrating && treatment != .none
        ? themeColor(.success)
        : isSelected
          ? themeColor(.link)
          : themeColor(.textSecondary).opacity(0.6)

    let diameter = MatrixClustering.dotDiameter(count: count) + (emphasised ? 4 : 0)

    Circle()
      .fill(isInherited ? Color.clear : tint)
      .frame(width: diameter, height: diameter)
      .overlay(
        Circle().stroke(
          isInherited ? tint : Color.white, lineWidth: isInherited ? 1.5 : (emphasised ? 2 : 0))
      )
      // Outside the dot rather than inside it: a 6pt dot has no room for a
      // numeral, and a pile of two should still read as a dot with a note
      // beside it rather than as a badge.
      .overlay(alignment: .leading) {
        if count > 1 {
          Text("\(count)")
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(themeColor(.textSecondary))
            .fixedSize()
            .offset(x: diameter + 3)
            .allowsHitTesting(false)
        }
      }
      .scaleEffect(treatment.iconScale(for: phase))
      .opacity(treatment.fades(at: phase) ? 0 : 1)
      .animation(.spring(response: 0.2), value: emphasised)
      .animation(CelebrationMotion.icon(reduceMotion: reduceMotion), value: phase)
  }
}
