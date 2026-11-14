import Foundation
import os
import Security

/// HTTP(S) transport on URLSession with per-task delegates: incremental body delivery, back-pressure
/// by suspending the data task, cancellation, and TLS trust customisation (custom CA, verification
/// against the original host name through SSH tunnels, explicit skip).
public final class URLSessionTransport: NSObject, ClickHouseTransport, URLSessionDelegate, @unchecked Sendable {
    /// Suspend the data task above this many unprocessed bytes and resume below `lowWatermark`.
    static let highWatermark = 8 * 1024 * 1024
    static let lowWatermark = 2 * 1024 * 1024

    private let trust: TrustPolicy
    private let delegateQueue: OperationQueue
    private let state = OSAllocatedUnfairLock<URLSession?>(initialState: nil)

    public init(tls: TLSOptions = TLSOptions(), serverName: String? = nil, maxConnectionsPerHost: Int = 6) {
        trust = TrustPolicy(tls: tls, serverName: serverName)
        delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.name = "ccinnclickhouse.urlsession"
        super.init()
        let session = URLSession(configuration: Self.configuration(maxConnectionsPerHost: maxConnectionsPerHost), delegate: self,
                                 delegateQueue: delegateQueue)
        state.withLock { $0 = session }
    }

    static func configuration(maxConnectionsPerHost: Int) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = max(1, maxConnectionsPerHost)
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        configuration.waitsForConnectivity = false
        return configuration
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body.isEmpty ? nil : request.body
        urlRequest.timeoutInterval = min(max(1, request.timeout.isFinite ? request.timeout : 60), 7 * 24 * 3600)
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }

        let session: URLSession
        var oneOff: URLSession?
        if request.freshConnection {
            urlRequest.setValue("close", forHTTPHeaderField: "Connection")
            let single = URLSession(configuration: Self.configuration(maxConnectionsPerHost: 1), delegate: self, delegateQueue: delegateQueue)
            session = single
            oneOff = single
        } else {
            guard let shared = state.withLock({ $0 }) else {
                throw ClickHouseError(.network, "The connection was closed")
            }
            session = shared
        }
        if Task.isCancelled {
            oneOff?.invalidateAndCancel()
            throw ClickHouseError.cancelled()
        }
        let task = session.dataTask(with: urlRequest)
        let streaming = StreamingTaskDelegate(trust: trust)
        task.delegate = streaming
        // A one-off session is invalidated once its only task completes.
        oneOff?.finishTasksAndInvalidate()
        return try await withTaskCancellationHandler {
            try await streaming.start(task)
        } onCancel: {
            task.cancel()
        }
    }

    public func close() {
        let session = state.withLock { current -> URLSession? in
            defer { current = nil }
            return current
        }
        session?.invalidateAndCancel()
    }

    // MARK: URLSessionDelegate

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (disposition, credential) = trust.handle(challenge)
        completionHandler(disposition, credential)
    }
}

/// Decides server trust for HTTPS.
struct TrustPolicy: Sendable {
    let anchors: [Data]
    let skipVerification: Bool
    let serverName: String?

    init(tls: TLSOptions, serverName: String?) {
        anchors = TrustPolicy.certificates(fromPEM: tls.customCACertificate ?? "")
        skipVerification = tls.skipVerification
        self.serverName = serverName?.isEmpty == true ? nil : serverName
    }

    var isDefault: Bool { anchors.isEmpty && !skipVerification && serverName == nil }

    func handle(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        if isDefault { return (.performDefaultHandling, nil) }
        if skipVerification { return (.useCredential, URLCredential(trust: serverTrust)) }
        let host = serverName ?? challenge.protectionSpace.host
        return evaluate(serverTrust, host: host) ? (.useCredential, URLCredential(trust: serverTrust)) : (.cancelAuthenticationChallenge, nil)
    }

    func evaluate(_ serverTrust: SecTrust, host: String) -> Bool {
        let policy = SecPolicyCreateSSL(true, host as CFString)
        guard SecTrustSetPolicies(serverTrust, policy) == errSecSuccess else { return false }
        if !anchors.isEmpty {
            let certificates = anchors.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
            guard !certificates.isEmpty, SecTrustSetAnchorCertificates(serverTrust, certificates as CFArray) == errSecSuccess else { return false }
            // Keep the system roots trusted as well.
            SecTrustSetAnchorCertificatesOnly(serverTrust, false)
        }
        var error: CFError?
        return SecTrustEvaluateWithError(serverTrust, &error)
    }

    /// DER blobs of every certificate in a PEM bundle; bare base64 DER is accepted too.
    static func certificates(fromPEM text: String) -> [Data] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var blobs: [Data] = []
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        var remainder = Substring(trimmed)
        while let start = remainder.range(of: begin), let finish = remainder.range(of: end, range: start.upperBound..<remainder.endIndex) {
            let body = remainder[start.upperBound..<finish.lowerBound].filter { !$0.isWhitespace }
            if let data = Data(base64Encoded: String(body)) { blobs.append(data) }
            remainder = remainder[finish.upperBound...]
        }
        if blobs.isEmpty, let data = Data(base64Encoded: trimmed.filter { !$0.isWhitespace }) { blobs.append(data) }
        return blobs
    }
}

/// Bridges one data task's delegate callbacks to async/await with back-pressure.
final class StreamingTaskDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct State {
        var responseContinuation: CheckedContinuation<HTTPStreamingResponse, any Error>?
        var bodyContinuation: AsyncThrowingStream<Data, any Error>.Continuation?
        var task: URLSessionDataTask?
        var buffered = 0
        var suspended = false
        var completed = false
    }

    private let trust: TrustPolicy
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(trust: TrustPolicy) {
        self.trust = trust
    }

    func start(_ task: URLSessionDataTask) async throws -> HTTPStreamingResponse {
        try await withCheckedThrowingContinuation { continuation in
            let alreadyCancelled = state.withLock { state -> Bool in
                state.responseContinuation = continuation
                state.task = task
                return false
            }
            if !alreadyCancelled { task.resume() }
        }
    }

    // MARK: Back-pressure

    private func acknowledge(_ count: Int) {
        let resumeTask = state.withLock { state -> URLSessionDataTask? in
            state.buffered = max(0, state.buffered - count)
            guard state.suspended, state.buffered < URLSessionTransport.lowWatermark, !state.completed else { return nil }
            state.suspended = false
            return state.task
        }
        resumeTask?.resume()
    }

    private func cancelTask() {
        let task = state.withLock { state -> URLSessionDataTask? in state.completed ? nil : state.task }
        task?.cancel()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        let head = HTTPResponseHead(status: http?.statusCode ?? 0, headers: headers)
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .unbounded)
        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination { self?.cancelTask() }
        }
        let response = HTTPStreamingResponse(head: head, body: stream, onAcknowledge: { [weak self] count in self?.acknowledge(count) },
                                             onCancel: { [weak self] in self?.cancelTask() })
        let pending = state.withLock { state -> CheckedContinuation<HTTPStreamingResponse, any Error>? in
            state.bodyContinuation = continuation
            defer { state.responseContinuation = nil }
            return state.responseContinuation
        }
        completionHandler(.allow)
        pending?.resume(returning: response)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let (continuation, suspendTask) = state.withLock { state -> (AsyncThrowingStream<Data, any Error>.Continuation?, URLSessionDataTask?) in
            state.buffered += data.count
            var toSuspend: URLSessionDataTask?
            if state.buffered > URLSessionTransport.highWatermark, !state.suspended {
                state.suspended = true
                toSuspend = state.task
            }
            return (state.bodyContinuation, toSuspend)
        }
        suspendTask?.suspend()
        continuation?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (responseContinuation, bodyContinuation) = state.withLock { state in
            state.completed = true
            defer {
                state.responseContinuation = nil
                state.bodyContinuation = nil
                state.task = nil
            }
            return (state.responseContinuation, state.bodyContinuation)
        }
        if let responseContinuation {
            responseContinuation.resume(throwing: ClickHouseError.transport(error ?? URLError(.badServerResponse)))
        }
        if let error {
            bodyContinuation?.finish(throwing: ClickHouseError.transport(error))
        } else {
            bodyContinuation?.finish()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            let (disposition, credential) = trust.handle(challenge)
            completionHandler(disposition, credential)
        } else {
            // Credentials always travel in our own headers; never answer HTTP auth prompts.
            completionHandler(.rejectProtectionSpace, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Never follow redirects: they would drop or leak the credentials header.
        completionHandler(nil)
    }
}
