import Foundation

public struct RemoteKeyBootstrapState: Equatable {
  public var remoteKey: String
  public var hasAttemptedBootstrap: Bool

  public init(
    remoteKey: String,
    hasAttemptedBootstrap: Bool
  ) {
  self.remoteKey = remoteKey
  self.hasAttemptedBootstrap = hasAttemptedBootstrap
  }
}

public enum RemoteKeyBootstrapPolicy {
  public static func bootstrap(
    state: RemoteKeyBootstrapState,
    usesKeychainStorage: Bool,
    loadFromKeychain: () -> String?
  ) -> RemoteKeyBootstrapState {
    guard usesKeychainStorage else { return state }
    let normalizedCurrent = state.remoteKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalizedCurrent.isEmpty, !state.hasAttemptedBootstrap else { return state }

    let loaded = loadFromKeychain()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return RemoteKeyBootstrapState(
      remoteKey: loaded.isEmpty ? state.remoteKey : loaded,
      hasAttemptedBootstrap: true
    )
  }
}
