import CoreImage.CIFilterBuiltins
import PrioritySync
import SwiftUI
import UIKit
import VisionKit

/// Pairing with the sync server and the state of sync once paired.
///
/// Paired: the status, Sync now, "Add a device" (a QR code another device
/// scans, or a link to send it), and Unpair. Unpaired: scan a code from a
/// paired device, paste its link, or — for the first device — the server's
/// address and admin token.
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
  @State private var pastedLink = ""
  @State private var isScanning = false
  @State private var isConfirmingUnpair = false
  @State private var isMakingCode = false
  @State private var codeError: String?

  private var session: SyncSession { controller.session }

  var body: some View {
    Form {
      // First, so a link that failed to pair says so without scrolling.
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
        paired
      } else {
        unpaired
      }
    }
    .scrollContentBackground(.hidden)
    .background(theme.paper)
    .font(theme.type.body)
    .disabled(controller.isPairing)
    .overlay {
      if controller.isPairing {
        ProgressView("Pairing…").padding(theme.space.lg)
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
  }

  // MARK: - Paired

  @ViewBuilder
  private var paired: some View {
    Section {
      TimelineView(.periodic(from: .now, by: 30)) { context in
        LabeledContent("Status") {
          Label(SyncPhaseText.describe(session.phase, now: context.date), systemImage: SyncPhaseText.symbol(session.phase))
            .foregroundStyle(statusTint)
        }
      }
      if let server = session.credentials?.serverURL {
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
      header("This device")
    }
    .listRowBackground(theme.raised)

    Section {
      if let link = session.pairingLink, !isExpired {
        VStack(spacing: theme.space.md) {
          QRCodeImage(text: link.url.absoluteString)
            .frame(width: 200, height: 200)
            .padding(theme.space.md)
            // A QR code is read by a camera, not a person: always dark on white,
            // whatever the theme, the way a photo’s letterbox is fixed.
            .background(Color.white, in: RoundedRectangle(cornerRadius: theme.radius.panel))
            .overlay(RoundedRectangle(cornerRadius: theme.radius.panel).strokeBorder(theme.border, lineWidth: theme.stroke))
            .accessibilityLabel("Pairing code")
          if let expires = session.pairingCodeExpiresAt {
            Text("Scan it on the other device. Expires \(expires, style: .relative).")
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
      Text("A one-time code. The other device scans it, or opens the link.")
        .font(theme.type.footnote).foregroundStyle(theme.muted)
    }
    .listRowBackground(theme.raised)

    Section {
      Button("Unpair this device", role: .destructive) { isConfirmingUnpair = true }
        .accessibilityIdentifier("sync.unpair")
        .confirmationDialog("Unpair this device?", isPresented: $isConfirmingUnpair, titleVisibility: .visible) {
          Button("Sign out", role: .destructive) { Task { await controller.signOut() } }
        } message: {
          Text("Your tasks stay on this device. They stop syncing with your other devices.")
        }
    }
    .listRowBackground(theme.raised)
  }

  private var isExpired: Bool {
    guard let expires = session.pairingCodeExpiresAt else { return false }
    return expires < .now
  }

  private var statusTint: Color {
    if case .failed = session.phase { return theme.danger }
    return theme.ink
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

  // MARK: - Unpaired

  @ViewBuilder
  private var unpaired: some View {
    Section {
      Button {
        isScanning = true
      } label: {
        Label("Scan code", systemImage: "qrcode.viewfinder")
      }
      .accessibilityIdentifier("sync.scan")
      HStack {
        TextField("Or paste a pairing link", text: $pastedLink)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
          .font(theme.type.callout)
          .accessibilityIdentifier("sync.pasteField")
        Button("Pair") {
          guard let link = SyncPairingLink(pastedLink) else {
            controller.pairingError = "That isn't a Priority pairing link."
            return
          }
          Task { if await controller.pair(with: link) { pastedLink = "" } }
        }
        .disabled(pastedLink.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    } header: {
      header("Join your other devices")
    } footer: {
      Text("On a paired device, open Settings → Sync → Add a device.")
        .font(theme.type.footnote).foregroundStyle(theme.muted)
    }
    .listRowBackground(theme.raised)
  }

  private func header(_ text: String) -> some View {
    Text(text).font(theme.type.caption).foregroundStyle(theme.muted).textCase(nil)
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
