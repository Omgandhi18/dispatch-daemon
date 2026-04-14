import AppKit
import ApplicationServices

final class WindowCommander {

    func execute(_ message: InboundMessage) {
        switch message {
        case .focus(let id):            focus(windowID: id)
        case .move(let id, let x, let y): move(windowID: id, x: x, y: y)
        case .resize(let id, let w, let h): resize(windowID: id, w: w, h: h)
        case .type_(let id, let text):  type_(text: text, windowID: id)
        case .close(let id):            closeWindow(windowID: id)
        case .openNew:                  openNewTerminal()
        case .auth:                     break  // handled upstream in DispatchApp before reaching commander
        }
    }

    private func focus(windowID: String) {
        guard let (app, window) = findWindow(id: windowID) else { return }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, true as CFTypeRef)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, true as CFTypeRef)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        app.activate(options: .activateIgnoringOtherApps)
    }

    private func move(windowID: String, x: Double, y: Double) {
        guard let (_, window) = findWindow(id: windowID) else { return }
        var point = CGPoint(x: x, y: y)
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    private func resize(windowID: String, w: Double, h: Double) {
        guard let (_, window) = findWindow(id: windowID) else { return }
        var size = CGSize(width: w, height: h)
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }

    private func type_(text: String, windowID: String) {
        focus(windowID: windowID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if text == "\u{03}" {
                self.runAppleScript(#"tell application "System Events" to keystroke "c" using {control down}"#)
            } else if text == "\u{1B}" {
                self.runAppleScript(#"tell application "System Events" to key code 53"#)
            } else if text == "\u{1B}[A" {
                self.runAppleScript(#"tell application "System Events" to key code 126"#)
            } else if text == "\u{1B}[B" {
                self.runAppleScript(#"tell application "System Events" to key code 125"#)
            } else if text == "\u{1B}[C" {
                self.runAppleScript(#"tell application "System Events" to key code 124"#)
            } else if text == "\u{1B}[D" {
                self.runAppleScript(#"tell application "System Events" to key code 123"#)
            } else if text == "\t" {
                self.runAppleScript(#"tell application "System Events" to key code 48"#)
            } else {
                self.typeViaAppleScript(text: text)
            }
        }
    }

    private func runAppleScript(_ source: String) {
        if let script = NSAppleScript(source: source) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if let error = error { print("[WindowCommander] AppleScript error: \(error)") }
        }
    }

    private func closeWindow(windowID: String) {
        guard let (_, window) = findWindow(id: windowID) else { return }
        focus(windowID: windowID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.runAppleScript(#"tell application "System Events" to keystroke "c" using {control down}"#)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            var closeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeRef) == .success,
                  let closeButton = closeRef else { return }
            AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.dismissCloseConfirmation(for: window)
            }
        }
    }

    private func dismissCloseConfirmation(for window: AXUIElement) {
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            guard (roleRef as? String) == "AXSheet" else { continue }
            var sheetChildrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &sheetChildrenRef) == .success,
                  let sheetChildren = sheetChildrenRef as? [AXUIElement] else { continue }
            for element in sheetChildren {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
                let title = titleRef as? String ?? ""
                if title == "Terminate" || title == "Close" || title == "Close Anyway" {
                    AXUIElementPerformAction(element, kAXPressAction as CFString)
                    return
                }
            }
        }
    }

    private func openNewTerminal() {
        let src = """
        tell application "Terminal"
            activate
            do script ""
        end tell
        """
        if let script = NSAppleScript(source: src) {
            var err: NSDictionary?
            script.executeAndReturnError(&err)
            if let err = err { print("[WindowCommander] openNew error: \(err)") }
        }
    }

    private func typeViaAppleScript(text: String) {
        let hasNewline = text.hasSuffix("\n")
        let content = hasNewline ? String(text.dropLast()) : text

        let escaped = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let typeLine = escaped.isEmpty ? "" : "\n            keystroke \"\(escaped)\""
        let returnLine = hasNewline ? "\n            keystroke return" : ""

        let script = """
        tell application "System Events"\(typeLine)\(returnLine)
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error { print("[WindowCommander] AppleScript error: \(error)") }
        }
    }

    private let trackedBundleIDs = ["com.apple.Terminal", "com.googlecode.iterm2"]

    private func findWindow(id: String) -> (NSRunningApplication, AXUIElement)? {
        let parts = id.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, let pid = pid_t(parts[0]) else { return nil }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }) else { return nil }

        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return nil }

        let targetHash = String(parts[1])
        for window in windows {
            if "\(CFHash(window))" == targetHash {
                return (app, window)
            }
        }
        return nil
    }
}
