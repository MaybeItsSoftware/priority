import Foundation

/// Error surfaced by the Checkvist session layer (login, refresh, request
/// auth). Extracted from `CheckvistSession.swift` so the type can be shared
/// with `TaktPlugins` / `TaktAppLogic` without the rest of the
/// session machinery.
enum CheckvistSessionError: LocalizedError {
  case authenticationUnavailable
  case invalidResponse(statusCode: Int?)
  case requestFailed(underlying: Error)

  var errorDescription: String? {
    switch self {
    case .authenticationUnavailable:
      return "Authentication unavailable — check your username and remote key."
    case .invalidResponse(let statusCode):
      if let code = statusCode {
        return "Unexpected response from Checkvist (HTTP \(code))."
      }
      return "Invalid response from Checkvist."
    case .requestFailed(let underlying):
      return "Could not reach Checkvist (\(underlying.localizedDescription))"
    }
  }
}
