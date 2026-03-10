@preconcurrency import OpenTelemetryApi

/// Shared W3C Trace Context parsing and serialization.
///
/// Used by both `OTelTracingBridge` (for gRPC distributed tracing) and
/// `SignozTracingMiddleware` (for Vapor HTTP tracing).
enum W3CTraceContext {

    static let traceparentKey = "traceparent"
    static let tracestateKey = "tracestate"

    /// Parse W3C `traceparent` and optional `tracestate` header values into a `SpanContext`.
    static func parse(traceparent: String, tracestate: String? = nil) -> SpanContext? {
        // W3C spec: reject only version "ff"; accept unknown future versions
        // for forward compatibility (the first 55 chars are guaranteed stable).
        // Future versions may append extra `-` delimited fields, so require >= 4 parts.
        let parts = traceparent.split(separator: "-")
        guard parts.count >= 4, parts[0] != "ff" else {
            return nil
        }

        let traceId = TraceId(fromHexString: String(parts[1]))
        let spanId = SpanId(fromHexString: String(parts[2]))
        guard traceId.isValid, spanId.isValid else {
            return nil
        }

        let sampled = UInt8(String(parts[3]), radix: 16).map { $0 & 0x01 != 0 } ?? false
        var traceFlags = TraceFlags()
        traceFlags.setIsSampled(sampled)

        var state = TraceState()
        if let tracestateHeader = tracestate {
            for entry in tracestateHeader.split(separator: ",") {
                let kv = entry.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    state = state.setting(
                        key: String(kv[0]).trimmingCharacters(in: .whitespaces),
                        value: String(kv[1]).trimmingCharacters(in: .whitespaces)
                    )
                }
            }
        }

        return SpanContext.createFromRemoteParent(
            traceId: traceId,
            spanId: spanId,
            traceFlags: traceFlags,
            traceState: state
        )
    }

    /// Serialize a `SpanContext` into W3C `traceparent` and optional `tracestate` header values.
    static func serialize(_ spanContext: SpanContext) -> (traceparent: String, tracestate: String?) {
        let flags = spanContext.traceFlags.sampled ? "01" : "00"
        let traceparent = "00-\(spanContext.traceId.hexString)-\(spanContext.spanId.hexString)-\(flags)"

        var tracestate: String? = nil
        if !spanContext.traceState.entries.isEmpty {
            tracestate = spanContext.traceState.entries
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ",")
        }

        return (traceparent, tracestate)
    }
}
