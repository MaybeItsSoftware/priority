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
        avatar(session.profile, email: session.email)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help(session.email.map { "Signed in as \($0)" } ?? "Signed in")
      .accessibilityLabel("Account")
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
      if let url = profile?.avatarURL {
        AsyncImage(url: url) { phase in
          if let image = phase.image {
            image.resizable().scaledToFill()
          } else {
            initial
          }
        }
      } else {
        initial
      }
    }
    .frame(width: diameter, height: diameter)
    .clipShape(Circle())
    .overlay(Circle().strokeBorder(theme.border, lineWidth: theme.hairline))
  }
}
