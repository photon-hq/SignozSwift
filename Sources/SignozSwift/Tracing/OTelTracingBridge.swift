import Foundation
@preconcurrency import OpenTelemetryApi
import OpenTelemetrySdk
@preconcurrency import Tracing

/// Bridges `swift-distributed-tracing`'s `Tracer` protocol to the
/// OpenTelemetry SDK, so that `grpc-swift-extras` OTel interceptors
/// create real OTel spans exported through the normal pipeline.
struct OTelTracingBridge: Tracing.Tracer {
    typealias Span = BridgedSpan

    private static let traceparentKey = "traceparent"
    private static let tracestateKey = "tracestate"

    func startSpan<Instant: TracerInstant>(
        _ operationName: String,
        context: @autoclosure () -> ServiceContext,
        ofKind kind: Tracing.SpanKind,
        at instant: @autoclosure () -> Instant,
        function: String,
        file fileID: String,
        line: UInt
    ) -> BridgedSpan {
        let serviceContext = context()
        let otelTracer = Signoz.tracer

        // Resolve parent: first from ServiceContext, then from OTel's active span.
        let builder = otelTracer.spanBuilder(spanName: operationName)
        builder.setSpanKind(spanKind: mapSpanKind(kind))

        if let parentContext = serviceContext.otelSpanContext, parentContext.isValid {
            builder.setParent(parentContext)
        } else if let activeSpan = OpenTelemetry.instance.contextProvider.activeSpan {
            builder.setParent(activeSpan)
        } else {
            builder.setNoParent()
        }

        let nanos = instant().nanosecondsSinceEpoch
        let date = Date(timeIntervalSince1970: Double(nanos) / 1_000_000_000)
        builder.setStartTime(time: date)

        let otelSpan = builder.startSpan()

        // Store the OTel SpanContext in the ServiceContext for propagation.
        var ctx = serviceContext
        ctx.otelSpanContext = otelSpan.context

        return BridgedSpan(otelSpan: otelSpan, context: ctx)
    }

    func forceFlush() {
        Signoz.tracerProvider?.forceFlush()
    }

    // MARK: - W3C Trace Context Propagation

    func inject<Carrier, Inject: Instrumentation.Injector>(
        _ context: ServiceContext,
        into carrier: inout Carrier,
        using injector: Inject
    ) where Inject.Carrier == Carrier {
        guard let spanContext = context.otelSpanContext, spanContext.isValid else {
            return
        }

        // W3C traceparent: version-traceId-spanId-traceFlags
        let flags = spanContext.traceFlags.sampled ? "01" : "00"
        let traceparent = "00-\(spanContext.traceId.hexString)-\(spanContext.spanId.hexString)-\(flags)"
        injector.inject(traceparent, forKey: Self.traceparentKey, into: &carrier)

        // W3C tracestate (if non-empty)
        if !spanContext.traceState.entries.isEmpty {
            let tracestate = spanContext.traceState.entries
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ",")
            injector.inject(tracestate, forKey: Self.tracestateKey, into: &carrier)
        }
    }

    func extract<Carrier, Extract: Instrumentation.Extractor>(
        _ carrier: Carrier,
        into context: inout ServiceContext,
        using extractor: Extract
    ) where Extract.Carrier == Carrier {
        guard let traceparent = extractor.extract(key: Self.traceparentKey, from: carrier) else {
            return
        }

        // Parse W3C traceparent: version-traceId-spanId-traceFlags
        let parts = traceparent.split(separator: "-")
        guard parts.count == 4, parts[0] == "00" else {
            return
        }

        let traceId = TraceId(fromHexString: String(parts[1]))
        let spanId = SpanId(fromHexString: String(parts[2]))
        guard traceId.isValid, spanId.isValid else {
            return
        }

        let sampled = UInt8(String(parts[3]), radix: 16).map { $0 & 0x01 != 0 } ?? false
        var traceFlags = TraceFlags()
        traceFlags.setIsSampled(sampled)

        // Parse tracestate if present
        var traceState = TraceState()
        if let tracestateHeader = extractor.extract(key: Self.tracestateKey, from: carrier) {
            for entry in tracestateHeader.split(separator: ",") {
                let kv = entry.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    traceState = traceState.setting(
                        key: String(kv[0]).trimmingCharacters(in: .whitespaces),
                        value: String(kv[1]).trimmingCharacters(in: .whitespaces)
                    )
                }
            }
        }

        let spanContext = SpanContext.createFromRemoteParent(
            traceId: traceId,
            spanId: spanId,
            traceFlags: traceFlags,
            traceState: traceState
        )
        context.otelSpanContext = spanContext
    }
}
