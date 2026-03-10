import Foundation
@preconcurrency import OpenTelemetryApi
import OpenTelemetrySdk
@preconcurrency import Tracing

/// Bridges `swift-distributed-tracing`'s `Tracer` protocol to the
/// OpenTelemetry SDK, so that `grpc-swift-extras` OTel interceptors
/// create real OTel spans exported through the normal pipeline.
struct OTelTracingBridge: Tracing.Tracer {
    typealias Span = BridgedSpan

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

        let (traceparent, tracestate) = W3CTraceContext.serialize(spanContext)
        injector.inject(traceparent, forKey: W3CTraceContext.traceparentKey, into: &carrier)
        if let tracestate {
            injector.inject(tracestate, forKey: W3CTraceContext.tracestateKey, into: &carrier)
        }
    }

    func extract<Carrier, Extract: Instrumentation.Extractor>(
        _ carrier: Carrier,
        into context: inout ServiceContext,
        using extractor: Extract
    ) where Extract.Carrier == Carrier {
        guard let traceparent = extractor.extract(key: W3CTraceContext.traceparentKey, from: carrier) else {
            return
        }

        let tracestate = extractor.extract(key: W3CTraceContext.tracestateKey, from: carrier)
        if let spanContext = W3CTraceContext.parse(traceparent: traceparent, tracestate: tracestate) {
            context.otelSpanContext = spanContext
        }
    }
}
