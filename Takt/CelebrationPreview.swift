import TaktCore
import SwiftUI

/// Plays the active celebration on a sample row, so a preset can be judged
/// before a real task has to be finished to see it.
///
/// It runs the real thing: the same `runInline` and `presentFlourish` a
/// completion goes through, with the sound if sound is on, against a row that
/// reads its phase the way the day's cards do. Only the task is pretend — its
/// id is one no workspace task can have, so nothing is marked done.
struct CelebrationPreview: View {
  @Environment(\.theme) private var theme
  let celebration: CompletionCelebrationManager

  @State private var occasion: Occasion = .ordinary
  @State private var isPlaying = false

  /// A UUID-shaped id is all a workspace task can have, so this cannot be one.
  private static let kind = CompletionKind.workspaceTask(id: "takt.celebration-preview")

  /// The occasions worth seeing, in the order they grow.
  enum Occasion: String, CaseIterable, Identifiable {
    case ordinary, dailyTicked, listCleared, tally, streak

    var id: String { rawValue }

    var title: String {
      switch self {
      case .ordinary: "A task"
      case .dailyTicked: "A daily"
      case .listCleared: "List cleared"
      case .tally: "10 today"
      case .streak: "5-day streak"
      }
    }

    var event: CompletionEvent {
      switch self {
      case .ordinary: CompletionEvent(kind: CelebrationPreview.kind, milestone: .ordinary, ordinal: 3)
      case .dailyTicked: CompletionEvent(kind: CelebrationPreview.kind, milestone: .dailyTicked, ordinal: 3)
      case .listCleared: CompletionEvent(kind: CelebrationPreview.kind, milestone: .listCleared, ordinal: 6)
      case .tally:
        CompletionEvent(kind: CelebrationPreview.kind, milestone: .dailyTally(count: 10), ordinal: 10)
      case .streak:
        CompletionEvent(kind: CelebrationPreview.kind, milestone: .dailyStreak(days: 5), ordinal: 1)
      }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: theme.space.sm) {
      HStack(spacing: theme.space.sm) {
        Picker("Occasion", selection: $occasion) {
          ForEach(Occasion.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        Button {
          play()
        } label: {
          Label("Play", systemImage: "play.fill")
        }
        .buttonStyle(FocusActionButtonStyle(prominent: true))
        .disabled(isPlaying)
        .keyboardShortcut("p", modifiers: [.command])
        .help("Play the celebration (⌘P)")
      }
      stage
    }
  }

  /// The sample row, on a page of its own so the flourish has somewhere to
  /// land that is not the settings around it.
  private var stage: some View {
    let phase = celebration.phase(for: Self.kind)
    let treatment = celebration.rowTreatment
    let celebrating = phase != .idle
    return ZStack {
      sampleRow(phase: phase, treatment: treatment, celebrating: celebrating)
        .padding(theme.space.lg)
      if let flourish = celebration.activeFlourish?.view {
        flourish
          .allowsHitTesting(false)
          .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 140)
    .background(theme.paper, in: RoundedRectangle(cornerRadius: theme.panelRadius))
    .overlay(
      RoundedRectangle(cornerRadius: theme.panelRadius)
        .strokeBorder(theme.border, lineWidth: theme.hairline))
    .clipShape(RoundedRectangle(cornerRadius: theme.panelRadius))
  }

  private func sampleRow(
    phase: CelebrationPhase, treatment: CelebrationRowTreatment, celebrating: Bool
  ) -> some View {
    HStack(spacing: theme.space.sm) {
      Image(systemName: celebrating ? "checkmark.circle.fill" : "circle")
        .font(theme.bodyFont())
        .foregroundStyle(celebrating ? theme.success : theme.dim)
        .scaleEffect(treatment.iconScale(for: phase))
      Text(occasion == .dailyTicked ? "Practise music" : "Write the quarterly plan")
        .font(theme.bodyFont())
        .foregroundStyle(theme.ink)
        .strikethrough(treatment.drawsStrikethrough && phase == .celebrating, color: theme.muted)
      Spacer(minLength: theme.space.sm)
      Text("25m")
        .font(theme.numeralFont(theme.scale.caption))
        .monospacedDigit()
        .foregroundStyle(theme.dim)
    }
    .padding(.horizontal, theme.space.md)
    .padding(.vertical, theme.space.sm)
    .background(
      celebrating ? theme.success.opacity(treatment.tintOpacity(for: phase)) : theme.raised,
      in: RoundedRectangle(cornerRadius: theme.rowRadius))
    .overlay(
      RoundedRectangle(cornerRadius: theme.rowRadius)
        .strokeBorder(celebrating ? theme.success : theme.border, lineWidth: theme.hairline))
    .overlay { if celebrating { celebration.rowAccent(for: Self.kind) } }
    .scaleEffect(treatment.rowScale(for: phase))
    .scaleEffect(y: treatment.collapses(at: phase) ? 0.01 : 1, anchor: .top)
    .opacity(treatment.fades(at: phase) ? 0 : 1)
  }

  /// The same two halves a completion runs, in the same order; then the row
  /// comes back, which a real one would not, so it can be played again.
  private func play() {
    let event = occasion.event
    isPlaying = true
    Task { @MainActor in
      if await celebration.runInline(event) {
        celebration.presentFlourish(for: event)
      }
      celebration.setPhase(.idle, for: nil)
      isPlaying = false
    }
  }
}
