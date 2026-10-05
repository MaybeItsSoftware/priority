import TaktCore
import SwiftUI

/// The sign-in controls, shown identically by every Google integration's
/// settings page.
///
/// It is one view rather than a copy per plugin because it edits one thing:
/// whichever page you sign in from, the other one is signed in too, and a
/// second set of controls that looked independent would say otherwise.
struct GoogleAccountSettingsSection: View {
  @Environment(\.theme) private var theme
  var account: GoogleAccount
  /// The integration asking — named in the "sign in again" message, since a
  /// grant made before this integration existed is the one failure the user
  /// cannot otherwise diagnose.
  var serviceName: String
  var requiredScopes: Set<String>

  @State private var signInError: String?

  var body: some View {
    @Bindable var account = account
    VStack(alignment: .leading, spacing: 10) {
      Text("Google account")
        .font(theme.bodyFont(size: theme.scale.caption, weight: .medium))

      Text("OAuth Client ID (Desktop app)")
      TextField(
        "",
        text: $account.clientID,
        prompt: Text("1234567890-abc123.apps.googleusercontent.com")
      )
      .themedTextField()
      .labelsHidden()
      .autocorrectionDisabled()

      HStack(spacing: 8) {
        Button(account.isAuthenticated ? "Re-authenticate" : "Sign in with Google") {
          Task { await signIn() }
        }
        .disabled(account.isAuthenticating || !account.hasClientConfiguration)

        Button("Sign out") {
          account.disconnect()
          signInError = nil
        }
        .disabled(account.isAuthenticating || !account.isAuthenticated)

        Spacer()
        if account.isAuthenticating { ProgressView().scaleEffect(0.8) }
      }

      Text(statusLine)
        .font(theme.captionFont)
        .foregroundStyle(account.hasGrantedScopes(requiredScopes) ? theme.success : theme.muted)

      if let signInError, !signInError.isEmpty {
        Text(signInError)
          .font(theme.captionFont)
          .foregroundStyle(theme.danger)
      }

      Text("One sign-in covers every Google integration. Enabling another one later needs a fresh sign-in so Google can grant the extra access.")
        .font(theme.captionFont)
        .foregroundStyle(theme.muted)
    }
    // Here rather than in the body: reading the keychain publishes observable
    // changes, and a view update is not allowed to cause those.
    .task { account.prepare() }
  }

  private var statusLine: String {
    if account.hasGrantedScopes(requiredScopes) {
      return "Signed in, with access to \(serviceName)."
    }
    if account.isAuthenticated {
      return "Signed in, but this grant predates \(serviceName). Sign in again."
    }
    return account.statusDescription
  }

  @MainActor
  private func signIn() async {
    signInError = nil
    do {
      try await account.beginAuthentication()
    } catch {
      signInError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
  }
}
