import Foundation

enum CheckvistConnectionState: Equatable {
  case disconnected
  case connecting
  case awaitingConnect
  case connected(listCount: Int)
}
