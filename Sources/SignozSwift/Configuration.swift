import Foundation
import OpenTelemetryApi

// AttributeValue from opentelemetry-swift-core does not conform to Sendable,
// but its cases are all value types. Safe to bridge with @unchecked.
extension AttributeValue: @retroactive @unchecked Sendable {}

/// Configuration for SignozSwift, passed to ``Signoz/start(serviceName:_:)``.
public struct Configuration: Sendable {

    /// gRPC endpoint in `host:port` format. Default: `"localhost:4317"`.
    public var endpoint: String = "localhost:4317"

    /// Service name for resource identification. Set via ``Signoz/start(serviceName:_:)``.
    public internal(set) var serviceName: String

    /// Service version.
    public var serviceVersion: String = ""

    /// Deployment environment (e.g. `"production"`, `"staging"`).
    /// Maps to `deployment.environment` resource attribute.
    /// Shows in SigNoz Logs > Quick Filters > Environment.
    public var environment: String = ""

    /// Host name strategy for the `host.name` resource attribute.
    /// - `.none` — attribute is omitted (default).
    /// - `.auto` — uses the system hostname at runtime.
    /// - `.custom("value")` — uses the provided string.
    public var hostName: HostName = .none

    /// Extra resource attributes beyond the built-in ones.
    public var resourceAttributes: [String: AttributeValue] = [:]

    /// Custom gRPC metadata headers (e.g. auth / ingestion keys).
    public var headers: [String: String] = [:]

    /// Transport security mode. Default: `.plaintext`.
    public var transportSecurity: TransportSecurity = .plaintext

    /// Instrumentation scope name used when obtaining the tracer and logger.
    public var instrumentationName: String = "SignozSwift"

    /// Span processing strategy.
    public var spanProcessing: SpanProcessing = .batch()

    /// Auto-instrumentation toggles.
    public var autoInstrumentation: AutoInstrumentation = .init()

    /// Optional local directory path for persisting telemetry data.
    ///
    /// When set, traces, logs, and metrics are written to disk in addition
    /// to being exported over the network. This ensures telemetry survives
    /// network outages — the persistence layer queues data locally and
    /// forwards it to the OTLP exporter when connectivity resumes.
    ///
    /// The directory is created automatically if it doesn't exist.
    ///
    /// Set to `nil` (default) to disable local persistence.
    public var localPersistencePath: URL? = nil

    // MARK: - Nested Types

    public enum HostName: Sendable, Equatable, ExpressibleByStringLiteral {
        /// Do not include the `host.name` resource attribute.
        case none
        /// Use the system hostname (`ProcessInfo.processInfo.hostName`).
        case auto
        /// Use a custom hostname value.
        case custom(String)

        public init(stringLiteral value: String) {
            self = .custom(value)
        }
    }

    public enum TransportSecurity: Sendable {
        case plaintext
        case tls
    }

    public enum SpanProcessing: Sendable {
        /// Flush each span immediately. Good for short-lived CLIs.
        case simple
        /// Batch spans before export. Recommended for servers and long-running apps.
        case batch(
            maxQueueSize: Int = 2048,
            scheduledDelay: TimeInterval = 5.0,
            maxExportBatchSize: Int = 512
        )
    }

    public struct AutoInstrumentation: Sendable {
        /// Auto-trace all URLSession network calls. *(Apple platforms only)*
        public var urlSession: Bool = true

        /// Auto-collect device/app/OS resource attributes. *(Apple platforms only)*
        public var resourceDetection: Bool = true

        /// Bridge spans to Xcode Instruments via `os_signpost`. *(Apple platforms only)*
        public var signpostIntegration: Bool = false

        /// Bridge `swift-metrics` to the OTel metrics pipeline.
        /// When enabled, Vapor's built-in HTTP metrics (`http_requests_total`,
        /// `http_request_duration_seconds`, etc.) are exported via OTLP automatically.
        public var metricsShim: Bool = true

        public init() {}
    }
}

// MARK: - Endpoint Parsing

extension Configuration {

    /// Parse `"host:port"` into components. Falls back to port 4317.
    func parseEndpoint() -> (host: String, port: Int) {
        let parts = endpoint.split(separator: ":", maxSplits: 1)
        let host = String(parts.first ?? "localhost")
        let port = parts.count > 1 ? Int(parts[1]) ?? 4317 : 4317
        return (host, port)
    }
}
