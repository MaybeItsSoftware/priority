import CoreGraphics
import Foundation

/// Decides where a restored window frame may actually go.
///
/// AppKit restores an autosaved frame verbatim, including one saved on a
/// monitor that has since been unplugged — and a window whose title bar is on
/// no screen cannot be dragged back, so the only way out was deleting the
/// preference. Kept free of AppKit so the geometry is testable: callers pass
/// `NSScreen.visibleFrame`s (bottom-left origin, y up), main screen first.
public enum WindowFrameClamp {

  /// Height of the strip along the top of the frame that has to be on a
  /// screen. It is where the window is grabbed to move it, so a frame whose
  /// body is visible but whose title bar is not is still stranded.
  public static let titleBarHeight: CGFloat = 28

  /// How much of the title bar has to be on a screen for the frame to count
  /// as reachable — enough to aim a pointer at, not a sliver at the edge.
  public static let minimumReachableWidth: CGFloat = 100

  /// Returns a frame that fits on one of `visibleFrames`.
  ///
  /// A frame whose title bar is meaningfully on some screen stays on that
  /// screen, shrunk to fit and nudged inside it, so a window the user put
  /// somewhere is only moved as far as it has to be. Anything else goes to
  /// the first (main) screen, shrunk to fit and centred. `minSize` wins over
  /// the screen: a window is never made smaller than its content allows, and
  /// when it overflows its top-left corner is what stays visible.
  public static func clamp(
    _ frame: CGRect,
    visibleFrames: [CGRect],
    minSize: CGSize = .zero
  ) -> CGRect {
    let screens = visibleFrames.filter { !$0.isEmpty }
    guard let main = screens.first else { return frame }

    let titleStrip = CGRect(
      x: frame.minX,
      y: frame.maxY - min(titleBarHeight, frame.height),
      width: frame.width,
      height: min(titleBarHeight, frame.height)
    )
    var host: CGRect?
    var bestArea: CGFloat = 0
    for screen in screens {
      let overlap = titleStrip.intersection(screen)
      guard !overlap.isNull, overlap.width >= minimumReachableWidth, overlap.height > 0 else { continue }
      let area = overlap.width * overlap.height
      if area > bestArea {
        bestArea = area
        host = screen
      }
    }

    if let host {
      return nudge(frame, into: host, minSize: minSize)
    }
    let size = fittedSize(frame.size, in: main, minSize: minSize)
    let centred = CGRect(
      x: main.midX - size.width / 2,
      y: main.midY - size.height / 2,
      width: size.width,
      height: size.height
    )
    // Centring an oversized frame would push its title bar off the top.
    return nudge(centred, into: main, minSize: minSize)
  }

  private static func fittedSize(_ size: CGSize, in screen: CGRect, minSize: CGSize) -> CGSize {
    CGSize(
      width: max(min(size.width, screen.width), minSize.width),
      height: max(min(size.height, screen.height), minSize.height)
    )
  }

  /// Shrinks `frame` to `screen` and moves it the least distance that puts it
  /// inside. When it still cannot fit, the left edge and the top — the title
  /// bar — are the parts kept on screen.
  private static func nudge(_ frame: CGRect, into screen: CGRect, minSize: CGSize) -> CGRect {
    let size = fittedSize(frame.size, in: screen, minSize: minSize)
    // Shrinking keeps the top-left pinned, the way a window resizes.
    var x = frame.minX
    var y = frame.maxY - size.height
    x = max(min(x, screen.maxX - size.width), screen.minX)
    y = min(max(y, screen.minY), screen.maxY - size.height)
    return CGRect(x: x, y: y, width: size.width, height: size.height)
  }
}
