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
        if let traceparent = request.headers.first(name: W3CTraceContext.traceparentKey),
           let parentContext = W3CTraceContext.parse(
               traceparent: traceparent,
               tracestate: request.headers.first(name: W3CTraceContext.tracestateKey)
           ) {
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

            Self.injectTraceContext(spanContext: span.context, into: response)
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

    private static func injectTraceContext(spanContext: SpanContext, into response: Response) {
        guard spanContext.isValid else { return }
        let (traceparent, tracestate) = W3CTraceContext.serialize(spanContext)
        response.headers.replaceOrAdd(name: W3CTraceContext.traceparentKey, value: traceparent)
        if let tracestate {
            response.headers.replaceOrAdd(name: W3CTraceContext.tracestateKey, value: tracestate)
        }
    }
}
#endif
