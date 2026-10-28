// swift-tools-version: 6.2
import PackageDescription

// Coordinator 的全部网络代码（Safe Transaction Service，之后加 RPC、模拟服务）。
// 只给 Coordinator 用：Signer 不链接它，core 也永远不依赖它。
let package = Package(
    name: "CoordinatorNetwork",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SafeTransactionService", targets: ["SafeTransactionService"]),
        .executable(name: "sts-probe", targets: ["sts-probe"]),
        .executable(name: "sts-write", targets: ["sts-write"]),
    ],
    dependencies: [
        .package(path: "../../../../core"),
    ],
    targets: [
        .target(name: "SafeTransactionService", dependencies: [.product(name: "UniPassCore", package: "core")]),
        // 命令行只读探测：对公开 Safe 调 STS，并用 core 重算 safeTxHash 对拍。
        .executableTarget(name: "sts-probe", dependencies: [
            "SafeTransactionService",
            .product(name: "UniPassCore", package: "core"),
        ]),
        // 测试网写操作：发起提案、追加确认（EOA / 合约签名）。
        .executableTarget(name: "sts-write", dependencies: [
            "SafeTransactionService",
            .product(name: "UniPassCore", package: "core"),
        ]),
        .testTarget(name: "SafeTransactionServiceTests", dependencies: [
            "SafeTransactionService",
            .product(name: "UniPassCore", package: "core"),
        ]),
    ]
)
