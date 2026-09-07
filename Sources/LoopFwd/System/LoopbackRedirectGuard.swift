import Foundation

/// A local provider endpoint must never redirect observation or control to
/// another host, port or application. Even loopback-to-loopback redirects fail.
final class LoopbackRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
