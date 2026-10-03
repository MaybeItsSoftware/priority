import Foundation
import Network

final class NetworkReachabilityMonitor: @unchecked Sendable {
  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "uk.co.maybeitssoftware.takt.network")

  var onStatusChange: (@Sendable (Bool) -> Void)?

  func start() {
    monitor.pathUpdateHandler = { [weak self] path in
      self?.onStatusChange?(path.status == .satisfied)
    }
    monitor.start(queue: queue)
  }

  func stop() {
    monitor.cancel()
  }
}
