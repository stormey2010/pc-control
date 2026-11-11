import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: JSONEncoder().encode(self)) }
    public subscript(_ key: String) -> JSONValue? { if case .object(let v) = self { return v[key] }; return nil }
    public var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var stringValue: String? { if case .string(let v) = self { return v }; return nil }
}

public struct Command: Encodable, Sendable, Equatable {
    public var id: Int?
    public let op: String
    public var level: Double?
    public var muted: Bool?
    public var display: String?
    public var dx: Int?
    public var dy: Int?
    public var button: String?
    public var action: String?
    public var text: String?
    public var key: String?
    public var modifiers: [String]?
    public var confirm: String?
    public var delaySeconds: Int?
    public init(_ op: String) { self.op = op }
    public static func move(dx: Int, dy: Int) -> Command { var c = Command("mouse.move"); c.dx = dx; c.dy = dy; return c }
    public static func scroll(dx: Int, dy: Int) -> Command { var c = Command("mouse.scroll"); c.dx = dx; c.dy = dy; return c }
    public static func button(_ button: String, _ action: String = "click") -> Command { var c = Command("mouse.button"); c.button = button; c.action = action; return c }
    public static func key(_ key: String, modifiers: [String] = []) -> Command { var c = Command("keyboard.key"); c.key = key; if !modifiers.isEmpty { c.modifiers = modifiers }; return c }
    public static func text(_ text: String) -> Command { var c = Command("keyboard.text"); c.text = text; return c }
    public static func media(_ key: String) -> Command { var c = Command("media.key"); c.key = key; return c }
    public static func volume(_ level: Double) -> Command { var c = Command("audio.set"); c.level = min(100,max(0,level)); return c }
    public static func mute(_ muted: Bool) -> Command { var c = Command("audio.set"); c.muted = muted; return c }
    public static func brightness(_ id: String, _ level: Double) -> Command { var c = Command("display.set"); c.display = id; c.level = min(100,max(0,level)); return c }
    public static func shutdown() -> Command { var c = Command("system.shutdown"); c.confirm = "shutdown"; c.delaySeconds = 30; return c }
}

public struct RemoteFailure: Decodable, Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public var errorDescription: String? { message }
}
public struct Reply: Decodable, Sendable {
    public let id: Int?
    public let ok: Bool?
    public let result: JSONValue?
    public let error: RemoteFailure?
    public let event: String?
    public let info: DeviceInfo?
}
public struct Desktop: Codable, Sendable, Equatable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
}
public struct DeviceInfo: Decodable, Sendable {
    public let version: String
    public let protocolVersion: Int
    public let deviceId: String
    public let name: String
    public let desktop: Desktop
}
public struct AudioState: Codable, Sendable, Equatable {
    public var level: Double
    public var muted: Bool
    public init(level: Double, muted: Bool) { self.level = level; self.muted = muted }
}
public struct DisplayState: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var backend: String
    public var bounds: Desktop?
    public var brightness: Double?
    public var supported: Bool
    public var reason: String?
    public init(id: String, name: String, backend: String = "ddc-ci", bounds: Desktop? = nil, brightness: Double?, supported: Bool = true, reason: String? = nil) {
        self.id = id; self.name = name; self.backend = backend; self.bounds = bounds; self.brightness = brightness; self.supported = supported; self.reason = reason
    }
}
