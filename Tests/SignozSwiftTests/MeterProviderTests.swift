import Foundation
import Testing
import OpenTelemetryApi
import OpenTelemetrySdk
@testable import SignozSwift

/// Captures every batch the meter provider hands to its exporter.
private final class CapturingMetricExporter: MetricExporter, @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [[MetricData]] = []

    var exported: [MetricData] {
        lock.lock()
        defer { lock.unlock() }
        return batches.flatMap { $0 }
    }

    func export(metrics: [MetricData]) -> ExportResult {
        lock.lock()
        batches.append(metrics)
        lock.unlock()
        return .success
    }

    func flush() -> ExportResult { .success }
    func shutdown() -> ExportResult { .success }
    func getAggregationTemporality(for instrument: InstrumentType) -> AggregationTemporality {
        .cumulative
    }
}

@Suite("Meter provider")
struct MeterProviderTests {

    @Test("Counter measurements are exported")
    func counterIsExported() {
        let exporter = CapturingMetricExporter()
        let provider = Signoz.makeMeterProvider(
            exporter: exporter, resource: Resource(), exportInterval: 3600)
        let counter = provider.meterBuilder(name: "test").build()
            .counterBuilder(name: "requests_total").build()

        counter.add(value: 2, attributes: ["route": .string("/status")])
        counter.add(value: 3, attributes: ["route": .string("/status")])
        _ = provider.forceFlush()

        let metric = exporter.exported.first { $0.name == "requests_total" }
        let points = metric?.data.points.compactMap { $0 as? LongPointData } ?? []
        #expect(points.map(\.value) == [5])
        #expect(points.first?.attributes["route"] == .string("/status"))
    }

    @Test("Histogram measurements are exported")
    func histogramIsExported() {
        let exporter = CapturingMetricExporter()
        let provider = Signoz.makeMeterProvider(
            exporter: exporter, resource: Resource(), exportInterval: 3600)
        let histogram = provider.meterBuilder(name: "test").build()
            .histogramBuilder(name: "duration_ms").build()

        histogram.record(value: 12.5, attributes: [:])
        _ = provider.forceFlush()

        let metric = exporter.exported.first { $0.name == "duration_ms" }
        let points = metric?.data.points.compactMap { $0 as? HistogramPointData } ?? []
        #expect(points.map(\.count) == [1])
    }
}
