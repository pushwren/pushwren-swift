// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pushwren",
    platforms: [.iOS(.v16), .macCatalyst(.v16), .macOS(.v13)],
    products: [
        .library(name: "Pushwren", targets: ["Pushwren"]),
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
    ]
)
