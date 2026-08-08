// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "auto-click-cdp-popup",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "auto-click-cdp-popup",
            targets: ["auto-click-cdp-popup"]
        )
    ],
    targets: [
        .executableTarget(
            name: "auto-click-cdp-popup"
        ),
        .testTarget(
            name: "auto-click-cdp-popupTests",
            dependencies: ["auto-click-cdp-popup"]
        )
    ]
)
