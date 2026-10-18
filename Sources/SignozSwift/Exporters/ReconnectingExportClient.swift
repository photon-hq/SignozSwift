import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import SwiftProtobuf

/// A `GrpcExportClient` that replaces its gRPC client after repeated connection failures.
///
/// grpc-swift only uses a connection once the server completes the TLS and HTTP/2
/// handshakes, and puts no time limit on them. If a handshake stalls while the TCP
/// connection stays open, every export waits behind it until its deadline, and the
/// client never dials again. After `failureThreshold` consecutive exports fail to reach
/// the collector, this drops the client with its connections and creates a new one, at
/// most once per `minimumRebuildInterval`.
final class ReconnectingExportClient: GrpcExportClient, @unchecked Sendable {

    /// A gRPC client and the task running its connections.
    struct Connection: Sendable {
        let client: any GrpcExportClient
        let task: Task<Void, Never>
        let beginShutdown: @Sendable () -> Void
    }

    private let makeConnection: @Sendable () throws -> Connection
    private let failureThreshold: Int
    private let minimumRebuildInterval: Duration
    private let now: @Sendable () -> ContinuousClock.Instant

    private let lock = NSLock()
    private var connection: Connection
    private var generation = 0
    private var consecutiveFailures = 0
    private var lastRebuild: ContinuousClock.Instant
    private var isClosed = false

    init(
        failureThreshold: Int = 3,
        minimumRebuildInterval: Duration = .seconds(60),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        makeConnection: @escaping @Sendable () throws -> Connection
    ) throws {
        self.makeConnection = makeConnection
        self.failureThreshold = failureThreshold
        self.minimumRebuildInterval = minimumRebuildInterval
        self.now = now
        self.connection = try makeConnection()
        self.lastRebuild = now()
    }

    func callUnary<Input: SwiftProtobuf.Message, Output: SwiftProtobuf.Message>(
        _ input: Input,
        descriptor: MethodDescriptor,
        metadata: Metadata,
        options: CallOptions
    ) async throws -> Output {
        let (client, generation) = lock.withLock { (connection.client, self.generation) }

        do {
            let output: Output = try await client.callUnary(
                input, descriptor: descriptor, metadata: metadata, options: options)
            record(failed: false, generation: generation)
            return output
        } catch {
            record(failed: Self.isConnectionFailure(error), generation: generation)
            throw error
        }
    }

    /// Stops rebuilding and returns the current connection for the caller to drain.
    func close() -> Connection {
        lock.lock()
        defer { lock.unlock() }
        isClosed = true
        return connection
    }

    /// Whether `error` means the export never got an answer from the collector. Any other
    /// `RPCError` came from a server that answered, so the connection works.
    static func isConnectionFailure(_ error: any Error) -> Bool {
        guard let error = error as? RPCError else { return true }
        return [.unavailable, .deadlineExceeded, .cancelled].contains(error.code)
    }

    private func record(failed: Bool, generation: Int) {
        lock.lock()
        guard !isClosed, generation == self.generation else {
            lock.unlock()
            return
        }
        guard failed else {
            consecutiveFailures = 0
            lock.unlock()
            return
        }
        consecutiveFailures += 1
        let current = now()
        guard consecutiveFailures >= failureThreshold,
              current - lastRebuild >= minimumRebuildInterval
        else {
            lock.unlock()
            return
        }
        let failures = consecutiveFailures
        lastRebuild = current
        consecutiveFailures = 0
        let replaced = connection
        do {
            connection = try makeConnection()
            self.generation += 1
        } catch {
            lock.unlock()
            fputs("SignozSwift: failed to recreate the gRPC client: \(error).\n", stdErr)
            return
        }
        lock.unlock()

        fputs("SignozSwift: \(failures) exports in a row got no answer from the collector; reconnecting.\n", stdErr)
        replaced.beginShutdown()
        replaced.task.cancel()
    }

    /// Creates a gRPC client for `host`:`port` and starts running its connections.
    static func connect(
        host: String,
        port: Int,
        transportSecurity: HTTP2ClientTransport.Posix.TransportSecurity
    ) throws -> Connection {
        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: host, port: port),
            transportSecurity: transportSecurity
        )
        let grpcClient = GRPCClient(transport: transport)
        let task = Task {
            do {
                try await grpcClient.runConnections()
            } catch is CancellationError {
                // Shutdown and reconnects cancel the connection loop after requesting a graceful drain.
            } catch {
                guard !Task.isCancelled else { return }
                fputs("SignozSwift: gRPC client connection loop stopped: \(error).\n", stdErr)
            }
        }
        return Connection(
            client: grpcClient,
            task: task,
            beginShutdown: { grpcClient.beginGracefulShutdown() }
        )
    }
}
