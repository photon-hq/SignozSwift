import Foundation
import OpenTelemetryApi
@preconcurrency import Tracing

/// A span that wraps an `OpenTelemetryApi.Span` but conforms to
/// `swift-distributed-tracing`'s `Tracing.Span` protocol.
final class BridgedSpan: Tracing.Span, @unchecked Sendable {
    private let otelSpan: any OpenTelemetryApi.Span
    let context: ServiceContext
    let isRecording: Bool

    var operationName: String {
        get { otelSpan.name }
        set { otelSpan.name = newValue }
    }

    var attributes: SpanAttributes {
        get { _attributes }
        set {
            _attributes = newValue
            newValue.forEach { key, value in
                otelSpan.setAttribute(key: key, value: mapAttribute(value))
            }
        }
    }

    private var _attributes: SpanAttributes = [:]

    init(otelSpan: any OpenTelemetryApi.Span, context: ServiceContext) {
        self.otelSpan = otelSpan
        self.context = context
        self.isRecording = otelSpan.isRecording
    }

    func setStatus(_ status: Tracing.SpanStatus) {
        switch status.code {
        case .ok:
            otelSpan.status = .ok
        case .error:
            otelSpan.status = .error(description: status.message ?? "")
        }
    }

    func addEvent(_ event: Tracing.SpanEvent) {
        var otelAttrs = [String: AttributeValue]()
        event.attributes.forEach { key, value in
            otelAttrs[key] = mapAttribute(value)
        }
        let date = Date(
            timeIntervalSince1970: Double(event.nanosecondsSinceEpoch) / 1_000_000_000
        )
        otelSpan.addEvent(name: event.name, attributes: otelAttrs, timestamp: date)
    }

    func recordError<Instant: TracerInstant>(
        _ error: Error,
        attributes: SpanAttributes,
        at instant: @autoclosure () -> Instant
    ) {
        var otelAttrs: [String: AttributeValue] = [
            "exception.type": .string(String(describing: type(of: error))),
            "exception.message": .string(String(describing: error)),
        ]
        attributes.forEach { key, value in
            otelAttrs[key] = mapAttribute(value)
        }
        let nanos = instant().nanosecondsSinceEpoch
        let date = Date(timeIntervalSince1970: Double(nanos) / 1_000_000_000)
        otelSpan.addEvent(name: "exception", attributes: otelAttrs, timestamp: date)
    }

    func addLink(_ link: SpanLink) {
        // OTel SDK only supports adding links at span creation time.
        // This is a known limitation of the bridge.
    }

    func end<Instant: TracerInstant>(at instant: @autoclosure () -> Instant) {
        let nanos = instant().nanosecondsSinceEpoch
        let date = Date(timeIntervalSince1970: Double(nanos) / 1_000_000_000)
        otelSpan.end(time: date)
    }
}

// MARK: - Attribute Mapping

/// Map a `Tracing.SpanAttribute` to an `OpenTelemetryApi.AttributeValue`.
func mapAttribute(_ attr: SpanAttribute) -> AttributeValue {
    switch attr {
    case .string(let v): return .string(v)
    case .int32(let v): return .int(Int(v))
    case .int64(let v): return .int(Int(v))
    case .double(let v): return .double(v)
    case .bool(let v): return .bool(v)
    case .stringArray(let v): return .array(AttributeArray(values: v.map { .string($0) }))
    case .int32Array(let v): return .array(AttributeArray(values: v.map { .int(Int($0)) }))
    case .int64Array(let v): return .array(AttributeArray(values: v.map { .int(Int($0)) }))
    case .doubleArray(let v): return .array(AttributeArray(values: v.map { .double($0) }))
    case .boolArray(let v): return .array(AttributeArray(values: v.map { .bool($0) }))
    case .stringConvertible(let v): return .string(String(describing: v))
    case .stringConvertibleArray(let v): return .array(AttributeArray(values: v.map { .string(String(describing: $0)) }))
    default: return .string(String(describing: attr))
    }
}

/// Map `Tracing.SpanKind` to `OpenTelemetryApi.SpanKind`.
func mapSpanKind(_ kind: Tracing.SpanKind) -> OpenTelemetryApi.SpanKind {
    switch kind {
    case .client: return .client
    case .server: return .server
    case .producer: return .producer
    case .consumer: return .consumer
    case .internal: return .internal
    }
}
