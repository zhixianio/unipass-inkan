import Foundation
import SafeTransactionService
import UniPassCore

/// 假 RPC：按方法名回固定结果，记下 eth_sendRawTransaction 收到的原始交易。用它的测试要 `.serialized`。
final class MockRPC: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var results: [String: Any] = [:]
    nonisolated(unsafe) static var sentRaw: [String] = []

    /// 一个正常的 Sepolia 节点：baseFee 1 gwei、小费 0.1 gwei、余额 1 ETH。
    static func honestSepolia(estimateGas: UInt64 = 200_000) {
        sentRaw = []
        results = [
            "eth_chainId": "0xaa36a7",
            "eth_getTransactionCount": "0x5",
            "eth_getBlockByNumber": ["baseFeePerGas": "0x3b9aca00"],
            "eth_maxPriorityFeePerGas": "0x5f5e100",
            "eth_estimateGas": "0x" + String(estimateGas, radix: 16),
            "eth_getBalance": "0xde0b6b3a7640000",
            "eth_sendRawTransaction": "0x" + String(repeating: "ab", count: 32),
        ]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let s = request.httpBodyStream {
            s.open()
            var d = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable {
                let n = s.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                d.append(buf, count: n)
            }
            s.close()
            body = d
        }
        let json = try! JSONSerialization.jsonObject(with: body!) as! [String: Any]
        let method = json["method"] as! String
        if method == "eth_sendRawTransaction" { Self.sentRaw.append((json["params"] as! [String])[0]) }
        let out = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "result": Self.results[method] ?? NSNull()])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: out)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func rpc() -> EthRPC {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [MockRPC.self]
        return EthRPC(url: URL(string: "https://sepolia.example.invalid")!, session: URLSession(configuration: c))
    }
}
