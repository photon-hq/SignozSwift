import OpenTelemetryApi

extension Logger {

    /// Emit a log record with the given severity and body.
    public func log(
        _ body: String,
        severity: Severity = .info,
        attributes: [String: AttributeValue] = [:]
    ) {
        logRecordBuilder()
            .setSeverity(severity)
            .setBody(.string(body))
            .setAttributes(attributes)
            .emit()
    }

    /// Emit a TRACE-level log.
    public func trace(_ body: String, attributes: [String: AttributeValue] = [:]) {
        log(body, severity: .trace, attributes: attributes)
    }

    /// Emit a DEBUG-level log.
    public func debug(_ body: String, attributes: [String: AttributeValue] = [:]) {
        log(body, severity: .debug, attributes: attributes)
    }

    /// Emit an INFO-level log.
    public func info(_ body: String, attributes: [String: AttributeValue] = [:]) {
        log(body, severity: .info, attributes: attributes)
    }

    /// Emit a WARN-level log.
    public func warn(_ body: String, attributes: [String: AttributeValue] = [:]) {
        log(body, severity: .warn, attributes: attributes)
    }

    /// Emit an ERROR-level log.
    public func error(_ body: String, attributes: [String: AttributeValue] = [:]) {
        log(body, severity: .error, attributes: attributes)
    }

    /// Emit a FATAL-level log.
    public func fatal(_ body: String, attributes: [String: AttributeValue] = [:]) {
        log(body, severity: .fatal, attributes: attributes)
    }
}
