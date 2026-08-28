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
      if manager.popoverChrome.showsMatrixUnplaced {
        Divider()
        unplacedDrawer(cache)
          .frame(height: PopoverLayout.matrixUnplacedDrawerHeight)
      }
    }
    .background(themeColor(.panelSurface))
  }

  // MARK: - The plot

  private func plot(_ cache: CacheState) -> some View {
    let clusters = cache.matrixClusters
    let currentSelectedId = taskListViewModel.currentTask?.id

    return GeometryReader { proxy in
      let size = min(proxy.size.width, proxy.size.height) - 40
      let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
      let plotPoints = clusters.map { cluster -> MatrixPlotPoint in
        let offset = MatrixGeometry.offset(
          urgency: cluster.urgency, importance: cluster.importance, plotSize: size)
        return MatrixPlotPoint(
          cluster: cluster,
          position: CGPoint(x: center.x + offset.x, y: center.y + offset.y)
        )
      }

      ZStack {
        Group {
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
          onTap: { manager.taskNavigationService.navigate(to: $0) }
        )
        .equatable()

        // With the drawer closed there is nothing else on screen to explain an
        // empty grid, and "no dots" and "nothing placed yet" look identical.
        if plotPoints.isEmpty {
          Text(
            cache.matrixUnplacedTasks.isEmpty
              ? "Nothing here to place."
              : "\(cache.matrixUnplacedTasks.count) unplaced — press m l to list them"
          )
          .font(.system(size: 11))
          .foregroundColor(themeColor(.textSecondary))
          .allowsHitTesting(false)
        }

        // The pointer's mark is drawn here rather than inside the dot, so that
        // moving it changes this overlay instead of every dot on the plot.
        if let hoveredTaskId,
          let point = plotPoints.first(where: { $0.task.id == hoveredTaskId })
        {
          let ring = MatrixClustering.dotDiameter(count: point.count) + 10
          Circle()
            .stroke(themeColor(.link), lineWidth: 1.5)
            .frame(width: ring, height: ring)
            .position(point.position)
            .allowsHitTesting(false)

          hoverDetail(point)
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
          let nearest = nearestTaskId(to: location, in: plotPoints)
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
        let coordinate = MatrixGeometry.snappedCoordinate(
          offsetX: location.x - center.x,
          offsetY: location.y - center.y,
          plotSize: size
        )
        // A drop landing exactly on the origin would read as "unplaced" and
        // vanish, so it is nudged onto the nearest real slot instead.
        let urgency = coordinate.urgency == 0 && coordinate.importance == 0 ? 1 : coordinate.urgency
        place(taskId: payload.taskId, urgency: urgency, importance: coordinate.importance)
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
              unplacedRow(task)
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

  private func unplacedRow(_ task: CheckvistTask) -> some View {
    let isSelected = task.id == taskListViewModel.currentTask?.id
    return HStack(spacing: 6) {
      Text(task.content.strippingTags)
        .font(.system(size: 11))
        .foregroundColor(
          isSelected ? themeColor(.selectionForeground) : themeColor(.textPrimary)
        )
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      isSelected ? themeColor(.selectionBackground).opacity(0.18) : Color.clear
    )
    .contentShape(Rectangle())
    .onTapGesture { manager.taskNavigationService.navigate(to: task) }
    .draggable(TaskDragPayload(taskId: task.id))
  }

  // MARK: - Chrome

  private func quadrantLabel(_ quadrant: MatrixQuadrant, alignment: Alignment) -> some View {
    Text(quadrant.title.uppercased())
      .font(.system(size: 24, weight: .black))
      .foregroundColor(themeColor(.textSecondary).opacity(0.12))
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
      .padding(30)
  }

  /// Names the pile, not just its representative — a dot standing for thirty
  /// tasks that says only one of their titles is a dot that lies about what it
  /// is.
  private func hoverDetail(_ point: MatrixPlotPoint) -> some View {
    VStack(spacing: 4) {
      Text(point.task.content.strippingTags)
        .font(.system(size: 11, weight: .semibold))
        .lineLimit(1)
      HStack(spacing: 12) {
        Text("Urgency: \(formatCoordinate(point.cluster.urgency))")
        Text("Importance: \(formatCoordinate(point.cluster.importance))")
        if point.count > 1 {
          Text("+\(point.count - 1) MORE HERE")
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

  private func nearestTaskId(to location: CGPoint, in points: [MatrixPlotPoint]) -> Int? {
    guard let nearest = points.min(by: {
      squaredDistance($0.position, location) < squaredDistance($1.position, location)
    }) else { return nil }
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
        .onTapGesture { onTap(point.task) }
        // A placed dot is draggable too, so refining a coordinate is the same
        // gesture as setting one. Dragging a pile drags the task that put it
        // there, so everything inheriting the coordinate follows.
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
