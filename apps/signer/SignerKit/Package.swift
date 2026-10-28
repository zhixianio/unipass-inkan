// swift-tools-version: 6.2
import PackageDescription

// Signer 专用的代码。和 UniPassCore 一样只允许纯计算 / 本机 API：
// 不依赖 URLSession、Network、CFNetwork。哪些该搬进 core 见 apps/signer/README.md。
let package = Package(
    name: "SignerKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "SignerKit", targets: ["SignerKit"]),
    ],
    dependencies: [
        .package(path: "../../../core"),
    ],
    targets: [
        .target(name: "SignerKit", dependencies: [.product(name: "UniPassCore", package: "core")]),
        .testTarget(name: "SignerKitTests", dependencies: ["SignerKit"]),
    ]
)
