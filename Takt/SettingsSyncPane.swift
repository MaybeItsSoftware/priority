import TaktCore
import TaktSync
import SwiftUI

/// Signing this Mac in to sync, and the account once it is.
///
/// Signed out: Apple, Google, or an email and password, to sign in or make an
/// account. All three are Supabase accounts (`docs/sync.md`). Signed in: the
/// account, its devices, signing out and deleting the account. The server and
/// the Supabase project are Takt's unless "Use a different server" names a
/// self-hosted pair (`docs/self-hosting.md`).
///
/// Sign in with Apple goes through Supabase's web flow here rather than the
/// native sheet the iPhone uses: the native one needs the Sign in with Apple
/// entitlement, which needs a provisioning profile, and this app is signed
/// without one (see `Priority.release.entitlements`).
struct SettingsSyncPane: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  @State private var email = ""
  @State private var password = ""
  @State private var newPassword = ""
  /// "Use a different server": a sync server, and the Supabase project it
  /// trusts. Blank fields are Takt's own (`SyncEndpoints.resolve`).
  @State private var serverURL = ""
  @State private var supabaseURL = ""
  @State private var supabaseKey = ""
  @State private var usesOtherServer = false
  @State private var isWorking = false
  @State private var message: String?
  /// What "Forgot password?" or "Create account" sent, shown where an error
  /// would be.
  @State private var notice: String?
  @State private var isConfirmingDelete = false

  var body: some View {
    if let session = model.syncSession {
      if session.isSignedIn {
        signedIn(session)
      } else {
        signedOut(session)
      }
    } else {
      Section {
        Text("The workspace did not open, so there is nothing to sync.")
          .foregroundStyle(theme.muted)
      } header: {
        Text("Sync")
      }
    }
  }

  // MARK: - Signed out

  private func signedOut(_ session: SyncSession) -> some View {
    Section {
      if session.phase == .needsSignIn {
        Label("Signed out. Sign in again to keep syncing.", systemImage: "exclamationmark.icloud")
          .foregroundStyle(theme.danger)
      }
      Text(
        "Keep this Mac, your iPhone and your Android phone on one workspace. Every device keeps "
          + "a full copy and works offline; changes travel through the sync server."
      )
      .font(theme.captionFont)
      .foregroundStyle(theme.muted)

      // The providers and the email form are two rows, so the panel's
      // hairline divides them.
      HStack(spacing: theme.space.sm) {
        Button { signIn(session, with: .apple) } label: { SyncProviderButtonLabel(.apple, font: providerFont) }
          .buttonStyle(.plain)
        Button { signIn(session, with: .google) } label: { SyncProviderButtonLabel(.google, font: providerFont) }
          .buttonStyle(.plain)
      }
      .disabled(isWorking)
      .frame(maxWidth: 460)

      VStack(alignment: .leading, spacing: theme.space.sm) {
        field("Email") {
          TextField("", text: $email, prompt: Text("you@example.com"))
            .textContentType(.username)
            .themedTextField()
        }
        field("Password") {
          SecureField("", text: $password, prompt: Text("At least 8 characters"))
            .textContentType(.password)
            .themedTextField()
            .onSubmit { signIn(session) }
        }
        HStack(spacing: theme.space.sm) {
          Button("Sign in") { signIn(session) }
            .buttonStyle(FocusActionButtonStyle(prominent: true))
            .keyboardShortcut(.defaultAction)
            .disabled(isWorking || email.isEmpty || password.isEmpty)
          Button("Create account") { signUp(session) }
            .buttonStyle(FocusActionButtonStyle())
            .disabled(isWorking || email.isEmpty || password.isEmpty)
          if isWorking { ProgressView().controlSize(.small) }
          Spacer()
          Button("Forgot password?") { requestPasswordReset(session) }
            .buttonStyle(.plain)
            .font(theme.captionFont)
            .foregroundStyle(theme.muted)
            .help("Email a link that opens Takt on this Mac, signed in, to choose a new password.")
            .disabled(isWorking)
        }
      }

      DisclosureGroup("Use a different server", isExpanded: $usesOtherServer) {
        VStack(alignment: .leading, spacing: theme.space.sm) {
          field("Sync server") {
            TextField("", text: $serverURL, prompt: Text(SyncServer.defaultURL.absoluteString))
              .themedTextField()
          }
          field("Supabase URL") {
            TextField("", text: $supabaseURL, prompt: Text("https://<project>.supabase.co"))
              .themedTextField()
          }
          field("Supabase publishable key") {
            TextField("", text: $supabaseKey, prompt: Text("sb_publishable_…"))
              .font(theme.monoFont(size: theme.scale.caption))
              .themedTextField()
          }
          HStack(alignment: .firstTextBaseline, spacing: theme.space.sm) {
            Text(
              "For a server you run yourself, and the Supabase project it trusts for accounts. "
                + "Leave a field blank to use Takt's. Changing them signs this Mac out."
            )
            .font(theme.captionFont)
            .foregroundStyle(theme.muted)
            Spacer()
            Button("Check") { checkEndpoints() }
              .buttonStyle(FocusActionButtonStyle())
              .disabled(isWorking)
              .help("Ask the server's /health and the Supabase project whether they answer.")
          }
        }
        .padding(.top, theme.space.xs)
      }
      feedback(session)
    } header: {
      Text("Sync")
    }
    .onAppear { prefill(from: session) }
  }

  private var providerFont: Font { theme.bodyFont(weight: .medium) }

  private func field(_ title: String, @ViewBuilder control: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: theme.space.xs) {
      Text(title).foregroundStyle(theme.muted)
      control()
    }
  }

  private func signIn(_ session: SyncSession) {
    guard !email.isEmpty, !password.isEmpty, !isWorking else { return }
    run { [email, password] in
      try await session.use(try chosenEndpoints())
      try await session.signIn(email: email, password: password)
      self.password = ""
    }
  }

  private func signIn(_ session: SyncSession, with provider: SyncOAuthProvider) {
    guard !isWorking else { return }
    run {
      try await session.use(try chosenEndpoints())
      try await session.signIn(with: provider)
    }
  }

  private func signUp(_ session: SyncSession) {
    run { [email, password] in
      try await session.use(try chosenEndpoints())
      let outcome = try await session.signUp(email: email, password: password)
      self.password = ""
      if case .confirmEmail(let address) = outcome {
        notice = SyncSession.confirmEmailMessage(for: address)
      }
    }
  }

  /// Emails a reset link for the typed address.
  private func requestPasswordReset(_ session: SyncSession) {
    guard !isWorking else { return }
    run { [email] in
      try await session.use(try chosenEndpoints())
      let sent = try await session.requestPasswordReset(email: email)
      notice = SyncSession.passwordResetSentMessage(for: sent)
    }
  }

  /// Takt's own, unless the disclosure is open and names others.
  private func chosenEndpoints() throws -> SyncEndpoints {
    guard usesOtherServer else { return .hosted }
    return try SyncEndpoints.resolve(server: serverURL, supabaseURL: supabaseURL, supabaseKey: supabaseKey)
  }

  /// Checks the typed server and project without switching to them.
  private func checkEndpoints() {
    run {
      let endpoints = try chosenEndpoints()
      if !endpoints.isHosted {
        try await SyncEndpointCheck.check(endpoints)
      }
      notice = "Both answered. Sign in to use them."
    }
  }

  /// After a refused session, the same email; and the server in use.
  private func prefill(from session: SyncSession) {
    if email.isEmpty, let remembered = session.rememberedEmail { email = remembered }
    let endpoints = session.endpoints
    guard !endpoints.isHosted else { return }
    if endpoints.serverURL != SyncServer.defaultURL { serverURL = endpoints.serverURL.absoluteString }
    if !endpoints.usesHostedAccounts {
      supabaseURL = endpoints.supabaseURL.absoluteString
      supabaseKey = endpoints.supabaseKey
    }
    usesOtherServer = true
  }

  // MARK: - Signed in

  @ViewBuilder
  private func signedIn(_ session: SyncSession) -> some View {
    Section {
      LabeledContent("Signed in as") {
        Text(session.email ?? "an account without an email").textSelection(.enabled)
      }
      LabeledContent("Status") { SyncPhaseText(phase: session.phase) }
      if let server = session.credentials?.serverURL, server != SyncServer.defaultURL {
        LabeledContent("Server") {
          Text(server.absoluteString).font(theme.monoFont(size: theme.scale.caption)).foregroundStyle(theme.muted)
        }
      }
      if !session.endpoints.usesHostedAccounts {
        LabeledContent("Accounts") {
          Text(session.endpoints.supabaseURL.absoluteString)
            .font(theme.monoFont(size: theme.scale.caption))
            .foregroundStyle(theme.muted)
            .help("The Supabase project this server trusts. Sign out to change it.")
        }
      }
      HStack(spacing: theme.space.sm) {
        Button("Sync now") { run { await session.syncNow() } }
          .buttonStyle(FocusActionButtonStyle())
          .disabled(isWorking || session.phase == .syncing)
        Spacer()
        Button("Sign out") {
          run {
            await session.signOut()
            password = ""
          }
        }
        .buttonStyle(FocusActionButtonStyle())
        .disabled(isWorking)
      }
      feedback(session)
    } header: {
      Text("Sync")
    }
    .task(id: session.credentials?.accountId) {
      try? await session.refreshAccount()
    }

    if session.needsNewPassword {
      Section {
        HStack(spacing: theme.space.sm) {
          SecureField("", text: $newPassword, prompt: Text("New password"))
            .textContentType(.newPassword)
            .themedTextField()
            .onSubmit { setNewPassword(session) }
          Button("Save") { setNewPassword(session) }
            .buttonStyle(FocusActionButtonStyle(prominent: true))
            .disabled(isWorking || newPassword.isEmpty)
          Button("Not now") { session.skipNewPassword() }
            .buttonStyle(FocusActionButtonStyle())
        }
      } header: {
        Text("Choose a new password")
      } footer: {
        Text("You signed in from a password-reset email. Set the password to use from now on.")
      }
    }

    Section {
      if let devices = session.account?.devices {
        ForEach(devices) { device in deviceRow(device) }
      } else {
        Text("Loading…").foregroundStyle(theme.muted)
      }
    } header: {
      Text("Devices")
    }

    Section {
      HStack(alignment: .firstTextBaseline, spacing: theme.space.md) {
        Text(
          "Deleting the account removes everything synced to the server and signs out every device. "
            + "Each device keeps its own copy of the workspace."
        )
        .font(theme.captionFont)
        .foregroundStyle(theme.muted)
        Spacer()
        Button("Delete account…", role: .destructive) { isConfirmingDelete = true }
          .buttonStyle(FocusActionButtonStyle())
          .disabled(isWorking)
      }
    } header: {
      Text("Account")
    }
    .confirmationDialog("Delete your sync account?", isPresented: $isConfirmingDelete) {
      Button("Delete account", role: .destructive) {
        run { try await session.deleteAccount() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This deletes \(session.email ?? "this account") and everything synced to it, and signs out every device. "
          + "Each one keeps its own copy of the workspace, and this Mac keeps its tasks. It can't be undone."
      )
    }
  }

  private func setNewPassword(_ session: SyncSession) {
    guard !newPassword.isEmpty else { return }
    run { [newPassword] in
      try await session.setNewPassword(newPassword)
      self.newPassword = ""
      notice = "Password changed."
    }
  }

  private func deviceRow(_ device: SyncDevice) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: theme.space.sm) {
      VStack(alignment: .leading, spacing: theme.space.xxs) {
        Text(device.displayName)
        HStack(spacing: theme.space.xs) {
          Text(device.platformName)
          if let seen = device.lastSeenDate {
            Text("·")
            Text("seen \(seen, format: .relative(presentation: .named))")
          }
        }
        .font(theme.captionFont)
        .foregroundStyle(theme.muted)
      }
      Spacer()
      if device.current {
        Text("This Mac").font(theme.captionFont).foregroundStyle(theme.muted)
      }
    }
  }

  @ViewBuilder
  private func feedback(_ session: SyncSession) -> some View {
    if let problem = message ?? session.linkProblem {
      Text(problem)
        .font(theme.captionFont)
        .foregroundStyle(theme.danger)
    } else if let notice {
      Text(notice)
        .font(theme.captionFont)
        .foregroundStyle(theme.muted)
        .textSelection(.enabled)
    }
  }

  private func run(_ work: @escaping @MainActor () async throws -> Void) {
    isWorking = true
    message = nil
    notice = nil
    model.syncSession?.linkProblem = nil
    Task { @MainActor in
      defer { isWorking = false }
      do {
        try await work()
      } catch SyncError.cancelled {
        // Closing the sign-in window is an answer, not a failure.
      } catch {
        message = error.localizedDescription
      }
    }
  }
}

/// One line saying what sync is doing, shared by the pane and the status bar.
struct SyncPhaseText: View {
  let phase: SyncSession.Phase
  @Environment(\.theme) private var theme

  var body: some View {
    switch phase {
    case .unpaired:
      Text("Not signed in")
    case .needsSignIn:
      Label("Signed out — sign in again", systemImage: "exclamationmark.icloud")
        .foregroundStyle(theme.danger)
        .help("Your sync sign-in has ended on this Mac. Sign in again in Settings → Sync.")
    case .syncing:
      Label("Syncing", systemImage: "arrow.triangle.2.circlepath")
    case .failed(let reason):
      Label("Sync failed", systemImage: "exclamationmark.icloud")
        .foregroundStyle(theme.danger)
        .help(reason)
    case .idle(let last):
      if let last {
        Label(last.formatted(date: .omitted, time: .shortened), systemImage: "checkmark.icloud")
          .help("Last synced")
      } else {
        Label("Waiting", systemImage: "icloud")
      }
    }
  }
}
