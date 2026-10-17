import Foundation
import GRPCCore
import SwiftProtobuf
import Testing
@testable import SignozSwift

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("Reconnecting export client")
struct ReconnectingExportClientTests {

    @Test("Reconnects after consecutive exports get no answer")
    func reconnectsAfterFailures() async throws {
        let failure = FakeConnections.Outcome.fail(RPCError(code: .deadlineExceeded, message: ""))
        let connections = FakeConnections(outcomes: [failure, failure, failure, .succeed])
        let client = try ReconnectingExportClient(
            failureThreshold: 3, minimumRebuildInterval: .zero, makeConnection: connections.make)

        for _ in 0..<3 { #expect(await export(through: client) == false) }

        let created = connections.created
        try #require(created.count == 2)
        #expect(created[0].shutdownRequested)
        #expect(created[0].connection.task.isCancelled)
        #expect(!created[1].shutdownRequested)
        #expect(await export(through: client))
    }

    @Test("Waits the minimum interval between reconnects")
    func rateLimited() async throws {
        let clock = ManualClock()
        let connections = FakeConnections(outcomes: [.fail(RPCError(code: .unavailable, message: ""))])
        let client = try ReconnectingExportClient(
            failureThreshold: 3, minimumRebuildInterval: .seconds(60), now: clock.now,
            makeConnection: connections.make)

        for _ in 0..<5 { _ = await export(through: client) }
        #expect(connections.created.count == 1)

        clock.advance(by: .seconds(60))
        _ = await export(through: client)
        #expect(connections.created.count == 2)

        for _ in 0..<5 { _ = await export(through: client) }
        #expect(connections.created.count == 2)
    }

    @Test("A successful export resets the failure count")
    func successResets() async throws {
        let failure = FakeConnections.Outcome.fail(RPCError(code: .deadlineExceeded, message: ""))
        let connections = FakeConnections(outcomes: [failure, failure, .succeed, failure, failure])
        let client = try ReconnectingExportClient(
            failureThreshold: 3, minimumRebuildInterval: .zero, makeConnection: connections.make)

        for _ in 0..<5 { _ = await export(through: client) }

        #expect(connections.created.count == 1)
    }

    @Test("Errors the collector answered with do not reconnect")
    func answeredErrorsDoNotCount() async throws {
        let connections = FakeConnections(outcomes: [.fail(RPCError(code: .invalidArgument, message: ""))])
        let client = try ReconnectingExportClient(
            failureThreshold: 3, minimumRebuildInterval: .zero, makeConnection: connections.make)

        for _ in 0..<5 { _ = await export(through: client) }

        #expect(connections.created.count == 1)
        #expect(ReconnectingExportClient.isConnectionFailure(CancellationError()))
        #expect(!ReconnectingExportClient.isConnectionFailure(RPCError(code: .resourceExhausted, message: "")))
    }

    @Test("Closing stops reconnects")
    func closeStopsReconnects() async throws {
        let connections = FakeConnections(outcomes: [.fail(RPCError(code: .unavailable, message: ""))])
        let client = try ReconnectingExportClient(
            failureThreshold: 1, minimumRebuildInterval: .zero, makeConnection: connections.make)

        _ = client.close()
        for _ in 0..<3 { _ = await export(through: client) }

        let created = connections.created
        #expect(created.count == 1)
        #expect(created.first?.shutdownRequested == false)
    }

    @Test("Drops a connection whose handshake never completes and dials again")
    func replacesStalledConnection() async throws {
        let server = try SilentServer()
        defer { server.stop() }
        let client = try ReconnectingExportClient(failureThreshold: 2, minimumRebuildInterval: .zero) {
            try ReconnectingExportClient.connect(host: "127.0.0.1", port: server.port, transportSecurity: .plaintext)
        }
        defer {
            let connection = client.close()
            connection.beginShutdown()
            connection.task.cancel()
        }

        var attempts = 0
        while server.acceptedCount < 2 && attempts < 10 {
            #expect(await export(through: client, timeout: .milliseconds(500)) == false)
            attempts += 1
        }

        #expect(server.acceptedCount >= 2)
        #expect(await server.waitUntilClosed(connection: 0, timeout: .seconds(5)))
    }
}

/// Sends one unary call through `client` and reports whether it succeeded.
private func export(through client: ReconnectingExportClient, timeout: Duration = .seconds(5)) async -> Bool {
    var options = CallOptions.defaults
    options.timeout = timeout
    do {
        let _: Google_Protobuf_Empty = try await client.callUnary(
            Google_Protobuf_Empty(),
            descriptor: MethodDescriptor(fullyQualifiedService: "signoz.test.Export", method: "Export"),
            metadata: Metadata(),
            options: options
        )
        return true
    } catch {
        return false
    }
}

/// Hands out fake connections whose exports follow `outcomes`, one per call, repeating the last.
private final class FakeConnections: @unchecked Sendable {
    enum Outcome {
        case succeed
        case fail(any Error)
    }

    struct Made {
        let connection: ReconnectingExportClient.Connection
        let shutdown: Flag

        var shutdownRequested: Bool { shutdown.isSet }
    }

    private let lock = NSLock()
    private var outcomes: [Outcome]
    private var made: [Made] = []

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    var created: [Made] {
        lock.lock()
        defer { lock.unlock() }
        return made
    }

    func make() throws -> ReconnectingExportClient.Connection {
        let shutdown = Flag()
        let connection = ReconnectingExportClient.Connection(
            client: FakeExportClient(next: { [unowned self] in self.nextOutcome() }),
            task: Task { try? await Task.sleep(for: .seconds(60)) },
            beginShutdown: { shutdown.set() }
        )
        lock.lock()
        made.append(Made(connection: connection, shutdown: shutdown))
        lock.unlock()
        return connection
    }

    private func nextOutcome() -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        return outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

private struct FakeExportClient: GrpcExportClient {
    let next: @Sendable () -> FakeConnections.Outcome

    func callUnary<Input: SwiftProtobuf.Message, Output: SwiftProtobuf.Message>(
        _ input: Input,
        descriptor: MethodDescriptor,
        metadata: Metadata,
        options: CallOptions
    ) async throws -> Output {
        switch next() {
        case .succeed: return Output()
        case .fail(let error): throw error
        }
    }
}

private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now

    var now: @Sendable () -> ContinuousClock.Instant {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            return instant
        }
    }

    func advance(by duration: Duration) {
        lock.lock()
        instant += duration
        lock.unlock()
    }
}

/// Accepts TCP connections on 127.0.0.1 and never sends a byte, so no handshake completes.
private final class SilentServer: @unchecked Sendable {
    let port: Int
    private let listener: Int32
    private let lock = NSLock()
    private var accepted: [Int32] = []
    private var closed: Set<Int> = []
    private var stopped = false

    init() throws {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw POSIXError(.EIO) }

        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && listen(fd, 16) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else {
            close(fd)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        listener = fd
        port = Int(UInt16(bigEndian: address.sin_port))

        Thread.detachNewThread { [self] in acceptLoop() }
    }

    var acceptedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return accepted.count
    }

    func waitUntilClosed(connection index: Int, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let isClosed = lock.withLock { closed.contains(index) }
            if isClosed { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop() {
        var listening = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        while !isStopped {
            guard poll(&listening, 1, 50) > 0 else { continue }
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { continue }
            lock.lock()
            let index = accepted.count
            accepted.append(fd)
            lock.unlock()
            Thread.detachNewThread { [self] in drain(fd, index: index) }
        }
        close(listener)
    }

    /// Reads and discards what the client sends until it closes the connection.
    private func drain(_ fd: Int32, index: Int) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var readable = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while !isStopped {
            guard poll(&readable, 1, 50) > 0 else { continue }
            if read(fd, &buffer, buffer.count) <= 0 {
                lock.lock()
                closed.insert(index)
                lock.unlock()
                break
            }
        }
        close(fd)
    }
}
