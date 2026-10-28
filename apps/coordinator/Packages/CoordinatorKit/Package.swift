// swift-tools-version: 6.2
import PackageDescription

// Coordinator 的本地代码（不联网）：二维码收发、和 Signer 之间的签名流程。Coordinator 不持有任何签名密钥。
// 网络代码（STS、RPC）在 ../CoordinatorNetwork，不放这里，也永远不进 core。
let package = Package(
    name: "CoordinatorKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "QRTransport", targets: ["QRTransport"]),
        .library(name: "CoordinatorFlow", targets: ["CoordinatorFlow"]),
        .executable(name: "qr-bench", targets: ["qr-bench"]),
    ],
    dependencies: [
        .package(path: "../../../../core"),
    ],
    targets: [
        // 摄像头 + Vision 扫码、CoreImage 出码、UR 多帧收发（UR / 喷泉码本身在 core）。
        .target(name: "QRTransport", dependencies: [.product(name: "UniPassCore", package: "core")]),
        // 配对、Safe 登记、签名请求、收回签名的校验：纯逻辑，Mac 上可以完整单测。
        .target(name: "CoordinatorFlow", dependencies: [.product(name: "UniPassCore", package: "core")]),
        // 离线基准：模拟摄像头拍手机屏幕的画质，测 Vision 识别率和耗时；生成给手机播放的测试 GIF。
        .executableTarget(name: "qr-bench", dependencies: [
            "QRTransport",
            .product(name: "UniPassCore", package: "core"),
        ]),
        .testTarget(name: "QRTransportTests", dependencies: [
            "QRTransport",
            .product(name: "UniPassCore", package: "core"),
        ]),
        .testTarget(name: "CoordinatorFlowTests", dependencies: [
            "CoordinatorFlow",
            .product(name: "UniPassCore", package: "core"),
        ]),
    ]
)
