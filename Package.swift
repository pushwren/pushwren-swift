// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pushwren",
    platforms: [.iOS(.v16), .macCatalyst(.v16), .macOS(.v13)],
    products: [
        .library(name: "Pushwren", targets: ["Pushwren"]),
        .library(name: "PushwrenNotificationService", targets: ["PushwrenNotificationService"]),
    ],
    targets: [
        .target(
            name: "Pushwren",
            resources: [.copy("Resources/PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "PushwrenTests",
            dependencies: ["Pushwren"],
            resources: [.copy("Fixtures")]
        ),
        // For a Notification Service Extension target. It doesn't depend on Pushwren, which uses
        // app-only APIs, and uses only APIs that are safe in app extensions.
        .target(name: "PushwrenNotificationService"),
        .testTarget(
            name: "PushwrenNotificationServiceTests",
            dependencies: ["PushwrenNotificationService"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
