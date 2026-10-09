import XCTest

@testable import TaktCore

/// What a render of the sidebar cost before the app memoised its rows: every
/// row's background asked whether it was the cursor's, and each asking built
/// the whole outline again. Printed so the figures are in the test log.
final class WorkspaceSidebarOutlineCostTests: XCTestCase {
  func testBuildingTheOutlineOncePerRenderBeatsOncePerRow() {
    let folders = (0..<8).map { SidebarFolderDescriptor(id: "f\($0)", parentFolderID: nil) }
    let lists = (0..<60).map { SidebarListDescriptor(id: "l\($0)", folderID: "f\($0 % 8)") }
    let nested = (0..<60).map {
      SidebarNestedListDescriptor(id: "n\($0)", listID: "l\($0)", depth: 0, isPromoted: $0 % 10 == 0)
    }
    func build() -> [WorkspaceSidebarRow] {
      WorkspaceSidebarOutline.rows(
        inbox: SidebarListDescriptor(id: "inbox", folderID: nil), lists: lists, folders: folders,
        nestedLists: nested, expandedFolderIDs: Set(folders.map(\.id)))
    }
    let rowCount = build().count

    let perRow = Self.seconds { for _ in 0..<rowCount { _ = build().first { $0.id == "n59" } } }
    let rows = build()
    let once = Self.seconds { for _ in 0..<rowCount { _ = rows.first { $0.id == "n59" } } }
    print(String(
      format: "Sidebar render, %d rows: outline per row %.3f ms, outline once %.3f ms",
      rowCount, perRow * 1000, once * 1000))
    XCTAssertLessThan(once, perRow)
  }

  private static func seconds(_ work: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    work()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
  }
}
