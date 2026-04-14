import Foundation
import Network

final class WebSocketServer {

    var onMessage: ((InboundMessage, NWConnection) -> Void)?
    var onBinaryData: ((Data, NWConnection) -> Void)?
    var onClientConnected: ((NWConnection) -> Void)?
    var onClientDisconnected: ((NWConnection) -> Void)?

    private var listener: NWListener?
    private(set) var connections: [ObjectIdentifier: NWConnection] = [:]
    private let port: NWEndpoint.Port = 8765
    private let queue = DispatchQueue(label: "dispatch.websocket", qos: .userInitiated)

    func start() {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            print("[WebSocketServer] Failed to create listener: \(error)")
            return
        }

        let macName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        listener?.service = NWListener.Service(name: macName, type: "_dispatch._tcp")

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[WebSocketServer] Listening on port \(self?.port.rawValue ?? 0), advertising via Bonjour")
            case .failed(let error):
                print("[WebSocketServer] Listener failed: \(error)")
                self?.listener?.cancel()
            default: break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.accept(connection: connection)
        }

        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
    }

    // MARK: - Text Messages

    func broadcast(_ message: OutboundMessage) {
        guard let json = message.toJSON(), let data = json.data(using: .utf8) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        for connection in connections.values {
            connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
        }
    }

    func send(_ message: OutboundMessage, to connection: NWConnection) {
        guard let json = message.toJSON(), let data = json.data(using: .utf8) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    // MARK: - Binary Messages

    func sendBinary(_ data: Data, to connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "binary", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    func sendBinary(_ data: Data) {
        for connection in connections.values {
            sendBinary(data, to: connection)
        }
    }

    // MARK: - Connection Lifecycle

    private func accept(connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[WebSocketServer] Client connected")
                self?.receive(from: connection)
                DispatchQueue.main.async {
                    self?.onClientConnected?(connection)
                }
            case .failed(let error):
                print("[WebSocketServer] Client failed: \(error)")
                self?.connections.removeValue(forKey: id)
                DispatchQueue.main.async {
                    self?.onClientDisconnected?(connection)
                }
            case .cancelled:
                self?.connections.removeValue(forKey: id)
                DispatchQueue.main.async {
                    self?.onClientDisconnected?(connection)
                }
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(from connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            defer { self?.receive(from: connection) }
            if let error = error { print("[WebSocketServer] Receive error: \(error)"); return }
            guard let data = data else { return }

            let isBinary = context?.protocolMetadata
                .compactMap { $0 as? NWProtocolWebSocket.Metadata }
                .first?.opcode == .binary

            if isBinary {
                self?.onBinaryData?(data, connection)
            } else {
                if let json = String(data: data, encoding: .utf8),
                   let message = InboundMessage.from(jsonString: json) {
                    self?.onMessage?(message, connection)
                }
            }
        }
    }
}
