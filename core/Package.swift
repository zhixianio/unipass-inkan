// swift-tools-version: 6.2
import PackageDescription

// UniPassCore 被离线 Signer 链接，所以这里只允许纯计算代码：
// 不依赖任何网络框架（URLSession、Network、CFNetwork）。
let package = Package(
    name: "UniPassCore",
    // 白话解释中英双语；String Catalog 和标签库在 Sources/UniPassCore/Resources。
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "UniPassCore", targets: ["UniPassCore"]),
    ],
    targets: [
        .target(name: "UniPassCore", resources: [.process("Resources")]),
        // 测试向量在仓库根目录的 testvectors/，测试里按 #filePath 定位。
        .testTarget(name: "UniPassCoreTests", dependencies: ["UniPassCore"]),
    ]
)
