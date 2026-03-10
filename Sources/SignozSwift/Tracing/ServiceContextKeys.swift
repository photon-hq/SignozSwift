import OpenTelemetryApi
import ServiceContextModule

/// Sendable wrapper for OTel's `SpanContext` (which is a class).
/// SpanContext is effectively immutable once created, so this is safe.
struct SendableSpanContext: Sendable {
    nonisolated(unsafe) let spanContext: SpanContext
    init(_ spanContext: SpanContext) {
        self.spanContext = spanContext
    }
}

/// Key for storing an OTel `SpanContext` inside a `ServiceContext`.
/// Used by the bridge tracer to propagate trace context between
/// `swift-distributed-tracing` and the OpenTelemetry SDK.
enum OTelSpanContextKey: ServiceContextKey {
    typealias Value = SendableSpanContext
    static let nameOverride: String? = "otel-span-context"
}

extension ServiceContext {
    var otelSpanContext: SpanContext? {
        get { self[OTelSpanContextKey.self]?.spanContext }
        set {
            if let newValue {
                self[OTelSpanContextKey.self] = SendableSpanContext(newValue)
            } else {
                self[OTelSpanContextKey.self] = nil
            }
        }
    }
}
