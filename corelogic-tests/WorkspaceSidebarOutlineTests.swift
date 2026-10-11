import XCTest

@testable import TaktCore

/// The sidebar's order, and the cursor that walks it.
final class WorkspaceSidebarOutlineTests: XCTestCase {

  private func outline(
    inbox: SidebarListDescriptor? = SidebarListDescriptor(id: "inbox", folderID: nil),
    lists: [SidebarListDescriptor] = [],
    folders: [SidebarFolderDescriptor] = [],
    nested: [SidebarNestedListDescriptor] = [],
    expanded: Set<String> = []
  ) -> [WorkspaceSidebarRow] {
    WorkspaceSidebarOutline.rows(
      inbox: inbox, lists: lists, folders: folders,
      nestedLists: nested, expandedFolderIDs: expanded)
  }

  /// Focus and the timeline live in the mode strip, not here: the sidebar
  /// opens on Everything.
  func testTodayComesFirst() {
    let rows = outline()
    XCTAssertEqual(rows.first?.kind, .today)
    XCTAssertFalse(rows.contains { $0.id == "row:focus" || $0.id == "row:timeline" })
  }

  func testTheOrderIsInboxThenPinnedThenFoldersThenLooseLists() {
    let rows = outline(
      lists: [
        SidebarListDescriptor(id: "loose", folderID: nil),
        SidebarListDescriptor(id: "filed", folderID: "work"),
      ],
      folders: [SidebarFolderDescriptor(id: "work", parentFolderID: nil)],
      nested: [SidebarNestedListDescriptor(id: "pin", listID: "inbox", depth: 0, isPromoted: true)],
      expanded: ["work"])
    XCTAssertEqual(
      rows.map(\.kind),
      [
        .today,
        .everything,
        .list("inbox"), .nestedList("pin"),
        .nestedList("pin"),
        .folder("work"), .list("filed"),
        .list("loose"),
      ])
  }

  /// Filter lists sit under the stock three — Today, Everything and the
  /// inbox with its nested lists — ahead of the pinned shortcuts, and the
  /// cursor finds the one in scope.
  func testFilterListsFollowTheInboxAndTheCursorFindsTheOneInScope() {
    let rows = WorkspaceSidebarOutline.rows(
      inbox: SidebarListDescriptor(id: "inbox", folderID: nil),
      lists: [SidebarListDescriptor(id: "loose", folderID: nil)], folders: [],
      nestedLists: [SidebarNestedListDescriptor(id: "pin", listID: "inbox", depth: 0, isPromoted: true)],
      expandedFolderIDs: [], filterListIDs: ["soon", "work"])
    XCTAssertEqual(
      rows.map(\.kind),
      [
        .today, .everything, .list("inbox"), .nestedList("pin"),
        .filterList("soon"), .filterList("work"),
        .nestedList("pin"), .list("loose"),
      ])
    XCTAssertEqual(rows.first { $0.kind == .filterList("work") }?.id, "filter:work")
    XCTAssertEqual(
      WorkspaceSidebarOutline.rowMatching(subjectID: nil, isEverything: true, filterListID: "work", in: rows)?.kind,
      .filterList("work"))
    XCTAssertEqual(
      WorkspaceSidebarOutline.row(after: "filter:soon", by: 1, in: rows)?.kind, .filterList("work"))
  }

  /// The bug this was written for. A pinned nested list is drawn twice, and
  /// both rows used to answer to the task's id, so the cursor could never get
  /// past the second one — looking up "where am I" always found the first.
  func testAPinnedListAppearsTwiceWithTwoDistinctRowIDs() {
    let rows = outline(
      nested: [SidebarNestedListDescriptor(id: "pin", listID: "inbox", depth: 0, isPromoted: true)])
    let pinned = rows.filter { $0.kind == .nestedList("pin") }
    XCTAssertEqual(pinned.count, 2, "drawn under its list and again as a shortcut")
    XCTAssertEqual(Set(pinned.map(\.id)).count, 2, "but they are two rows")
    XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "no row id repeats")
  }

  func testWalkingReachesEveryRowIncludingTheSecondCopy() {
    let rows = outline(
      nested: [SidebarNestedListDescriptor(id: "pin", listID: "inbox", depth: 0, isPromoted: true)])
    var visited: [String] = []
    var cursor = rows.first?.id
    while let id = cursor {
      visited.append(id)
      let next = WorkspaceSidebarOutline.row(after: id, by: 1, in: rows)
      // The cursor wraps, so the walk is over when it comes round again.
      cursor = next?.id == rows.first?.id ? nil : next?.id
    }
    XCTAssertEqual(visited, rows.map(\.id))
  }

  /// The sidebar draws this outline as one flat run keyed by row id, so the
  /// ids have to be unique, and a list's depth has to come from where it is
  /// now. The bug behind the flat drawing: Habits, moved into "Life admin"
  /// from the top level, drew at the top level's indent in the folder,
  /// with the list after it looking nested in it.
  func testEveryListInAFolderIsOneLevelInWhateverItHolds() {
    let rows = outline(
      lists: [
        SidebarListDescriptor(id: "errands", folderID: "life"),
        SidebarListDescriptor(id: "coding", folderID: "life"),
        SidebarListDescriptor(id: "habits", folderID: "life"),
        SidebarListDescriptor(id: "aspirations", folderID: "life"),
        SidebarListDescriptor(id: "loose", folderID: nil),
      ],
      folders: [SidebarFolderDescriptor(id: "life", parentFolderID: nil)],
      nested: [SidebarNestedListDescriptor(id: "sub", listID: "habits", depth: 0, isPromoted: false)],
      expanded: ["life"])
    XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "row ids are unique")
    let depths = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.depth) })
    XCTAssertEqual(depths["folder:life"], 0)
    for id in ["errands", "coding", "habits", "aspirations"] {
      XCTAssertEqual(depths["list:\(id)"], 1, id)
    }
    XCTAssertEqual(depths["nested:habits:sub"], 2)
    XCTAssertEqual(depths["list:loose"], 0)
    XCTAssertEqual(
      rows.map(\.id).drop { $0 != "folder:life" }.prefix(6),
      ["folder:life", "list:errands", "list:coding", "list:habits", "nested:habits:sub", "list:aspirations"])
  }

  /// Where `%` and `d` draw the name field: the end of the group the store
  /// will put the new list or folder at.
  func testANewListOrFolderIsNamedWhereItWillAppear() {
    let rows = outline(
      lists: [
        SidebarListDescriptor(id: "a", folderID: "work"),
        SidebarListDescriptor(id: "b", folderID: "work"),
        SidebarListDescriptor(id: "c", folderID: "clients"),
        SidebarListDescriptor(id: "loose", folderID: nil),
      ],
      folders: [
        SidebarFolderDescriptor(id: "work", parentFolderID: nil),
        SidebarFolderDescriptor(id: "clients", parentFolderID: "work"),
      ],
      nested: [SidebarNestedListDescriptor(id: "sub", listID: "b", depth: 0, isPromoted: false)],
      expanded: ["work", "clients"])
    func point(_ isFolder: Bool, _ folderID: String?) -> (String?, Int) {
      let found = WorkspaceSidebarOutline.insertionPoint(
        isFolder: isFolder, inFolder: folderID, inboxID: "inbox", in: rows)
      return (found.index < rows.count ? rows[found.index].id : nil, found.depth)
    }
    // A list in "work": after b and its nested list, before the sub-folder.
    XCTAssertEqual(point(false, "work").0, "folder:clients")
    XCTAssertEqual(point(false, "work").1, 1)
    // A sub-folder of "work": after everything it holds.
    XCTAssertEqual(point(true, "work").0, "list:loose")
    XCTAssertEqual(point(true, "clients").1, 2)
    // A top-level folder: after the last folder, before the loose lists.
    XCTAssertEqual(point(true, nil).0, "list:loose")
    XCTAssertEqual(point(true, nil).1, 0)
    // A top-level list: at the very end.
    XCTAssertNil(point(false, nil).0)
    XCTAssertEqual(point(false, nil).1, 0)
  }

  func testACollapsedFolderHidesItsContents() {
    let lists = [SidebarListDescriptor(id: "filed", folderID: "work")]
    let folders = [SidebarFolderDescriptor(id: "work", parentFolderID: nil)]
    let collapsed = outline(lists: lists, folders: folders, expanded: [])
    XCTAssertFalse(collapsed.contains { $0.kind == .list("filed") })
    let expanded = outline(lists: lists, folders: folders, expanded: ["work"])
    XCTAssertTrue(expanded.contains { $0.kind == .list("filed") })
  }

  func testNestingIsReportedAsDepth() {
    let rows = outline(
      inbox: nil,
      lists: [SidebarListDescriptor(id: "filed", folderID: "inner")],
      folders: [
        SidebarFolderDescriptor(id: "outer", parentFolderID: nil),
        SidebarFolderDescriptor(id: "inner", parentFolderID: "outer"),
      ],
      nested: [SidebarNestedListDescriptor(id: "deep", listID: "filed", depth: 1, isPromoted: false)],
      expanded: ["outer", "inner"])
    func depth(_ kind: WorkspaceSidebarRowKind) -> Int? {
      rows.first { $0.kind == kind }?.depth
    }
    XCTAssertEqual(depth(.folder("outer")), 0)
    XCTAssertEqual(depth(.folder("inner")), 1)
    XCTAssertEqual(depth(.list("filed")), 2)
    XCTAssertEqual(depth(.nestedList("deep")), 4)
  }

  /// A cycle in the folder parentage must not hang the sidebar.
  func testAFolderCycleTerminates() {
    let rows = outline(
      inbox: nil,
      folders: [
        SidebarFolderDescriptor(id: "a", parentFolderID: "b"),
        SidebarFolderDescriptor(id: "b", parentFolderID: "a"),
      ],
      expanded: ["a", "b"])
    XCTAssertEqual(rows.map(\.kind), [.today, .everything])
  }

  func testTheCursorWrapsAroundEitherEnd() {
    let rows = outline()
    let first = rows[0].id
    let last = rows[rows.count - 1].id
    XCTAssertEqual(WorkspaceSidebarOutline.row(after: first, by: -1, in: rows)?.id, last)
    XCTAssertEqual(WorkspaceSidebarOutline.row(after: last, by: 1, in: rows)?.id, first)
  }

  func testAnUnknownCursorStartsFromTheNearEnd() {
    let rows = outline()
    XCTAssertEqual(WorkspaceSidebarOutline.row(after: nil, by: 1, in: rows)?.id, rows.first?.id)
    XCTAssertEqual(WorkspaceSidebarOutline.row(after: nil, by: -1, in: rows)?.id, rows.last?.id)
  }

  /// A click selects a list without touching the cursor, so the cursor has to
  /// be recoverable from the selection alone.
  func testTheRowIsRecoverableFromWhatIsSelected() {
    let rows = outline(lists: [SidebarListDescriptor(id: "loose", folderID: nil)])
    XCTAssertEqual(
      WorkspaceSidebarOutline.rowMatching(subjectID: "loose", isEverything: false, in: rows)?.kind,
      .list("loose"))
    XCTAssertEqual(
      WorkspaceSidebarOutline.rowMatching(subjectID: nil, isEverything: true, in: rows)?.kind,
      .everything)
    XCTAssertNil(
      WorkspaceSidebarOutline.rowMatching(subjectID: "gone", isEverything: false, in: rows))
  }
}

/// Which lists a folder stands for.
final class WorkspaceFolderScopeTests: XCTestCase {
  private func folder(_ id: String, in parent: String? = nil) -> SidebarFolderDescriptor {
    SidebarFolderDescriptor(id: id, parentFolderID: parent)
  }

  private func list(_ id: String, in folder: String?) -> SidebarListDescriptor {
    SidebarListDescriptor(id: id, folderID: folder)
  }

  func testAFolderStandsForItsOwnLists() {
    let ids = WorkspaceSidebarOutline.listIDs(
      inFolder: "work",
      folders: [folder("work")],
      lists: [list("a", in: "work"), list("b", in: "work"), list("loose", in: nil)])
    XCTAssertEqual(ids, ["a", "b"])
  }

  func testSubFolderListsAreIncludedEvenWhenCollapsed() {
    // Collapsing a folder hides rows; it does not move the lists out of it.
    let ids = WorkspaceSidebarOutline.listIDs(
      inFolder: "work",
      folders: [folder("work"), folder("clients", in: "work"), folder("deep", in: "clients")],
      lists: [list("a", in: "work"), list("b", in: "clients"), list("c", in: "deep")])
    XCTAssertEqual(ids, ["a", "b", "c"])
  }

  func testTheFoldersOwnListsComeFirst() {
    let ids = WorkspaceSidebarOutline.listIDs(
      inFolder: "work",
      folders: [folder("work"), folder("clients", in: "work")],
      lists: [list("nested", in: "clients"), list("own", in: "work")])
    XCTAssertEqual(ids.first, "own")
  }

  func testASiblingFolderIsNotIncluded() {
    let ids = WorkspaceSidebarOutline.listIDs(
      inFolder: "work",
      folders: [folder("work"), folder("home")],
      lists: [list("a", in: "work"), list("b", in: "home")])
    XCTAssertEqual(ids, ["a"])
  }

  func testAnEmptyFolderStandsForNothing() {
    XCTAssertTrue(WorkspaceSidebarOutline.listIDs(
      inFolder: "work", folders: [folder("work")], lists: []).isEmpty)
  }

  func testACycleInTheParentChainTerminates() {
    let ids = WorkspaceSidebarOutline.listIDs(
      inFolder: "a",
      folders: [folder("a", in: "b"), folder("b", in: "a")],
      lists: [list("one", in: "a"), list("two", in: "b")])
    XCTAssertEqual(Set(ids), ["one", "two"])
  }
}
