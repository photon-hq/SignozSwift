// swift-tools-version: 6.2

import PackageDescription

let signozDependencies: [Target.Dependency] = {
    var deps: [Target.Dependency] = [
        .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
        .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
        .product(name: "OpenTelemetryProtocolExporter", package: "opentelemetry-swift"),
        .product(name: "SwiftMetricsShim", package: "opentelemetry-swift"),
        .product(name: "PersistenceExporter", package: "opentelemetry-swift"),
        .product(name: "GRPC", package: "grpc-swift"),
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
    platforms: [.macOS(.v13), .iOS(.v16)],
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
            url: "https://github.com/open-telemetry/opentelemetry-swift",
            exact: "2.3.0"
        ),
        .package(
            url: "https://github.com/grpc/grpc-swift.git",
            exact: "1.27.0"
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
                .product(name: "InMemoryExporter", package: "opentelemetry-swift"),
            ]
        ),
    ]
)
