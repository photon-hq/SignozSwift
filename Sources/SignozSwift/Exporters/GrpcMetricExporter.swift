import Foundation
import GRPCCore
import OpenTelemetryProtocolExporterCommon
import OpenTelemetrySdk

final class GrpcMetricExporter: MetricExporter {

    private let client: any GrpcExportClient
    private let defaultTimeout: TimeInterval
    private let metadata: Metadata
    private let temporalitySelector: AggregationTemporalitySelector
    private let aggregationSelector: AggregationSelector

    private static let descriptor = MethodDescriptor(
        fullyQualifiedService: "opentelemetry.proto.collector.metrics.v1.MetricsService",
        method: "Export"
    )

    init(
        client: any GrpcExportClient,
        headers: [(String, String)],
        timeout: TimeInterval = 30,
        temporalitySelector: AggregationTemporalitySelector = AggregationTemporality.alwaysCumulative(),
        aggregationSelector: AggregationSelector = .instance
    ) {
        self.client = client
        self.defaultTimeout = timeout
        self.temporalitySelector = temporalitySelector
        self.aggregationSelector = aggregationSelector
        var md = Metadata()
        for (key, value) in headers {
            md.addString(value, forKey: key)
        }
        self.metadata = md
    }

    func export(metrics: [MetricData]) -> ExportResult {
        let request = Opentelemetry_Proto_Collector_Metrics_V1_ExportMetricsServiceRequest.with {
            $0.resourceMetrics = MetricsAdapter.toProtoResourceMetrics(metricData: metrics)
        }

        let opts = {
            var o = CallOptions.defaults
            o.timeout = GrpcTimeout.duration(from: defaultTimeout)
            return o
        }()

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: ExportResult = .failure
        let client = self.client
        let md = self.metadata

        Task { @Sendable in
            defer { semaphore.signal() }
            do {
                let _: Opentelemetry_Proto_Collector_Metrics_V1_ExportMetricsServiceResponse =
                    try await client.callUnary(
                        request, descriptor: GrpcMetricExporter.descriptor, metadata: md, options: opts)
                result = .success
            } catch {
                result = .failure
            }
        }

        semaphore.wait()
        return result
    }

    func flush() -> ExportResult { .success }
    func shutdown() -> ExportResult { .success }

    func getAggregationTemporality(for instrument: InstrumentType) -> AggregationTemporality {
        temporalitySelector.getAggregationTemporality(for: instrument)
    }

    func getDefaultAggregation(for instrument: InstrumentType) -> Aggregation {
        aggregationSelector.getDefaultAggregation(for: instrument)
    }
}
