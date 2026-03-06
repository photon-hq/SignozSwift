import GRPCCore
import SwiftProtobuf

/// Serializes a SwiftProtobuf message for gRPC transport.
struct ProtobufSerializer<Message: SwiftProtobuf.Message>: MessageSerializer {
    func serialize<Bytes: GRPCContiguousBytes>(_ message: Message) throws -> Bytes {
        do {
            let data = try message.serializedBytes() as [UInt8]
            return Bytes(data)
        } catch {
            throw RPCError(
                code: .invalidArgument,
                message: "Failed to serialize \(type(of: message)).",
                cause: error
            )
        }
    }
}

/// Deserializes a SwiftProtobuf message from gRPC transport.
struct ProtobufDeserializer<Message: SwiftProtobuf.Message>: MessageDeserializer {
    func deserialize<Bytes: GRPCContiguousBytes>(_ serializedMessageBytes: Bytes) throws -> Message {
        do {
            return try serializedMessageBytes.withUnsafeBytes { buffer in
                try Message(serializedBytes: Array(buffer))
            }
        } catch {
            throw RPCError(
                code: .invalidArgument,
                message: "Failed to deserialize \(Message.self).",
                cause: error
            )
        }
    }
}
