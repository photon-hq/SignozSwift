import Foundation
import GRPCCore
import OpenTelemetryProtocolExporterCommon
import OpenTelemetrySdk

final class GrpcLogExporter: LogRecordExporter {

    private let client: any GrpcExportClient
    private let defaultTimeout: TimeInterval
    private let metadata: Metadata

    private static let descriptor = MethodDescriptor(
        fullyQualifiedService: "opentelemetry.proto.collector.logs.v1.LogsService",
        method: "Export"
    )

    init(client: any GrpcExportClient, headers: [(String, String)], timeout: TimeInterval = 30) {
        self.client = client
        self.defaultTimeout = timeout
        var md = Metadata()
        for (key, value) in headers {
            md.addString(value, forKey: key)
        }
        self.metadata = md
    }

    func export(logRecords: [ReadableLogRecord], explicitTimeout: TimeInterval?) -> ExportResult {
        let request = Opentelemetry_Proto_Collector_Logs_V1_ExportLogsServiceRequest.with {
            $0.resourceLogs = LogRecordAdapter.toProtoResourceRecordLog(logRecordList: logRecords)
        }

        let timeout = explicitTimeout ?? defaultTimeout
        let opts = {
            var o = CallOptions.defaults
            o.timeout = .seconds(Int64(timeout))
            return o
        }()

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: ExportResult = .failure
        let client = self.client
        let md = self.metadata

        Task { @Sendable in
            defer { semaphore.signal() }
            do {
                let _: Opentelemetry_Proto_Collector_Logs_V1_ExportLogsServiceResponse =
                    try await client.callUnary(
                        request, descriptor: GrpcLogExporter.descriptor, metadata: md, options: opts)
                result = .success
            } catch {
                result = .failure
            }
        }

        semaphore.wait()
        return result
    }

    func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult { .success }
    func shutdown(explicitTimeout: TimeInterval?) {}
}
