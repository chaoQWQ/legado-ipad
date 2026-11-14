// swift-tools-version: 5.9
import PackageDescription

let xmlHeaders: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-iwithsysroot", "-Xcc", "/usr/include/libxml2"])]

let package = Package(
    name: "LegadoPadCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LocalBooks", targets: ["LocalBooks"]),
        .library(name: "BookSources", targets: ["BookSources"])
    ],
    targets: [
        .systemLibrary(name: "CLibXML2"),
        .target(name: "LocalBooks", dependencies: ["CLibXML2"], swiftSettings: xmlHeaders),
        .target(
            name: "BookSources",
            dependencies: ["CLibXML2"],
            swiftSettings: xmlHeaders
        ),
        .testTarget(name: "LocalBooksTests", dependencies: ["LocalBooks"]),
        .testTarget(name: "BookSourcesTests", dependencies: ["BookSources"])
    ]
)
