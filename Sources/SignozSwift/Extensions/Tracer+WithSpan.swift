import OpenTelemetryApi

extension Tracer {

    /// Execute a synchronous operation within a span.
    ///
    /// The span is automatically started before `operation` runs and ended
    /// when it returns. If `operation` throws, the span status is set to
    /// `.error` with the error description before re-throwing.
    ///
    /// ```swift
    /// let result = try Signoz.tracer.withSpan("load-config") { span in
    ///     span.setAttribute(key: "path", value: "/etc/app.json")
    ///     return try loadConfig()
    /// }
    /// ```
    @discardableResult
    public func withSpan<T>(
        _ name: String,
        kind: SpanKind = .internal,
        attributes: [String: AttributeValue] = [:],
        _ operation: (any Span) throws -> T
    ) rethrows -> T {
        let span = spanBuilder(spanName: name)
            .setSpanKind(spanKind: kind)
            .startSpan()

        for (key, value) in attributes {
            span.setAttribute(key: key, value: value)
        }

        do {
            let result = try operation(span)
            span.status = .ok
            span.end()
            return result
        } catch {
            span.status = .error(description: "\(error)")
            span.end()
            throw error
        }
    }

    /// Execute an asynchronous operation within a span.
    ///
    /// The span is automatically started before `operation` runs and ended
    /// when it returns. If `operation` throws, the span status is set to
    /// `.error` with the error description before re-throwing.
    ///
    /// ```swift
    /// let users = try await Signoz.tracer.withSpan("fetch-users", kind: .client) { span in
    ///     let (data, _) = try await URLSession.shared.data(from: url)
    ///     return try JSONDecoder().decode([User].self, from: data)
    /// }
    /// ```
    @discardableResult
    public func withSpan<T>(
        _ name: String,
        kind: SpanKind = .internal,
        attributes: [String: AttributeValue] = [:],
        _ operation: (any Span) async throws -> T
    ) async rethrows -> T {
        let span = spanBuilder(spanName: name)
            .setSpanKind(spanKind: kind)
            .startSpan()

        for (key, value) in attributes {
            span.setAttribute(key: key, value: value)
        }

        do {
            let result = try await operation(span)
            span.status = .ok
            span.end()
            return result
        } catch {
            span.status = .error(description: "\(error)")
            span.end()
            throw error
        }
    }
}
