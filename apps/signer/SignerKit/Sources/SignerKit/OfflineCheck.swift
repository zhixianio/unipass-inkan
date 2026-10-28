import Darwin
import Foundation

/// 一个网络接口上的一个地址（`getifaddrs` 的一项）。只保留判断要用的字段，方便在测试里伪造。
public struct InterfaceAddress: Hashable, Sendable, CustomStringConvertible {
    public enum Family: Hashable, Sendable {
        case ipv4
        case ipv6
    }

    public var name: String
    public var family: Family
    /// 网络字节序：IPv4 4 字节，IPv6 16 字节。
    public var bytes: [UInt8]

    public init(name: String, family: Family, bytes: [UInt8]) {
        self.name = name
        self.family = family
        self.bytes = bytes
    }

    /// 用 `inet_pton` 解析文本地址，测试里用。
    public init?(name: String, address: String) {
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            self.init(name: name, family: .ipv4, bytes: withUnsafeBytes(of: v4) { Array($0) })
        } else if inet_pton(AF_INET6, address, &v6) == 1 {
            self.init(name: name, family: .ipv6, bytes: withUnsafeBytes(of: v6) { Array($0) })
        } else {
            return nil
        }
    }

    public var addressString: String {
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let af = family == .ipv4 ? AF_INET : AF_INET6
        let ok = bytes.withUnsafeBytes { inet_ntop(af, $0.baseAddress, &buf, socklen_t(buf.count)) } != nil
        return ok ? String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : "?"
    }

    public var description: String { "\(name) \(addressString)" }
}

public enum NetworkStatus: Hashable, Sendable {
    case offline
    /// 联网，附带触发判断的地址。
    case online([InterfaceAddress])

    public var isOffline: Bool { self == .offline }

    /// 触发"联网"的是哪几种连接，界面按这个告诉用户要断开什么。
    public var connections: Set<ConnectionKind> {
        guard case .online(let hits) = self else { return [] }
        return Set(hits.map(OfflineCheck.kind))
    }
}

/// 用户能理解、能自己断开的连接类型。
public enum ConnectionKind: String, CaseIterable, Hashable, Sendable {
    /// `en0`：iPhone 上就是 Wi-Fi。
    case wifi
    /// `pdp_ip*`：蜂窝数据。
    case cellular
    /// 其它 `en*`：数据线连着电脑（实测 `en2`），或有线网卡转接头。
    case cable
    /// 读不出接口（`getifaddrs` 失败）。
    case unknown
}

/// 联网判断。纯函数，不碰系统；读系统接口见 `InterfaceAddress.current()`。
///
/// 规则：Wi-Fi / 有线（`en*`）或蜂窝（`pdp_ip*`）上只要有一个**非链路本地、非回环、非未指定**
/// 的地址就算联网。其它接口（`lo0`、`utun*` VPN、`awdl*` / `llw*` AirDrop 等）不看：
/// VPN 本身要靠 `en*` / `pdp_ip*` 出去，AWDL 在飞行模式下也可能挂着 `fe80::`。
///
/// 和"可路由"的字面意思不同，IPv4 的 `169.254/16` **算联网**：系统只有在真的连上某个
/// 网络、但没拿到 DHCP 地址时才会分配它，说明射频开着且接入了链路。IPv6 的 `fe80::/10`
/// 不算，因为接口在没有任何连接时也会挂着它。
public enum OfflineCheck {
    /// 要看的接口名前缀。
    public static let watchedPrefixes = ["en", "pdp_ip"]

    public static func evaluate(_ addresses: [InterfaceAddress]) -> NetworkStatus {
        let hits = addresses.filter(countsAsOnline)
        return hits.isEmpty ? .offline : .online(hits)
    }

    public static func countsAsOnline(_ a: InterfaceAddress) -> Bool {
        guard watchedPrefixes.contains(where: { a.name.hasPrefix($0) }) else { return false }
        switch a.family {
        case .ipv4:
            guard a.bytes.count == 4 else { return false }
            if a.bytes == [0, 0, 0, 0] { return false } // 未指定
            if a.bytes[0] == 127 { return false } // 回环
            return true
        case .ipv6:
            guard a.bytes.count == 16 else { return false }
            if a.bytes.allSatisfy({ $0 == 0 }) { return false } // ::
            if a.bytes == [UInt8](repeating: 0, count: 15) + [1] { return false } // ::1
            if a.bytes[0] == 0xFE, a.bytes[1] & 0xC0 == 0x80 { return false } // fe80::/10
            return true
        }
    }
}

extension OfflineCheck {
    /// 一个触发联网的地址属于哪种连接。iPhone 上 `en0` 是 Wi-Fi（实测），其它 `en*` 是数据线或转接头。
    /// 蓝牙不在这里：开关蓝牙不改变任何接口地址（实测），App 查不到，界面上单独提醒。
    public static func kind(of a: InterfaceAddress) -> ConnectionKind {
        if a.name == "en0" { return .wifi }
        if a.name.hasPrefix("pdp_ip") { return .cellular }
        if a.name.hasPrefix("en") { return .cable }
        return .unknown
    }
}

extension InterfaceAddress {
    /// 用 libc 的 `getifaddrs` 读当前所有接口的 IPv4 / IPv6 地址。
    /// 读失败时抛错，调用方应当按"联网"处理（拒签）。
    public static func current() throws -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { freeifaddrs(head) }

        var out: [InterfaceAddress] = []
        var cur = head
        while let p = cur {
            defer { cur = p.pointee.ifa_next }
            guard let sa = p.pointee.ifa_addr else { continue }
            let name = String(cString: p.pointee.ifa_name)
            switch Int32(sa.pointee.sa_family) {
            case AF_INET:
                let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                out.append(InterfaceAddress(name: name, family: .ipv4, bytes: withUnsafeBytes(of: addr) { Array($0) }))
            case AF_INET6:
                let addr = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                out.append(InterfaceAddress(name: name, family: .ipv6, bytes: withUnsafeBytes(of: addr) { Array($0) }))
            default:
                continue
            }
        }
        return out
    }
}

extension OfflineCheck {
    /// 读系统接口并判断；读失败按联网处理。
    public static func currentStatus() -> NetworkStatus {
        guard let addresses = try? InterfaceAddress.current() else {
            return .online([InterfaceAddress(name: "getifaddrs-failed", family: .ipv4, bytes: [0, 0, 0, 0])])
        }
        return evaluate(addresses)
    }
}
