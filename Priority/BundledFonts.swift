import CoreText
import Foundation
import OSLog

/// The faces Priority ships: IBM Plex Sans for the interface and Lilex for
/// code and numerals — the pair Zed ships as `.ZedSans` and `.ZedMono`. Both
/// are SIL OFL; the licences sit beside the files in `Priority/Fonts/`.
///
/// They are registered for this process only, rather than listed under
/// `ATSApplicationFontsPath`, so that the Info.plist can stay generated and a
/// face that fails to load is a line in the log rather than a silent miss.
/// Registration has to happen before the first view resolves a font:
/// `Theme.font` checks what is installed at the moment it is asked, and a view
/// built before this ran would be set in the fallback design until it redrew.
enum BundledFonts {
  private static let logger = Logger(subsystem: "uk.co.maybeitssoftware.takt", category: "BundledFonts")

  /// Registers every `.ttf` in the app bundle. Idempotent: a face that is
  /// already registered reports `alreadyRegistered`, which is not a failure.
  static func register(bundle: Bundle = .main) {
    // The synchronized group copies `Priority/Fonts/` flat into Resources;
    // the subdirectory is checked too so a later switch to a folder reference
    // does not quietly drop the fonts.
    let urls =
      (bundle.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
      + (bundle.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
    guard !urls.isEmpty else {
      logger.error("No bundled fonts found; the theme will fall back to system faces")
      return
    }
    for url in urls {
      var error: Unmanaged<CFError>?
      guard !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) else { continue }
      let failure = error?.takeRetainedValue()
      if let failure, CFErrorGetCode(failure) == CTFontManagerError.alreadyRegistered.rawValue {
        continue
      }
      let reason = failure.map { String(describing: $0) } ?? "unknown error"
      logger.error(
        "Could not register \(url.lastPathComponent, privacy: .public): \(reason, privacy: .public)")
    }
  }
}
