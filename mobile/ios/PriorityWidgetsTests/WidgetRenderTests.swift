import SwiftUI
import WidgetKit
import XCTest

/// Renders the widgets and the Live Activity's lock-screen view off the same
/// sources the extension builds, with the sample snapshot, so a broken layout
/// shows up as a failure rather than on someone's home screen. When
/// `/tmp/iosshots` exists the images are left there for review.
@MainActor
final class WidgetRenderTests: XCTestCase {
  func testTheNextUpWidgetRendersInEachHomeScreenSize() throws {
    for (family, size) in [
      (WidgetFamily.systemSmall, CGSize(width: 170, height: 170)),
      (.systemMedium, CGSize(width: 364, height: 170)),
      (.systemLarge, CGSize(width: 364, height: 382)),
    ] {
      let view = NextUpWidgetView(snapshot: .sample, familyOverride: family).padding(16)
      try render(view, size: size, name: "widget-nextup-\(family)")
    }
  }

  func testTheTodayCountWidgetRenders() throws {
    try render(
      TodayCountView(snapshot: .sample).padding(16),
      size: CGSize(width: 170, height: 170), name: "widget-today")
  }

  func testTheLiveActivityLockScreenViewRendersRunningAndPaused() throws {
    for paused in [false, true] {
      let state = FocusActivityAttributes.ContentState(
        taskID: "1", taskTitle: "Polish the outline rows", timerStart: .now.addingTimeInterval(-754),
        isPaused: paused, elapsedSeconds: 754, plannedSeconds: 1_500)
      try render(LockScreenFocusView(state: state), size: CGSize(width: 364, height: 160),
                 name: paused ? "liveactivity-paused" : "liveactivity-running")
    }
  }

  private func render(_ view: some View, size: CGSize, name: String) throws {
    let framed = view
      .frame(width: size.width, height: size.height)
      .background(ChalkColors.paper)
      .clipShape(RoundedRectangle(cornerRadius: 22))
    let renderer = ImageRenderer(content: framed)
    renderer.scale = 3
    let image = try XCTUnwrap(renderer.uiImage, name)
    XCTAssertEqual(image.size.width, size.width, accuracy: 1, name)
    let data = try XCTUnwrap(image.pngData())
    XCTAssertGreaterThan(data.count, 2_000, "\(name) drew something")
    let directory = URL(filePath: "/tmp/iosshots")
    if FileManager.default.fileExists(atPath: directory.path) {
      try data.write(to: directory.appending(path: "\(name).png"))
    }
  }
}
