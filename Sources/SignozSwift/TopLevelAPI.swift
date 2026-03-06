import Foundation
import OpenTelemetryApi
import Rainbow

#if canImport(Darwin)
nonisolated(unsafe) private let consoleStdErr = stderr
#elseif canImport(Glibc)
import Glibc
nonisolated(unsafe) private let consoleStdErr = fdopen(STDERR_FILENO, "w")!
#endif

// MARK: - Top-Level Tracing

/// Execute a synchronous operation within a span.
///
/// The span is automatically started, ended, and error-status is set on throw.
///
/// ```swift
/// let result = try span("load-config") { s in
///     s.setAttribute(key: "path", value: "/etc/app.json")
///     return try loadConfig()
/// }
/// ```
@discardableResult
public func span<T>(
    _ name: String,
    kind: SpanKind = .internal,
    attributes: [String: AttributeValue] = [:],
    _ operation: (any Span) throws -> T
) rethrows -> T {
    try Signoz.tracer.withSpan(name, kind: kind, attributes: attributes, operation)
}

/// Execute a synchronous operation within a span, without access to the span handle.
///
/// ```swift
/// span("debug.test", attributes: ["debug": .bool(true)]) {
///     info("Test span sent successfully.")
/// }
/// ```
@discardableResult
public func span<T>(
    _ name: String,
    kind: SpanKind = .internal,
    attributes: [String: AttributeValue] = [:],
    _ operation: () throws -> T
) rethrows -> T {
    try Signoz.tracer.withSpan(name, kind: kind, attributes: attributes, operation)
}

/// Execute an asynchronous operation within a span.
///
/// ```swift
/// let users = try await span("fetch-users", kind: .client) { s in
///     let (data, _) = try await URLSession.shared.data(from: url)
///     return try JSONDecoder().decode([User].self, from: data)
/// }
/// ```
@discardableResult
public func span<T>(
    _ name: String,
    kind: SpanKind = .internal,
    attributes: [String: AttributeValue] = [:],
    _ operation: (any Span) async throws -> T
) async rethrows -> T {
    try await Signoz.tracer.withSpan(name, kind: kind, attributes: attributes, operation)
}

/// Execute an asynchronous operation within a span, without access to the span handle.
@discardableResult
public func span<T>(
    _ name: String,
    kind: SpanKind = .internal,
    attributes: [String: AttributeValue] = [:],
    _ operation: () async throws -> T
) async rethrows -> T {
    try await Signoz.tracer.withSpan(name, kind: kind, attributes: attributes, operation)
}

// MARK: - Top-Level Logging

/// Emit a TRACE-level log record.
public func trace(_ body: String, attributes: [String: AttributeValue] = [:]) {
    consolePrint(body, level: "TRACE", color: { $0.lightBlack })
    Signoz.logger.trace(body, attributes: attributes)
}

/// Emit a DEBUG-level log record.
public func debug(_ body: String, attributes: [String: AttributeValue] = [:]) {
    consolePrint(body, level: "DEBUG", color: { $0.cyan })
    Signoz.logger.debug(body, attributes: attributes)
}

/// Emit an INFO-level log record.
public func info(_ body: String, attributes: [String: AttributeValue] = [:]) {
    consolePrint(body, level: "INFO", color: { $0 })
    Signoz.logger.info(body, attributes: attributes)
}

/// Emit a WARN-level log record.
public func warn(_ body: String, attributes: [String: AttributeValue] = [:]) {
    consolePrint(body, level: "WARN", color: { $0.yellow })
    Signoz.logger.warn(body, attributes: attributes)
}

/// Emit an ERROR-level log record.
public func error(_ body: String, attributes: [String: AttributeValue] = [:]) {
    consolePrint(body, level: "ERROR", color: { $0.red })
    Signoz.logger.error(body, attributes: attributes)
}

/// Emit a FATAL-level log record.
public func fatal(_ body: String, attributes: [String: AttributeValue] = [:]) {
    consolePrint(body, level: "FATAL", color: { $0.red.bold })
    Signoz.logger.fatal(body, attributes: attributes)
}

// MARK: - Console Output

private func consolePrint(_ message: String, level: String, color: (String) -> String) {
    guard Signoz.consoleLogEnabled else { return }
    fputs(color("[\(level)] \(message)") + "\n", consoleStdErr)
}
