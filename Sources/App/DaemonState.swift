import Combine
import Foundation

final class DaemonState: ObservableObject {
    @Published var isRunning = false
    @Published var connectedClients = 0
    @Published var authenticatedClients = 0
    @Published var pairingToken = ""
    @Published var activeSessions = 0

    static let shared = DaemonState()
    private init() {}
}
