import Testing
import OpenTelemetryApi
import OpenTelemetrySdk
import InMemoryExporter
@testable import SignozSwift

// MARK: - Configuration Tests

@Suite("Configuration")
struct ConfigurationTests {

    @Test("Default values")
    func defaults() {
        let config = Configuration(serviceName: "test-svc")
        #expect(config.endpoint == "localhost:4317")
        #expect(config.serviceName == "test-svc")
        #expect(config.serviceVersion == "")
        #expect(config.environment == "")
        #expect(config.hostName == .none)
        #expect(config.resourceAttributes.isEmpty)
        #expect(config.headers.isEmpty)
        #expect(config.instrumentationName == "SignozSwift")
    }

    @Test("Closure-based mutation")
    func closureMutation() {
        var config = Configuration(serviceName: "my-app")
        config.endpoint = "ingest.signoz.io:4317"
        config.serviceVersion = "2.0.0"
        config.headers = ["signoz-ingestion-key": "secret"]

        #expect(config.endpoint == "ingest.signoz.io:4317")
        #expect(config.serviceName == "my-app")
        #expect(config.serviceVersion == "2.0.0")
        #expect(config.headers["signoz-ingestion-key"] == "secret")
    }

    @Test("Default transport is plaintext")
    func transportSecurityDefault() {
        let config = Configuration(serviceName: "test")
        if case .plaintext = config.transportSecurity {
            // pass
        } else {
            Issue.record("Expected default .plaintext")
        }
    }

    @Test("Span processing defaults to batch")
    func spanProcessingDefault() {
        let config = Configuration(serviceName: "test")
        if case let .batch(maxQueue, delay, maxBatch) = config.spanProcessing {
            #expect(maxQueue == 2048)
            #expect(delay == 5.0)
            #expect(maxBatch == 512)
        } else {
            Issue.record("Expected .batch, got .simple")
        }
    }

    @Test("Span processing simple mode")
    func spanProcessingSimple() {
        var config = Configuration(serviceName: "test")
        config.spanProcessing = .simple
        if case .simple = config.spanProcessing {
            // pass
        } else {
            Issue.record("Expected .simple")
        }
    }

    @Test("Auto-instrumentation defaults")
    func autoInstrumentationDefaults() {
        let ai = Configuration.AutoInstrumentation()
        #expect(ai.urlSession == true)
        #expect(ai.resourceDetection == true)
        #expect(ai.signpostIntegration == false)
        #expect(ai.metricsShim == true)
    }
}

// MARK: - Endpoint Parsing Tests

@Suite("Endpoint Parsing")
struct EndpointParsingTests {

    @Test("host:port format")
    func hostPort() {
        var config = Configuration(serviceName: "test")
        config.endpoint = "ingest.signoz.io:4317"
        let (host, port) = config.parseEndpoint()
        #expect(host == "ingest.signoz.io")
        #expect(port == 4317)
    }

    @Test("Default endpoint")
    func defaultEndpoint() {
        let config = Configuration(serviceName: "test")
        let (host, port) = config.parseEndpoint()
        #expect(host == "localhost")
        #expect(port == 4317)
    }

    @Test("Host only — defaults to port 4317")
    func hostOnly() {
        var config = Configuration(serviceName: "test")
        config.endpoint = "myhost"
        let (host, port) = config.parseEndpoint()
        #expect(host == "myhost")
        #expect(port == 4317)
    }

    @Test("Invalid port — defaults to 4317")
    func invalidPort() {
        var config = Configuration(serviceName: "test")
        config.endpoint = "myhost:abc"
        let (host, port) = config.parseEndpoint()
        #expect(host == "myhost")
        #expect(port == 4317)
    }
}

// MARK: - AttributeValue Literal Tests

@Suite("AttributeValue Literals")
struct AttributeValueLiteralTests {

    @Test("String literal")
    func stringLiteral() {
        let attr: AttributeValue = "hello"
        #expect(attr == .string("hello"))
    }

    @Test("Integer literal")
    func integerLiteral() {
        let attr: AttributeValue = 42
        #expect(attr == .int(42))
    }

    @Test("Float literal")
    func floatLiteral() {
        let attr: AttributeValue = 3.14
        #expect(attr == .double(3.14))
    }

    @Test("Boolean literal")
    func booleanLiteral() {
        let attr: AttributeValue = true
        #expect(attr == .bool(true))

        let attrFalse: AttributeValue = false
        #expect(attrFalse == .bool(false))
    }

    @Test("Literals in dictionary context")
    func dictionaryContext() {
        let attrs: [String: AttributeValue] = [
            "name": "test",
            "count": 5,
            "ratio": 0.75,
            "enabled": true,
        ]
        #expect(attrs["name"] == .string("test"))
        #expect(attrs["count"] == .int(5))
        #expect(attrs["ratio"] == .double(0.75))
        #expect(attrs["enabled"] == .bool(true))
    }
}

// MARK: - Tracer withSpan Tests

@Suite("Tracer.withSpan")
struct TracerWithSpanTests {

    /// Create a TracerSdk backed by an InMemoryExporter.
    /// Returns the tracer, exporter, and provider (needed for flushing).
    private func makeTracer() -> (any Tracer, InMemoryExporter, TracerProviderSdk) {
        let exporter = InMemoryExporter()
        let processor = SimpleSpanProcessor(spanExporter: exporter)
        let provider = TracerProviderBuilder()
            .add(spanProcessor: processor)
            .build()
        let tracer = provider.get(
            instrumentationName: "test",
            instrumentationVersion: nil
        )
        return (tracer, exporter, provider)
    }

    @Test("Successful operation sets status OK and returns value")
    func successfulSpan() {
        let (tracer, exporter, provider) = makeTracer()

        let result = tracer.withSpan("test-op") { span in
            span.setAttribute(key: "key", value: "value")
            return 42
        }

        provider.forceFlush()

        #expect(result == 42)
        let spans = exporter.getFinishedSpanItems()
        #expect(spans.count == 1)
        #expect(spans[0].name == "test-op")
        #expect(spans[0].status == .ok)
        #expect(spans[0].attributes["key"] == .string("value"))
    }

    @Test("Throwing operation sets error status and rethrows")
    func throwingSpan() {
        let (tracer, exporter, provider) = makeTracer()

        struct TestError: Error {}

        do {
            try tracer.withSpan("failing-op") { _ -> Int in
                throw TestError()
            }
            Issue.record("Expected error to be thrown")
        } catch {
            #expect(error is TestError)
        }

        provider.forceFlush()

        let spans = exporter.getFinishedSpanItems()
        #expect(spans.count == 1)
        #expect(spans[0].name == "failing-op")
        if case .error = spans[0].status {
            // pass
        } else {
            Issue.record("Expected .error status, got \(spans[0].status)")
        }
    }

    @Test("Span kind is forwarded")
    func spanKind() {
        let (tracer, exporter, provider) = makeTracer()

        tracer.withSpan("client-call", kind: .client) { _ in }

        provider.forceFlush()

        let spans = exporter.getFinishedSpanItems()
        #expect(spans.count == 1)
        #expect(spans[0].kind == .client)
    }

    @Test("Initial attributes are set")
    func initialAttributes() {
        let (tracer, exporter, provider) = makeTracer()

        tracer.withSpan("with-attrs", attributes: [
            "http.method": "GET",
            "http.status_code": 200,
        ]) { _ in }

        provider.forceFlush()

        let spans = exporter.getFinishedSpanItems()
        #expect(spans[0].attributes["http.method"] == .string("GET"))
        #expect(spans[0].attributes["http.status_code"] == .int(200))
    }

    @Test("Async withSpan succeeds")
    func asyncSpan() async {
        let (tracer, exporter, provider) = makeTracer()

        let result = await tracer.withSpan("async-op") { span async in
            span.setAttribute(key: "async", value: true)
            return "done"
        }

        provider.forceFlush()

        #expect(result == "done")
        let spans = exporter.getFinishedSpanItems()
        #expect(spans.count == 1)
        #expect(spans[0].name == "async-op")
        #expect(spans[0].status == .ok)
    }
}

// MARK: - Logger Convenience Tests

@Suite("Logger Convenience")
struct LoggerConvenienceTests {

    @Test("All severity methods execute without crashing")
    func allSeverities() {
        let logger: any OpenTelemetryApi.Logger = DefaultLoggerProvider.instance
            .loggerBuilder(instrumentationScopeName: "test")
            .build()

        logger.trace("t")
        logger.debug("d")
        logger.info("i")
        logger.warn("w")
        logger.error("e")
        logger.fatal("f")
        logger.log("custom", severity: .info)
    }

    @Test("Log with attributes does not crash")
    func logWithAttributes() {
        let logger: any OpenTelemetryApi.Logger = DefaultLoggerProvider.instance
            .loggerBuilder(instrumentationScopeName: "test")
            .build()

        logger.info("request", attributes: [
            "method": "POST",
            "status": 201,
        ])
    }
}

// MARK: - Signoz Fallback Tests

@Suite("Signoz Defaults")
struct SignozDefaultTests {

    @Test("Tracer returns no-op before start()")
    func tracerDefault() {
        let tracer = Signoz.tracer
        let span = tracer.spanBuilder(spanName: "noop").startSpan()
        span.setAttribute(key: "key", value: "value")
        span.end()
    }

    @Test("Logger returns no-op before start()")
    func loggerDefault() {
        let logger = Signoz.logger
        logger.logRecordBuilder()
            .setSeverity(.info)
            .setBody(.string("test"))
            .emit()
    }
}

// MARK: - Integration Tests (sends real telemetry to SigNoz)

@Suite("Integration", .serialized)
struct IntegrationTests {

    @Test("Full lifecycle: start, trace, log, shutdown")
    func fullLifecycle() {
        // 1. Start — just like a real user would in main.swift or configure()
        Signoz.start(serviceName: "signoz-swift-test") {
            $0.spanProcessing = .simple
            $0.autoInstrumentation.metricsShim = false
        }

        // 2. Use top-level span() — the primary tracing API
        let result = span("integration.test", kind: .internal, attributes: [
            "test.suite": "SignozSwiftTests",
        ]) { s in
            s.setAttribute(key: "step", value: "running")
            return "ok"
        }
        #expect(result == "ok")

        // 3. Use top-level logging functions
        info("Integration test started", attributes: ["test": true])
        debug("Debug details", attributes: ["count": 42])
        warn("Something to watch", attributes: ["threshold": 0.9])
        error("Simulated error", attributes: ["code": 500])

        // 4. Use Signoz.tracer directly for advanced use
        let advancedSpan = Signoz.tracer.spanBuilder(spanName: "integration.advanced")
            .setSpanKind(spanKind: .client)
            .startSpan()
        advancedSpan.setAttribute(key: "http.method", value: "GET")
        advancedSpan.setAttribute(key: "http.url", value: "https://example.com/api")
        advancedSpan.status = .ok
        advancedSpan.end()

        // 5. Use Signoz.logger directly for advanced use
        Signoz.logger.log("Direct logger call", severity: .info, attributes: [
            "source": "integration-test",
        ])

        // 6. Nested spans
        span("integration.parent") { parent in
            parent.setAttribute(key: "level", value: "parent")
            span("integration.child") { child in
                child.setAttribute(key: "level", value: "child")
                info("Inside nested span")
            }
        }

        // 7. Shutdown
        Signoz.shutdown()
    }

    @Test("CLI-style usage with simple processing")
    func cliUsage() {
        Signoz.start(serviceName: "signoz-swift-cli-test") {
            $0.spanProcessing = .simple
            $0.autoInstrumentation.metricsShim = false
        }
        defer { Signoz.shutdown() }

        span("cli.process-data") { s in
            info("Processing started", attributes: ["input": "test-data"])
            s.setAttribute(key: "records.processed", value: 100)
            info("Processing complete", attributes: ["records": 100])
        }
    }

    @Test("Span with error propagation")
    func spanErrorHandling() {
        Signoz.start(serviceName: "signoz-swift-error-test") {
            $0.spanProcessing = .simple
            $0.autoInstrumentation.metricsShim = false
        }
        defer { Signoz.shutdown() }

        struct AppError: Error, CustomStringConvertible {
            let message: String
            var description: String { message }
        }

        do {
            try span("will-fail") { _ -> String in
                error("About to fail")
                throw AppError(message: "Something went wrong")
            }
            Issue.record("Expected error to be thrown")
        } catch {
            #expect(error is AppError)
        }
    }

    @Test("Async span usage")
    func asyncSpanUsage() async {
        Signoz.start(serviceName: "signoz-swift-async-test") {
            $0.spanProcessing = .simple
            $0.autoInstrumentation.metricsShim = false
        }
        defer { Signoz.shutdown() }

        let value = await span("async.fetch", kind: .client) { s async in
            s.setAttribute(key: "http.method", value: "GET")
            info("Fetching data")
            return 200
        }
        #expect(value == 200)
    }

    @Test("Environment and hostname resource attributes")
    func environmentAndHostName() {
        Signoz.start(serviceName: "signoz-swift-env-test") {
            $0.environment = "staging"
            $0.hostName = .custom("test-host-01")
            $0.spanProcessing = .simple
            $0.autoInstrumentation.metricsShim = false
        }
        defer { Signoz.shutdown() }

        span("env.test") { s in
            info("Environment test", attributes: [
                "deployment.env": "staging",
            ])
        }
    }

    @Test("Hostname defaults to system hostname when empty")
    func hostNameDefaultsToSystem() {
        Signoz.start(serviceName: "signoz-swift-hostname-test") {
            // hostName left empty — should auto-detect
            $0.spanProcessing = .simple
            $0.autoInstrumentation.metricsShim = false
        }
        defer { Signoz.shutdown() }

        span("hostname.test") { s in
            info("Hostname auto-detect test")
        }
    }

    @Test("Literal attributes in real usage")
    func literalAttributes() {
        Signoz.start(serviceName: "signoz-swift-literal-test") {
            $0.spanProcessing = .simple
            $0.autoInstrumentation.metricsShim = false
        }
        defer { Signoz.shutdown() }

        span("http.request", kind: .server, attributes: [
            "http.method": "POST",
            "http.status_code": 201,
            "http.response_content_length": 1024.0,
            "http.retry": false,
        ]) { s in
            info("Request handled", attributes: [
                "user.id": "u-123",
                "latency_ms": 42,
            ])
        }
    }
}
