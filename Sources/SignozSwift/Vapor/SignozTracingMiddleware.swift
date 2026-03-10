#if SIGNOZ_VAPOR
import Vapor
@preconcurrency import OpenTelemetryApi

/// Vapor middleware that automatically creates OpenTelemetry `.server` spans
/// for every incoming HTTP request with standard OTel HTTP semantic convention attributes.
///
/// Enable by adding the `Vapor` trait to your SignozSwift dependency:
/// ```swift
/// .package(url: "https://github.com/photon-hq/SignozSwift.git", from: "0.1.0", traits: ["Vapor"])
/// ```
///
/// Then register the middleware:
/// ```swift
/// import SignozSwift
///
/// app.middleware.use(SignozTracingMiddleware())
/// ```
public struct SignozTracingMiddleware: AsyncMiddleware {

    public init() {}

    public func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        let method = request.method.rawValue
        let path = request.url.path

        let builder = Signoz.tracer.spanBuilder(spanName: "\(method) \(path)")
        builder.setSpanKind(spanKind: .server)

        // Extract W3C traceparent/tracestate from request headers
        if let parentContext = Self.extractTraceContext(from: request) {
            builder.setParent(parentContext)
        }

        let span = builder.startSpan()
        span.setAttribute(key: "http.method", value: .string(method))
        span.setAttribute(key: "http.target", value: .string(path))
        span.setAttribute(key: "http.scheme", value: .string(request.url.scheme ?? "http"))

        do {
            let response = try await OpenTelemetry.instance.contextProvider
                .withActiveSpan(span) {
                    try await next.respond(to: request)
                }

            // Route is available after the responder chain resolves the route
            if let route = request.route {
                let pattern = Self.routePattern(route)
                span.name = "\(method) \(pattern)"
                span.setAttribute(key: "http.route", value: .string(pattern))
            }

            let statusCode = Int(response.status.code)
            span.setAttribute(key: "http.status_code", value: .int(statusCode))

            if response.status.code >= 500 {
                span.status = .error(description: "\(response.status)")
            } else {
                span.status = .ok
            }

            Self.injectTraceContext(span: span, into: response)
            span.end()
            return response
        } catch {
            if let route = request.route {
                let pattern = Self.routePattern(route)
                span.name = "\(method) \(pattern)"
                span.setAttribute(key: "http.route", value: .string(pattern))
            }
            span.status = .error(description: "\(error)")
            span.end()
            throw error
        }
    }

    // MARK: - Route Pattern

    private static func routePattern(_ route: Route) -> String {
        "/" + route.path.map { component in
            switch component {
            case .constant(let value): return value
            case .parameter(let name): return ":\(name)"
            case .anything: return "*"
            case .catchall: return "**"
            }
        }.joined(separator: "/")
    }

    // MARK: - W3C Trace Context

    private static func extractTraceContext(from request: Request) -> SpanContext? {
        guard let traceparent = request.headers.first(name: "traceparent") else {
            return nil
        }

        let parts = traceparent.split(separator: "-")
        guard parts.count == 4, parts[0] == "00" else {
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

        var traceState = TraceState()
        if let tracestateHeader = request.headers.first(name: "tracestate") {
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

        return SpanContext.createFromRemoteParent(
            traceId: traceId,
            spanId: spanId,
            traceFlags: traceFlags,
            traceState: traceState
        )
    }

    private static func injectTraceContext(span: any OpenTelemetryApi.Span, into response: Response) {
        let ctx = span.context
        guard ctx.isValid else { return }

        let flags = ctx.traceFlags.sampled ? "01" : "00"
        let traceparent = "00-\(ctx.traceId.hexString)-\(ctx.spanId.hexString)-\(flags)"
        response.headers.replaceOrAdd(name: "traceparent", value: traceparent)

        if !ctx.traceState.entries.isEmpty {
            let tracestate = ctx.traceState.entries
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ",")
            response.headers.replaceOrAdd(name: "tracestate", value: tracestate)
        }
    }
}
#endif
