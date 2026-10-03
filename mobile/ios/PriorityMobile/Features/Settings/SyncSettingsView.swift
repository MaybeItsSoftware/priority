import CoreImage.CIFilterBuiltins
import PrioritySync
import SwiftUI
import UIKit
import VisionKit

/// Signing in to sync, and the state of sync once signed in.
///
/// Signed out: an email and password, to sign in or make an account; or a
/// code from a device already signed in, scanned, pasted or typed. Signed
/// in: the account, the status, Sync now, the account's devices, "Add a
/// device" (a QR code another device scans, or a link to send it), signing
/// out, and deleting the account — which the App Store requires be possible
/// in the app. The server is Priority's unless "Use a different server" says
/// otherwise.
struct SyncSettingsView: View {
  @Environment(\.theme) private var theme
  var body: some View {
    Group {
      if let controller = SyncController.shared {
        SyncSettingsForm(controller: controller)
      } else {
        EmptyState(title: "Sync is off", message: "Sync isn't available in this build.", systemImage: "icloud.slash")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(theme.paper)
      }
    }
    .navigationTitle("Sync")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct SyncSettingsForm: View {
  @Environment(\.theme) private var theme
  @Bindable var controller: SyncController
  @State private var email = ""
  @State private var password = ""
  @State private var serverURL = SyncServer.defaultURL.absoluteString
  @State private var usesOtherServer = false
  @State private var codeOrLink = ""
  @State private var isScanning = false
  @State private var isConfirmingSignOut = false
  @State private var isDeletingAccount = false
  @State private var isMakingCode = false
  @State private var codeError: String?
  /// What "Forgot password?" sent.
  @State private var resetNotice: String?

  private var session: SyncSession { controller.session }

  var body: some View {
    Form {
      // First, so a refused password or code says so without scrolling.
      if let error = controller.pairingError {
        Section {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(theme.type.caption)
            .foregroundStyle(theme.danger)
            .accessibilityIdentifier("sync.pairingError")
        }
        .listRowBackground(theme.danger.opacity(0.08))
      }
      if session.isSignedIn {
        signedIn
      } else {
        signedOut
      }
    }
    .scrollContentBackground(.hidden)
    .background(theme.paper)
    .font(theme.type.body)
    .disabled(controller.isPairing)
    .overlay {
      if controller.isPairing {
        ProgressView("Signing in…").padding(theme.space.lg)
          .background(theme.raised, in: RoundedRectangle(cornerRadius: theme.radius.panel))
          .overlay(RoundedRectangle(cornerRadius: theme.radius.panel).strokeBorder(theme.border, lineWidth: theme.stroke))
      }
    }
    .sheet(isPresented: $isScanning) {
      QRScannerSheet { scanned in
        isScanning = false
        if let link = SyncPairingLink(scanned) {
          Task { await controller.pair(with: link) }
        } else {
          controller.pairingError = "That code isn't a Priority pairing code."
        }
      }
    }
    .sheet(isPresented: $isDeletingAccount) {
      DeleteAccountSheet(controller: controller)
    }
  }

  // MARK: - Signed in

  @ViewBuilder
  private var signedIn: some View {
    Section {
      LabeledContent("Signed in as") {
        Text(session.email ?? "This account").foregroundStyle(theme.muted).textSelection(.enabled)
      }
      TimelineView(.periodic(from: .now, by: 30)) { context in
        LabeledContent("Status") {
          Label(SyncPhaseText.describe(session.phase, now: context.date), systemImage: SyncPhaseText.symbol(session.phase))
            .foregroundStyle(SyncPhaseText.isProblem(session.phase) ? theme.danger : theme.ink)
        }
      }
      if let server = session.credentials?.serverURL, server != SyncServer.defaultURL {
        LabeledContent("Server") {
          Text(server.host() ?? server.absoluteString).font(theme.type.numeral).foregroundStyle(theme.muted)
        }
      }
      Button {
        Task { await controller.syncNow() }
      } label: {
        Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
      }
      .disabled(session.phase == .syncing)
      .accessibilityIdentifier("sync.now")
    } header: {
      header("Account")
    }
    .listRowBackground(theme.raised)
    .task(id: session.credentials?.token) {
      try? await session.refreshAccount()
    }

    Section {
      if let devices = session.account?.devices {
        ForEach(devices) { device in
          VStack(alignment: .leading, spacing: 2) {
            HStack {
              Text(device.displayName)
              Spacer()
              if device.current {
                Text("This device").font(theme.type.caption).foregroundStyle(theme.muted)
              }
            }
            Group {
              if let seen = device.lastSeenDate {
                Text("\(device.platformName) · seen \(seen, format: .relative(presentation: .named))")
              } else {
                Text(device.platformName)
              }
            }
            .font(theme.type.caption)
            .foregroundStyle(theme.muted)
          }
        }
      } else {
        Text("Loading…").foregroundStyle(theme.muted)
      }
    } header: {
      header("Devices")
    }
    .listRowBackground(theme.raised)

    Section {
      if let link = session.pairingLink, !isExpired {
        pairingCode(link)
      } else {
        Button {
          Task { await makeCode() }
        } label: {
          Label(isMakingCode ? "Making a code…" : "Add a device", systemImage: "qrcode")
        }
        .disabled(isMakingCode)
        .accessibilityIdentifier("sync.addDevice")
        if let codeError {
          Text(codeError).font(theme.type.caption).foregroundStyle(theme.danger)
        }
      }
    } header: {
      header("Add a device")
    } footer: {
      Text("A one-time code. The other device scans it, types it, or opens the link. Signing in there works too.")
        .font(theme.type.footnote).foregroundStyle(theme.muted)
    }
    .listRowBackground(theme.raised)

    Section {
      Button("Sign out", role: .destructive) { isConfirmingSignOut = true }
        .accessibilityIdentifier("sync.signOut")
        .confirmationDialog("Sign out of sync?", isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
          Button("Sign out", role: .destructive) { Task { await controller.signOut() } }
        } message: {
          Text("Your tasks stay on this device. They stop syncing with your other devices.")
        }
      Button("Delete account…", role: .destructive) { isDeletingAccount = true }
        .accessibilityIdentifier("sync.deleteAccount")
    } footer: {
      Text("Deleting the account removes everything synced to the server and signs out every device. Each device keeps its own copy.")
        .font(theme.type.footnote).foregroundStyle(theme.muted)
    }
    .listRowBackground(theme.raised)
  }

  private func pairingCode(_ link: SyncPairingLink) -> some View {
    VStack(spacing: theme.space.md) {
      QRCodeImage(text: link.url.absoluteString)
        .frame(width: 200, height: 200)
        .padding(theme.space.md)
        // A QR code is read by a camera, not a person: always dark on white,
        // whatever the theme, the way a photo’s letterbox is fixed.
        .background(Color.white, in: RoundedRectangle(cornerRadius: theme.radius.panel))
        .overlay(RoundedRectangle(cornerRadius: theme.radius.panel).strokeBorder(theme.border, lineWidth: theme.stroke))
        .accessibilityLabel("Pairing code")
      Text(link.code)
        .font(theme.type.numeral)
        .textSelection(.enabled)
        .accessibilityIdentifier("sync.pairingCode")
      if let expires = session.pairingCodeExpiresAt {
        Text("Scan it or type it on the other device. Expires \(expires, style: .relative).")
          .font(theme.type.caption)
          .foregroundStyle(theme.muted)
          .multilineTextAlignment(.center)
      }
      HStack(spacing: theme.space.sm) {
        Button {
          UIPasteboard.general.string = link.url.absoluteString
        } label: {
          Label("Copy link", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
        }
        .buttonStyle(ThemedButtonStyle(kind: .quiet))
        ShareLink(item: link.url) {
          Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
        }
        .buttonStyle(ThemedButtonStyle(kind: .quiet))
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, theme.space.sm)
  }

  private var isExpired: Bool {
    guard let expires = session.pairingCodeExpiresAt else { return false }
    return expires < .now
  }

  private func makeCode() async {
    isMakingCode = true
    codeError = nil
    defer { isMakingCode = false }
    do {
      try await session.makePairingLink()
    } catch {
      codeError = error.localizedDescription
    }
  }

  // MARK: - Signed out

  @ViewBuilder
  private var signedOut: some View {
    if session.phase == .needsSignIn {
      Section {
        Label("Signed out. Sign in again to keep syncing.", systemImage: "exclamationmark.icloud")
          .foregroundStyle(theme.danger)
          .accessibilityIdentifier("sync.needsSignIn")
      }
      .listRowBackground(theme.raised)
    }

    Section {
      TextField("Email", text: $email)
        .textContentType(.username)
        .keyboardType(.emailAddress)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .accessibilityIdentifier("sync.email")
      SecureField("Password", text: $password)
        .textContentType(.password)
        .submitLabel(.go)
        .onSubmit { signIn() }
        .accessibilityIdentifier("sync.password")
      Button("Sign in") { signIn() }
        .disabled(!canSubmit)
        .accessibilityIdentifier("sync.signIn")
      Button("Create account") {
        guard let server = chosenServer() else { return }
        Task {
          if await controller.signUp(email: email, password: password, serverURL: server) { password = "" }
        }
      }
      .disabled(!canSubmit)
      .accessibilityIdentifier("sync.signUp")
      Button("Forgot password?") { requestPasswordReset() }
        .font(theme.type.callout)
        .foregroundStyle(theme.muted)
        .accessibilityIdentifier("sync.forgotPassword")
      if let resetNotice {
        Text(resetNotice)
          .font(theme.type.caption)
          .foregroundStyle(theme.muted)
          .accessibilityIdentifier("sync.resetNotice")
      }
    } header: {
      header("Sign in")
    } footer: {
      Text("Keep this iPhone, your Mac and your other devices on one workspace. Every device keeps a full copy and works offline. A new password needs 8 characters.")
        .font(theme.type.footnote).foregroundStyle(theme.muted)
    }
    .listRowBackground(theme.raised)

    Section {
      Button {
        isScanning = true
      } label: {
        Label("Scan code", systemImage: "qrcode.viewfinder")
      }
      .accessibilityIdentifier("sync.scan")
      HStack {
        TextField("Or type the code or paste the link", text: $codeOrLink)
          .textInputAutocapitalization(.characters)
          .autocorrectionDisabled()
          .font(theme.type.callout)
          .accessibilityIdentifier("sync.pasteField")
        Button("Join") {
          guard let server = chosenServer() else { return }
          Task {
            if await controller.pair(codeOrLink: codeOrLink, serverURL: server) { codeOrLink = "" }
          }
        }
        .disabled(codeOrLink.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    } header: {
      header("Use a pairing code")
    } footer: {
      Text("On a device that is already signed in, open Settings → Sync → Add a device.")
        .font(theme.type.footnote).foregroundStyle(theme.muted)
    }
    .listRowBackground(theme.raised)

    Section {
      DisclosureGroup("Use a different server", isExpanded: $usesOtherServer) {
        TextField(SyncServer.defaultURL.absoluteString, text: $serverURL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
          .font(theme.type.callout)
          .accessibilityIdentifier("sync.server")
      }
    } footer: {
      Text("For a server you run yourself. Leave it as it is to use Priority's.")
        .font(theme.type.footnote).foregroundStyle(theme.muted)
    }
    .listRowBackground(theme.raised)
    .onAppear(perform: prefill)
  }

  private var canSubmit: Bool {
    !email.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
  }

  private func signIn() {
    guard canSubmit, let server = chosenServer() else { return }
    Task {
      if await controller.signIn(email: email, password: password, serverURL: server) { password = "" }
    }
  }

  /// Emails a reset link for the typed address, on the chosen server.
  private func requestPasswordReset() {
    resetNotice = nil
    guard let server = chosenServer() else { return }
    Task { resetNotice = await controller.requestPasswordReset(email: email, serverURL: server) }
  }

  /// The hosted server, unless the disclosure names another.
  private func chosenServer() -> URL? {
    guard let url = SyncServer.url(from: serverURL) else {
      controller.pairingError = "That server address isn't a web address."
      return nil
    }
    return url
  }

  /// After a refused token, the same email and server again.
  private func prefill() {
    if email.isEmpty, let remembered = session.rememberedEmail { email = remembered }
    if let server = session.rememberedServerURL, server != SyncServer.defaultURL {
      serverURL = server.absoluteString
      usesOtherServer = true
    }
  }

  private func header(_ text: String) -> some View {
    Text(text).font(theme.type.caption).foregroundStyle(theme.muted).textCase(nil)
  }
}

/// Deleting the account, behind the password. The account is gone from the
/// server for every device; each device keeps its own copy of the workspace.
private struct DeleteAccountSheet: View {
  @Environment(\.theme) private var theme
  @Environment(\.dismiss) private var dismiss
  @Bindable var controller: SyncController
  @State private var password = ""

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(
            "This deletes \(controller.session.email ?? "your account") and everything synced to it, and signs out every device. "
              + "Each device keeps its own copy of the workspace, and this iPhone keeps its tasks."
          )
          .font(theme.type.callout)
          .foregroundStyle(theme.muted)
        }
        .listRowBackground(theme.raised)
        Section {
          SecureField("Password", text: $password)
            .textContentType(.password)
            .accessibilityIdentifier("sync.deletePassword")
          if let error = controller.pairingError {
            Text(error).font(theme.type.caption).foregroundStyle(theme.danger)
          }
        } header: {
          Text("Enter your password to confirm").font(theme.type.caption).foregroundStyle(theme.muted).textCase(nil)
        }
        .listRowBackground(theme.raised)
        Section {
          Button("Delete account", role: .destructive) {
            Task {
              if await controller.deleteAccount(password: password) { dismiss() }
            }
          }
          .disabled(password.isEmpty || controller.isPairing)
          .accessibilityIdentifier("sync.confirmDelete")
        }
        .listRowBackground(theme.raised)
      }
      .scrollContentBackground(.hidden)
      .background(theme.paper)
      .font(theme.type.body)
      .navigationTitle("Delete account")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      }
    }
    .onAppear { controller.pairingError = nil }
  }
}

/// A QR code for `text`, drawn crisp at any size.
struct QRCodeImage: View {
  @Environment(\.theme) private var theme
  let text: String

  var body: some View {
    if let image = Self.render(text) {
      Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
    } else {
      Image(systemName: "qrcode").resizable().scaledToFit().foregroundStyle(theme.dim)
    }
  }

  static func render(_ text: String) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
      let cgImage = CIContext().createCGImage(output, from: output.extent)
    else { return nil }
    return UIImage(cgImage: cgImage)
  }
}

/// A camera sheet that reads the first QR code it sees. Where the camera or
/// the scanner is unavailable — the simulator, a device without the Neural
/// Engine, camera access refused — it says so and offers the clipboard
/// instead, so pairing never dead-ends on a missing camera.
struct QRScannerSheet: View {
  @Environment(\.theme) private var theme
  @Environment(\.dismiss) private var dismiss
  let onScan: (String) -> Void

  var body: some View {
    NavigationStack {
      Group {
        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
          QRScanner(onScan: onScan).ignoresSafeArea()
        } else {
          VStack(spacing: theme.space.lg) {
            EmptyState(
              title: "Camera unavailable",
              message: "Copy the pairing link on the other device, then paste it here.",
              systemImage: "camera")
            Button {
              if let text = UIPasteboard.general.string { onScan(text) } else { dismiss() }
            } label: {
              Label("Paste pairing link", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(ThemedButtonStyle(kind: .primary))
            .accessibilityIdentifier("sync.scanner.paste")
          }
          .padding(theme.space.lg)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(theme.paper)
        }
      }
      .navigationTitle("Scan code")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      }
    }
  }
}

private struct QRScanner: UIViewControllerRepresentable {
  let onScan: (String) -> Void

  func makeUIViewController(context: Context) -> DataScannerViewController {
    let scanner = DataScannerViewController(
      recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
      recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
    scanner.delegate = context.coordinator
    try? scanner.startScanning()
    return scanner
  }

  func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

  static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
    scanner.stopScanning()
  }

  func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

  final class Coordinator: NSObject, DataScannerViewControllerDelegate {
    let onScan: (String) -> Void
    private var didScan = false

    init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

    func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
      guard !didScan else { return }
      for item in items {
        if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
          didScan = true
          scanner.stopScanning()
          onScan(payload)
          return
        }
      }
    }
  }
}
