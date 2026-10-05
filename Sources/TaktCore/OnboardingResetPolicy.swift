import Foundation

public struct OnboardingResetState: Equatable {
  public var remoteKey: String
  public var onboardingCompleted: Bool
  public var username: String
  public var listId: String
  public var availableListsCount: Int
  public var tasksCount: Int
  public var currentParentId: Int
  public var currentSiblingIndex: Int

  public init(
    remoteKey: String,
    onboardingCompleted: Bool,
    username: String,
    listId: String,
    availableListsCount: Int,
    tasksCount: Int,
    currentParentId: Int,
    currentSiblingIndex: Int
  ) {
  self.remoteKey = remoteKey
  self.onboardingCompleted = onboardingCompleted
  self.username = username
  self.listId = listId
  self.availableListsCount = availableListsCount
  self.tasksCount = tasksCount
  self.currentParentId = currentParentId
  self.currentSiblingIndex = currentSiblingIndex
  }
}

public enum OnboardingResetPolicy {
  public static func reset(_ state: OnboardingResetState) -> OnboardingResetState {
    OnboardingResetState(
      remoteKey: state.remoteKey,
      onboardingCompleted: false,
      username: "",
      listId: "",
      availableListsCount: 0,
      tasksCount: 0,
      currentParentId: 0,
      currentSiblingIndex: 0
    )
  }
}
