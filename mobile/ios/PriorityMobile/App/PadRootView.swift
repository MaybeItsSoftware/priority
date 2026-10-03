import PriorityWorkspace
import SwiftUI

/// iPad: the list tree and the root views in the sidebar, the chosen view in
/// the content column, and the selected task's inspector in the detail column.
struct PadRootView: View {
  @Environment(\.theme) private var theme
  @Environment(WorkspaceModel.self) private var model
  @State private var columns = NavigationSplitViewVisibility.all

  var body: some View {
    @Bindable var navigation = model.navigation
    NavigationSplitView(columnVisibility: $columns) {
      List(selection: $navigation.sidebarSelection) {
        Section {
          ForEach([RootTab.today, .focus, .review, .search]) { tab in
            Label(tab.title, systemImage: tab.symbol)
              .font(theme.type.body)
              .tag(SidebarItem.root(tab))
              .accessibilityIdentifier("sidebar.\(tab.rawValue)")
          }
        }
        ListsTreeView(embedded: true)
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .background(theme.paper)
      .navigationTitle("Takt")
      .toolbar {
        ListsTreeToolbar()
        ToolbarItem(placement: .topBarLeading) {
          Button { model.navigation.isSettingsPresented = true } label: { Image(systemName: "gearshape") }
            .accessibilityLabel("Settings")
        }
      }
      .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
    } content: {
      NavigationStack {
        content
      }
      .navigationSplitViewColumnWidth(min: 360, ideal: 520)
    } detail: {
      NavigationStack {
        if let taskID = model.navigation.selectedTaskID {
          TaskInspector(taskID: taskID)
            .id(taskID)
        } else {
          EmptyState(title: "No task selected", message: "Select a task to see its details.", systemImage: "sidebar.right")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.paper)
        }
      }
    }
    .navigationSplitViewStyle(.balanced)
    .onChange(of: model.navigation.sidebarSelection) { _, _ in
      model.navigation.selectedTaskID = nil
    }
  }

  @ViewBuilder
  private var content: some View {
    switch model.navigation.sidebarSelection {
    case .root(let tab):
      switch tab {
      case .today: TodayScreen()
      case .focus: FocusScreen()
      case .review: ReviewScreen()
      case .search: SearchScreen()
      case .lists: ListScreen(scope: .everything)
      }
    case .scope(let scope):
      ListScreen(scope: scope).id(scope)
    case nil:
      TodayScreen()
    }
  }
}
