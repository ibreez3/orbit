import Foundation

public enum AgentJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AgentJSONValue])
    case object([String: AgentJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AgentJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AgentJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    public var jsonString: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public enum AgentOp: String, Codable, Sendable {
    case hello
    case admissionStatus = "admission_status"
    case call
    case revoke
    case ping
}

public struct AgentRequest: Codable, Equatable, Sendable {
    public var id: String
    public var op: AgentOp
    public var sessionId: String?
    public var token: String?
    public var tool: String?
    public var args: AgentJSONValue?

    public init(
        id: String,
        op: AgentOp,
        sessionId: String? = nil,
        token: String? = nil,
        tool: String? = nil,
        args: AgentJSONValue? = nil
    ) {
        self.id = id
        self.op = op
        self.sessionId = sessionId
        self.token = token
        self.tool = tool
        self.args = args
    }
}

public struct AgentResponse: Codable, Equatable, Sendable {
    public var id: String
    public var ok: Bool
    public var result: AgentJSONValue?
    public var error: AgentErrorBody?

    public init(
        id: String,
        ok: Bool,
        result: AgentJSONValue? = nil,
        error: AgentErrorBody? = nil
    ) {
        self.id = id
        self.ok = ok
        self.result = result
        self.error = error
    }
}
