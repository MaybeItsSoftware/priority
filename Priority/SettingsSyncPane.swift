import CoreImage.CIFilterBuiltins
import PriorityCore
import PrioritySync
import SwiftUI

/// Signing this Mac in to sync, and letting a phone join it.
///
/// Signed out: an email and password, to sign in or make an account, or a
/// code from a device already signed in. Signed in: the account, its devices,
/// a QR code for a phone (`SyncPairingLink`), signing out and deleting the
/// account. The server is the hosted one unless "Use a different server"
/// says otherwise. See `docs/sync.md`.
struct SettingsSyncPane: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  @State private var email = ""
  @State private var password = ""
  @State private var serverURL = SyncServer.defaultURL.absoluteString
  @State private var usesOtherServer = false
  @State private var usesPairingCode = false
  @State private var pairingCode = ""
  @State private var isWorking = false
  @State private var message: String?
  /// What "Forgot password?" sent, shown where an error would be.
  @State private var notice: String?
  @State private var isConfirmingDelete = false
  @State private var deletePassword = ""

  var body: some View {
    if let session = model.syncSession {
      if session.isSignedIn {
        signedIn(session)
      } else {
        signedOut(session)
      }
    } else {
      Section(header: Text("Sync")) {
        Text("The workspace did not open, so there is nothing to sync.")
          .foregroundStyle(theme.muted)
      }
    }
  }

  // MARK: - Signed out

  private func signedOut(_ session: SyncSession) -> some View {
    Section(header: Text("Sync")) {
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
          Button("Create account") {
            run { [email, password] in
              try await session.signUp(email: email, password: password, serverURL: try chosenServer())
              self.password = ""
            }
          }
          .buttonStyle(FocusActionButtonStyle())
          .disabled(isWorking || email.isEmpty || password.isEmpty)
          if isWorking { ProgressView().controlSize(.small) }
          Spacer()
          Button("Forgot password?") { requestPasswordReset(session) }
            .buttonStyle(.plain)
            .font(theme.captionFont)
            .foregroundStyle(theme.muted)
            .help("Email a link for setting a new password. Setting one signs out every device.")
            .disabled(isWorking)
        }
      }
      .padding(.vertical, theme.space.xs)

      DisclosureGroup("Use a pairing code", isExpanded: $usesPairingCode) {
        VStack(alignment: .leading, spacing: theme.space.sm) {
          Text("On a device that is already signed in, choose Add a phone, then type the code here.")
            .font(theme.captionFont)
            .foregroundStyle(theme.muted)
          HStack(spacing: theme.space.sm) {
            TextField("", text: $pairingCode, prompt: Text("ABCD-EFGH, or a pairing link"))
              .themedTextField()
            Button("Join") {
              run { [pairingCode] in
                try await session.pair(codeOrLink: pairingCode, serverURL: try chosenServer())
                self.pairingCode = ""
              }
            }
            .buttonStyle(FocusActionButtonStyle())
            .disabled(isWorking || pairingCode.trimmingCharacters(in: .whitespaces).isEmpty)
          }
        }
        .padding(.top, theme.space.xs)
      }

      DisclosureGroup("Use a different server", isExpanded: $usesOtherServer) {
        VStack(alignment: .leading, spacing: theme.space.xs) {
          TextField("", text: $serverURL, prompt: Text(SyncServer.defaultURL.absoluteString))
            .themedTextField()
          Text("For a server you run yourself. Leave it as it is to use Priority's.")
            .font(theme.captionFont)
            .foregroundStyle(theme.muted)
        }
        .padding(.top, theme.space.xs)
      }
      feedback
    }
    .onAppear { prefill(from: session) }
  }

  private func field(_ title: String, @ViewBuilder control: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: theme.space.xs) {
      Text(title).foregroundStyle(theme.muted)
      control()
    }
  }

  private func signIn(_ session: SyncSession) {
    guard !email.isEmpty, !password.isEmpty, !isWorking else { return }
    run { [email, password] in
      try await session.signIn(email: email, password: password, serverURL: try chosenServer())
      self.password = ""
    }
  }

  /// Emails a reset link for the typed address, on the chosen server.
  private func requestPasswordReset(_ session: SyncSession) {
    guard !isWorking else { return }
    run { [email] in
      let sent = try await session.requestPasswordReset(email: email, serverURL: try chosenServer())
      notice = SyncSession.passwordResetSentMessage(for: sent)
    }
  }

  /// The hosted server, unless the disclosure names another.
  private func chosenServer() throws -> URL {
    guard let url = SyncServer.url(from: serverURL) else {
      throw SyncError.invalid("That server address isn't a web address.")
    }
    return url
  }

  /// After a refused token, the same email and server again.
  private func prefill(from session: SyncSession) {
    if email.isEmpty, let remembered = session.rememberedEmail { email = remembered }
    if let server = session.rememberedServerURL, server != SyncServer.defaultURL {
      serverURL = server.absoluteString
      usesOtherServer = true
    }
  }

  // MARK: - Signed in

  @ViewBuilder
  private func signedIn(_ session: SyncSession) -> some View {
    Section(header: Text("Sync")) {
      LabeledContent("Signed in as") {
        Text(session.email ?? "an account without an email").textSelection(.enabled)
      }
      LabeledContent("Status") { SyncPhaseText(phase: session.phase) }
      if let server = session.credentials?.serverURL, server != SyncServer.defaultURL {
        LabeledContent("Server") {
          Text(server.absoluteString).font(theme.monoFont(size: 11)).foregroundStyle(theme.muted)
        }
      }
      HStack(spacing: theme.space.sm) {
        Button("Sync now") { run { await session.syncNow() } }
          .buttonStyle(FocusActionButtonStyle())
          .disabled(isWorking || session.phase == .syncing)
        Button("Add a phone") { run { try await session.makePairingLink() } }
          .buttonStyle(FocusActionButtonStyle())
          .disabled(isWorking)
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
      if let link = session.pairingLink {
        pairingCode(link, expiresAt: session.pairingCodeExpiresAt)
      }
      feedback
    }
    .task(id: session.credentials?.token) {
      try? await session.refreshAccount()
    }

    Section(header: Text("Devices")) {
      if let devices = session.account?.devices {
        ForEach(devices) { device in deviceRow(device) }
      } else {
        Text("Loading…").foregroundStyle(theme.muted)
      }
    }

    Section(header: Text("Account")) {
      HStack(alignment: .firstTextBaseline, spacing: theme.space.md) {
        Text(
          "Deleting the account removes everything synced to the server and signs out every device. "
            + "Each device keeps its own copy of the workspace."
        )
        .font(theme.captionFont)
        .foregroundStyle(theme.muted)
        Spacer()
        Button("Delete account…", role: .destructive) {
          deletePassword = ""
          isConfirmingDelete = true
        }
        .buttonStyle(FocusActionButtonStyle())
        .disabled(isWorking)
      }
    }
    .alert("Delete your sync account?", isPresented: $isConfirmingDelete) {
      SecureField("Password", text: $deletePassword)
      Button("Delete account", role: .destructive) {
        run { [deletePassword] in
          try await session.deleteAccount(password: deletePassword)
          self.deletePassword = ""
        }
      }
      Button("Cancel", role: .cancel) { deletePassword = "" }
    } message: {
      Text(
        "Enter your password to delete \(session.email ?? "this account") and everything synced to it. "
          + "Every device is signed out. Each one keeps its own copy of the workspace, and this Mac keeps its tasks."
      )
    }
  }

  private func deviceRow(_ device: SyncDevice) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: theme.space.sm) {
      VStack(alignment: .leading, spacing: 2) {
        Text(device.displayName)
        HStack(spacing: 4) {
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

  private func pairingCode(_ link: SyncPairingLink, expiresAt: Date?) -> some View {
    HStack(alignment: .top, spacing: 16) {
      if let image = Self.qrImage(for: link.url.absoluteString) {
        Image(nsImage: image)
          .interpolation(.none)
          .resizable()
          .frame(width: 168, height: 168)
          .padding(8)
          .background(Color.white)
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border))
      }
      VStack(alignment: .leading, spacing: 8) {
        Text("Scan this in Priority on the phone: Settings → Sync → Scan code. Or type the code.")
        Text(link.code)
          .font(theme.monoFont(size: 20))
          .textSelection(.enabled)
        Text(link.url.absoluteString)
          .font(theme.monoFont(size: 11))
          .textSelection(.enabled)
          .foregroundStyle(theme.muted)
        if let expiresAt {
          Text("Works once, until \(expiresAt.formatted(date: .omitted, time: .shortened)).")
            .font(theme.captionFont)
            .foregroundStyle(theme.muted)
        }
        Button("Copy link") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
        }
        .buttonStyle(FocusActionButtonStyle())
      }
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private var feedback: some View {
    if let message {
      Text(message)
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
    Task { @MainActor in
      defer { isWorking = false }
      do { try await work() } catch { message = error.localizedDescription }
    }
  }

  private static func qrImage(for string: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    let rep = NSCIImageRep(ciImage: scaled)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
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
        .help("The sync server no longer recognises this Mac. Sign in again in Settings → Sync.")
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
