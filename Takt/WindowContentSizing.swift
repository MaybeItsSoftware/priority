import AppKit

/// Converts a SwiftUI root's minimum *content* size into the window's `minSize`,
/// which is a *frame* measurement, and grows the window if an autosaved frame
/// came back smaller than that.
///
/// These are two different quantities and conflating them is a real bug, not a
/// rounding error: the Preferences window once set `minSize` to the content
/// minimum while the frame also carried a 28pt titlebar and a 52pt
/// preference-style toolbar. A restored frame of 720x612 left only 532pt of
/// content for a view that cannot shrink below 560, and SwiftUI overflowed and
/// clipped — which is what cut the plugin sidebar's button bar off the bottom.
/// `minSize` also does nothing on a window without `.resizable` in its mask, so
/// nothing enforced it at all.
enum WindowContentSizing {

  /// - Parameters:
  ///   - minContentSize: what the SwiftUI root's `.frame(minWidth:minHeight:)` asks for.
  ///   - maxContentSize: `nil` for a window that may grow to fill the screen.
  static func enforce(
    on window: NSWindow,
    minContentSize: NSSize,
    maxContentSize: NSSize?
  ) {
    // Measured rather than hardcoded: the toolbar style, and therefore the
    // chrome height, is not ours to predict across OS versions.
    let chrome = window.frame.height - window.contentLayoutRect.height
    guard chrome >= 0 else { return }

    window.minSize = NSSize(
      width: minContentSize.width,
      height: minContentSize.height + chrome
    )
    if let maxContentSize {
      window.maxSize = NSSize(
        width: maxContentSize.width,
        height: maxContentSize.height + chrome
      )
    }

    var frame = window.frame
    frame.size.width = max(frame.width, window.minSize.width)
    frame.size.height = max(frame.height, window.minSize.height)
    if frame.size != window.frame.size {
      // Keep the top-left pin so the window grows downward rather than
      // appearing to jump when a stale small frame is corrected.
      frame.origin.y = window.frame.maxY - frame.height
      window.setFrame(frame, display: false)
    }
  }
}
