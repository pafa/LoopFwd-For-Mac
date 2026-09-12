import Foundation

/// HTTPS + WebSocket client for Session Hub transmitter endpoints (protocol v1).
final class HubClient: NSObject, URLSessionWebSocketDelegate {
    struct Registration: Equatable {
        var macDeviceId: String
        var macToken: String
        var pairingCode: String
        var hubUrl: String
    }

    var onActionForward: ((RemoteActionEnvelope) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    private var baseURL: URL
    private var macToken: String?
    private var session: URLSession!
    private var webSocket: URLSessionWebSocketTask?
    private var receiveLoopActive = false
    private let protocolHeader = "1"

    init(baseURL: URL = URL(string: "http://127.0.0.1:8787")!) {
        self.baseURL = baseURL
        super.init()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    func updateBaseURL(_ url: URL) {
        baseURL = url
    }

    // MARK: - HTTPS

    func register(displayName: String, pairingCode: String, macDeviceId: String?) async throws -> Registration {
        var body: [String: Any] = [
            "displayName": displayName,
            "pairingCode": pairingCode,
        ]
        if let macDeviceId, !macDeviceId.isEmpty {
            body["macDeviceId"] = macDeviceId
        }
        let data = try await postJSON(path: "/v1/transmitter/register", body: body, bearer: nil)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = obj["macDeviceId"] as? String,
            let token = obj["macToken"] as? String,
            let code = obj["pairingCode"] as? String
        else {
            throw HubClientError.badResponse
        }
        let hubUrl = (obj["hubUrl"] as? String) ?? baseURL.absoluteString
        macToken = token
        return Registration(macDeviceId: id, macToken: token, pairingCode: code, hubUrl: hubUrl)
    }

    func publishSessionsHTTPS(_ sessions: [SessionProjection], headline: AggregateHeadline?, token: String)
        async throws
    {
        var body: [String: Any] = [
            "sessions": try jsonObject(sessions)
        ]
        if let headline {
            body["headline"] = try jsonObject(headline)
        }
        _ = try await postJSON(path: "/v1/transmitter/sessions", body: body, bearer: token)
    }

    func postActionResult(_ result: ActionResult, token: String) async throws {
        let body = try jsonObject(result)
        guard let dict = body as? [String: Any] else { throw HubClientError.badResponse }
        _ = try await postJSON(path: "/v1/transmitter/action-result", body: dict, bearer: token)
    }

    func postPresence(online: Bool, token: String) async throws {
        _ = try await postJSON(
            path: "/v1/transmitter/presence", body: ["online": online], bearer: token)
    }

    // MARK: - WebSocket

    func connect(macToken: String) {
        self.macToken = macToken
        disconnect(sendPresence: false)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return }
        components.scheme = (components.scheme == "https") ? "wss" : "ws"
        components.path = "/v1/transmitter"
        components.queryItems = [URLQueryItem(name: "macToken", value: macToken)]
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.setValue(protocolHeader, forHTTPHeaderField: "X-LoopFwd-Protocol")
        let task = session.webSocketTask(with: request)
        webSocket = task
        receiveLoopActive = true
        task.resume()
        listen()
        send(["type": "presence", "online": true])
        onConnectionChange?(true)
    }

    func disconnect(sendPresence: Bool = true) {
        receiveLoopActive = false
        if sendPresence, macToken != nil {
            send(["type": "presence", "online": false])
        }
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        onConnectionChange?(false)
    }

    func sendSessionsPublish(_ sessions: [SessionProjection], headline: AggregateHeadline?) {
        do {
            var payload: [String: Any] = [
                "type": "sessionsPublish",
                "sessions": try jsonObject(sessions),
            ]
            if let headline {
                payload["headline"] = try jsonObject(headline)
            }
            send(payload)
        } catch {
            onError?("sessionsPublish encode failed: \(error.localizedDescription)")
        }
    }

    func sendActionResult(_ result: ActionResult) {
        do {
            send([
                "type": "actionResult",
                "result": try jsonObject(result),
            ])
        } catch {
            onError?("actionResult encode failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Internals

    private func listen() {
        guard receiveLoopActive, let webSocket else { return }
        webSocket.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.onError?(error.localizedDescription)
                self.onConnectionChange?(false)
            case .success(let message):
                self.handle(message)
                self.listen()
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let text): data = text.data(using: .utf8)
        case .data(let d): data = d
        @unknown default: data = nil
        }
        guard let data,
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = obj["type"] as? String
        else { return }

        switch type {
        case "ping":
            send(["type": "ping"])
        case "actionForward":
            if let envelopeObj = obj["envelope"] {
                do {
                    let envelopeData = try JSONSerialization.data(withJSONObject: envelopeObj)
                    var envelope = try ProtocolJSON.decoder.decode(RemoteActionEnvelope.self, from: envelopeData)
                    envelope.normalize()
                    onActionForward?(envelope)
                } catch {
                    onError?("actionForward decode failed: \(error.localizedDescription)")
                }
            }
        case "error":
            onError?((obj["message"] as? String) ?? "Hub error")
        default:
            break
        }
    }

    private func send(_ payload: [String: Any]) {
        guard let webSocket,
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let text = String(data: data, encoding: .utf8)
        else { return }
        webSocket.send(.string(text)) { [weak self] error in
            if let error {
                self?.onError?(error.localizedDescription)
            }
        }
    }

    private func postJSON(path: String, body: [String: Any], bearer: String?) async throws -> Data {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        guard let requestURL = components.url else { throw HubClientError.badURL }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(protocolHeader, forHTTPHeaderField: "X-LoopFwd-Protocol")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HubClientError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw HubClientError.http(http.statusCode, message)
        }
        return data
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try ProtocolJSON.encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    // URLSessionWebSocketDelegate
    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        onConnectionChange?(true)
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        onConnectionChange?(false)
    }
}

enum HubClientError: Error, LocalizedError {
    case badURL
    case badResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid Hub URL"
        case .badResponse: return "Unexpected Hub response"
        case .http(let code, let body): return "Hub HTTP \(code): \(body)"
        }
    }
}
