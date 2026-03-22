import Combine
import Foundation

enum DaemonPowerSource {
    case ac
    case battery
}

final class DaemonState: ObservableObject {
    @Published var isRunning = false
    @Published var connectedClients = 0
    @Published var authenticatedClients = 0
    @Published var pairingToken = ""
    @Published var trackedWindowCount = 0
    @Published var pollingMode: PollingMode = .active
    @Published var powerSource: DaemonPowerSource = .ac
    @Published var trackedWindows: [WindowState] = []

    static let shared = DaemonState()
    private init() {}
}
