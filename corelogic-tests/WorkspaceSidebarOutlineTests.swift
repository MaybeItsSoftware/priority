import XCTest

@testable import PriorityCore

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
  func testEverythingComesFirst() {
    let rows = outline()
    XCTAssertEqual(rows.first?.kind, .everything)
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
        .everything,
        .list("inbox"), .nestedList("pin"),
        .nestedList("pin"),
        .folder("work"), .list("filed"),
        .list("loose"),
      ])
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
      cursor = next?.id == id ? nil : next?.id
    }
    XCTAssertEqual(visited, rows.map(\.id))
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
    XCTAssertEqual(rows.map(\.kind), [.everything])
  }

  func testTheCursorStopsAtEitherEndRatherThanWrapping() {
    let rows = outline()
    let first = rows[0].id
    let last = rows[rows.count - 1].id
    XCTAssertEqual(WorkspaceSidebarOutline.row(after: first, by: -1, in: rows)?.id, first)
    XCTAssertEqual(WorkspaceSidebarOutline.row(after: last, by: 1, in: rows)?.id, last)
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
