import AppKit
import Combine
import Network
import SwiftUI

// MARK: - Entry Point

@main
struct DispatchDaemonApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var tokenMenuItem: NSMenuItem?
    private let server = WebSocketServer()
    private let tracker = WindowTracker()
    private let commander = WindowCommander()
    private var authenticatedConnections: Set<ObjectIdentifier> = []
    private var cancellables = Set<AnyCancellable>()

    private var mainWindow: NSWindow?

    private var pairingToken: String = {
        if let t = UserDefaults.standard.string(forKey: "dispatch.authToken") { return t }
        let chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        let t = String((0..<8).map { _ in chars.randomElement()! })
        UserDefaults.standard.set(t, forKey: "dispatch.authToken")
        return t
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupDaemonState()
        setupMenuBar()
        setupPipeline()
        tracker.onPermissionDenied = {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Accessibility Access Required"
                alert.informativeText = "Dispatch needs Accessibility access to track and control your terminal windows. Please enable it in System Settings → Privacy & Security → Accessibility."
                alert.addButton(withTitle: "Open Settings")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                    NSWorkspace.shared.open(url)
                }
            }
        }
        tracker.start()
        server.start()
        print("[Dispatch] Daemon started. Pairing token: \(pairingToken)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        tracker.stop()
        server.stop()
    }

    private func setupDaemonState() {
        DaemonState.shared.isRunning = true
        DaemonState.shared.pairingToken = pairingToken

        // Observe client changes to update icon
        DaemonState.shared.$authenticatedClients
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMenuBarIcon() }
            .store(in: &cancellables)
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateMenuBarIcon()
        statusItem?.button?.toolTip = "Dispatch - Click to open"

        // Left-click opens window
        if let button = statusItem?.button {
            button.action = #selector(openMainWindow)
            button.target = self
            button.sendAction(on: .leftMouseDown)
        }

        let tokenItem = NSMenuItem(title: "Token: \(pairingToken)", action: nil, keyEquivalent: "")
        tokenItem.isEnabled = false
        tokenMenuItem = tokenItem

        // Right-click menu
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Dispatch", action: #selector(openMainWindow), keyEquivalent: "o"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Dispatch — Running", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(tokenItem)
        menu.addItem(NSMenuItem(title: "Copy Pairing Token", action: #selector(copyPairingToken), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "Generate New Token", action: #selector(regenerateToken), keyEquivalent: "n"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func openMainWindow() {
        if mainWindow == nil {
            let contentView = MainWindow()
            let hostingController = NSHostingController(rootView: contentView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Dispatch"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateMenuBarIcon() {
        let hasClients = DaemonState.shared.authenticatedClients > 0
        if hasClients {
            let image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: nil)
            statusItem?.button?.image = image
            statusItem?.button?.title = ""
        } else {
            statusItem?.button?.image = nil
            statusItem?.button?.title = "D"
        }
    }

    @objc private func copyPairingToken() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairingToken, forType: .string)
    }

    @objc private func regenerateToken() {
        let chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        let t = String((0..<8).map { _ in chars.randomElement()! })
        UserDefaults.standard.set(t, forKey: "dispatch.authToken")
        pairingToken = t
        tokenMenuItem?.title = "Token: \(pairingToken)"
        DaemonState.shared.pairingToken = t
        authenticatedConnections.removeAll()
        DaemonState.shared.authenticatedClients = 0
        print("[Dispatch] New pairing token: \(pairingToken)")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func setupPipeline() {
        let screenSize = WindowTracker.mainScreenSize

        tracker.onInitialState = { [weak self] windows in
            guard let self else { return }
            let authenticated = self.connectionsByID(self.authenticatedConnections)
            for conn in authenticated {
                self.server.send(.handshake(screenW: Double(screenSize.width), screenH: Double(screenSize.height)), to: conn)
                self.server.send(.state(windows), to: conn)
            }
        }

        tracker.onDelta = { [weak self] changed, removed in
            guard let self else { return }
            let authenticated = self.connectionsByID(self.authenticatedConnections)
            for conn in authenticated {
                self.server.send(.delta(changed: changed, removed: removed), to: conn)
            }
        }

        server.onClientConnected = { [weak self] _ in
            guard let self else { return }
            DaemonState.shared.connectedClients = self.server.connections.count
        }

        server.onClientDisconnected = { [weak self] connection in
            guard let self else { return }
            self.authenticatedConnections.remove(ObjectIdentifier(connection))
            DaemonState.shared.connectedClients = self.server.connections.count
            DaemonState.shared.authenticatedClients = self.authenticatedConnections.count
        }

        server.onMessage = { [weak self] message, connection in
            guard let self else { return }
            let connID = ObjectIdentifier(connection)

            if case .auth(let token) = message {
                if token == self.pairingToken {
                    self.authenticatedConnections.insert(connID)
                    self.server.send(.authResult(success: true), to: connection)
                    DaemonState.shared.authenticatedClients = self.authenticatedConnections.count
                    DispatchQueue.main.async {
                        let screenSize = WindowTracker.mainScreenSize
                        self.server.send(.handshake(screenW: Double(screenSize.width), screenH: Double(screenSize.height)), to: connection)
                        self.server.send(.state(self.tracker.currentWindows), to: connection)
                    }
                } else {
                    self.server.send(.authResult(success: false), to: connection)
                }
                return
            }

            guard self.authenticatedConnections.contains(connID) else { return }

            DispatchQueue.main.async {
                self.commander.execute(message)
            }
        }
    }

    private func connectionsByID(_ ids: Set<ObjectIdentifier>) -> [NWConnection] {
        ids.compactMap { server.connections[$0] }
    }
}
