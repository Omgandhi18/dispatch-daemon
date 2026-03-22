import AppKit
import ApplicationServices
import IOKit.ps

final class WindowTracker {

    var onInitialState: (([WindowState]) -> Void)?
    var onDelta: ((_ changed: [WindowState], _ removed: [String]) -> Void)?
    var onPermissionDenied: (() -> Void)?

    var currentWindows: [WindowState] { Array(previousState.values) }

    private var previousState: [String: WindowState] = [:]
    private var timer: Timer?
    private var permissionPollTimer: Timer?
    private var isFirstPoll = true

    private let pollingController = PollingController()
    private var previousTitles: [String: String] = [:]
    private var cachedContents: [String: String] = [:]

    private let trackedBundleIDs = [
        "com.apple.Terminal",
        "com.googlecode.iterm2"
    ]

    private let promptSuffixes = ["$ ", "% ", "❯ ", "> ", "# "]

    func start() {
        if AXIsProcessTrusted() {
            startPolling()
        } else {
            print("[WindowTracker] Accessibility permission not granted — waiting...")
            onPermissionDenied?()
            permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                if AXIsProcessTrusted() {
                    print("[WindowTracker] Accessibility permission granted — starting.")
                    self.permissionPollTimer?.invalidate()
                    self.permissionPollTimer = nil
                    self.startPolling()
                }
            }
        }
    }

    private func startPolling() {
        scheduleNextPoll()
    }

    private func scheduleNextPoll() {
        timer = Timer.scheduledTimer(withTimeInterval: pollingController.currentInterval, repeats: false) { [weak self] _ in
            self?.poll()
            self?.scheduleNextPoll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    private func poll() {
        let windows = collectWindows()

        if isFirstPoll {
            isFirstPoll = false
            previousState = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
            onInitialState?(windows)
            updateDaemonState(windows: windows, hadChanges: true)
            return
        }

        var changed: [WindowState] = []
        var removed: [String] = []

        let currentIDs = Set(windows.map { $0.id })
        let previousIDs = Set(previousState.keys)

        for id in previousIDs where !currentIDs.contains(id) {
            removed.append(id)
            previousTitles.removeValue(forKey: id)
            cachedContents.removeValue(forKey: id)
        }

        for window in windows {
            if let prev = previousState[window.id] {
                if prev != window { changed.append(window) }
            } else {
                changed.append(window)
            }
        }

        previousState = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })

        let hadChanges = !changed.isEmpty || !removed.isEmpty
        if hadChanges {
            onDelta?(changed, removed)
        }

        updateDaemonState(windows: windows, hadChanges: hadChanges)
    }

    private func updateDaemonState(windows: [WindowState], hadChanges: Bool) {
        let onBattery = checkPowerSource()
        pollingController.recordPollResult(hadChanges: hadChanges, windowCount: windows.count, onBattery: onBattery)

        DispatchQueue.main.async {
            DaemonState.shared.pollingMode = self.pollingController.currentMode
            DaemonState.shared.powerSource = onBattery ? .battery : .ac
            DaemonState.shared.trackedWindowCount = windows.count
            DaemonState.shared.trackedWindows = windows
        }
    }

    private func collectWindows() -> [WindowState] {
        var result: [WindowState] = []
        var globalIndex = 0
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  trackedBundleIDs.contains(bundleID) else { continue }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement] else { continue }
            for window in windows {
                if let state = windowState(from: window, app: app, zOrder: globalIndex) {
                    result.append(state)
                    globalIndex += 1
                }
            }
        }
        return result
    }

    private func windowState(from window: AXUIElement, app: NSRunningApplication, zOrder: Int = 0) -> WindowState? {
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String else { return nil }

        var posRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              let posValue = posRef else { return nil }
        var position = CGPoint.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &position)

        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let sizeValue = sizeRef else { return nil }
        var size = CGSize.zero
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

        var focusedRef: CFTypeRef?
        let isFocused = AXUIElementCopyAttributeValue(window, kAXFocusedAttribute as CFString, &focusedRef) == .success &&
                        (focusedRef as? Bool ?? false)

        let id = "\(app.processIdentifier)-\(CFHash(window))"
        let cleanTitleStr = cleanTitle(title, bundleID: app.bundleIdentifier ?? "")

        // Content caching: only re-read if title changed
        let content: String?
        if shouldReadContent(for: id, currentTitle: cleanTitleStr) {
            let newContent = readContent(from: window)
            cachedContents[id] = newContent
            content = newContent
        } else {
            content = cachedContents[id]
        }

        let status = inferStatus(from: content)

        return WindowState(
            id: id,
            title: cleanTitleStr,
            status: status,
            x: Double(position.x),
            y: Double(position.y),
            w: Double(size.width),
            h: Double(size.height),
            isFocused: isFocused,
            content: content,
            zOrder: zOrder
        )
    }

    private func shouldReadContent(for windowID: String, currentTitle: String) -> Bool {
        if let prev = previousTitles[windowID], prev == currentTitle {
            return false
        }
        previousTitles[windowID] = currentTitle
        return true
    }

    private func readContent(from element: AXUIElement) -> String? {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if (roleRef as? String) == (kAXTextAreaRole as String) {
            var valueRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
               let text = valueRef as? String, !text.isEmpty {
                let lines = text.components(separatedBy: "\n")
                return lines.suffix(200).joined(separator: "\n")
            }
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let result = readContent(from: child) { return result }
        }
        return nil
    }

    private func inferStatus(from content: String?) -> WindowStatus {
        guard let content,
              let lastLine = content.components(separatedBy: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return .idle }
        return promptSuffixes.contains(where: { lastLine.hasSuffix($0) }) ? .idle : .running
    }

    private func cleanTitle(_ title: String, bundleID: String) -> String {
        var clean = title
        let prefixes = ["zsh — ", "bash — ", "fish — ", "sh — "]
        for prefix in prefixes {
            if clean.hasPrefix(prefix) { clean = String(clean.dropFirst(prefix.count)); break }
        }
        return clean
    }

    private func checkPowerSource() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        for source in sources {
            if let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
               let type = desc[kIOPSPowerSourceStateKey as String] as? String {
                return type != kIOPSACPowerValue as String
            }
        }
        return false
    }
}

extension WindowTracker {
    static var mainScreenSize: CGSize {
        NSScreen.main?.frame.size ?? CGSize(width: 2560, height: 1600)
    }
}
