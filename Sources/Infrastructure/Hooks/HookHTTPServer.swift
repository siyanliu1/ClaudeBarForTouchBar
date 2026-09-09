import Foundation
import Network
import Domain

/// Lightweight HTTP server using Network.framework (NWListener).
/// Listens on localhost only, receives hook events via POST /hook.
/// All mutable state is accessed only from `queue` — NWListener callbacks
/// and external callers both dispatch onto it, so no queue.sync is needed
/// inside callbacks (which already run on queue).
public final class HookHTTPServer: @unchecked Sendable {
    private var listener: NWListener?
    private var continuation: AsyncStream<SessionEvent>.Continuation?
    private let defaultPort: UInt16

    /// Serial queue for synchronizing all mutable state.
    /// NWListener and NWConnection callbacks also run on this queue.
    private let queue = DispatchQueue(label: "com.tddworks.claudebar.hookserver")

    /// The actual port the server is listening on
    public private(set) var actualPort: UInt16 = 0

    /// Hook payloads are a few KB at most; this only bounds a runaway sender.
    private static let maxRequestBytes = 1 << 20

    private static let continueResponse = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)

    public init(defaultPort: UInt16 = HookConstants.defaultPort) {
        self.defaultPort = defaultPort
    }

    /// Starts the HTTP server and returns a stream of parsed session events.
    public func start() async throws -> AsyncStream<SessionEvent> {
        let stream = AsyncStream<SessionEvent> { continuation in
            self.queue.async {
                self.continuation = continuation
            }
            continuation.onTermination = { _ in
                self.stop()
            }
        }

        // Try default port first, fall back to auto-assign
        let port: NWEndpoint.Port
        if let preferredPort = NWEndpoint.Port(rawValue: defaultPort) {
            port = preferredPort
        } else {
            port = .any
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)

        let listener = try NWListener(using: parameters)

        // stateUpdateHandler runs on `queue` (set by listener.start below),
        // so we access mutable state directly — no queue.sync needed.
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let actualPort = listener.port?.rawValue {
                    self.actualPort = actualPort
                    try? PortDiscovery.writePort(Int(actualPort))
                    AppLog.hooks.info("Hook HTTP server listening on port \(actualPort)")
                }
            case .failed(let error):
                AppLog.hooks.error("Hook HTTP server failed: \(error.localizedDescription)")
                self.continuation?.finish()
            default:
                break
            }
        }

        // newConnectionHandler also runs on `queue`.
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener.start(queue: queue)
        queue.async { self.listener = listener }

        return stream
    }

    /// Stops the HTTP server and cleans up.
    public func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            continuation?.finish()
            continuation = nil
            PortDiscovery.removePortFile()
            AppLog.hooks.info("Hook HTTP server stopped")
        }
    }

    // MARK: - Connection Handling

    /// Runs on `queue` (via newConnectionHandler).
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, into: HTTPRequestBuffer())
    }

    /// Reads until the whole request has arrived, then answers and closes.
    ///
    /// A single `receive` is not enough: curl holds a body over roughly 1 KB
    /// behind `Expect: 100-continue`, so the first read returns headers alone —
    /// and those already end in `\r\n\r\n`, so they parse as a complete
    /// request with an empty body. Every `Stop` event carrying a long assistant
    /// message was lost that way.
    ///
    /// Runs on `queue` (the connection was started on it).
    private func receive(on connection: NWConnection, into buffer: HTTPRequestBuffer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestBytes) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                AppLog.hooks.debug("Connection error: \(error.localizedDescription)")
                self.respondAndClose(connection)
                return
            }

            var buffer = buffer
            if let data, !data.isEmpty {
                buffer.append(data)
            }

            // Unblock a client that is waiting for permission to send its body.
            if buffer.needsContinue {
                buffer.didSendContinue = true
                connection.send(
                    content: Self.continueResponse,
                    completion: .contentProcessed { _ in }
                )
            }

            if buffer.isComplete {
                self.processHTTPRequest(buffer.data)
                self.respondAndClose(connection)
                return
            }

            // The peer finished without completing the request, or is sending
            // more than any hook event could plausibly be.
            if isComplete || buffer.data.count >= Self.maxRequestBytes {
                AppLog.hooks.warning("Incomplete hook request (\(buffer.data.count) bytes); dropping")
                self.respondAndClose(connection)
                return
            }

            self.receive(on: connection, into: buffer)
        }
    }

    private func respondAndClose(_ connection: NWConnection) {
        let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(
            content: Data(response.utf8),
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }

    /// Runs on `queue` (called from connection.receive callback).
    private func processHTTPRequest(_ rawData: Data) {
        guard let rawString = String(data: rawData, encoding: .utf8) else { return }

        guard let separatorRange = rawString.range(of: "\r\n\r\n") else {
            AppLog.hooks.debug("No HTTP body found in request")
            return
        }

        let headerPart = rawString[rawString.startIndex..<separatorRange.lowerBound]

        // Only accept POST /hook
        guard headerPart.hasPrefix("POST /hook") else {
            AppLog.hooks.debug("Rejected non-POST /hook request")
            return
        }

        let bodyString = rawString[separatorRange.upperBound...]
        guard let bodyData = bodyString.data(using: .utf8) else { return }

        if let event = SessionEventParser.parse(bodyData) {
            AppLog.hooks.info("Received hook event: \(event.eventName.rawValue) for session \(event.sessionId)")
            continuation?.yield(event)
        } else {
            AppLog.hooks.warning("Failed to parse hook event payload")
        }
    }
}
