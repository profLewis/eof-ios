import Network
import Observation

/// Monitors network connectivity type (WiFi vs cellular).
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()
    private let monitor = NWPathMonitor()

    var isWiFi = true
    var isCellular = false
    var isConnected = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = path.status == .satisfied
                self?.isWiFi = path.usesInterfaceType(.wifi)
                self?.isCellular = path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi)
            }
        }
        monitor.start(queue: DispatchQueue(label: "uk.ac.ucl.eof.network"))
    }
}
