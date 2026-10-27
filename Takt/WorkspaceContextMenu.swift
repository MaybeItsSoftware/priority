import AppKit
import SwiftUI
import TaktCore
import TaktWorkspace

// MARK: - Models

/// The active context menu's state in window coordinates.
struct HouseContextMenuState: Identifiable {
  let id = UUID()
  let point: CGPoint
  let items: [HouseMenuItem]
}

enum HouseMenuItem: Identifiable {
  case action(HouseMenuAction)
  case submenu(HouseSubmenu)
  case divider(id: String)

  var id: String {
    switch self {
    case .action(let action): action.id
    case .submenu(let submenu): submenu.id
    case .divider(let id): id
    }
  }

  var isSelectable: Bool {
    switch self {
    case .action(let action): !action.isDisabled
    case .submenu: true
    case .divider: false
    }
  }
}

struct HouseMenuAction: Identifiable {
  let id: String
  let title: String
  let icon: String?
  let role: ButtonRole?
  let shortcut: String?
  let isDisabled: Bool
  let action: () -> Void

  init(
    id: String = UUID().uuidString,
    title: String,
    icon: String? = nil,
    role: ButtonRole? = nil,
    shortcut: String? = nil,
    isDisabled: Bool = false,
    action: @escaping () -> Void
  ) {
    self.id = id
    self.title = title
    self.icon = icon
    self.role = role
    self.shortcut = shortcut
    self.isDisabled = isDisabled
    self.action = action
  }
}

struct HouseSubmenu: Identifiable {
  let id: String
  let title: String
  let icon: String?
  let items: [HouseMenuItem]

  init(
    id: String = UUID().uuidString,
    title: String,
    icon: String? = nil,
    items: [HouseMenuItem]
  ) {
    self.id = id
    self.title = title
    self.icon = icon
    self.items = items
  }
}

// MARK: - Result Builder

@resultBuilder
enum HouseMenuBuilder {
  static func buildBlock(_ components: [HouseMenuItem]...) -> [HouseMenuItem] {
    components.flatMap { $0 }
  }

  static func buildExpression(_ item: HouseMenuItem) -> [HouseMenuItem] {
    [item]
  }

  static func buildExpression(_ items: [HouseMenuItem]) -> [HouseMenuItem] {
    items
  }

  static func buildExpression(_ expression: ()) -> [HouseMenuItem] {
    []
  }

  static func buildOptional(_ component: [HouseMenuItem]?) -> [HouseMenuItem] {
    component ?? []
  }

  static func buildEither(first component: [HouseMenuItem]) -> [HouseMenuItem] {
    component
  }

  static func buildEither(second component: [HouseMenuItem]) -> [HouseMenuItem] {
    component
  }

  static func buildArray(_ components: [[HouseMenuItem]]) -> [HouseMenuItem] {
    components.flatMap { $0 }
  }
}

// MARK: - Builders & Helpers

func houseMenuItem(
  _ title: String,
  icon: String? = nil,
  role: ButtonRole? = nil,
  shortcut: String? = nil,
  disabled: Bool = false,
  action: @escaping () -> Void
) -> HouseMenuItem {
  .action(HouseMenuAction(title: title, icon: icon, role: role, shortcut: shortcut, isDisabled: disabled, action: action))
}

func houseMenuItem(
  _ title: String,
  command: WorkspaceCommandID,
  on surface: WorkspaceCommandSurface,
  icon: String? = nil,
  role: ButtonRole? = nil,
  disabled: Bool = false,
  action: @escaping () -> Void
) -> HouseMenuItem {
  let token = WorkspaceCommandCatalog.byID[command]?.contextMenuKey(on: surface)
  let shortcut = token.map { ShortcutReference.display(token: $0) }
  return .action(HouseMenuAction(title: title, icon: icon, role: role, shortcut: shortcut, isDisabled: disabled, action: action))
}

func houseMenuDivider() -> HouseMenuItem {
  .divider(id: UUID().uuidString)
}

func houseSubmenu(
  _ title: String,
  icon: String? = nil,
  @HouseMenuBuilder items: () -> [HouseMenuItem]
) -> HouseMenuItem {
  .submenu(HouseSubmenu(title: title, icon: icon, items: items()))
}

// MARK: - View Modifier

struct HouseContextMenuModifier: ViewModifier {
  @Environment(WorkspaceViewModel.self) private var model
  let items: () -> [HouseMenuItem]

  func body(content: Content) -> some View {
    content.overlay {
      HouseContextMenuDetector { point in
        let built = items()
        guard !built.isEmpty else { return }
        model.presentContextMenu(at: point, items: built)
      }
    }
  }
}

extension View {
  /// Presents a context menu in the house style on right-click.
  func houseContextMenu(@HouseMenuBuilder items: @escaping () -> [HouseMenuItem]) -> some View {
    modifier(HouseContextMenuModifier(items: items))
  }
}

// MARK: - Right-click Detector

struct HouseContextMenuDetector: NSViewRepresentable {
  let onRightClick: (CGPoint) -> Void

  func makeNSView(context: Context) -> HouseContextMenuDetectorView {
    let view = HouseContextMenuDetectorView()
    view.onRightClick = onRightClick
    return view
  }

  func updateNSView(_ nsView: HouseContextMenuDetectorView, context: Context) {
    nsView.onRightClick = onRightClick
  }
}

final class HouseContextMenuDetectorView: NSView {
  var onRightClick: ((CGPoint) -> Void)?

  override func hitTest(_ point: NSPoint) -> NSView? {
    // Only claim the hit test on right click or Control-click, so all left clicks,
    // drags, hover and scrolling pass cleanly to the view underneath.
    if let event = NSApp.currentEvent,
       event.type == .rightMouseDown ||
       (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
      return self
    }
    return nil
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    trigger(event)
    return nil
  }

  override func rightMouseDown(with event: NSEvent) {
    trigger(event)
  }

  private func trigger(_ event: NSEvent) {
    guard let window, let contentView = window.contentView else { return }
    let windowPoint = event.locationInWindow
    let y = contentView.isFlipped ? windowPoint.y : (contentView.bounds.height - windowPoint.y)
    onRightClick?(CGPoint(x: windowPoint.x, y: y))
  }
}

// MARK: - Host View

struct HouseContextMenuHost: View {
  @Environment(WorkspaceViewModel.self) private var model

  var body: some View {
    if let menu = model.activeContextMenu {
      GeometryReader { proxy in
        ZStack(alignment: .topLeading) {
          // Transparent backdrop to dismiss on click outside
          Color.black.opacity(0.0001)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
              model.dismissContextMenu()
            }

          HouseContextMenuCard(menu: menu, windowSize: proxy.size)
        }
      }
      .transition(.opacity)
    }
  }
}

// MARK: - Menu Card

struct HouseContextMenuCard: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  let menu: HouseContextMenuState
  let windowSize: CGSize

  @State private var hoveredIndex: Int?
  @State private var activeSubmenu: HouseSubmenu?
  @State private var submenuOffsetY: CGFloat = 0
  @State private var hoveredSubmenuActionId: String?
  @State private var parentFrame: CGRect = .zero
  @State private var submenuFrame: CGRect?

  private let menuWidth: CGFloat = 210

  private var selectableIndices: [Int] {
    menu.items.enumerated().compactMap { $0.element.isSelectable ? $0.offset : nil }
  }

  private func updateCombinedFrame() {
    if let sub = submenuFrame {
      model.contextMenuFrame = parentFrame.union(sub)
    } else {
      model.contextMenuFrame = parentFrame
    }
  }

  var body: some View {
    let position = calculatePosition()
    ZStack(alignment: .topLeading) {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(menu.items.enumerated()), id: \.element.id) { index, item in
          switch item {
          case .action(let action):
            actionRow(action, isHovered: hoveredIndex == index)
              .onHover { isHovering in
                if isHovering {
                  hoveredIndex = index
                  activeSubmenu = nil
                  submenuFrame = nil
                  updateCombinedFrame()
                } else if hoveredIndex == index {
                  hoveredIndex = nil
                }
              }
              .onTapGesture {
                guard !action.isDisabled else { return }
                model.dismissContextMenu()
                action.action()
              }
          case .submenu(let submenu):
            submenuRow(submenu, isHovered: hoveredIndex == index || activeSubmenu?.id == submenu.id)
              .onHover { isHovering in
                if isHovering {
                  hoveredIndex = index
                  activeSubmenu = submenu
                  submenuOffsetY = CGFloat(index) * 24
                }
              }
          case .divider:
            Rectangle()
              .fill(theme.borderMuted)
              .frame(height: theme.hairline)
              .padding(.vertical, theme.space.xxs)
              .padding(.horizontal, theme.space.xxs)
          }
        }
      }
      .padding(.vertical, theme.space.xxs)
      .frame(width: menuWidth)
      .themedSurface(theme, fill: theme.raised, radius: theme.panelRadius, stroke: theme.border, width: theme.hairline)
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
        parentFrame = frame
        updateCombinedFrame()
      }
      .offset(x: position.x, y: position.y)

      if let submenu = activeSubmenu {
        let subPos = calculateSubmenuPosition(parentPosition: position)
        VStack(alignment: .leading, spacing: 0) {
          ForEach(submenu.items) { subItem in
            switch subItem {
            case .action(let action):
              actionRow(action, isHovered: hoveredSubmenuActionId == action.id)
                .onHover { isHovering in
                  if isHovering {
                    hoveredSubmenuActionId = action.id
                  } else if hoveredSubmenuActionId == action.id {
                    hoveredSubmenuActionId = nil
                  }
                }
                .onTapGesture {
                  guard !action.isDisabled else { return }
                  model.dismissContextMenu()
                  action.action()
                }
            case .divider:
              Rectangle()
                .fill(theme.borderMuted)
                .frame(height: theme.hairline)
                .padding(.vertical, theme.space.xxs)
                .padding(.horizontal, theme.space.xxs)
            case .submenu:
              EmptyView()
            }
          }
        }
        .padding(.vertical, theme.space.xxs)
        .frame(width: menuWidth)
        .themedSurface(theme, fill: theme.raised, radius: theme.panelRadius, stroke: theme.border, width: theme.hairline)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
          submenuFrame = frame
          updateCombinedFrame()
        }
        .offset(x: subPos.x, y: subPos.y)
      }
    }
  }

  @ViewBuilder
  private func actionRow(_ action: HouseMenuAction, isHovered: Bool) -> some View {
    HStack(spacing: theme.space.xs) {
      if let icon = action.icon {
        Image(systemName: icon)
          .font(.system(size: theme.scale.caption, weight: .regular))
          .foregroundStyle(action.role == .destructive ? theme.danger : (action.isDisabled ? theme.dim : theme.muted))
          .frame(width: theme.scale.body)
      }
      Text(action.title)
        .font(theme.bodyFont())
        .foregroundStyle(action.role == .destructive ? theme.danger : (action.isDisabled ? theme.dim : theme.ink))
        .lineLimit(1)
      Spacer(minLength: theme.space.md)
      if let shortcut = action.shortcut {
        Text(shortcut)
          .font(theme.monoCaptionFont)
          .foregroundStyle(theme.muted)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, theme.listGutter)
    .padding(.vertical, theme.space.xs)
    .background(
      RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
        .fill(isHovered && !action.isDisabled ? theme.hover : Color.clear)
    )
    .padding(.horizontal, theme.space.xxs)
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private func submenuRow(_ submenu: HouseSubmenu, isHovered: Bool) -> some View {
    HStack(spacing: theme.space.xs) {
      if let icon = submenu.icon {
        Image(systemName: icon)
          .font(.system(size: theme.scale.caption, weight: .regular))
          .foregroundStyle(theme.muted)
          .frame(width: theme.scale.body)
      }
      Text(submenu.title)
        .font(theme.bodyFont())
        .foregroundStyle(theme.ink)
        .lineLimit(1)
      Spacer(minLength: theme.space.md)
      Image(systemName: "chevron.right")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(theme.muted)
    }
    .padding(.horizontal, theme.listGutter)
    .padding(.vertical, theme.space.xs)
    .background(
      RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
        .fill(isHovered ? theme.hover : Color.clear)
    )
    .padding(.horizontal, theme.space.xxs)
    .contentShape(Rectangle())
  }

  private func calculatePosition() -> CGPoint {
    let rawX = menu.point.x
    let rawY = menu.point.y
    let estimatedHeight = CGFloat(menu.items.count) * 26 + 10
    var x = rawX
    var y = rawY

    if x + menuWidth > windowSize.width - 12 {
      x = max(12, windowSize.width - menuWidth - 12)
    }
    if y + estimatedHeight > windowSize.height - 12 {
      y = max(12, rawY - estimatedHeight)
    }
    return CGPoint(x: max(12, x), y: max(12, y))
  }

  private func calculateSubmenuPosition(parentPosition: CGPoint) -> CGPoint {
    var x = parentPosition.x + menuWidth - 4
    if x + menuWidth > windowSize.width - 12 {
      x = max(12, parentPosition.x - menuWidth + 4)
    }
    let y = min(parentPosition.y + submenuOffsetY, windowSize.height - 200)
    return CGPoint(x: x, y: max(12, y))
  }
}

// MARK: - Key Handling

extension WorkspaceViewModel {
  func handleContextMenuKey(_ event: NSEvent) -> Bool {
    guard activeContextMenu != nil, let key = event.workspaceCommandKey else { return false }
    if key == "escape" {
      dismissContextMenu()
      return true
    }
    return false
  }
}

// MARK: - Standard Context Menus

@MainActor
func makeTaskContextMenu(task: WorkspaceTask, model: WorkspaceViewModel) -> [HouseMenuItem] {
  model.selectTask(task)
  var surface: WorkspaceCommandSurface {
    switch model.viewMode {
    case .today: .today
    case .board: .board
    case .outline: .outline
    case .matrix: .matrix
    }
  }

  var items: [HouseMenuItem] = []
  items.append(houseMenuItem(task.isList ? "Open list" : "Open subtasks", command: .planEnterTask, on: surface) {
    model.openItemList(task)
  })
  items.append(houseMenuItem("Rename…", command: .taskRename, on: surface) {
    model.presentOverlay(.quickEdit(WorkspaceTaskQuickEditRequest(task: task, kind: .title)))
  })
  if !task.isList {
    items.append(houseMenuItem(task.status == .open ? "Complete" : "Reopen", command: .taskComplete, on: surface) {
      model.toggleTask(task)
    })
  }
  items.append(houseMenuItem(task.isList ? "Convert to task" : "Convert to list", command: .taskConvertToList, on: surface) {
    model.convertItem(task)
  })
  items.append(houseMenuItem("Move to list or folder…", command: .taskMove, on: surface) {
    model.requestMove(task)
  })
  items.append(houseMenuItem("New nested list…") {
    model.requestNestedListCreation(under: task)
  })
  if task.isList {
    items.append(houseMenuItem("Move to top level") {
      model.moveDroppedItem(task.id, toFolderID: nil)
    })
    items.append(houseMenuItem(task.isPromoted == true ? "Unpin from sidebar" : "Promote to sidebar", command: .taskPromoteList, on: surface) {
      model.toggleListPromotion(task)
    })
    let iconItems = WorkspaceViewModel.availableListIcons.map { icon in
      houseMenuItem(icon.label, icon: icon.symbol) {
        model.setNestedListIcon(icon.symbol, for: task)
      }
    }
    items.append(.submenu(HouseSubmenu(title: "Choose icon", icon: "app.dashed", items: iconItems)))
    items.append(houseMenuDivider())
    items.append(houseMenuItem(task.status == .open ? "Complete list" : "Reopen list", command: .taskComplete, on: surface) {
      model.toggleTask(task)
    })
    items.append(houseMenuItem("Archive list") {
      model.archiveNestedList(task)
    })
  }
  let taskLinks = model.links(of: task)
  if !taskLinks.isEmpty {
    items.append(houseMenuDivider())
    if taskLinks.count == 1, let link = taskLinks.first {
      if let fileURL = model.fileURL(from: link.url) {
        let isFolder = link.icon == "folder" || model.isDirectory(url: fileURL)
        if isFolder {
          items.append(houseMenuItem("Open in Finder", icon: "folder") {
            model.openLinkInFinder(link.url)
          })
          if model.isAlacrittyAvailable {
            items.append(houseMenuItem("Open in Alacritty", icon: "terminal") {
              model.openFolderInAlacritty(link.url)
            })
          }
          items.append(houseMenuItem("Open in Terminal", icon: "apple.terminal") {
            model.openFolderInTerminal(link.url)
          })
        } else {
          let apps = model.availableApplications(for: link.url)
          let defaultAppName = apps.defaultApp?.deletingPathExtension().lastPathComponent
          let openTitle = defaultAppName.map { "Open with \($0)" } ?? "Open file"
          items.append(houseMenuItem(openTitle, icon: "arrow.up.forward.app") {
            model.openLink(link.url)
          })
          var openWithItems: [HouseMenuItem] = []
          for app in apps.otherApps {
            let name = app.deletingPathExtension().lastPathComponent
            openWithItems.append(houseMenuItem(name) {
              model.openFile(link.url, withApplicationAt: app)
            })
          }
          if !openWithItems.isEmpty {
            openWithItems.append(houseMenuDivider())
          }
          openWithItems.append(houseMenuItem("Other…") {
            model.promptOpenWith(link.url)
          })
          items.append(.submenu(HouseSubmenu(title: "Open file with", icon: "square.and.arrow.up", items: openWithItems)))
        }
      } else {
        items.append(houseMenuItem("Open “\(link.title)”", icon: "arrow.up.right") {
          model.openLink(link.url)
        })
      }
    } else {
      var linkMenuItems: [HouseMenuItem] = []
      for link in taskLinks {
        let subItems = makeLinkContextMenu(link: link, task: task, model: model)
        linkMenuItems.append(.submenu(HouseSubmenu(title: link.title, icon: linkSymbol(link.icon), items: subItems)))
      }
      items.append(.submenu(HouseSubmenu(title: "Links", icon: "link", items: linkMenuItems)))
    }
  }
  items.append(houseMenuDivider())
  items.append(houseMenuItem("Delete", role: .destructive) {
    model.deleteTask(task)
  })
  return items
}

@MainActor
func makeLinkContextMenu(link: WorkspaceTaskLink, task: WorkspaceTask, model: WorkspaceViewModel) -> [HouseMenuItem] {
  var items: [HouseMenuItem] = []

  if let fileURL = model.fileURL(from: link.url) {
    let isFolder = link.icon == "folder" || model.isDirectory(url: fileURL)

    if isFolder {
      items.append(houseMenuItem("Open in Finder", icon: "folder") {
        model.openLinkInFinder(link.url)
      })
      if model.isAlacrittyAvailable {
        items.append(houseMenuItem("Open in Alacritty", icon: "terminal") {
          model.openFolderInAlacritty(link.url)
        })
      }
      items.append(houseMenuItem("Open in Terminal", icon: "apple.terminal") {
        model.openFolderInTerminal(link.url)
      })

      let apps = model.availableApplications(for: link.url)
      var openWithItems: [HouseMenuItem] = []
      if let defaultApp = apps.defaultApp {
        let name = defaultApp.deletingPathExtension().lastPathComponent
        openWithItems.append(houseMenuItem("\(name) (Default)") {
          model.openFile(link.url, withApplicationAt: defaultApp)
        })
      }
      for app in apps.otherApps {
        let name = app.deletingPathExtension().lastPathComponent
        openWithItems.append(houseMenuItem(name) {
          model.openFile(link.url, withApplicationAt: app)
        })
      }
      if !openWithItems.isEmpty {
        openWithItems.append(houseMenuDivider())
      }
      openWithItems.append(houseMenuItem("Other…") {
        model.promptOpenWith(link.url)
      })
      items.append(.submenu(HouseSubmenu(title: "Open With", icon: "arrow.up.forward.app", items: openWithItems)))

      items.append(houseMenuDivider())
      items.append(houseMenuItem("Reveal in Finder") {
        model.revealInFinder(link.url)
      })
      items.append(houseMenuItem("Copy Path") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fileURL.path, forType: .string)
      })
    } else {
      let apps = model.availableApplications(for: link.url)
      let defaultAppName = apps.defaultApp?.deletingPathExtension().lastPathComponent
      let openTitle = defaultAppName.map { "Open with \($0)" } ?? "Open"
      items.append(houseMenuItem(openTitle, icon: "arrow.up.forward.app") {
        model.openLink(link.url)
      })

      var openWithItems: [HouseMenuItem] = []
      if let defaultApp = apps.defaultApp {
        let name = defaultApp.deletingPathExtension().lastPathComponent
        openWithItems.append(houseMenuItem("\(name) (Default)") {
          model.openFile(link.url, withApplicationAt: defaultApp)
        })
      }
      for app in apps.otherApps {
        let name = app.deletingPathExtension().lastPathComponent
        openWithItems.append(houseMenuItem(name) {
          model.openFile(link.url, withApplicationAt: app)
        })
      }
      if !openWithItems.isEmpty {
        openWithItems.append(houseMenuDivider())
      }
      openWithItems.append(houseMenuItem("Other…") {
        model.promptOpenWith(link.url)
      })
      items.append(.submenu(HouseSubmenu(title: "Open With", icon: "square.and.arrow.up", items: openWithItems)))

      items.append(houseMenuDivider())
      items.append(houseMenuItem("Reveal in Finder", icon: "folder") {
        model.revealInFinder(link.url)
      })
      items.append(houseMenuItem("Copy Path") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fileURL.path, forType: .string)
      })
    }
  } else {
    items.append(houseMenuItem("Open", icon: "arrow.up.right") {
      model.openLink(link.url)
    })
    items.append(houseMenuItem("Copy Link") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(link.url, forType: .string)
    })
  }

  items.append(houseMenuDivider())
  items.append(houseMenuItem("Remove Link", role: .destructive) {
    model.removeLink(link.url, from: task)
  })

  return items
}

@MainActor
func makeSidebarContextMenu(target: WorkspaceIconTarget, rowID: String, model: WorkspaceViewModel) -> [HouseMenuItem] {
  var creationFolderID: String? {
    switch target {
    case .folder(let folder): folder.id
    case .list(let list): list.isSystemList ? nil : list.folderId
    case .nestedList(let task): model.lists.first { $0.id == task.listId }?.folderId
    case .filterList: nil
    }
  }

  func canMove(by offset: Int) -> Bool {
    switch target {
    case .filterList(let filter):
      guard let index = model.filterLists.firstIndex(of: filter) else { return false }
      return model.filterLists.indices.contains(index + offset)
    case .list(let list):
      return !list.isSystemList
    case .folder, .nestedList:
      return true
    }
  }

  func move(by offset: Int) {
    switch target {
    case .list(let list): model.moveListWithinFolder(list, by: offset)
    case .folder(let folder): model.moveFolderWithinSiblings(folder, by: offset)
    case .nestedList(let task): model.moveTaskWithinSiblings(task, by: offset)
    case .filterList(let filter):
      if let index = model.filterLists.firstIndex(of: filter) { model.moveFilterList(filter, to: index + offset) }
    }
  }

  var items: [HouseMenuItem] = []
  items.append(houseMenuItem("New List", command: .listNew, on: .sidebar) {
    model.beginSidebarDraft(.list, in: creationFolderID)
  })
  items.append(houseMenuItem("New Folder", command: .folderNew, on: .sidebar) {
    model.beginSidebarDraft(.folder, in: creationFolderID)
  })
  items.append(houseMenuDivider())

  switch target {
  case .list(let list):
    items.append(houseMenuItem("Rename", command: .listRename, on: .sidebar) {
      model.beginRenaming(.list(list))
    })
  case .folder(let folder):
    items.append(houseMenuItem("Rename", command: .listRename, on: .sidebar) {
      model.beginRenaming(.folder(folder))
    })
  case .nestedList(let task):
    items.append(houseMenuItem("Rename…", command: .listRename, on: .sidebar) {
      model.presentOverlay(.quickEdit(WorkspaceTaskQuickEditRequest(task: task, kind: .title)))
    })
  case .filterList(let filter):
    items.append(houseMenuItem("Rename…") {
      model.requestEditFilterList(filter)
    })
  }

  items.append(houseMenuItem("Icon…", command: .listIcon, on: .sidebar) {
    model.iconPickerRowID = rowID
  })

  switch target {
  case .list(let list):
    items.append(houseMenuItem("List Settings…", command: .listSettings, on: .sidebar) {
      model.showSettings(for: list)
    })
  case .folder(let folder):
    items.append(houseMenuItem("Folder Settings…", command: .listSettings, on: .sidebar) {
      model.showSettings(for: folder)
    })
  case .filterList(let filter):
    items.append(houseMenuItem("Edit Filter List…", command: .filterListEdit, on: .sidebar) {
      model.requestEditFilterList(filter)
    })
  case .nestedList:
    break
  }

  items.append(houseMenuItem("Move Up", command: .listMoveUp, on: .sidebar, disabled: !canMove(by: -1)) {
    move(by: -1)
  })
  items.append(houseMenuItem("Move Down", command: .listMoveDown, on: .sidebar, disabled: !canMove(by: 1)) {
    move(by: 1)
  })
  items.append(houseMenuDivider())

  switch target {
  case .list(let list):
    items.append(houseMenuItem("New Nested List…") {
      model.selectList(list.id)
      model.requestNestedListCreation()
    })
    if !list.isSystemList {
      items.append(houseMenuItem("Convert to Task in Inbox") { model.convertListToTask(list) })
      items.append(houseMenuItem(list.completedAt == nil ? "Complete List" : "Reopen List") { model.toggleListCompletion(list) })
    }
  case .nestedList(let task):
    items.append(houseMenuItem("Open List") { model.openItemList(task) })
    items.append(houseMenuItem("Convert to Task") { model.convertItem(task) })
    items.append(houseMenuItem("Move to List or Folder…") { model.requestMove(task) })
    items.append(houseMenuItem("New Nested List…") { model.requestNestedListCreation(under: task) })
    items.append(houseMenuItem("Move to Top Level") { model.moveDroppedItem(task.id, toFolderID: nil) })
    items.append(houseMenuItem(task.isPromoted == true ? "Unpin from Sidebar" : "Pin to Sidebar", command: .taskPromoteList, on: .sidebar) { model.toggleListPromotion(task) })
    items.append(houseMenuItem(task.status == .open ? "Complete List" : "Reopen List") { model.toggleTask(task) })
  case .filterList:
    items.append(houseMenuItem("New Filter List…") { model.requestNewFilterList() })
  case .folder:
    break
  }

  switch target {
  case .list(let list) where !list.isSystemList:
    items.append(houseMenuItem("Archive", command: .listArchive, on: .sidebar) {
      model.archiveList(list)
    })
  case .nestedList(let task):
    items.append(houseMenuItem("Archive", command: .listArchive, on: .sidebar) {
      model.archiveNestedList(task)
    })
  default:
    break
  }

  switch target {
  case .list(let list) where !list.isSystemList:
    items.append(houseMenuItem("Delete", command: .listDelete, on: .sidebar, role: .destructive) {
      model.requestDeletion(of: .list(list))
    })
  case .folder(let folder):
    items.append(houseMenuItem("Delete", command: .listDelete, on: .sidebar, role: .destructive) {
      model.requestDeletion(of: .folder(folder))
    })
  case .nestedList(let task):
    items.append(houseMenuItem("Delete", command: .listDelete, on: .sidebar, role: .destructive) {
      model.requestTaskDeletion(task)
    })
  case .filterList(let filter):
    items.append(houseMenuItem("Delete", command: .listDelete, on: .sidebar, role: .destructive) {
      model.deleteFilterList(filter)
    })
  default:
    break
  }

  items.append(houseMenuDivider())
  items.append(houseMenuItem("Expand All", command: .folderExpandAll, on: .sidebar) {
    model.setAllFoldersExpanded(true)
  })
  items.append(houseMenuItem("Collapse All", command: .folderCollapseAll, on: .sidebar) {
    model.setAllFoldersExpanded(false)
  })

  return items
}

@MainActor
func makeBoardColumnContextMenu(column: WorkspaceKanbanColumn, model: WorkspaceViewModel) -> [HouseMenuItem] {
  var items: [HouseMenuItem] = []
  items.append(houseMenuItem("Rename Column…") {
    model.requestRenameBoardColumn(column)
  })
  items.append(houseMenuItem("Move Left", disabled: !model.canMoveKanbanColumn(column.id, by: -1)) {
    model.moveKanbanColumn(column.id, by: -1)
  })
  items.append(houseMenuItem("Move Right", disabled: !model.canMoveKanbanColumn(column.id, by: 1)) {
    model.moveKanbanColumn(column.id, by: 1)
  })
  items.append(houseMenuItem("Add Column to the Left…", command: .planBoardAddColumnLeft, on: .board) {
    model.requestNewBoardColumn(beside: column.id, after: false)
  })
  items.append(houseMenuItem("Add Column to the Right…", command: .planBoardAddColumnRight, on: .board) {
    model.requestNewBoardColumn(beside: column.id, after: true)
  })
  items.append(houseMenuDivider())
  items.append(houseMenuItem("Make These the Default Columns", command: .planBoardMakeDefaultColumns, on: .board) {
    model.makeBoardColumnsDefault()
  })
  items.append(houseMenuItem("Reset to Default Columns", command: .planBoardResetColumns, on: .board, disabled: model.boardColumnSource != .own) {
    model.resetBoardColumnsToDefault()
  })
  items.append(houseMenuDivider())
  let isEmpty = model.tasks(in: column).isEmpty
  items.append(houseMenuItem(isEmpty ? "Delete Column" : "Delete Column…", command: .planBoardRemoveColumn, on: .board, role: .destructive, disabled: model.editableBoardColumns.count <= 1) {
    model.requestDeleteBoardColumn(column)
  })
  return items
}

@MainActor
func makePaneContextMenu(surface: WorkspaceCommandSurface, column: WorkspaceKanbanColumn?, model: WorkspaceViewModel) -> [HouseMenuItem] {
  var items: [HouseMenuItem] = []
  items.append(houseMenuItem(column.map { "New Task in \($0.title)" } ?? "New Task", command: .taskNew, on: surface) {
    if let column {
      model.focusedBoardColumnID = column.id
      model.selectedTaskID = nil
    }
    model.run(.taskNew)
  })
  if surface == .board {
    items.append(houseMenuItem("New Column…", command: .planBoardNewColumn, on: .board) {
      model.requestNewBoardColumn(beside: column?.id, after: true)
    })
  }
  items.append(houseMenuDivider())
  items.append(houseMenuItem("Today", command: .goToday, on: surface, disabled: model.viewMode == .today) {
    model.run(.goToday)
  })
  items.append(houseMenuItem("Board", command: .goBoard, on: surface, disabled: model.viewMode == .board) {
    model.run(.goBoard)
  })
  items.append(houseMenuItem("Outline", command: .goOutline, on: surface, disabled: model.viewMode == .outline) {
    model.run(.goOutline)
  })
  return items
}
