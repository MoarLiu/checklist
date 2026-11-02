// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CheckList",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CheckList", targets: ["CheckList"])],
    targets: [
        .executableTarget(name: "CheckList"),
        .testTarget(name: "CheckListTests", dependencies: ["CheckList"]),
    ]
)
