import SwiftUI

/// Takt on the wrist: today's tasks to tick off, and the focus block to run.
/// The iPhone holds the workspace; this shows what it last said and sends
/// taps back to it.
@main
struct TaktWatchApp: App {
  @State private var store = WatchStore.shared
  @Environment(\.scenePhase) private var scenePhase

  init() {
    WatchStore.shared.activate()
  }

  var body: some Scene {
    WindowGroup {
      WatchRootView()
        .environment(store)
        .tint(WatchPalette.azure)
        .onChange(of: scenePhase) { _, phase in
          if phase == .active { store.refresh() }
        }
    }
  }
}

/// Today, with the running block a page away. Starting a block turns to it;
/// ending one turns back.
struct WatchRootView: View {
  @Environment(WatchStore.self) private var store
  @State private var page = Page.today

  enum Page: Hashable {
    case today
    case focus
  }

  var body: some View {
    TabView(selection: $page) {
      TodayView(onStart: { page = .focus })
        .tag(Page.today)
      if store.session != nil {
        FocusView()
          .tag(Page.focus)
      }
    }
    .tabViewStyle(.verticalPage)
    .background(WatchPalette.page)
    .onAppear { if store.session != nil { page = .focus } }
    .onChange(of: store.session?.taskId) { old, new in
      if new == nil { page = .today } else if old == nil { page = .focus }
    }
  }
}
