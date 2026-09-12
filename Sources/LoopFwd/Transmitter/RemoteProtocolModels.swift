import Foundation

/// LoopFwd Remote Protocol v1 DTOs (Session Projection + actions).
/// Kept local to the transmitter so Mac does not depend on the iOS target.

enum RemoteActionLimits {
    static let replyTextMaxLength = 500
}

enum RemoteSessionStatus: String, Codable, Sendable {
    case working, stalled, completed, needsAttention, failed, stopped, idle
}

enum RemoteAttentionKind: String, Codable, Sendable {
    case question, approval, authentication, confirmation
}

struct RemoteSessionCapabilities: Codable, Sendable, Equatable {
    var observe: Bool
    var reply: Bool
    var approve: Bool
    var stop: Bool
    var openDetail: Bool

    static let observeOnly = RemoteSessionCapabilities(
        observe: true, reply: false, approve: false, stop: false, openDetail: true)
}

struct RemotePendingQuestion: Codable, Sendable, Equatable {
    var prompt: String
    var options: [String]
    var multiSelect: Bool
    var requestId: String
    var expiresAt: Date
}

enum RemoteApprovalActionKind: String, Codable, Sendable {
    case approve, alwaysAllow, deny
}

struct RemoteApprovalRequest: Codable, Sendable, Equatable {
    var title: String
    var toolName: String?
    /// Sticky / glance category (`files`, `app`, or provider-native).
    var permissionCategory: String?
    var message: String?
    var actions: [RemoteApprovalActionKind]
    var requestId: String
    var expiresAt: Date
}

struct SessionProjection: Codable, Sendable, Equatable {
    var sessionId: String
    var macDeviceId: String
    var kind: String
    var surfaceId: String?
    var title: String
    var project: String?
    var status: RemoteSessionStatus
    var attentionKind: RemoteAttentionKind?
    var activity: String?
    var taskSummary: String?
    var updatedAt: Date
    var pendingQuestion: RemotePendingQuestion?
    var approval: RemoteApprovalRequest?
    var capabilities: RemoteSessionCapabilities
    var macOnline: Bool
    var observationStale: Bool
}

struct AggregateHeadline: Codable, Sendable, Equatable {
    var macDeviceId: String?
    var attentionCount: Int
    var workingCount: Int
    var priorityStatus: RemoteSessionStatus
    var prioritySessionId: String?
    var priorityKind: String?
    var priorityTitle: String?

    static func from(sessions: [SessionProjection], macDeviceId: String) -> AggregateHeadline {
        let attention = sessions.filter { $0.status == .needsAttention }
        let working = sessions.filter { $0.status == .working || $0.status == .stalled }
        let order: [RemoteSessionStatus] = [
            .needsAttention, .failed, .stalled, .working, .completed, .stopped, .idle,
        ]
        let priority = sessions.min { a, b in
            let ia = order.firstIndex(of: a.status) ?? 99
            let ib = order.firstIndex(of: b.status) ?? 99
            if ia != ib { return ia < ib }
            return a.updatedAt > b.updatedAt
        }
        return AggregateHeadline(
            macDeviceId: macDeviceId,
            attentionCount: attention.count,
            workingCount: working.count,
            priorityStatus: priority?.status ?? .idle,
            prioritySessionId: priority?.sessionId,
            priorityKind: priority?.kind,
            priorityTitle: priority?.title
        )
    }
}

enum RemoteActionKind: String, Codable, Sendable {
    case approve, deny, alwaysAllow, selectOptions, replyText, stop
}

struct RemoteActionEnvelope: Codable, Sendable {
    var action: RemoteActionKind
    var sessionId: String
    var macDeviceId: String
    var requestId: String
    var clientActionId: String
    var issuedAt: Date
    var deviceToken: String
    var optionIndexes: [Int]?
    var text: String?

    init(
        action: RemoteActionKind,
        sessionId: String,
        macDeviceId: String,
        requestId: String,
        clientActionId: String = UUID().uuidString,
        issuedAt: Date = Date(),
        deviceToken: String,
        optionIndexes: [Int]? = nil,
        text: String? = nil
    ) {
        self.action = action
        self.sessionId = sessionId
        self.macDeviceId = macDeviceId
        self.requestId = requestId
        self.clientActionId = clientActionId
        self.issuedAt = issuedAt
        self.deviceToken = deviceToken
        self.optionIndexes = optionIndexes
        self.text = text
    }

    mutating func normalize() {
        guard let text else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.text = trimmed.isEmpty ? "" : String(trimmed.prefix(RemoteActionLimits.replyTextMaxLength))
    }
}

enum ActionResultStatus: String, Codable, Sendable {
    case accepted, rejected, expired, offline, unauthorized
}

struct ActionResult: Codable, Sendable {
    var clientActionId: String
    var status: ActionResultStatus
    var message: String?
    var session: SessionProjection?
}

enum ProtocolJSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
