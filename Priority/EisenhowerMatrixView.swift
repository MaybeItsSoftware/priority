import PriorityCore
import SwiftUI

/// A dot's identity and where it sits, resolved once per layout.
///
/// `Equatable` by what the dot actually draws — its id, its place, and whether
/// the coordinate is its own. The task's text never reaches the plot, so
/// comparing it would only cost a string compare per dot per pointer move.
private struct MatrixPlotPoint: Equatable {
  let task: CheckvistTask
  let position: CGPoint
  let isInherited: Bool

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.task.id == rhs.task.id && lhs.position == rhs.position
      && lhs.isInherited == rhs.isInherited
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

  /// Every open task the current scope covers, whether or not it has a
  /// coordinate, split by whether it has one. The view used to filter
  /// placed-only right here, which is what made the matrix unable to show you
  /// the work it exists to help you sort: the tasks needing a placement were
  /// the exact set it declined to draw.
  ///
  /// Both halves now arrive pre-resolved from `TaskListViewModel.cache`. They
  /// used to be computed in `body` — four scope passes and two inheritance
  /// resolutions, each walking every task's ancestor chain — and
  /// `onContinuousHover` re-runs `body` on every pointer move. That was the
  /// lag. The cache rebuilds on the inputs that actually change these: the
  /// task list, the stored coordinates, and the scope.

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

  var body: some View {
    let cache = taskListViewModel.cache
    return HStack(spacing: 0) {
      plot(cache)
      Divider()
      unplacedRail(cache)
        .frame(width: 190)
    }
    .background(themeColor(.panelSurface))
  }

  // MARK: - The plot

  private func plot(_ cache: CacheState) -> some View {
    let levels = cache.effectiveEisenhowerLevels
    let placed = cache.matrixPlacedTasks
    let currentSelectedId = taskListViewModel.currentTask?.id

    return GeometryReader { proxy in
      let size = min(proxy.size.width, proxy.size.height) - 40
      let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
      let plotPoints = placed.map { task -> MatrixPlotPoint in
        let level = levels[task.id]
        let offset = MatrixGeometry.offset(
          urgency: level?.urgency ?? 0, importance: level?.importance ?? 0, plotSize: size)
        return MatrixPlotPoint(
          task: task,
          position: CGPoint(x: center.x + offset.x, y: center.y + offset.y),
          isInherited: level?.isInherited ?? false
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

        // The pointer's mark is drawn here rather than inside the dot, so that
        // moving it changes this overlay instead of every dot on the plot.
        if let hoveredTaskId,
          let point = plotPoints.first(where: { $0.task.id == hoveredTaskId })
        {
          Circle()
            .stroke(themeColor(.link), lineWidth: 1.5)
            .frame(width: 16, height: 16)
            .position(point.position)
            .allowsHitTesting(false)

          hoverDetail(task: point.task, level: levels[hoveredTaskId])
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

  // MARK: - The unplaced rail

  /// What is left to sort, and the thing you drag from. Also the honest answer
  /// to "is this view doing anything" — an empty matrix with 200 unplaced
  /// tasks now says so, rather than rendering a blank grid.
  private func unplacedRail(_ cache: CacheState) -> some View {
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
    // Dropping a placed card back onto the rail unplaces it, which is the only
    // way to undo a placement without knowing the clear-coordinate command.
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
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
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

  private func hoverDetail(
    task: CheckvistTask, level: EffectiveEisenhowerLevel?
  ) -> some View {
    VStack(spacing: 4) {
      Text(task.content.strippingTags)
        .font(.system(size: 11, weight: .semibold))
        .lineLimit(1)
      HStack(spacing: 12) {
        Text("Urgency: \(formatCoordinate(level?.urgency ?? 0))")
        Text("Importance: \(formatCoordinate(level?.importance ?? 0))")
        if level?.isInherited == true {
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

  var body: some View {
    ForEach(points, id: \.task.id) { point in
      TaskDotView(
        task: point.task,
        isSelected: point.task.id == selectedTaskId,
        isInherited: point.isInherited
      )
      .position(point.position)
      .onTapGesture { onTap(point.task) }
      // A placed dot is draggable too, so refining a coordinate is the same
      // gesture as setting one.
      .draggable(TaskDragPayload(taskId: point.task.id))
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

    Circle()
      .fill(isInherited ? Color.clear : tint)
      .frame(width: emphasised ? 10 : 6, height: emphasised ? 10 : 6)
      .overlay(
        Circle().stroke(isInherited ? tint : Color.white, lineWidth: isInherited ? 1.5 : (emphasised ? 2 : 0))
      )
      .scaleEffect(treatment.iconScale(for: phase))
      .opacity(treatment.fades(at: phase) ? 0 : 1)
      .animation(.spring(response: 0.2), value: emphasised)
      .animation(CelebrationMotion.icon(reduceMotion: reduceMotion), value: phase)
  }
}
