import Foundation

/// Why a workspace task could not be put on Google Calendar. Lives with the
/// plugin rather than in `IntegrationCoordinator`, which only throws it.
enum WorkspaceGoogleCalendarError: LocalizedError {
  case integrationDisabled

  var errorDescription: String? {
    "Enable Google Calendar in Preferences → Integrations first."
  }
}
