import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import Testing
@testable import SignozSwift

@Suite("Background log export")
struct AsyncLogExportTests {
    @Test("A stalled exporter cannot block logging, and excess pending records are dropped")
    func stalledExporter() {
        let exporter = BlockingLogExporter()
        let processor = Signoz.makeLogProcessor(exporter: exporter)
        let emitter = LogEmitter(processor: processor)
        defer {
            exporter.unblock()
            _ = processor.shutdown(explicitTimeout: 1)
        }

        let firstEmission = emitter.emitAsync(count: 1)
        #expect(firstEmission.wait(timeout: .now() + 1) == .success)
        #expect(exporter.started.wait(timeout: .now() + 6) == .success)

        let remainingEmissions = emitter.emitAsync(count: 2148)
        #expect(remainingEmissions.wait(timeout: .now() + 1) == .success)
        exporter.unblock()
        _ = processor.forceFlush(explicitTimeout: 1)

        let records = exporter.records
        #expect(records.count == 2049)
        #expect(records.allSatisfy { $0.spanContext == emitter.context })
        #expect(records.allSatisfy { $0.timestamp == emitter.timestamp })
        #expect(records.allSatisfy { $0.body == .string("heartbeat") })
        #expect(records.allSatisfy { $0.attributes["report"] == .int(1) })
    }

    @Test("Shutdown flushes logs waiting for the next batch")
    func shutdownFlushes() {
        let exporter = BlockingLogExporter()
        exporter.unblock()
        let processor = Signoz.makeLogProcessor(exporter: exporter)
        let emitter = LogEmitter(processor: processor)
        emitter.emit()
        _ = processor.shutdown(explicitTimeout: 1)
        #expect(exporter.records.count == 1)
        #expect(exporter.records.first?.spanContext == emitter.context)
    }
}

private final class LogEmitter: @unchecked Sendable {
    let context = SpanContext.create(
        traceId: .random(), spanId: .random(), traceFlags: TraceFlags(), traceState: TraceState()
    )
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    private let logger: any OpenTelemetryApi.Logger

    init(processor: any LogRecordProcessor) {
        logger = LoggerProviderBuilder().with(processors: [processor]).build()
            .get(instrumentationScopeName: "async-log-export-test")
    }

    func emit() {
        logger.logRecordBuilder()
            .setSpanContext(context)
            .setTimestamp(timestamp)
            .setBody(.string("heartbeat"))
            .setAttributes(["report": .int(1)])
            .emit()
    }

    func emitAsync(count: Int) -> DispatchGroup {
        let done = DispatchGroup()
        done.enter()
        DispatchQueue.global().async { [self] in
            defer { done.leave() }
            for _ in 0..<count { emit() }
        }
        return done
    }
}

private final class BlockingLogExporter: LogRecordExporter, @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    private let condition = NSCondition()
    private var released = false
    private var stored: [ReadableLogRecord] = []

    var records: [ReadableLogRecord] {
        condition.lock()
        defer { condition.unlock() }
        return stored
    }

    func unblock() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func export(logRecords: [ReadableLogRecord], explicitTimeout: TimeInterval?) -> ExportResult {
        condition.lock()
        defer { condition.unlock() }
        started.signal()
        while !released { condition.wait() }
        stored.append(contentsOf: logRecords)
        return .success
    }

    func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult { .success }
    func shutdown(explicitTimeout: TimeInterval?) {}
}
