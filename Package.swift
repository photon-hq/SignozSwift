// swift-tools-version: 6.2

import PackageDescription

let signozDependencies: [Target.Dependency] = {
    var deps: [Target.Dependency] = [
        .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
        .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
        .product(name: "OpenTelemetryProtocolExporterHTTP", package: "opentelemetry-swift"),
        .product(name: "SwiftMetricsShim", package: "opentelemetry-swift"),
        .product(name: "PersistenceExporter", package: "opentelemetry-swift"),
        .product(name: "GRPCCore", package: "grpc-swift-2"),
        .product(name: "GRPCOTelTracingInterceptors", package: "grpc-swift-extras"),
        .product(name: "Tracing", package: "swift-distributed-tracing"),
        .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        .product(name: "Rainbow", package: "Rainbow"),
    ]

    #if canImport(Darwin)
    deps.append(contentsOf: [
        .product(name: "URLSessionInstrumentation", package: "opentelemetry-swift"),
        .product(name: "ResourceExtension", package: "opentelemetry-swift"),
        .product(name: "SignPostIntegration", package: "opentelemetry-swift"),
    ])
    #endif

    return deps
}()

let package = Package(
    name: "SignozSwift",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(
            name: "SignozSwift",
            targets: ["SignozSwift"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/open-telemetry/opentelemetry-swift-core",
            exact: "2.3.0"
        ),
        .package(
            url: "https://github.com/photon-hq/opentelemetry-swift",
            exact: "3.0.0"
        ),
        .package(
            url: "https://github.com/grpc/grpc-swift-2.git",
            exact: "2.2.1"
        ),
        .package(
            url: "https://github.com/grpc/grpc-swift-nio-transport.git",
            exact: "2.4.3"
        ),
        .package(
            url: "https://github.com/grpc/grpc-swift-extras.git",
            exact: "2.1.1"
        ),
        .package(
            url: "https://github.com/apple/swift-distributed-tracing.git",
            from: "1.3.0"
        ),
        .package(
            url: "https://github.com/apple/swift-protobuf.git",
            from: "1.28.1"
        ),
        .package(
            url: "https://github.com/onevcat/Rainbow.git",
            from: "4.0.0"
        ),
    ],
    targets: [
        .target(
            name: "SignozSwift",
            dependencies: signozDependencies,
            swiftSettings: [
                .enableExperimentalFeature(
                    "AvailabilityMacro=gRPCSwiftExtras 2.0:macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0"
                ),
                .enableExperimentalFeature(
                    "AvailabilityMacro=gRPCSwiftExtras 2.1:macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0"
                ),
                .enableExperimentalFeature(
                    "AvailabilityMacro=gRPCSwiftNIOTransport 2.0:macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0"
                ),
                .enableExperimentalFeature(
                    "AvailabilityMacro=gRPCSwiftNIOTransport 2.1:macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0"
                ),
                .enableExperimentalFeature(
                    "AvailabilityMacro=gRPCSwiftNIOTransport 2.2:macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0"
                ),
                .enableExperimentalFeature(
                    "AvailabilityMacro=gRPCSwiftNIOTransport 2.3:macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0"
                ),
                .enableExperimentalFeature(
                    "AvailabilityMacro=gRPCSwiftNIOTransport 2.4:macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0"
                ),
            ]
        ),
        .testTarget(
            name: "SignozSwiftTests",
            dependencies: [
                "SignozSwift",
                .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
                .product(name: "InMemoryExporter", package: "opentelemetry-swift"),
            ]
        ),
    ]
)
