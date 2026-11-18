// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftCat",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "SwiftCat", targets: ["SwiftCat"])
    ],
    targets: [
        .executableTarget(
            name: "SwiftCat",
            linkerSettings: [
                .unsafeFlags(["-framework", "FoundationModels"])
            ]
        ),
        .testTarget(
            name: "SwiftCatTests",
            dependencies: ["SwiftCat"]
        )
    ]
)
