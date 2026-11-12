// swift-tools-version: 5.9
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let package = Package(
    name: "HangelDisasterWalkieTalkie",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "HangelDisasterWalkieTalkie", targets: ["DisasterWalkieTalkiePlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0")
    ],
    targets: [
        .target(
            name: "DisasterWalkieTalkiePlugin",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm")
            ],
            path: "ios/Sources/DisasterWalkieTalkiePlugin"
        )
    ]
)
