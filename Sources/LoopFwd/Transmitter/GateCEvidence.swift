import Foundation

/// Greppable Gate C evidence markers for live same-requestId clear proof.
/// Device E2E greps these strings in logs; unit tests may set `logSink`.
enum GateCEvidence {
    static let actionForward = "GATE_C_ACTION_FORWARD"
    static let actionResult = "GATE_C_ACTION_RESULT"
    static let requestIdClear = "GATE_C_REQUEST_ID_CLEAR"
    static let sameRequestIdProof = "GATE_C_SAME_REQUEST_ID_PROOF"
    static let hubForwardReceived = "GATE_C_HUB_FORWARD_RECEIVED"
    static let hubActionResultSent = "GATE_C_HUB_ACTION_RESULT_SENT"

    /// Optional sink for tests; production falls back to `print`.
    static var logSink: ((String) -> Void)?

    static func log(_ marker: String, _ detail: String = "") {
        let line = detail.isEmpty ? marker : "\(marker) \(detail)"
        if let logSink {
            logSink(line)
        } else {
            print(line)
        }
    }

    static func actionForward(requestId: String, action: String) {
        log(actionForward, "requestId=\(requestId) action=\(action)")
    }

    static func actionResult(status: String, requestId: String) {
        log(actionResult, "status=\(status) requestId=\(requestId)")
    }

    static func requestIdClear(requestId: String) {
        log(requestIdClear, "requestId=\(requestId)")
    }

    static func sameRequestIdProof(requestId: String) {
        log(sameRequestIdProof, "requestId=\(requestId)")
    }

    static func hubForwardReceived(requestId: String) {
        log(hubForwardReceived, "requestId=\(requestId)")
    }

    static func hubActionResultSent(status: String, requestId: String) {
        log(hubActionResultSent, "status=\(status) requestId=\(requestId)")
    }
}
