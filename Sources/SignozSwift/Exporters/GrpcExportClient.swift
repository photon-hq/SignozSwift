import GRPCCore
import SwiftProtobuf

/// Protocol that type-erases `GRPCClient<Transport>` so exporters don't need to know the transport type.
protocol GrpcExportClient: Sendable {
    func callUnary<Input: SwiftProtobuf.Message, Output: SwiftProtobuf.Message>(
        _ input: Input,
        descriptor: MethodDescriptor,
        metadata: Metadata,
        options: CallOptions
    ) async throws -> Output
}

extension GRPCClient: GrpcExportClient {
    func callUnary<Input: SwiftProtobuf.Message, Output: SwiftProtobuf.Message>(
        _ input: Input,
        descriptor: MethodDescriptor,
        metadata: Metadata,
        options: CallOptions
    ) async throws -> Output {
        try await self.unary(
            request: ClientRequest(message: input, metadata: metadata),
            descriptor: descriptor,
            serializer: ProtobufSerializer<Input>(),
            deserializer: ProtobufDeserializer<Output>(),
            options: options
        ) { response in
            try response.message
        }
    }
}
