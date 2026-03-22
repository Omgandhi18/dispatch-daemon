import Foundation

// MARK: - Window Status

enum WindowStatus: String, Codable {
    case running
    case idle
    case finished
}

// MARK: - Window State

struct WindowState: Codable, Equatable {
    let id: String
    var title: String
    var status: WindowStatus
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var isFocused: Bool
    var content: String?
    var zOrder: Int

    static func == (lhs: WindowState, rhs: WindowState) -> Bool {
        lhs.id == rhs.id &&
        lhs.title == rhs.title &&
        lhs.status == rhs.status &&
        lhs.x == rhs.x &&
        lhs.y == rhs.y &&
        lhs.w == rhs.w &&
        lhs.h == rhs.h &&
        lhs.isFocused == rhs.isFocused &&
        lhs.content == rhs.content &&
        lhs.zOrder == rhs.zOrder
    }
}

// MARK: - Outbound Messages (Mac → Phone)

enum OutboundMessage {
    case handshake(screenW: Double, screenH: Double)
    case state([WindowState])
    case delta(changed: [WindowState], removed: [String])
    case authResult(success: Bool)

    func toJSON() -> String? {
        let encoder = JSONEncoder()
        switch self {
        case .handshake(let w, let h):
            let payload: [String: Any] = ["type": "handshake", "screenW": w, "screenH": h]
            return payload.toJSONString()
        case .state(let windows):
            guard let data = try? encoder.encode(windows),
                  let arr = String(data: data, encoding: .utf8) else { return nil }
            return #"{"type":"state","windows":\#(arr)}"#
        case .delta(let changed, let removed):
            guard let changedData = try? encoder.encode(changed),
                  let removedData = try? encoder.encode(removed),
                  let changedStr = String(data: changedData, encoding: .utf8),
                  let removedStr = String(data: removedData, encoding: .utf8) else { return nil }
            return #"{"type":"delta","changed":\#(changedStr),"removed":\#(removedStr)}"#
        case .authResult(let success):
            let payload: [String: Any] = ["type": "authResult", "success": success]
            return payload.toJSONString()
        }
    }
}

// MARK: - Inbound Messages (Phone → Mac)

enum InboundMessage: Decodable {
    case focus(id: String)
    case move(id: String, x: Double, y: Double)
    case resize(id: String, w: Double, h: Double)
    case type_(id: String, text: String)
    case close(id: String)
    case openNew
    case auth(token: String)

    private enum CodingKeys: String, CodingKey {
        case type, id, x, y, w, h, text, token
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type_ = try container.decode(String.self, forKey: .type)
        if type_ == "openNew" {
            self = .openNew
            return
        }
        if type_ == "auth" {
            let token = try container.decode(String.self, forKey: .token)
            self = .auth(token: token)
            return
        }
        let id = try container.decode(String.self, forKey: .id)
        switch type_ {
        case "focus":
            self = .focus(id: id)
        case "move":
            let x = try container.decode(Double.self, forKey: .x)
            let y = try container.decode(Double.self, forKey: .y)
            self = .move(id: id, x: x, y: y)
        case "resize":
            let w = try container.decode(Double.self, forKey: .w)
            let h = try container.decode(Double.self, forKey: .h)
            self = .resize(id: id, w: w, h: h)
        case "type":
            let text = try container.decode(String.self, forKey: .text)
            self = .type_(id: id, text: text)
        case "close":
            self = .close(id: id)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown type: \(type_)")
        }
    }

    static func from(jsonString: String) -> InboundMessage? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(InboundMessage.self, from: data)
    }
}

private extension Dictionary where Key == String, Value == Any {
    func toJSONString() -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
