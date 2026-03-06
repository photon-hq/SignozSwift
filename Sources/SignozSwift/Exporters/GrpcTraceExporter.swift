import Foundation
import GRPCCore
import OpenTelemetryProtocolExporterCommon
import OpenTelemetrySdk

final class GrpcTraceExporter: SpanExporter {

    private let client: any GrpcExportClient
    private let defaultTimeout: TimeInterval
    private let metadata: Metadata

    private static let descriptor = MethodDescriptor(
        fullyQualifiedService: "opentelemetry.proto.collector.trace.v1.TraceService",
        method: "Export"
    )

    init(client: any GrpcExportClient, headers: [(String, String)], timeout: TimeInterval = 30) {
        self.client = client
        self.defaultTimeout = timeout
        self.metadata = Metadata(headers: headers)
    }

    func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        let request = Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest.with {
            $0.resourceSpans = SpanAdapter.toProtoResourceSpans(spanDataList: spans)
        }

        let timeout = explicitTimeout ?? defaultTimeout
        let opts = {
            var o = CallOptions.defaults
            o.timeout = GrpcTimeout.duration(from: timeout)
            return o
        }()

        let client = self.client
        let md = self.metadata

        let didSucceed = GrpcExportExecutor.run(timeout: timeout) {
            let _: Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceResponse =
                try await client.callUnary(
                    request, descriptor: GrpcTraceExporter.descriptor, metadata: md, options: opts)
        }

        return didSucceed ? .success : .failure
    }

    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .success }
    func shutdown(explicitTimeout: TimeInterval?) {}
}
