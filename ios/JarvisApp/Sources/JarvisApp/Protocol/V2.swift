// Canonical iOS-app wire protocol v2 — Swift mirror of shared/ios-app-protocol/v2.ts.
// Pinned by shared/ios-app-protocol/fixtures/*.json contract tests in ProtocolFixtureTests.
import Foundation

enum V2 {
    static let protocolVersion = 2

    enum Kind: String, Codable {
        case data
        case control
        case ack
        case status
    }

    // Type literal strings for envelope.type — must match the canonical TS schema.
    enum TypeTag: String, Codable {
        case auth
        case authOk = "auth_ok"
        case authFail = "auth_fail"
        case message
        case contextRequest = "context_request"
        case contextResponse = "context_response"
        case newConversation = "new_conversation"
        case actionResponse = "action_response"
        case feedback
        case ack
        case ping
        case pong
        case delivered
        case read
    }

    // Discriminated payload union driven by the outer `type` field.
    enum Payload: Equatable {
        case auth(Auth)
        case authOk(AuthOk)
        case authFail(AuthFail)
        case message(Message)
        case contextRequest(ContextRequest)
        case contextResponse(ContextResponse)
        case newConversation(NewConversation)
        case actionResponse(ActionResponse)
        case feedback(Feedback)
        case ack(Ack)
        case ping(Ping)
        case pong(Pong)
        case statusBatch(StatusBatch) // covers both delivered and read
    }

    struct Envelope: Equatable {
        let v: Int
        let kind: Kind
        let type: TypeTag
        let id: String
        let seq: Int?
        let ts: String
        let payload: Payload
    }

    // MARK: - Payload bodies

    struct Auth: Codable, Equatable {
        let token: String
        let last_seen_inbound_seq: Int
        let capabilities: [String]
    }

    struct AuthOk: Codable, Equatable {
        let last_seen_outbound_seq: Int
        let server_time: String
        let commands: [Command]?
    }

    struct Command: Codable, Equatable {
        let command: String
        let description: String
    }

    struct AuthFail: Codable, Equatable {
        let reason: String
    }

    struct Message: Codable, Equatable {
        let thread_id: String
        let text: String
        let attachments: [Attachment]?
        let context: InlineContext?
        let agent_id: String?
        init(thread_id: String, text: String, attachments: [Attachment]? = nil, context: InlineContext? = nil, agent_id: String? = nil) {
            self.thread_id = thread_id
            self.text = text
            self.attachments = attachments
            self.context = context
            self.agent_id = agent_id
        }
    }

    struct Attachment: Codable, Equatable {
        let id: String
        let kind: String           // "image" | "file"
        let name: String
        let mime_type: String
        let byte_size: Int
        let bytes_base64: String?
        let remote_id: String?
    }

    struct InlineContext: Codable, Equatable {
        struct Location: Codable, Equatable {
            let lat: Double
            let lon: Double
            let accuracy: Double?
        }
        let location: Location?
        let timestamp: String
        let timezone: String
        let locality: String?
    }

    struct ContextRequest: Codable, Equatable {
        let request_id: String
        let fields: [String]
        let params: JSONValue?
        let agent_id: String?
        init(request_id: String, fields: [String], params: JSONValue? = nil, agent_id: String? = nil) {
            self.request_id = request_id
            self.fields = fields
            self.params = params
            self.agent_id = agent_id
        }
    }

    struct ContextResponse: Codable, Equatable {
        let request_id: String
        let data: JSONValue
        let errors: [String: String]?
        let agent_id: String?
        init(request_id: String, data: JSONValue, errors: [String: String]? = nil, agent_id: String? = nil) {
            self.request_id = request_id
            self.data = data
            self.errors = errors
            self.agent_id = agent_id
        }
    }

    struct NewConversation: Codable, Equatable {
        let thread_id: String
        let agent_id: String?
        init(thread_id: String, agent_id: String? = nil) {
            self.thread_id = thread_id
            self.agent_id = agent_id
        }
    }

    struct ActionResponse: Codable, Equatable {
        let action_id: String
        let choice: String
    }

    struct Feedback: Codable, Equatable {
        let message_id: String
        let kind: String           // "up" | "down"
    }

    struct Ack: Codable, Equatable {
        let id: String
        let seq: Int
    }

    struct Ping: Codable, Equatable {
        let nonce: String
    }

    typealias Pong = Ping

    struct StatusBatch: Codable, Equatable {
        let ids: [String]
    }

    // MARK: - Type-erased JSON value
    //
    // Used for ContextRequest.params and ContextResponse.data, which the
    // canonical schema declares as arbitrary records of unknown values.
    indirect enum JSONValue: Codable, Equatable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case array([JSONValue])
        case object([String: JSONValue])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() {
                self = .null
                return
            }
            if let v = try? c.decode(Bool.self) {
                self = .bool(v)
                return
            }
            // Try Int before Double so integer JSON literals stay integers.
            if let v = try? c.decode(Int.self) {
                self = .int(v)
                return
            }
            if let v = try? c.decode(Double.self) {
                self = .double(v)
                return
            }
            if let v = try? c.decode(String.self) {
                self = .string(v)
                return
            }
            if let v = try? c.decode([JSONValue].self) {
                self = .array(v)
                return
            }
            if let v = try? c.decode([String: JSONValue].self) {
                self = .object(v)
                return
            }
            throw DecodingError.dataCorruptedError(
                in: c,
                debugDescription: "unrecognized JSON value"
            )
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .bool(let v): try c.encode(v)
            case .int(let v): try c.encode(v)
            case .double(let v): try c.encode(v)
            case .string(let v): try c.encode(v)
            case .array(let v): try c.encode(v)
            case .object(let v): try c.encode(v)
            }
        }
    }
}

// MARK: - Envelope Codable

extension V2.Envelope: Codable {
    enum CodingKeys: String, CodingKey {
        case v, kind, type, id, seq, ts, payload
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        kind = try c.decode(V2.Kind.self, forKey: .kind)
        type = try c.decode(V2.TypeTag.self, forKey: .type)
        id = try c.decode(String.self, forKey: .id)
        // seq is nullable on the wire (e.g. ack, ping, pong, status:*). Treat
        // both "absent" and "null" as nil.
        seq = try c.decodeIfPresent(Int.self, forKey: .seq)
        ts = try c.decode(String.self, forKey: .ts)
        let payloadDecoder = try c.superDecoder(forKey: .payload)
        switch type {
        case .auth:
            payload = .auth(try V2.Auth(from: payloadDecoder))
        case .authOk:
            payload = .authOk(try V2.AuthOk(from: payloadDecoder))
        case .authFail:
            payload = .authFail(try V2.AuthFail(from: payloadDecoder))
        case .message:
            payload = .message(try V2.Message(from: payloadDecoder))
        case .contextRequest:
            payload = .contextRequest(try V2.ContextRequest(from: payloadDecoder))
        case .contextResponse:
            payload = .contextResponse(try V2.ContextResponse(from: payloadDecoder))
        case .newConversation:
            payload = .newConversation(try V2.NewConversation(from: payloadDecoder))
        case .actionResponse:
            payload = .actionResponse(try V2.ActionResponse(from: payloadDecoder))
        case .feedback:
            payload = .feedback(try V2.Feedback(from: payloadDecoder))
        case .ack:
            payload = .ack(try V2.Ack(from: payloadDecoder))
        case .ping:
            payload = .ping(try V2.Ping(from: payloadDecoder))
        case .pong:
            payload = .pong(try V2.Pong(from: payloadDecoder))
        case .delivered, .read:
            payload = .statusBatch(try V2.StatusBatch(from: payloadDecoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(kind, forKey: .kind)
        try c.encode(type, forKey: .type)
        try c.encode(id, forKey: .id)
        // Always encode seq so explicit `null` round-trips. Stateless envelopes
        // (ack/ping/pong/status:*) carry seq=null on the wire and we want the
        // re-encoded form to match.
        try c.encode(seq, forKey: .seq)
        try c.encode(ts, forKey: .ts)
        let payloadEncoder = c.superEncoder(forKey: .payload)
        switch payload {
        case .auth(let p): try p.encode(to: payloadEncoder)
        case .authOk(let p): try p.encode(to: payloadEncoder)
        case .authFail(let p): try p.encode(to: payloadEncoder)
        case .message(let p): try p.encode(to: payloadEncoder)
        case .contextRequest(let p): try p.encode(to: payloadEncoder)
        case .contextResponse(let p): try p.encode(to: payloadEncoder)
        case .newConversation(let p): try p.encode(to: payloadEncoder)
        case .actionResponse(let p): try p.encode(to: payloadEncoder)
        case .feedback(let p): try p.encode(to: payloadEncoder)
        case .ack(let p): try p.encode(to: payloadEncoder)
        case .ping(let p): try p.encode(to: payloadEncoder)
        case .pong(let p): try p.encode(to: payloadEncoder)
        case .statusBatch(let p): try p.encode(to: payloadEncoder)
        }
    }
}

// MARK: - HealthUpload (POST /ios/health/upload body)
// Schema lives in shared/ios-app-protocol/v2.ts:HealthUploadDay/HealthUploadBody.
// Pinned by fixtures/health/*.json — the Swift contract test round-trips the
// same fixture through this Codable mirror.

extension V2 {
    enum HealthUpload {
        struct Workout: Codable, Equatable {
            let type: String
            let startISO: String
            let durationMin: Double
            var energyKcal: Double?
            var avgHR: Int?
            var maxHR: Int?
        }

        struct Day: Codable, Equatable {
            let date: String
            var steps: Int?
            var activeEnergy: Int?
            var exerciseMinutes: Int?
            var heartRate: Int?
            var restingHeartRate: Int?
            var hrv: Int?
            var sleepHours: Double?
            // New in 2026-06-05 spec.
            var wristTempDeviation: Double?     // signed: ±°C from user baseline
            var respiratoryRate: Double?        // breaths/min
            var walkingHeartRateAverage: Int?   // bpm
            var vo2max: Double?                 // mL/kg/min
            var workouts: [Workout]?
        }

        struct Body: Codable, Equatable {
            var platformId: String?
            var requestId: String?
            var days: [Day]
        }
    }
}
