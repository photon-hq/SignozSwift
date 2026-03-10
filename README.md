# SignozSwift

Ergonomic OpenTelemetry wrapper for sending traces, logs, and metrics to [SigNoz](https://signoz.io) via OTLP/gRPC. One call to set up, top-level functions to instrument.

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/photon-hq/SignozSwift.git", from: "0.1.0"),
]
```

Then add `"SignozSwift"` to your target's dependencies:

```swift
.target(
    name: "MyApp",
    dependencies: ["SignozSwift"]
),
```

## Quick Start

```swift
import SignozSwift

// Start instrumentation
Signoz.start(serviceName: "my-app") {
    $0.environment = "production"
    $0.serviceVersion = "1.0.0"
}
defer { Signoz.shutdown() }

// Trace
let result = try span("fetch-users", kind: .client) { s in
    s.setAttribute(key: "db.system", value: "postgresql")
    return try db.fetchUsers()
}

// Log
info("Request handled", attributes: ["status": 200])
```

## Usage

### Vapor HTTP Backend

For Vapor projects, depend on the `SignozVapor` product instead of `SignozSwift` — it re-exports everything plus the tracing middleware:

```swift
.target(
    name: "MyVaporApp",
    dependencies: [
        .product(name: "SignozVapor", package: "SignozSwift"),
    ]
),
```

```swift
import SignozVapor

func configure(_ app: Application) throws {
    Signoz.start(serviceName: "my-vapor-api") {
        $0.endpoint = "ingest.signoz.io:4317"       // or localhost:4317 for self-hosted
        $0.transportSecurity = .tls
        $0.headers = ["signoz-ingestion-key": "..."]
        $0.environment = "production"
        $0.serviceVersion = "1.0.0"
    }

    // Automatic request tracing — creates a .server span for every HTTP request
    // with OTel semantic convention attributes and W3C trace context propagation
    app.middleware.use(SignozTracingMiddleware())

    app.get("users") { req async throws -> [User] in
        // Spans created here are automatically nested under the request span
        try await db.fetchUsers()
    }
}

// In entrypoint:
defer { Signoz.shutdown() }
```

`SignozTracingMiddleware` sets `http.method`, `http.target`, `http.scheme`, `http.status_code`, and `http.route` on each span. Span names use the matched route pattern (e.g. `GET /users/:id`) when available. Vapor's HTTP metrics (`http_requests_total`, `http_request_duration_seconds`) are also automatically exported via the swift-metrics bridge.

### ArgumentParser CLI

```swift
import ArgumentParser
import SignozSwift

@main
struct MyCLI: AsyncParsableCommand {
    @Option var input: String

    func run() async throws {
        Signoz.start(serviceName: "my-cli") {
            $0.spanProcessing = .simple  // flush immediately for short-lived CLI
        }
        defer { Signoz.shutdown() }

        try await span("process-data") { s in
            info("Starting", attributes: ["input": .string(input)])
            let result = try await processData(input)
            s.setAttribute(key: "records.processed", value: result.count)
        }
    }
}
```

### iOS App

```swift
import SignozSwift
import SwiftUI

@main
struct MyApp: App {
    init() {
        Signoz.start(serviceName: "my-ios-app") {
            $0.endpoint = "ingest.signoz.io:4317"
            $0.transportSecurity = .tls
            $0.headers = ["signoz-ingestion-key": "..."]
            $0.environment = "production"
            $0.autoInstrumentation.signpostIntegration = true
            // urlSession + resourceDetection are ON by default
        }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

## API Reference

### Setup & Lifecycle

```swift
// Start — serviceName is required, everything else has defaults
Signoz.start(serviceName: "my-app") { config in
    config.endpoint = "localhost:4317"  // default
    config.environment = "production"                 // deployment.environment
    config.hostName = .auto                             // host.name (system hostname)
    config.hostName = .custom("web-01")                 // host.name (explicit value)
    // config.hostName = .none                           // omit host.name (default)
    config.serviceVersion = "1.0.0"
    config.transportSecurity = .plaintext              // default
    config.spanProcessing = .batch()                  // default, use .simple for CLIs
    config.headers = ["signoz-ingestion-key": "..."]
    config.resourceAttributes = ["custom.attr": "value"]
    config.localPersistencePath = URL(filePath: "/tmp/signoz")  // optional on-disk queue
    config.consoleLog = .enabled                              // colored stderr output
}

// Shutdown — flush and clean up
Signoz.shutdown()
```

### Tracing

```swift
// Sync span — auto-starts, auto-ends, auto-sets error status on throw
let result = try span("operation-name", kind: .client, attributes: [
    "http.method": "GET",
    "http.status_code": 200,
]) { s in
    s.setAttribute(key: "extra", value: "value")
    return try doWork()
}

// Async span
let data = try await span("fetch", kind: .client) { s async in
    try await URLSession.shared.data(from: url)
}

// Nested spans
span("parent") { _ in
    span("child") { _ in
        info("Inside child span")
    }
}

// Direct tracer access for advanced use
let s = Signoz.tracer.spanBuilder(spanName: "manual").startSpan()
s.end()
```

### Logging

```swift
trace("Verbose detail")
debug("Debug info", attributes: ["count": 42])
info("Request handled", attributes: ["status": 200])
warn("Approaching limit", attributes: ["threshold": 0.9])
error("Something failed", attributes: ["code": 500])
fatal("Unrecoverable error")

// Direct logger access
Signoz.logger.log("Custom", severity: .info, attributes: ["key": "value"])
```

### Console Output

By default (`.auto`), log calls also print colored output to stderr in DEBUG builds — useful during development without extra setup. In RELEASE builds, console output is automatically disabled to avoid noise.

```swift
Signoz.start(serviceName: "my-app") {
    $0.consoleLog = .enabled   // always print to stderr
    // $0.consoleLog = .disabled  // never print to stderr
    // $0.consoleLog = .auto      // DEBUG only (default)
}

info("Server started", attributes: ["port": 8080])
// stderr: [INFO] Server started {"port": 8080}
```

### gRPC Auto-Tracing

If your app uses gRPC (via [`grpc-swift-2`](https://github.com/grpc/grpc-swift-2)), you can automatically trace all RPC calls by attaching the bundled interceptors from [grpc-swift-extras](https://github.com/grpc/grpc-swift-extras):

```swift
import SignozSwift
import GRPCNIOTransportHTTP2

// Client — auto-creates a span for each outgoing RPC
let client = GRPCClient(
    transport: try .http2NIOPosix(target: .dns(host: "api.example.com", port: 443)),
    interceptors: [
        ClientOTelTracingInterceptor(
            serverHostname: "api.example.com",
            networkTransportMethod: "tcp"
        )
    ]
)

// Server — auto-creates a span for each incoming RPC
let server = GRPCServer(
    transport: try .http2NIOPosix(address: .ipv4(host: "0.0.0.0", port: 8080)),
    services: [myService],
    interceptors: [
        ServerOTelTracingInterceptor(
            serverHostname: "api.example.com",
            networkTransportMethod: "tcp"
        )
    ]
)
```

Each span is annotated with OTel semantic conventions (`rpc.system`, `rpc.service`, `rpc.method`, `rpc.grpc.status_code`, etc.) and context is automatically propagated via W3C `traceparent` headers.

### Attribute Literals

`AttributeValue` conforms to `ExpressibleByStringLiteral`, `ExpressibleByIntegerLiteral`, `ExpressibleByFloatLiteral`, and `ExpressibleByBooleanLiteral`, so you can write:

```swift
let attrs: [String: AttributeValue] = [
    "name": "alice",     // .string("alice")
    "count": 42,         // .int(42)
    "ratio": 0.75,       // .double(0.75)
    "enabled": true,     // .bool(true)
]
```

## Configuration

| Property | Type | Default | Description |
|---|---|---|---|
| `endpoint` | `String` | `"localhost:4317"` | gRPC endpoint (`host:port`) |
| `serviceName` | `String` | *required* | Service name (`service.name`) |
| `serviceVersion` | `String` | `""` | Service version (`service.version`) |
| `environment` | `String` | `""` | Deployment environment (`deployment.environment`) |
| `hostName` | `.none` \| `.auto` \| `.custom(String)` | `.none` | Host name (`host.name`). `.none` omits the attribute, `.auto` uses the system hostname, `.custom("...")` uses an explicit value. |
| `resourceAttributes` | `[String: AttributeValue]` | `[:]` | Extra resource attributes |
| `headers` | `[String: String]` | `[:]` | gRPC metadata headers |
| `transportSecurity` | `.plaintext` \| `.tls` | `.plaintext` | Transport security mode |
| `spanProcessing` | `.simple` \| `.batch(...)` | `.batch()` | Span processing strategy |
| `localPersistencePath` | `URL?` | `nil` | Directory for on-disk telemetry backup. When set, spans and logs are exported to the network immediately **and** written to disk independently. Persisted data is retried by a background worker if the live export fails. |
| `consoleLog` | `.auto` \| `.enabled` \| `.disabled` | `.auto` | Colored console output to stderr. `.auto` enables in DEBUG builds only, `.enabled` always prints, `.disabled` never prints. |
| `autoInstrumentation` | `AutoInstrumentation` | see below | Auto-instrumentation toggles |

### Auto-Instrumentation

| Property | Default | Description |
|---|---|---|
| `urlSession` | `true` | Auto-trace URLSession calls *(Apple platforms)* |
| `resourceDetection` | `true` | Auto-detect device/app/OS attributes *(Apple platforms)* |
| `signpostIntegration` | `false` | Bridge spans to Xcode Instruments *(Apple platforms)* |
| `metricsShim` | `true` | Bridge swift-metrics to OTel (enables Vapor HTTP metrics) |

## SigNoz Dashboard Mapping

| Configuration | Resource Attribute | SigNoz Filter |
|---|---|---|
| `serviceName` | `service.name` | Services |
| `environment` | `deployment.environment` | Logs > Environment |
| `hostName` | `host.name` | Logs > Hostname |

## What's Under the Hood

SignozSwift wraps the official OpenTelemetry Swift SDK — it does not reinvent any OTel types.

- **[opentelemetry-swift-core](https://github.com/open-telemetry/opentelemetry-swift-core) 2.3.0** — `OpenTelemetryApi`, `OpenTelemetrySdk`
- **[opentelemetry-swift](https://github.com/open-telemetry/opentelemetry-swift) 3.0.0** — OTLP proto adapters, URLSession instrumentation, ResourceExtension, SignPost integration, SwiftMetricsShim
- **[grpc-swift-2](https://github.com/grpc/grpc-swift-2) 2.2.1** — gRPC transport (v2, async/await)
- **[grpc-swift-extras](https://github.com/grpc/grpc-swift-extras) 2.1.1** — OTel tracing interceptors for automatic gRPC span injection
- **[Rainbow](https://github.com/onevcat/Rainbow) 4.x** — Colored console output

All OTel types (`Span`, `Tracer`, `Logger`, `AttributeValue`, `SpanKind`, etc.) are re-exported via `@_exported import OpenTelemetryApi`, so you only need `import SignozSwift`.

## Testing

Integration tests export telemetry via gRPC to `localhost:4317`. A local OpenTelemetry Collector must be running, otherwise each test will block waiting for gRPC timeouts (~60-240s per test).

Start the collector with Docker:

```bash
docker run -d --name otel-collector \
  -p 4317:4317 \
  -v $(pwd)/otel-collector-config.yaml:/etc/otelcol-contrib/config.yaml \
  otel/opentelemetry-collector-contrib:latest
```

The collector's debug exporter logs all received telemetry. One integration test reads `docker logs` to verify spans and logs were actually received end-to-end.

Then run tests:

```bash
swift test
```

Start/stop the collector between sessions:

```bash
docker start otel-collector
docker stop otel-collector
```

## Requirements

- Swift 6.2+
- macOS 15+ / iOS 18+ / Linux

## License

MIT
