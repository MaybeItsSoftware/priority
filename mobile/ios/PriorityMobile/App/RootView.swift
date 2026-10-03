import PriorityWorkspace
import SwiftUI
import UIKit

/// The app's frame: tabs on iPhone, a three-column split view on iPad.
///
/// The iPad layout is chosen by idiom *and* width, so an iPad app in a narrow
/// Slide Over or split-screen column gets the phone's tabs.
struct RootView: View {
  @Environment(WorkspaceModel.self) private var model
  @Environment(\.horizontalSizeClass) private var sizeClass

  private var isPad: Bool {
    UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular
  }

  var body: some View {
    @Bindable var navigation = model.navigation
    Group {
      if isPad {
        PadRootView()
      } else {
        PhoneRootView()
      }
    }
    .environment(\.isPadLayout, isPad)
    .sheet(isPresented: $navigation.isQuickAddPresented) {
      QuickAddSheet()
        .environment(model)
        .environment(\.isPadLayout, isPad)
    }
    .sheet(item: movingTask) { item in
      MoveToListSheet(taskID: item.id)
        .environment(model)
    }
    .sheet(isPresented: $navigation.isHistoryPresented) {
      HistorySheet().environment(model)
    }
    .sheet(isPresented: $navigation.isSettingsPresented) {
      SettingsScreen().environment(model)
    }
    .sheet(item: pendingBlock) { pending in
      BlockQualityPrompt(pending: pending).environment(model)
    }
    .modifier(ListsPresenters())
    .overlay(alignment: .bottom) { ToastView() }
    .sensoryFeedback(trigger: model.completionCount) { _, _ in
      CompletionHaptics.isEnabled() ? .success : nil
    }
    .alert("Something went wrong", isPresented: errorBinding) {
      Button("OK", role: .cancel) { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
    .background(ShakeToUndo())
    .background(KeyboardCommands())
  }

  private var errorBinding: Binding<Bool> {
    Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
  }

  /// The one quality prompt, for whichever surface ended the block.
  private var pendingBlock: Binding<PendingBlockCompletion?> {
    Binding(
      get: { model.pendingBlock },
      set: { if $0 == nil, model.pendingBlock != nil { model.cancelBlockCompletion() } })
  }

  private var movingTask: Binding<IdentifiedString?> {
    Binding(
      get: { model.navigation.movingTaskID.map(IdentifiedString.init) },
      set: { model.navigation.movingTaskID = $0?.id })
  }
}

struct IdentifiedString: Identifiable, Hashable {
  let id: String
}

// MARK: - iPhone

struct PhoneRootView: View {
  @Environment(WorkspaceModel.self) private var model

  var body: some View {
    @Bindable var navigation = model.navigation
    TabView(selection: $navigation.tab) {
      Tab(RootTab.today.title, systemImage: RootTab.today.symbol, value: RootTab.today) {
        NavigationStack { TodayScreen() }
      }
      Tab(RootTab.lists.title, systemImage: RootTab.lists.symbol, value: RootTab.lists) {
        NavigationStack(path: $navigation.listPath) {
          ListsTreeView()
            .navigationDestination(for: ListScope.self) { scope in
              ListScreen(scope: scope)
            }
        }
      }
      Tab(RootTab.focus.title, systemImage: RootTab.focus.symbol, value: RootTab.focus) {
        NavigationStack { FocusScreen() }
      }
      Tab(RootTab.review.title, systemImage: RootTab.review.symbol, value: RootTab.review) {
        NavigationStack { ReviewScreen() }
      }
      Tab(RootTab.search.title, systemImage: RootTab.search.symbol, value: RootTab.search, role: .search) {
        NavigationStack { SearchScreen() }
      }
    }
    .sheet(item: inspected) { item in
      NavigationStack {
        TaskInspector(taskID: item.id)
      }
      .environment(model)
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
    }
  }

  private var inspected: Binding<IdentifiedString?> {
    Binding(
      get: { model.navigation.inspectedTaskID.map(IdentifiedString.init) },
      set: { model.navigation.inspectedTaskID = $0?.id })
  }
}

// MARK: - Shared chrome

/// The buttons every root screen carries: undo, redo, and add.
struct WorkspaceToolbar: ToolbarContent {
  @Environment(WorkspaceModel.self) private var model
  /// What the add button does; nil opens quick add for the Inbox.
  var onAdd: (() -> Void)?

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .topBarTrailing) {
      Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
        .disabled(model.undoLabel == nil)
        .accessibilityLabel(model.undoLabel.map { "Undo \($0)" } ?? "Undo")
        .accessibilityIdentifier("toolbar.undo")
        .contextMenu {
          Button("History…") { model.navigation.isHistoryPresented = true }
          if model.redoLabel != nil {
            Button("Redo \(model.redoLabel ?? "")") { model.redo() }
          }
        }
      Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
        .disabled(model.redoLabel == nil)
        .accessibilityLabel(model.redoLabel.map { "Redo \($0)" } ?? "Redo")
        .accessibilityIdentifier("toolbar.redo")
      Button {
        if let onAdd { onAdd() } else {
          model.navigation.quickAddListID = nil
          model.navigation.quickAddParentTaskID = nil
          model.navigation.isQuickAddPresented = true
        }
      } label: { Image(systemName: "plus") }
        .accessibilityLabel("Add task")
        .accessibilityIdentifier("toolbar.add")
    }
  }
}

struct ToastView: View {
  @Environment(\.theme) private var theme
  @Environment(WorkspaceModel.self) private var model

  var body: some View {
    if let toast = model.toast {
      Text(toast)
        .font(theme.type.callout)
        .foregroundStyle(theme.ink)
        .padding(.horizontal, theme.space.lg)
        .padding(.vertical, theme.space.sm)
        .background(theme.raised, in: RoundedRectangle(cornerRadius: theme.radius.panel))
        .overlay(RoundedRectangle(cornerRadius: theme.radius.panel).strokeBorder(theme.border, lineWidth: theme.stroke))
        .padding(.bottom, 64)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .accessibilityIdentifier("toast")
        .allowsHitTesting(false)
    }
  }
}

/// Shake to undo, the system's gesture, routed to the store's undo journal
/// rather than an `UndoManager` that knows nothing of it.
struct ShakeToUndo: UIViewControllerRepresentable {
  @Environment(WorkspaceModel.self) private var model

  func makeUIViewController(context: Context) -> ShakeController {
    let controller = ShakeController()
    controller.onShake = { [weak model] in model?.confirmShakeUndo() }
    return controller
  }

  func updateUIViewController(_ controller: ShakeController, context: Context) {}

  final class ShakeController: UIViewController {
    var onShake: (() -> Void)?
    override var canBecomeFirstResponder: Bool { true }
    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      becomeFirstResponder()
    }
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
      if motion == .motionShake { onShake?() } else { super.motionEnded(motion, with: event) }
    }
  }
}
