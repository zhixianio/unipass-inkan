import Testing
@testable import SignerKit

@Suite struct OfflineCheckTests {
    private func addrs(_ list: [(String, String)]) -> [InterfaceAddress] {
        list.map { InterfaceAddress(name: $0.0, address: $0.1)! }
    }

    @Test func airplaneModeIsOffline() {
        // 飞行模式下 iPhone 上常见的接口：回环、链路本地、AWDL、VPN 隧道。
        let list = addrs([
            ("lo0", "127.0.0.1"), ("lo0", "::1"), ("lo0", "fe80::1"),
            ("en0", "fe80::1c2b:3aff:fe4d:5e6f"),
            ("awdl0", "fe80::a1:b2ff:fec3:d4e5"), ("llw0", "fe80::a1:b2ff:fec3:d4e5"),
            ("utun0", "fe80::abcd"), ("utun3", "10.8.0.2"), ("utun4", "2001:db8::5"),
        ])
        #expect(OfflineCheck.evaluate(list) == .offline)
        #expect(OfflineCheck.evaluate([]) == .offline)
    }

    @Test func wifiIPv4IsOnline() {
        let list = addrs([("lo0", "127.0.0.1"), ("en0", "fe80::1"), ("en0", "192.168.1.23")])
        #expect(OfflineCheck.evaluate(list) == .online(addrs([("en0", "192.168.1.23")])))
    }

    @Test func cellularIsOnline() {
        #expect(!OfflineCheck.evaluate(addrs([("pdp_ip0", "10.12.34.56")])).isOffline)
        #expect(!OfflineCheck.evaluate(addrs([("pdp_ip1", "2408:8456:1234::1")])).isOffline)
    }

    @Test func globalAndUniqueLocalIPv6AreOnline() {
        #expect(!OfflineCheck.evaluate(addrs([("en0", "2001:db8::1")])).isOffline)
        #expect(!OfflineCheck.evaluate(addrs([("en0", "fd00::1")])).isOffline)
        #expect(!OfflineCheck.evaluate(addrs([("en2", "2001:db8::2")])).isOffline)
    }

    @Test func ipv4LinkLocalCountsAsOnline() {
        // 169.254/16 说明接入了某个链路（只是 DHCP 失败），按联网处理。
        #expect(!OfflineCheck.evaluate(addrs([("en0", "169.254.10.20")])).isOffline)
    }

    @Test func linkLocalBoundaries() {
        // fe80::/10 覆盖 fe80 … febf；fec0 已经不在里面。
        #expect(OfflineCheck.evaluate(addrs([("en0", "febf::1")])).isOffline)
        #expect(!OfflineCheck.evaluate(addrs([("en0", "fec0::1")])).isOffline)
    }

    @Test func unspecifiedAndLoopbackOnWatchedInterfaceIgnored() {
        #expect(OfflineCheck.evaluate(addrs([("en0", "0.0.0.0"), ("en0", "::"), ("en0", "127.0.0.2"), ("en0", "::1")])).isOffline)
    }

    @Test func interfaceNameMatching() {
        // 只看 en* / pdp_ip*。
        for name in ["lo0", "utun0", "awdl0", "llw0", "ipsec0", "anpi0", "gif0", "stf0"] {
            #expect(OfflineCheck.evaluate(addrs([(name, "8.8.8.8")])).isOffline, "\(name)")
        }
        for name in ["en0", "en1", "en10", "pdp_ip0", "pdp_ip4"] {
            #expect(!OfflineCheck.evaluate(addrs([(name, "8.8.8.8")])).isOffline, "\(name)")
        }
    }

    @Test func malformedAddressesIgnored() {
        #expect(OfflineCheck.evaluate([InterfaceAddress(name: "en0", family: .ipv4, bytes: [1, 2, 3])]).isOffline)
    }

    @Test func addressRoundTrip() {
        #expect(InterfaceAddress(name: "en0", address: "fe80::1")!.addressString == "fe80::1")
        #expect(InterfaceAddress(name: "en0", address: "10.0.0.1")!.addressString == "10.0.0.1")
        #expect(InterfaceAddress(name: "en0", address: "nope") == nil)
    }

    @Test func readsSystemInterfaces() throws {
        // 真读一次 getifaddrs：至少有 lo0。
        let list = try InterfaceAddress.current()
        #expect(list.contains { $0.name == "lo0" })
    }

    /// 界面按连接类型提示要断开什么。
    @Test func connectionKinds() {
        #expect(OfflineCheck.evaluate(addrs([("en0", "fe80::1"), ("awdl0", "fe80::2")])).connections.isEmpty)
        #expect(OfflineCheck.evaluate(addrs([("en0", "192.168.1.23")])).connections == [.wifi])
        #expect(OfflineCheck.evaluate(addrs([("pdp_ip0", "10.12.34.56")])).connections == [.cellular])
        // 实测：数据线连着 Mac 时 en2 有 169.254.x.x。
        #expect(OfflineCheck.evaluate(addrs([("en2", "169.254.10.20"), ("en2", "fe80::3")])).connections == [.cable])
        #expect(OfflineCheck.evaluate(addrs([("en0", "192.168.1.23"), ("en2", "169.254.10.20"), ("pdp_ip1", "2408:8456::1")])).connections
            == [.wifi, .cable, .cellular])
        #expect(OfflineCheck.kind(of: InterfaceAddress(name: "getifaddrs-failed", family: .ipv4, bytes: [0, 0, 0, 0])) == .unknown)
    }
}
