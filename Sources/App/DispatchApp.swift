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
    private let ptyManager = PTYManager()
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
        server.start()
        print("[Dispatch] Daemon started. Pairing token: \(pairingToken)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }

    private func setupDaemonState() {
        DaemonState.shared.isRunning = true
        DaemonState.shared.pairingToken = pairingToken

        DaemonState.shared.$authenticatedClients
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMenuBarIcon() }
            .store(in: &cancellables)
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateMenuBarIcon()
        statusItem?.button?.toolTip = "Dispatch - Click to open"

        if let button = statusItem?.button {
            button.action = #selector(openMainWindow)
            button.target = self
            button.sendAction(on: .leftMouseDown)
        }

        let tokenItem = NSMenuItem(title: "Token: \(pairingToken)", action: nil, keyEquivalent: "")
        tokenItem.isEnabled = false
        tokenMenuItem = tokenItem

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

    // MARK: - PTY + WebSocket Pipeline

    private func setupPipeline() {
        ptyManager.onOutput = { [weak self] sessionID, data in
            guard let self else { return }
            let frame = BinaryFrame.encode(sessionID: sessionID, data: data)
            let authenticated = self.connectionsByID(self.authenticatedConnections)
            for conn in authenticated {
                self.server.sendBinary(frame, to: conn)
            }
        }

        ptyManager.onExit = { [weak self] sessionID, exitCode in
            guard let self else { return }
            let authenticated = self.connectionsByID(self.authenticatedConnections)
            for conn in authenticated {
                self.server.send(.sessionExited(id: sessionID, exitCode: exitCode), to: conn)
            }
            DaemonState.shared.activeSessions = self.ptyManager.activeSessionIDs.count
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

                    let sessions = self.ptyManager.activeSessionIDs.map { SessionState(id: $0) }
                    self.server.send(.sessionsList(sessions), to: connection)
                } else {
                    self.server.send(.authResult(success: false), to: connection)
                }
                return
            }

            guard self.authenticatedConnections.contains(connID) else { return }

            switch message {
            case .createSession(let id, let rows, let cols):
                let success = self.ptyManager.createSession(id: id, rows: UInt16(rows), cols: UInt16(cols))
                if success {
                    self.server.send(.sessionCreated(id: id), to: connection)
                    DaemonState.shared.activeSessions = self.ptyManager.activeSessionIDs.count
                }
            case .resizeSession(let id, let rows, let cols):
                self.ptyManager.resize(sessionID: id, rows: UInt16(rows), cols: UInt16(cols))
            case .closeSession(let id):
                self.ptyManager.close(sessionID: id)
                DaemonState.shared.activeSessions = self.ptyManager.activeSessionIDs.count
            default:
                break
            }
        }

        server.onBinaryData = { [weak self] data, connection in
            guard let self, self.authenticatedConnections.contains(ObjectIdentifier(connection)) else { return }
            if let (sessionID, ptyData) = BinaryFrame.decode(data) {
                self.ptyManager.write(sessionID: sessionID, data: ptyData)
            }
        }
    }

    private func connectionsByID(_ ids: Set<ObjectIdentifier>) -> [NWConnection] {
        ids.compactMap { server.connections[$0] }
    }
}
