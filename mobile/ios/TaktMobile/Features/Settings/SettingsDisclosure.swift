import SwiftUI

/// A long group of settings folded behind one row: a title, what is chosen
/// now, and a chevron that opens the group in place.
///
/// Settings pages use it where a section would otherwise run to a screen of
/// rows (every theme, every celebration, every calendar), so the page reads as
/// a short list. It is the system `DisclosureGroup`, so VoiceOver announces it
/// expanded or collapsed and the row keeps the list's 44pt height; whether it
/// is open is remembered, by `key`, across launches.
struct SettingsDisclosure<Content: View>: View {
  @Environment(\.theme) private var theme
  @AppStorage private var isExpanded: Bool
  let title: String
  var value: String?
  @ViewBuilder var content: Content

  init(
    _ title: String,
    value: String? = nil,
    key: String,
    opensByDefault: Bool = false,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.value = value
    self.content = content()
    _isExpanded = AppStorage(wrappedValue: opensByDefault, "settings.disclosure.\(key)")
  }

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      content
    } label: {
      HStack(spacing: theme.space.sm) {
        Text(title).font(theme.type.body).foregroundStyle(theme.ink)
        Spacer(minLength: theme.space.sm)
        if let value, !isExpanded {
          Text(value)
            .font(theme.type.caption)
            .foregroundStyle(theme.muted)
            .lineLimit(1)
        }
      }
      .frame(minHeight: theme.touchTarget)
      .contentShape(Rectangle())
    }
    .tint(theme.muted)
  }
}
