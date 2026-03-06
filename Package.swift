// swift-tools-version: 6.2

import PackageDescription

let signozDependencies: [Target.Dependency] = {
    var deps: [Target.Dependency] = [
        .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
        .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
        .product(name: "OpenTelemetryProtocolExporterHTTP", package: "opentelemetry-swift"),
        .product(name: "SwiftMetricsShim", package: "opentelemetry-swift"),
        .product(name: "PersistenceExporter", package: "opentelemetry-swift"),
        .product(name: "GRPCCore", package: "grpc-swift"),
        .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
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
            branch: "no-grpc-v1"
        ),
        .package(
            url: "https://github.com/grpc/grpc-swift.git",
            exact: "2.2.2"
        ),
        .package(
            url: "https://github.com/grpc/grpc-swift-nio-transport.git",
            exact: "1.1.0"
        ),
        .package(
            url: "https://github.com/apple/swift-protobuf.git",
            from: "1.28.1"
        ),
    ],
    targets: [
        .target(
            name: "SignozSwift",
            dependencies: signozDependencies
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
