// swift-tools-version: 6.2
import PackageDescription

// 提交账户：桌面端保管的一个普通 EOA，**不是 Safe 的 owner**，只放少量 gas，
// 负责把签齐的交易发上链。整个功能都在这个包里；删掉这个包和 App 里的 SubmitterAccount*.swift 即可去掉。
//
// secp256k1 用 swift-secp256k1（21-DOT-DEV，MIT），固定 0.23.2，只链接其中的 C 库 `libsecp256k1`
// （Bitcoin Core 的 libsecp256k1，MIT）。不用它的 Swift 封装 P256K：那个 target 带一个构建插件，
// 要在 Xcode 里额外信任；C 库没有插件。只有这个包依赖它，core 和签名器永远不依赖；
// 只有 Secp256k1Key.swift 一个文件 import 它。
let package = Package(
    name: "SubmitterAccount",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SubmitterAccount", targets: ["SubmitterAccount"]),
    ],
    dependencies: [
        .package(path: "../../../../core"),
        .package(path: "../CoordinatorNetwork"),
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.23.2"),
    ],
    targets: [
        .target(name: "SubmitterAccount", dependencies: [
            .product(name: "UniPassCore", package: "core"),
            .product(name: "SafeTransactionService", package: "CoordinatorNetwork"),
            .product(name: "libsecp256k1", package: "swift-secp256k1"),
        ]),
        .testTarget(name: "SubmitterAccountTests", dependencies: [
            "SubmitterAccount",
            .product(name: "UniPassCore", package: "core"),
        ]),
    ]
)
