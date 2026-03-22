import Foundation

enum PollingMode: String {
    case active = "Active"         // 1.0s - recent changes
    case idle = "Idle"             // 3.0s - no changes for 30s
    case background = "Background" // 10.0s - no windows or on battery
}

final class PollingController {
    private(set) var currentMode: PollingMode = .active
    private var noChangeCount = 0
    private let idleThreshold = 10

    var currentInterval: TimeInterval {
        switch currentMode {
        case .active: return 1.0
        case .idle: return 3.0
        case .background: return 10.0
        }
    }

    func recordPollResult(hadChanges: Bool, windowCount: Int, onBattery: Bool) {
        if hadChanges {
            noChangeCount = 0
            currentMode = onBattery ? .background : .active
        } else {
            noChangeCount += 1
            if windowCount == 0 || onBattery {
                currentMode = .background
            } else if noChangeCount >= idleThreshold {
                currentMode = .idle
            }
        }
    }

    func reset() {
        currentMode = .active
        noChangeCount = 0
    }
}
