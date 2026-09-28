import Foundation
import Observation

/// Whether first-run setup has been satisfied.
///
/// It also used to queue setup dialogs — plugin selection, Checkvist,
/// Obsidian — into `activeOnboardingDialog`, which no view ever presented.
/// That queue is gone; the flag is what the rest of the app reads.
@MainActor
@Observable class OnboardingService {
  @ObservationIgnored private let preferencesStore: PreferencesStore
  @ObservationIgnored private let repository: TaskRepository
  @ObservationIgnored private let integrations: IntegrationCoordinator

  var onboardingCompleted: Bool {
    didSet {
      preferencesStore.set(onboardingCompleted, for: .onboardingCompleted)
    }
  }
  
  init(
    preferencesStore: PreferencesStore,
    repository: TaskRepository,
    integrations: IntegrationCoordinator
  ) {
    self.preferencesStore = preferencesStore
    self.repository = repository
    self.integrations = integrations

    let storedUsername = preferencesStore.string(.checkvistUsername)
    let storedListId = preferencesStore.string(.checkvistListId)
    let storedOnboardingCompletedFlag = preferencesStore.optionalBool(.onboardingCompleted)

    if let storedOnboarding = storedOnboardingCompletedFlag {
      self.onboardingCompleted = storedOnboarding
    } else {
      self.onboardingCompleted = !storedUsername.isEmpty && !storedListId.isEmpty
    }
  }

  func markOnboardingCompleted() {
    onboardingCompleted = true
  }

  func markOnboardingRequired() {
    onboardingCompleted = false
  }
}
