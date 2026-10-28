import Foundation
import Testing
import UniPassCore
@testable import CoordinatorFlow

@Suite struct AmountInputTests {
    @Test(arguments: [
        ("25", 6, "25000000"),
        ("25.5", 6, "25500000"),
        ("0.000001", 6, "1"),
        (".5", 18, "500000000000000000"),
        ("1.", 18, "1000000000000000000"),
        ("0.001", 18, "1000000000000000"),
        ("1,000.25", 6, "1000250000"),
        ("  7 ", 0, "7"),
        ("0.10000", 2, "10"), // 末尾的 0 不算超精度
        ("115792089237316195423570985008687907853269984665640564039457584007913129639935", 0,
         "115792089237316195423570985008687907853269984665640564039457584007913129639935"),
    ])
    func parses(_ text: String, _ decimals: Int, _ expected: String) {
        #expect(AmountInput.parse(text, decimals: decimals) == .success(UInt256(decimal: expected)!))
    }

    @Test func rejectsBadInput() {
        #expect(AmountInput.parse("", decimals: 6) == .failure(.empty))
        #expect(AmountInput.parse("   ", decimals: 6) == .failure(.empty))
        #expect(AmountInput.parse("abc", decimals: 6) == .failure(.invalidFormat))
        #expect(AmountInput.parse("1.2.3", decimals: 6) == .failure(.invalidFormat))
        #expect(AmountInput.parse("-1", decimals: 6) == .failure(.invalidFormat))
        #expect(AmountInput.parse("1e5", decimals: 6) == .failure(.invalidFormat))
        #expect(AmountInput.parse(".", decimals: 6) == .failure(.invalidFormat))
        #expect(AmountInput.parse("١٢", decimals: 6) == .failure(.invalidFormat)) // 非 ASCII 数字
        #expect(AmountInput.parse("0", decimals: 6) == .failure(.zero))
        #expect(AmountInput.parse("0.000", decimals: 6) == .failure(.zero))
        #expect(AmountInput.parse("0.0000001", decimals: 6) == .failure(.tooManyDecimals(max: 6)))
        #expect(AmountInput.parse("1.5", decimals: 0) == .failure(.tooManyDecimals(max: 0)))
        #expect(AmountInput.parse("115792089237316195423570985008687907853269984665640564039457584007913129639936", decimals: 0) == .failure(.tooLarge))
        #expect(AmountInput.parse("1", decimals: 78) == .failure(.tooLarge))
    }

    @Test func checksBalance() {
        var usdc = Asset(kind: .erc20(Address(hex: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238")!), symbol: "USDC", name: "USDC", decimals: 6,
                         balance: UInt256(25_000_000))
        #expect(AmountInput.validate("25", asset: usdc) == .success(UInt256(25_000_000)))
        #expect(AmountInput.validate("25.000001", asset: usdc) == .failure(.insufficientBalance))
        usdc.balance = nil // 余额未知时不检查
        #expect(AmountInput.validate("1000", asset: usdc) == .success(UInt256(1_000_000_000)))
    }

    @Test func displayRoundsDownToSixDecimals() {
        let eth = Asset.native(chainID: 11_155_111)
        #expect(eth.display(UInt256(5_000_000_000_000_315), fractionDigits: 6) == "0.005 ETH")
        #expect(eth.display(UInt256(1_234_567_890_000_000_000), fractionDigits: 6) == "1.234567 ETH")
        #expect(eth.display(UInt256(2_000_000_000_000_000_000), fractionDigits: 6) == "2 ETH")
        #expect(eth.display(UInt256(1_000_000_000), fractionDigits: 6) == "< 0.000001 ETH")
        #expect(eth.display(UInt256.zero, fractionDigits: 6) == "0 ETH")
    }

    @Test func plainAndDisplay() {
        let eth = Asset.native(chainID: 11_155_111)
        #expect(AmountInput.plain(UInt256(10_000_000_000_000_000), decimals: 18) == "0.01")
        #expect(AmountInput.plain(UInt256(1_234_500_000), decimals: 6) == "1234.5")
        #expect(eth.display(UInt256(10_000_000_000_000_000)) == "0.01 ETH")
        #expect(eth.display(UInt256(decimal: "1234500000000000000000")!) == "1,234.5 ETH")
        // 显示出来的写法能原样解析回来（"全部"按钮）。
        let raw = UInt256(decimal: "123456789012345678")!
        #expect(AmountInput.parse(AmountInput.plain(raw, decimals: 18), decimals: 18) == .success(raw))
    }
}

@Suite struct RecipientInputTests {
    let safe = KnownSafes.sepoliaTestSafe.safe

    @Test func acceptsChecksummedAndSingleCase() {
        let a = "0x938313A557B6129d2D8CbDa84aD962B1869AB39a"
        #expect(RecipientInput.parse(a) == .success(Address(hex: a)!))
        #expect(RecipientInput.parse(a.lowercased()) == .success(Address(hex: a)!))
        #expect(RecipientInput.parse("0x" + a.dropFirst(2).uppercased()) == .success(Address(hex: a)!))
        #expect(RecipientInput.parse("  \(a)\n") == .success(Address(hex: a)!))
        #expect(RecipientInput.parse(String(a.dropFirst(2))) == .success(Address(hex: a)!)) // 不带 0x
    }

    @Test func rejectsBadAddresses() {
        #expect(RecipientInput.parse("") == .failure(.empty))
        #expect(RecipientInput.parse("0x1234") == .failure(.notAnAddress))
        #expect(RecipientInput.parse("vitalik.eth") == .failure(.notAnAddress))
        #expect(RecipientInput.parse("0x938313A557B6129d2D8CbDa84aD962B1869AB3zz") == .failure(.notAnAddress))
        // 改了一位的大小写：校验和不对。
        #expect(RecipientInput.parse("0x938313a557B6129d2D8CbDa84aD962B1869AB39a") == .failure(.badChecksum))
        #expect(RecipientInput.parse("0x0000000000000000000000000000000000000000") == .failure(.zeroAddress))
        #expect(RecipientInput.parse(safe.checksummed, safe: safe) == .failure(.isTheSafe))
    }
}

@Suite struct TransferTests {
    let safe = KnownSafes.sepoliaTestSafe.safe
    let alice = Address(hex: "0x938313A557B6129d2D8CbDa84aD962B1869AB39a")!
    let usdc = Asset.known(chainID: 11_155_111).first { $0.symbol == "USDC" }!

    @Test func knownAssetsForSepolia() {
        let assets = Asset.known(chainID: 11_155_111)
        #expect(assets.first?.kind == .native)
        #expect(Set(assets.map(\.symbol)) == ["ETH", "EURC", "LINK", "USDC"])
        #expect(usdc.decimals == 6 && usdc.name == "USDC (Circle testnet)")
    }

    @Test func nativeTransfer() {
        let tx = Transfer.safeTx(asset: .native(chainID: 11_155_111), to: alice, amount: UInt256(10_000_000_000_000_000), nonce: UInt256(3))
        #expect(tx.to == alice && tx.value == UInt256(10_000_000_000_000_000) && tx.data.isEmpty && tx.operation == .call)
        #expect(tx.gasPrice.isZero && tx.refundReceiver == .zero && tx.safeTxGas.isZero)
    }

    @Test func erc20Transfer() {
        let tx = Transfer.safeTx(asset: usdc, to: alice, amount: UInt256(25_000_000), nonce: UInt256(3))
        #expect(tx.to == usdc.tokenAddress && tx.value.isZero)
        #expect(tx.data.hexString == "0xa9059cbb000000000000000000000000938313a557b6129d2d8cbda84ad962b1869ab39a"
            + "00000000000000000000000000000000000000000000000000000000017d7840")
    }

    @Test func summaries() {
        var book = AddressBook()
        book.save(name: "  Alice  ", address: alice)
        let native = SafeTxRequest(chainID: 11_155_111, safe: safe,
                                   tx: Transfer.safeTx(asset: .native(chainID: 11_155_111), to: alice, amount: UInt256(10_000_000_000_000_000), nonce: .zero))
        #expect(TransactionSummary.describe(native, addressBook: book).kind == .send(amount: "0.01 ETH", to: alice, toName: "Alice"))
        let token = SafeTxRequest(chainID: 11_155_111, safe: safe, tx: Transfer.safeTx(asset: usdc, to: alice, amount: UInt256(25_000_000), nonce: .zero))
        #expect(TransactionSummary.describe(token, addressBook: book).kind == .send(amount: "25 USDC", to: alice, toName: "Alice"))
        let unknownRecipient = SafeTxRequest(chainID: 11_155_111, safe: safe,
                                             tx: Transfer.safeTx(asset: usdc, to: alice, amount: UInt256(1), nonce: .zero))
        #expect(TransactionSummary.describe(unknownRecipient, addressBook: AddressBook()).kind == .send(amount: "0.000001 USDC", to: alice, toName: nil))
        let empty = SafeTxRequest(chainID: 11_155_111, safe: safe, tx: SafeTx(to: safe, nonce: .zero))
        #expect(TransactionSummary.describe(empty, addressBook: book).kind == .empty)
    }

    @Test func addressBookEdits() {
        var book = AddressBook()
        book.save(name: "Bob", address: alice)
        book.save(name: "Alice", address: alice) // 同一地址改名
        #expect(book.entries.count == 1 && book.name(for: alice) == "Alice")
        book.save(name: "   ", address: safe) // 空名字不存
        #expect(book.entries.count == 1)
        book.remove(alice)
        #expect(book.entries.isEmpty)
    }
}

@Suite struct FeeEstimateTests {
    @Test func fee() {
        // 110,000 gas × (14 + 3) wei
        #expect(FeeEstimate.fee(gas: 110_000, baseFee: UInt256(14), tip: UInt256(3)) == UInt256(1_870_000))
        // 140,000 gas × 2,000 gwei：超过 64 位也算得对
        let big = FeeEstimate.fee(gas: 140_000, baseFee: UInt256(2_000_000_000_000), tip: .zero)
        #expect(big == UInt256(decimal: "280000000000000000"))
        #expect(FeeEstimate.fee(gas: UInt64.max, baseFee: UInt256(UInt64.max), tip: .zero) == UInt256(words: [1, UInt64.max - 1, 0, 0]))
        #expect(FeeEstimate.fee(gas: 1, baseFee: .max, tip: .zero) == nil)
        #expect(FeeEstimate.executionGas(SafeTx(to: .zero, nonce: .zero)) < FeeEstimate.executionGas(SafeTx(to: .zero, data: Data([1]), nonce: .zero)))
    }

    @Test func roundedForDisplay() {
        let eth = Asset.native(chainID: 11_155_111)
        #expect(FeeEstimate.rounded(UInt256(1_870_000), asset: eth) == nil) // 不到 0.000001 ETH
        #expect(FeeEstimate.rounded(.zero, asset: eth) == .zero)
        #expect(FeeEstimate.rounded(UInt256(1_000_000_000_000), asset: eth) == UInt256(1_000_000_000_000))
        // 0.0001857 ETH → 0.000186 ETH（向上取整）
        #expect(FeeEstimate.rounded(UInt256(185_700_000_000_000), asset: eth) == UInt256(186_000_000_000_000))
        #expect(eth.display(FeeEstimate.rounded(UInt256(185_700_000_000_000), asset: eth)!) == "0.000186 ETH")
        #expect(FeeEstimate.smallest(eth) == "0.000001 ETH")
    }

    @Test func shortAddress() {
        #expect(AddressDisplay.short(Address(hex: "0x938313A557B6129d2D8CbDa84aD962B1869AB39a")!) == "0x938313A5…869AB39a")
    }
}
