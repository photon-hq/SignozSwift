import CoreMetrics
import Foundation
import GRPC
import NIO
import NIOSSL
@preconcurrency import OpenTelemetryApi
import OpenTelemetryProtocolExporterCommon
import OpenTelemetryProtocolExporterGrpc
import PersistenceExporter
import OpenTelemetrySdk
import SwiftMetricsShim

#if canImport(Darwin)
nonisolated(unsafe) private let stdErr = stderr
#else
nonisolated(unsafe) private let stdErr = fdopen(STDERR_FILENO, "w")!
#endif

#if canImport(ResourceExtension)
import ResourceExtension
#endif

#if canImport(URLSessionInstrumentation)
import URLSessionInstrumentation
#endif

#if canImport(SignPostIntegration)
import SignPostIntegration
#endif

/// The main entry point for SignozSwift.
///
/// Call ``start(serviceName:_:)`` once at app launch to configure OpenTelemetry
/// with OTLP/gRPC export to SigNoz. Then use the top-level ``span(_:kind:attributes:_:)``
/// and logging functions (``info(_:attributes:)``, ``error(_:attributes:)``, etc.)
/// to instrument your code.
///
/// ```swift
/// Signoz.start(serviceName: "my-app") {
///     $0.headers = ["signoz-ingestion-key": "..."]
/// }
/// defer { Signoz.shutdown() }
/// ```
public enum Signoz {

    // MARK: - State

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _tracer: (any Tracer)?
    nonisolated(unsafe) private static var _logger: (any Logger)?
    nonisolated(unsafe) private static var _channel: ClientConnection?
    nonisolated(unsafe) private static var _group: MultiThreadedEventLoopGroup?
    nonisolated(unsafe) private static var _tracerProvider: TracerProviderSdk?
    nonisolated(unsafe) private static var _logProcessor: (any LogRecordProcessor)?

    #if canImport(URLSessionInstrumentation)
    nonisolated(unsafe) private static var _urlSessionInstrumentation: URLSessionInstrumentation?
    #endif

    // MARK: - Public API

    /// No-op tracer returned before ``start(serviceName:_:)`` is called.
    private static let noopTracer: any Tracer = {
        nonisolated(unsafe) let t = DefaultTracer.instance
        return t
    }()

    /// No-op logger returned before ``start(serviceName:_:)`` is called.
    private static let noopLogger: any Logger = DefaultLoggerProvider.instance
        .loggerBuilder(instrumentationScopeName: "noop")
        .build()

    /// The configured OTel tracer. Falls back to a no-op tracer if ``start(serviceName:_:)`` hasn't been called.
    public static var tracer: any Tracer {
        lock.lock()
        defer { lock.unlock() }
        return _tracer ?? noopTracer
    }

    /// The configured OTel logger. Falls back to a no-op logger if ``start(serviceName:_:)`` hasn't been called.
    public static var logger: any Logger {
        lock.lock()
        defer { lock.unlock() }
        return _logger ?? noopLogger
    }

    /// Start SigNoz instrumentation.
    ///
    /// Configures the OpenTelemetry SDK with OTLP/gRPC exporters for traces,
    /// logs, and metrics, and enables auto-instrumentation as configured.
    ///
    /// If ``Configuration/localPersistencePath`` is set but persistence setup
    /// fails, the SDK falls back to network-only export and logs a warning
    /// to stderr. This ensures observability never crashes the host app.
    ///
    /// - Parameters:
    ///   - serviceName: The service name used for resource identification.
    ///   - configure: An optional closure that mutates a ``Configuration`` value.
    public static func start(
        serviceName: String,
        _ configure: ((inout Configuration) -> Void)? = nil
    ) {
        var config = Configuration(serviceName: serviceName)
        configure?(&config)

        let (host, port) = config.parseEndpoint()

        // 1. gRPC channel
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let channel: ClientConnection
        switch config.transportSecurity {
        case .tls:
            channel = ClientConnection
                .usingTLSBackedByNIOSSL(on: group)
                .connect(host: host, port: port)
        case .plaintext:
            channel = ClientConnection
                .insecure(group: group)
                .connect(host: host, port: port)
        }

        // 2. Resource
        var attrs: [String: AttributeValue] = [:]
        attrs["service.name"] = .string(config.serviceName)
        if !config.serviceVersion.isEmpty {
            attrs["service.version"] = .string(config.serviceVersion)
        }
        if !config.environment.isEmpty {
            attrs["deployment.environment"] = .string(config.environment)
        }
        switch config.hostName {
        case .none:
            break
        case .auto:
            attrs["host.name"] = .string(ProcessInfo.processInfo.hostName)
        case .custom(let value):
            attrs["host.name"] = .string(value)
        }
        attrs.merge(config.resourceAttributes) { _, new in new }

        var resource: Resource

        #if canImport(ResourceExtension)
        if config.autoInstrumentation.resourceDetection {
            // Merge auto-detected resources first, then overlay explicit attrs
            // so that user-provided service.name always wins.
            resource = DefaultResources().get().merging(other: Resource(attributes: attrs))
        } else {
            resource = Resource(attributes: attrs)
        }
        #else
        resource = Resource(attributes: attrs)
        #endif

        // 3. Local persistence directory
        var persistenceURL: URL? = config.localPersistencePath
        if let url = persistenceURL {
            do {
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true
                )
            } catch {
                fputs("SignozSwift: failed to create persistence directory \(url.path): \(error). Falling back to network-only export.\n", stdErr)
                persistenceURL = nil
            }
        }

        // 4. OTLP configuration
        let otlpHeaders: [(String, String)]? = config.headers.isEmpty
            ? nil
            : config.headers.map { ($0.key, $0.value) }
        let otlpConfig = OtlpConfiguration(
            timeout: TimeInterval(30),
            headers: otlpHeaders
        )

        // 5. Trace exporter + processor
        let otlpTraceExporter: any SpanExporter = OtlpTraceExporter(channel: channel, config: otlpConfig)
        let traceExporter: any SpanExporter
        if let persistenceURL {
            do {
                // Fanout: OTLP exporter sends directly to network; file-only persistence exporter
                // writes to disk independently for crash recovery. This ensures spans reach Signoz
                // immediately (even in short-lived CLIs) while still persisting locally.
                let fileOnlyExporter = try PersistenceSpanExporterDecorator(
                    spanExporter: NoopSpanExporter(),
                    storageURL: persistenceURL.appendingPathComponent("traces")
                )
                traceExporter = MultiSpanExporter(spanExporters: [otlpTraceExporter, fileOnlyExporter])
            } catch {
                fputs("SignozSwift: failed to set up trace persistence: \(error). Using network-only export.\n", stdErr)
                traceExporter = otlpTraceExporter
            }
        } else {
            traceExporter = otlpTraceExporter
        }

        let spanProcessor: any SpanProcessor
        switch config.spanProcessing {
        case .simple:
            spanProcessor = SimpleSpanProcessor(spanExporter: traceExporter)
        case let .batch(maxQueue, delay, maxBatch):
            spanProcessor = BatchSpanProcessor(
                spanExporter: traceExporter,
                scheduleDelay: delay,
                maxQueueSize: maxQueue,
                maxExportBatchSize: maxBatch
            )
        }

        // 6. TracerProvider
        let tracerBuilder = TracerProviderBuilder()
            .with(resource: resource)
            .add(spanProcessor: spanProcessor)

        #if canImport(SignPostIntegration)
        if config.autoInstrumentation.signpostIntegration {
            _ = tracerBuilder.add(spanProcessor: SignPostIntegration())
        }
        #endif

        let tracerProvider = tracerBuilder.build()
        OpenTelemetry.registerTracerProvider(tracerProvider: tracerProvider)

        // 7. Log exporter + LoggerProvider
        let otlpLogExporter: any LogRecordExporter = OtlpLogExporter(channel: channel, config: otlpConfig)
        let logExporter: any LogRecordExporter
        if let persistenceURL {
            do {
                let fileOnlyExporter = try PersistenceLogExporterDecorator(
                    logRecordExporter: NoopLogRecordExporter(),
                    storageURL: persistenceURL.appendingPathComponent("logs")
                )
                logExporter = MultiLogRecordExporter(logRecordExporters: [otlpLogExporter, fileOnlyExporter])
            } catch {
                fputs("SignozSwift: failed to set up log persistence: \(error). Using network-only export.\n", stdErr)
                logExporter = otlpLogExporter
            }
        } else {
            logExporter = otlpLogExporter
        }
        let logProcessor = SimpleLogRecordProcessor(logRecordExporter: logExporter)
        let loggerProvider = LoggerProviderBuilder()
            .with(processors: [logProcessor])
            .with(resource: resource)
            .build()
        OpenTelemetry.registerLoggerProvider(loggerProvider: loggerProvider)

        // 8. Metrics shim (bridges swift-metrics → OTel → OTLP)
        if config.autoInstrumentation.metricsShim {
            var metricExporter: any MetricExporter = OtlpMetricExporter(channel: channel, config: otlpConfig)
            if let persistenceURL {
                do {
                    metricExporter = try PersistenceMetricExporterDecorator(
                        metricExporter: metricExporter,
                        storageURL: persistenceURL.appendingPathComponent("metrics")
                    )
                } catch {
                    fputs("SignozSwift: failed to set up metric persistence: \(error). Using network-only export.\n", stdErr)
                }
            }
            let metricReader = PeriodicMetricReaderBuilder(exporter: metricExporter)
                .setInterval(timeInterval: 60)
                .build()
            let meterProvider = MeterProviderSdk.builder()
                .registerMetricReader(reader: metricReader)
                .setResource(resource: resource)
                .build()

            OpenTelemetry.registerMeterProvider(meterProvider: meterProvider)

            let meter = meterProvider.meterBuilder(name: "SwiftMetrics").build()
            MetricsSystem.bootstrap(
                OpenTelemetrySwiftMetrics(meter: meter)
            )
        }

        // 9. URLSession auto-instrumentation (Apple platforms)
        #if canImport(URLSessionInstrumentation)
        if config.autoInstrumentation.urlSession {
            _urlSessionInstrumentation = URLSessionInstrumentation(
                configuration: URLSessionInstrumentationConfiguration()
            )
        }
        #endif

        // 10. Store references
        lock.lock()
        _tracer = tracerProvider.get(
            instrumentationName: config.instrumentationName,
            instrumentationVersion: nil
        )
        _logger = loggerProvider
            .loggerBuilder(instrumentationScopeName: config.instrumentationName)
            .build()
        _channel = channel
        _group = group
        _tracerProvider = tracerProvider
        _logProcessor = logProcessor
        lock.unlock()
    }

    /// Flush all pending telemetry and shut down.
    ///
    /// Call this before your process exits to ensure all spans, logs,
    /// and metrics are exported.
    public static func shutdown() {
        lock.lock()
        let channel = _channel
        let group = _group
        let tracerProvider = _tracerProvider
        let logProcessor = _logProcessor
        _tracer = nil
        _logger = nil
        _channel = nil
        _group = nil
        _tracerProvider = nil
        _logProcessor = nil
        lock.unlock()

        // Flush and shut down providers
        tracerProvider?.forceFlush(timeout: 10)
        tracerProvider?.shutdown()
        _ = logProcessor?.forceFlush(explicitTimeout: 10)
        _ = logProcessor?.shutdown()

        try? channel?.close().wait()
        try? group?.syncShutdownGracefully()
    }
}

// MARK: - Private noop exporters

/// A span exporter that does nothing. Used as the wrapped exporter inside
/// `PersistenceSpanExporterDecorator` so that the persistence layer only writes
/// to disk — the actual network export is handled by the direct OTLP exporter
/// in the `MultiSpanExporter` fanout.
private class NoopSpanExporter: SpanExporter {
    func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .success }
    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .success }
    func shutdown(explicitTimeout: TimeInterval?) {}
}

/// A log record exporter that does nothing. Used as the wrapped exporter inside
/// `PersistenceLogExporterDecorator` for the same reason as `NoopSpanExporter`.
private struct NoopLogRecordExporter: LogRecordExporter {
    func export(logRecords: [ReadableLogRecord], explicitTimeout: TimeInterval?) -> ExportResult { .success }
    func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult { .success }
    func shutdown(explicitTimeout: TimeInterval?) {}
}
