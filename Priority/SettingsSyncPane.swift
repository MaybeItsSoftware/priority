import CoreImage.CIFilterBuiltins
import PrioritySync
import SwiftUI

/// Pairing this Mac with the sync server, and letting a phone join it.
///
/// The first device pairs with the server's admin token; every device after
/// joins by scanning the QR code this pane shows, which carries the server and
/// a ten-minute, one-use code (`SyncPairingLink`). See `docs/sync.md`.
struct SettingsSyncPane: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  @State private var serverURL = ""
  @State private var adminToken = ""
  @State private var joinLink = ""
  @State private var isWorking = false
  @State private var message: String?

  var body: some View {
    if let session = model.syncSession {
      if let credentials = session.credentials {
        paired(session, credentials: credentials)
      } else {
        unpaired(session)
      }
    } else {
      Section(header: Text("Sync")) {
        Text("The workspace did not open, so there is nothing to sync.")
          .foregroundStyle(theme.muted)
      }
    }
  }

  private func unpaired(_ session: SyncSession) -> some View {
    Section(header: Text("Sync")) {
      Text(
        "Keep this Mac, your iPhone and your Android phone on one workspace. Every device keeps "
          + "a full copy and works offline; changes travel through your sync server."
      )
      .font(theme.captionFont)
      .foregroundStyle(theme.muted)

      VStack(alignment: .leading, spacing: 6) {
        Text("First device: the server and its admin token")
        TextField("https://priority-sync.up.railway.app", text: $serverURL)
          .textFieldStyle(.roundedBorder)
        SecureField("SYNC_ADMIN_TOKEN", text: $adminToken)
          .textFieldStyle(.roundedBorder)
        Button("Pair this Mac") {
          run { [serverURL, adminToken] in
            guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespaces)) else {
              throw SyncError.server(status: 0, message: "That server address is not a URL.")
            }
            try await session.pair(serverURL: url, adminToken: adminToken)
          }
        }
        .disabled(isWorking || serverURL.isEmpty || adminToken.isEmpty)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Or join with a link from a device that is already paired")
        TextField("priority-sync://pair?…", text: $joinLink)
          .textFieldStyle(.roundedBorder)
        Button("Join") {
          run { [joinLink] in
            guard let link = SyncPairingLink(joinLink) else {
              throw SyncError.server(status: 0, message: "That is not a Priority pairing link.")
            }
            try await session.pair(with: link)
          }
        }
        .disabled(isWorking || joinLink.isEmpty)
      }
      feedback
    }
  }

  private func paired(_ session: SyncSession, credentials: SyncCredentials) -> some View {
    Section(header: Text("Sync")) {
      LabeledContent("Server", value: credentials.serverURL.absoluteString)
      LabeledContent("Status") { SyncPhaseText(phase: session.phase) }
      HStack {
        Button("Sync now") { run { await session.syncNow() } }
          .disabled(isWorking)
        Button("Add a phone") { run { try await session.makePairingLink() } }
          .disabled(isWorking)
        Spacer()
        Button("Unpair", role: .destructive) { run { try session.unpair() } }
          .foregroundStyle(theme.danger)
      }
      if let link = session.pairingLink {
        pairingCode(link, expiresAt: session.pairingCodeExpiresAt)
      }
      feedback
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
        Text("Scan this in Priority on the phone: Settings → Sync → Scan code.")
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
    }
  }

  private func run(_ work: @escaping @MainActor () async throws -> Void) {
    isWorking = true
    message = nil
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
      Text("Not paired")
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
