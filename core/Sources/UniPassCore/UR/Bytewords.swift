import Foundation

/// CRC-32/ISO-HDLC（zlib 用的那个）：反射多项式 0xEDB88320，初值和末尾异或都是 0xFFFFFFFF。
/// bytewords 校验和、多帧消息校验和、喷泉码随机数种子都用它（BCR-2020-012、BCR-2024-001）。
public enum CRC32 {
    static let table: [UInt32] = (0...255).map { i in
        (0..<8).reduce(UInt32(i)) { c, _ in c & 1 == 0 ? c >> 1 : 0xEDB8_8320 ^ (c >> 1) }
    }

    public static func checksum(_ data: some Sequence<UInt8>) -> UInt32 {
        ~data.reduce(~UInt32(0)) { crc, byte in (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)] }
    }

    static func bigEndianBytes(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }
}

/// Bytewords（BCR-2020-012）：每个字节一个 4 字母单词，数据后面跟 4 字节大端 CRC32。
/// UR 一律用 minimal 风格（每个单词只取首尾字母）。解码不区分大小写。
public enum Bytewords {
    public enum Style: Sendable {
        /// 完整单词，空格分隔。
        case standard
        /// 完整单词，连字符分隔。
        case uri
        /// 首尾字母，无分隔（UR 用这个）。
        case minimal
    }

    public enum DecodingError: Error, Hashable, Sendable {
        case invalidWord
        /// 解出的字节不足 5 个（至少 1 字节数据 + 4 字节校验和）。
        case tooShort
        case invalidChecksum
    }

    /// BCR-2020-012 的单词表，第 i 个字节对应第 i 个单词。
    static let words: [String] = {
        let all = "ableacidalsoapexaquaarchatomauntawayaxisbackbaldbarnbeltbetabiasbluebodybragbrewbulbbuzzcalmcashcatschefcityclawcodecolacookcostcruxcurlcuspcyandarkdatadaysdelidicedietdoordowndrawdropdrumdulldutyeacheasyechoedgeepicevenexamexiteyesfactfairfernfigsfilmfishfizzflapflewfluxfoxyfreefrogfuelfundgalagamegeargemsgiftgirlglowgoodgraygrimgurugushgyrohalfhanghardhawkheathelphighhillholyhopehornhutsicedideaidleinchinkyintoirisironitemjadejazzjoinjoltjowljudojugsjumpjunkjurykeepkenokeptkeyskickkilnkingkitekiwiknoblamblavalazyleaflegsliarlimplionlistlogoloudloveluaulucklungmainmanymathmazememomenumeowmildmintmissmonknailnavyneednewsnextnoonnotenumbobeyoboeomitonyxopenovalowlspaidpartpeckplaypluspoempoolposepuffpumapurrquadquizraceramprealredorichroadrockroofrubyruinrunsrustsafesagascarsetssilkskewslotsoapsolosongstubsurfswantacotasktaxitenttiedtimetinytoiltombtoystriptunatwinuglyundouniturgeuservastveryvetovialvibeviewvisavoidvowswallwandwarmwaspwavewaxywebswhatwhenwhizwolfworkyankyawnyellyogayurtzapszerozestzinczonezoom"
        let chars = Array(all)
        return (0..<256).map { String(chars[$0 * 4..<$0 * 4 + 4]) }
    }()

    static let minimalWords: [String] = words.map { String([$0.first!, $0.last!]) }

    static let wordIndex: [String: UInt8] = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($1, UInt8($0)) })
    static let minimalIndex: [String: UInt8] = Dictionary(uniqueKeysWithValues: minimalWords.enumerated().map { ($1, UInt8($0)) })

    public static func encode(_ data: Data, style: Style = .minimal) -> String {
        let bytes = Array(data) + CRC32.bigEndianBytes(CRC32.checksum(data))
        switch style {
        case .standard: return bytes.map { words[Int($0)] }.joined(separator: " ")
        case .uri: return bytes.map { words[Int($0)] }.joined(separator: "-")
        case .minimal: return bytes.map { minimalWords[Int($0)] }.joined()
        }
    }

    public static func decode(_ string: String, style: Style = .minimal) throws -> Data {
        let s = string.lowercased()
        var bytes: [UInt8] = []
        switch style {
        case .standard, .uri:
            for word in s.split(separator: style == .standard ? " " : "-", omittingEmptySubsequences: false) {
                guard let b = wordIndex[String(word)] else { throw DecodingError.invalidWord }
                bytes.append(b)
            }
        case .minimal:
            let chars = Array(s)
            guard chars.count % 2 == 0 else { throw DecodingError.invalidWord }
            bytes.reserveCapacity(chars.count / 2)
            for i in stride(from: 0, to: chars.count, by: 2) {
                guard let b = minimalIndex[String(chars[i..<i + 2])] else { throw DecodingError.invalidWord }
                bytes.append(b)
            }
        }
        guard bytes.count >= 5 else { throw DecodingError.tooShort }
        let body = bytes.dropLast(4)
        let expected = CRC32.bigEndianBytes(CRC32.checksum(body))
        guard Array(bytes.suffix(4)) == expected else { throw DecodingError.invalidChecksum }
        return Data(body)
    }
}
