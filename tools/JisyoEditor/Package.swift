// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "JisyoEditor",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Core library: parser/serializer, model, edit operations,
        // file store, and the AquaSKK distributed-notification client.
        .target(
            name: "JisyoKit"
        ),
        // SwiftUI executable app.
        .executableTarget(
            name: "JisyoEditor",
            dependencies: ["JisyoKit"]
        ),
        // Unit tests for JisyoKit.
        .testTarget(
            name: "JisyoKitTests",
            dependencies: ["JisyoKit"]
        ),
    ]
)
