import SwiftUI
import TaktCore
import TaktSync

/// The account at the right end of the title strip.
///
/// Signed out, a quiet person glyph that opens Settings on Sync, where the
/// Google, Apple and email sign-ins are. Signed in, the picture Google or
/// Apple gave the account — or its initial on a well, for an account with
/// none — and a menu with who it is, syncing now, the sync settings and
/// signing out.
struct WorkspaceAccountButton: View {
  @Environment(WorkspaceViewModel.self) private var model
  @Environment(\.theme) private var theme
  @Environment(\.displayScale) private var displayScale
  /// The account's picture, fetched once per URL.
  @State private var photo: (url: URL, image: NSImage)?

  private var diameter: CGFloat { theme.scale.body + theme.space.xs }

  var body: some View {
    if let session = model.syncSession, session.isSignedIn {
      Menu {
        if let name = session.profile?.name { Text(name) }
        if let email = session.email { Text(email) }
        Divider()
        Button("Sync now") { Task { _ = await session.syncNow() } }
        Button("Sync settings…") { AppDelegate.shared.menuSettings(pane: .sync) }
        Divider()
        Button("Sign out") { Task { await session.signOut() } }
      } label: {
        // A menu's label is redrawn as a native button, which keeps an image
        // but drops the frame and the clip around it; a photo then shows at
        // its own size. So the round avatar goes in already drawn.
        Image(nsImage: rendered(avatar(session.profile, email: session.email)))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help(session.email.map { "Signed in as \($0)" } ?? "Signed in")
      .accessibilityLabel("Account")
      .task(id: session.profile?.avatarURL) { await load(session.profile?.avatarURL) }
    } else {
      Button { AppDelegate.shared.menuSettings(pane: .sync) } label: {
        Image(systemName: "person.crop.circle")
          .font(.system(size: diameter * 0.85))
          .foregroundStyle(theme.muted)
          .frame(width: diameter, height: diameter)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Sign in to sync")
      .accessibilityLabel("Sign in")
    }
  }

  /// A face is a genuinely round thing, the one place the radius scale
  /// allows a circle; the hairline keeps a pale photo off a pale strip.
  @ViewBuilder
  private func avatar(_ profile: SyncAuthUser?, email: String?) -> some View {
    let initial = Text(String((profile?.name ?? email ?? "?").prefix(1)).uppercased())
      .font(theme.captionFont)
      .foregroundStyle(theme.ink)
      .frame(width: diameter, height: diameter)
      .background(theme.well, in: Circle())
    Group {
      if let photo, photo.url == profile?.avatarURL {
        Image(nsImage: photo.image).resizable().scaledToFill()
      } else {
        initial
      }
    }
    .frame(width: diameter, height: diameter)
    .clipShape(Circle())
    .overlay(Circle().strokeBorder(theme.border, lineWidth: theme.hairline))
  }

  private func rendered(_ view: some View) -> NSImage {
    let renderer = ImageRenderer(content: view)
    renderer.scale = displayScale
    return renderer.nsImage ?? NSImage()
  }

  private func load(_ url: URL?) async {
    guard let url, photo?.url != url else { return }
    guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) else { return }
    photo = (url, image)
  }
}
