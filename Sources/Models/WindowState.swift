import Foundation

// MARK: - Session State (replaces WindowState)

struct SessionState: Codable, Equatable, Identifiable {
    let id: String
    var title: String
    var rows: UInt16
    var cols: UInt16

    init(id: String, title: String = "Terminal", rows: UInt16 = 24, cols: UInt16 = 80) {
        self.id = id
        self.title = title
        self.rows = rows
        self.cols = cols
    }
}

// MARK: - Binary Frame Header

enum FrameType: UInt8 {
    case control = 0x01
    case ptyData = 0x02
}

struct BinaryFrame {
    static func encode(sessionID: String, data: Data) -> Data {
        var result = Data([FrameType.ptyData.rawValue])
        let idData = sessionID.data(using: .utf8) ?? Data()
        result.append(UInt8(idData.count))
        result.append(idData)
        result.append(data)
        return result
    }

    static func decode(_ frame: Data) -> (sessionID: String, data: Data)? {
        guard frame.count >= 2, frame[0] == FrameType.ptyData.rawValue else { return nil }
        let idLength = Int(frame[1])
        guard frame.count >= 2 + idLength else { return nil }
        let sessionID = String(data: frame[2..<(2 + idLength)], encoding: .utf8) ?? ""
        let ptyData = frame[(2 + idLength)...]
        return (sessionID, Data(ptyData))
    }
}

// MARK: - Outbound Messages (Daemon → Client, JSON text frames)

enum OutboundMessage {
    case authResult(success: Bool)
    case sessionCreated(id: String)
    case sessionExited(id: String, exitCode: Int32)
    case sessionsList([SessionState])

    func toJSON() -> String? {
        switch self {
        case .authResult(let success):
            return Self.encode(["type": "authResult", "success": success])
        case .sessionCreated(let id):
            return Self.encode(["type": "sessionCreated", "id": id])
        case .sessionExited(let id, let exitCode):
            return Self.encode(["type": "sessionExited", "id": id, "exitCode": Int(exitCode)])
        case .sessionsList(let sessions):
            guard let data = try? JSONEncoder().encode(sessions),
                  let str = String(data: data, encoding: .utf8) else { return nil }
            return #"{"type":"sessionsList","sessions":\#(str)}"#
        }
    }

    private static func encode(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Inbound Messages (Client → Daemon, JSON text frames)

enum InboundMessage: Decodable {
    case auth(token: String)
    case createSession(id: String, rows: Int, cols: Int)
    case resizeSession(id: String, rows: Int, cols: Int)
    case closeSession(id: String)

    private enum CodingKeys: String, CodingKey {
        case type, id, token, rows, cols
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "auth":
            let token = try container.decode(String.self, forKey: .token)
            self = .auth(token: token)
        case "createSession":
            let id = try container.decode(String.self, forKey: .id)
            let rows = try container.decode(Int.self, forKey: .rows)
            let cols = try container.decode(Int.self, forKey: .cols)
            self = .createSession(id: id, rows: rows, cols: cols)
        case "resizeSession":
            let id = try container.decode(String.self, forKey: .id)
            let rows = try container.decode(Int.self, forKey: .rows)
            let cols = try container.decode(Int.self, forKey: .cols)
            self = .resizeSession(id: id, rows: rows, cols: cols)
        case "closeSession":
            let id = try container.decode(String.self, forKey: .id)
            self = .closeSession(id: id)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown type: \(type)")
        }
    }

    static func from(jsonString: String) -> InboundMessage? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(InboundMessage.self, from: data)
    }
}
