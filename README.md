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

```swift
import SignozSwift
import Vapor

func configure(_ app: Application) throws {
    Signoz.start(serviceName: "my-vapor-api") {
        $0.endpoint = "ingest.signoz.io:4317"       // or localhost:4317 for self-hosted
        $0.transportSecurity = .tls
        $0.headers = ["signoz-ingestion-key": "..."]
        $0.environment = "production"
        $0.serviceVersion = "1.0.0"
        // Vapor's HTTP metrics (http_requests_total, http_request_duration_seconds)
        // are automatically exported via the swift-metrics bridge. Zero extra code.
    }

    app.get("users") { req async throws -> [User] in
        try await span("GET /users", kind: .server) { s in
            s.setAttribute(key: "http.method", value: "GET")
            return try await db.fetchUsers()
        }
    }
}

// In entrypoint:
defer { Signoz.shutdown() }
```

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
- **[opentelemetry-swift](https://github.com/open-telemetry/opentelemetry-swift) 2.3.0** — OTLP/gRPC exporters, URLSession instrumentation, ResourceExtension, SignPost integration, SwiftMetricsShim
- **[grpc-swift](https://github.com/grpc/grpc-swift) 1.27.0** — gRPC transport

All OTel types (`Span`, `Tracer`, `Logger`, `AttributeValue`, `SpanKind`, etc.) are re-exported via `@_exported import OpenTelemetryApi`, so you only need `import SignozSwift`.

## Testing

Integration tests export telemetry via gRPC to `localhost:4317`. A local OpenTelemetry Collector must be running, otherwise each test will block waiting for gRPC timeouts (~60-240s per test).

Start the collector with Docker:

```bash
docker run -d --name otel-collector \
  -p 4317:4317 \
  -v $(pwd)/otel-collector-config.yaml:/etc/otelcol/config.yaml \
  otel/opentelemetry-collector:latest
```

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
- macOS 13+ / iOS 16+ / Linux

## License

MIT
