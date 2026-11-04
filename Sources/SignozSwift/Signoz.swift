import CoreMetrics
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
@preconcurrency import OpenTelemetryApi
import OpenTelemetryProtocolExporterCommon
import PersistenceExporter
import OpenTelemetrySdk
import SwiftMetricsShim
import Tracing

#if canImport(Darwin)
nonisolated(unsafe) let stdErr = stderr
#elseif canImport(Glibc)
import Glibc
nonisolated(unsafe) let stdErr = fdopen(STDERR_FILENO, "w")!
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
    nonisolated(unsafe) private static var _tracer: (any OpenTelemetryApi.Tracer)?
    nonisolated(unsafe) private static var _logger: (any Logger)?
    nonisolated(unsafe) private static var _client: ReconnectingExportClient?
    nonisolated(unsafe) private static var _tracerProvider: TracerProviderSdk?
    nonisolated(unsafe) private static var _logProcessor: (any LogRecordProcessor)?
    nonisolated(unsafe) private static var _meterProvider: MeterProviderSdk?

    nonisolated(unsafe) private static var _consoleLogEnabled: Bool = false
    nonisolated(unsafe) private static var _instrumentationBootstrapped: Bool = false
    nonisolated(unsafe) private static var _metricsBootstrapped: Bool = false
    private static let _metricsBridge = OTelMetricsBridge()

    #if canImport(URLSessionInstrumentation)
    nonisolated(unsafe) private static var _urlSessionInstrumentation: URLSessionInstrumentation?
    #endif

    // MARK: - Public API

    /// No-op tracer returned before ``start(serviceName:_:)`` is called.
    private static let noopTracer: any OpenTelemetryApi.Tracer = {
        nonisolated(unsafe) let t = DefaultTracer.instance
        return t
    }()

    /// No-op logger returned before ``start(serviceName:_:)`` is called.
    private static let noopLogger: any Logger = DefaultLoggerProvider.instance
        .loggerBuilder(instrumentationScopeName: "noop")
        .build()

    /// The configured OTel tracer. Falls back to a no-op tracer if ``start(serviceName:_:)`` hasn't been called.
    public static var tracer: any OpenTelemetryApi.Tracer {
        lock.lock()
        defer { lock.unlock() }
        return _tracer ?? noopTracer
    }

    /// Whether log messages should also print to the local console.
    static var consoleLogEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _consoleLogEnabled
    }

    /// The underlying TracerProviderSdk, exposed for the distributed-tracing bridge.
    static var tracerProvider: TracerProviderSdk? {
        lock.lock()
        defer { lock.unlock() }
        return _tracerProvider
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

        // 1. gRPC client (v2)
        let client: ReconnectingExportClient
        do {
            let transportSecurity: HTTP2ClientTransport.Posix.TransportSecurity =
                config.transportSecurity == .tls ? .tls(.defaults) : .plaintext
            client = try ReconnectingExportClient {
                try ReconnectingExportClient.connect(
                    host: host, port: port, transportSecurity: transportSecurity)
            }
        } catch {
            fputs("SignozSwift: failed to create gRPC transport: \(error).\n", stdErr)
            return
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
            let raw = ProcessInfo.processInfo.hostName
            let short = raw.split(separator: ".", maxSplits: 1).first.map(String.init) ?? raw
            attrs["host.name"] = .string(short)
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
        let otlpHeaders: [(String, String)] = config.headers.map { ($0.key, $0.value) }
        let otlpTimeout: TimeInterval = 30

        // 5. Trace exporter + processor
        let otlpTraceExporter: any SpanExporter = GrpcTraceExporter(
            client: client, headers: otlpHeaders, timeout: otlpTimeout)
        let traceExporter: any SpanExporter
        if let persistenceURL {
            do {
                // Durable queue: spans are written to disk and forwarded to SigNoz from disk.
                // On a network outage the files are retained and replayed once the collector is
                // reachable again; this applies only to records that reach disk.
                let tracesURL = try makePersistenceDir(persistenceURL, "traces")
                traceExporter = try PersistenceSpanExporterDecorator(
                    spanExporter: otlpTraceExporter,
                    storageURL: tracesURL
                )
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

        // 6b. Bridge swift-distributed-tracing → OTel SDK
        //     Required for grpc-swift-extras OTel tracing interceptors.
        //     Can only be called once per process (precondition in InstrumentationSystem).
        lock.lock()
        let shouldBootstrapInstrumentation = !_instrumentationBootstrapped
        if shouldBootstrapInstrumentation { _instrumentationBootstrapped = true }
        lock.unlock()
        if shouldBootstrapInstrumentation {
            InstrumentationSystem.bootstrap(OTelTracingBridge())
        }

        // 7. Log exporter + LoggerProvider
        let otlpLogExporter: any LogRecordExporter = GrpcLogExporter(
            client: client, headers: otlpHeaders, timeout: otlpTimeout)
        let logExporter: any LogRecordExporter
        if let persistenceURL {
            do {
                let logsURL = try makePersistenceDir(persistenceURL, "logs")
                logExporter = try PersistenceLogExporterDecorator(
                    logRecordExporter: otlpLogExporter,
                    storageURL: logsURL
                )
            } catch {
                fputs("SignozSwift: failed to set up log persistence: \(error). Using network-only export.\n", stdErr)
                logExporter = otlpLogExporter
            }
        } else {
            logExporter = otlpLogExporter
        }
        let logProcessor = makeLogProcessor(exporter: logExporter)
        let loggerProvider = LoggerProviderBuilder()
            .with(processors: [logProcessor])
            .with(resource: resource)
            .build()
        OpenTelemetry.registerLoggerProvider(loggerProvider: loggerProvider)

        // 8. Metric exporter + MeterProvider
        var metricExporter: any MetricExporter = GrpcMetricExporter(
            client: client, headers: otlpHeaders, timeout: otlpTimeout)
        if let persistenceURL {
            do {
                let metricsURL = try makePersistenceDir(persistenceURL, "metrics")
                metricExporter = try PersistenceMetricExporterDecorator(
                    metricExporter: metricExporter,
                    storageURL: metricsURL
                )
            } catch {
                fputs("SignozSwift: failed to set up metric persistence: \(error). Using network-only export.\n", stdErr)
            }
        }
        let meterProvider = makeMeterProvider(exporter: metricExporter, resource: resource)
        OpenTelemetry.registerMeterProvider(meterProvider: meterProvider)

        // 8b. Metrics shim (bridges swift-metrics → OTel → OTLP)
        //     Can only be bootstrapped once per process (precondition in MetricsSystem),
        //     so bootstrap a delegating bridge once and swap its backing factory.
        if config.autoInstrumentation.metricsShim {
            let meter = meterProvider.meterBuilder(name: "SwiftMetrics").build()
            _metricsBridge.setFactory(OpenTelemetrySwiftMetrics(meter: meter))
            lock.lock()
            let shouldBootstrapMetrics = !_metricsBootstrapped
            if shouldBootstrapMetrics { _metricsBootstrapped = true }
            lock.unlock()
            if shouldBootstrapMetrics {
                MetricsSystem.bootstrap(_metricsBridge)
            }
        } else {
            _metricsBridge.setFactory(NOOPMetricsHandler.instance)
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
        _client = client
        _tracerProvider = tracerProvider
        _logProcessor = logProcessor
        _meterProvider = meterProvider
        switch config.consoleLog {
        case .auto:
            #if DEBUG
            _consoleLogEnabled = true
            #else
            _consoleLogEnabled = false
            #endif
        case .enabled:
            _consoleLogEnabled = true
        case .disabled:
            _consoleLogEnabled = false
        }
        lock.unlock()
    }

    /// Flush all pending telemetry and shut down.
    ///
    /// Call this before your process exits to ensure all spans, logs,
    /// and metrics are exported.
    public static func shutdown() {
        lock.lock()
        let client = _client
        let tracerProvider = _tracerProvider
        let logProcessor = _logProcessor
        let meterProvider = _meterProvider
        _tracer = nil
        _logger = nil
        _client = nil
        _tracerProvider = nil
        _logProcessor = nil
        _meterProvider = nil
        _consoleLogEnabled = false
        lock.unlock()

        _metricsBridge.setFactory(NOOPMetricsHandler.instance)
        OpenTelemetry.registerMeterProvider(meterProvider: DefaultMeterProvider.instance)

        // Flush and shut down providers
        tracerProvider?.forceFlush(timeout: 10)
        tracerProvider?.shutdown()
        _ = logProcessor?.forceFlush(explicitTimeout: 10)
        _ = logProcessor?.shutdown()
        _ = meterProvider?.forceFlush()
        _ = meterProvider?.shutdown()

        if let connection = client?.close() {
            connection.beginShutdown()
            let semaphore = DispatchSemaphore(value: 0)
            let drainTask = Task.detached {
                await connection.task.value
                semaphore.signal()
            }

            let didDrain = semaphore.wait(timeout: .now() + .seconds(10)) == .success
            if !didDrain {
                connection.task.cancel()
            }

            drainTask.cancel()
        }
    }

    /// Enqueues logs in memory before export, including before any persistence write.
    static func makeLogProcessor(exporter: any LogRecordExporter) -> any LogRecordProcessor {
        BatchLogRecordProcessor(logRecordExporter: exporter)
    }

    /// Create a per-signal subdirectory (e.g. `traces`/`logs`/`metrics`) under the
    /// persistence root and return its URL.
    ///
    /// The opentelemetry-swift `PersistenceExporter` uses `Directory(url:)`, which does
    /// NOT create the directory, and its file writer swallows write errors — so each
    /// subdirectory must exist up front or every persistence write silently no-ops.
    static func makePersistenceDir(_ root: URL, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Build the meter provider that exports every instrument through `exporter`.
    ///
    /// opentelemetry-swift-core only stores measurements for instruments that match a
    /// registered view: `ViewRegistry.findViews` never falls back to the default view
    /// it builds. Without the catch-all view below, every counter, histogram and gauge
    /// gets no storage and its measurements are dropped before export.
    static func makeMeterProvider(
        exporter: any MetricExporter,
        resource: Resource,
        exportInterval: TimeInterval = 60
    ) -> MeterProviderSdk {
        let reader = PeriodicMetricReaderBuilder(exporter: exporter)
            .setInterval(timeInterval: exportInterval)
            .build()
        return MeterProviderSdk.builder()
            .registerView(
                selector: InstrumentSelector.builder().setInstrument(name: ".*").build(),
                view: View.builder().build()
            )
            .registerMetricReader(reader: reader)
            .setResource(resource: resource)
            .build()
    }
}

// MARK: - Metrics Shim Bridge

/// Delegates `swift-metrics` calls to the active `Signoz` metrics factory so
/// `MetricsSystem.bootstrap` only needs to run once per process.
final class OTelMetricsBridge: MetricsFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var underlying: any MetricsFactory = NOOPMetricsHandler.instance

    func setFactory(_ factory: any MetricsFactory) {
        lock.lock()
        underlying = factory
        lock.unlock()
    }

    private var current: any MetricsFactory {
        lock.lock()
        defer { lock.unlock() }
        return underlying
    }

    func makeCounter(label: String, dimensions: [(String, String)]) -> any CounterHandler {
        current.makeCounter(label: label, dimensions: dimensions)
    }

    func makeFloatingPointCounter(
        label: String, dimensions: [(String, String)]
    ) -> any FloatingPointCounterHandler {
        current.makeFloatingPointCounter(label: label, dimensions: dimensions)
    }

    func makeMeter(label: String, dimensions: [(String, String)]) -> any MeterHandler {
        current.makeMeter(label: label, dimensions: dimensions)
    }

    func makeRecorder(
        label: String, dimensions: [(String, String)], aggregate: Bool
    ) -> any RecorderHandler {
        current.makeRecorder(label: label, dimensions: dimensions, aggregate: aggregate)
    }

    func makeTimer(label: String, dimensions: [(String, String)]) -> any TimerHandler {
        current.makeTimer(label: label, dimensions: dimensions)
    }

    func destroyCounter(_ handler: any CounterHandler) {
        current.destroyCounter(handler)
    }

    func destroyMeter(_ handler: any MeterHandler) {
        current.destroyMeter(handler)
    }

    func destroyFloatingPointCounter(_ handler: any FloatingPointCounterHandler) {
        current.destroyFloatingPointCounter(handler)
    }

    func destroyRecorder(_ handler: any RecorderHandler) {
        current.destroyRecorder(handler)
    }

    func destroyTimer(_ handler: any TimerHandler) {
        current.destroyTimer(handler)
    }
}

// MARK: - Persistence

// Telemetry persistence wraps the real OTLP exporters in the opentelemetry-swift
// `Persistence*ExporterDecorator`s (see `start(serviceName:_:)`), which buffer each
// signal to `<localPersistencePath>/{traces,logs,metrics}` and forward from disk —
// retaining and replaying data across network outages. No no-op exporters are needed.
