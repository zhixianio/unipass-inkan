import CoreGraphics
import Foundation
import Testing
import UniPassCore
@testable import QRTransport

func bytesUR(_ count: Int, seed: UInt64 = 1) -> UR {
    try! UR(type: "bytes", value: .bytes(TestPayload.bytes(count: count, seed: seed)))
}

@Suite struct URTransferTests {
    @Test func multiFrameRoundTripWithLossAndDuplicates() throws {
        let ur = bytesUR(2_000)
        var frames = URFrames(ur)
        #expect(!frames.isSinglePart)
        var tracker = URTransferTracker(acceptedTypes: ["bytes"])
        var done: UR?
        var t = 0.0
        while done == nil, t < 100 {
            let f = frames.next()
            #expect(f == f.uppercased())
            t += 0.1
            // 每 3 帧丢一帧，偶尔重复一帧：喷泉码照样收齐。
            if Int(t * 10) % 3 == 0 { continue }
            done = tracker.receive([f, f], at: t)
        }
        #expect(done == ur)
        #expect(tracker.transferSeconds != nil)
    }

    @Test func singlePartUR() {
        let ur = bytesUR(50)
        var frames = URFrames(ur)
        #expect(frames.isSinglePart)
        var tracker = URTransferTracker()
        #expect(tracker.receive([frames.next()], at: 1) == ur)
    }

    @Test func foreignAndWrongTypeAreCounted() {
        var tracker = URTransferTracker(acceptedTypes: ["unipass-signature"])
        var frames = URFrames(bytesUR(50))
        #expect(tracker.receive(["hello", frames.next()], at: 1) == nil)
        #expect(tracker.foreign == 2)
    }

    @Test func corruptFrameIsSkippedNotFatal() throws {
        let ur = bytesUR(1_000)
        var frames = URFrames(ur)
        var tracker = URTransferTracker()
        var good = frames.next()
        // 改坏一帧的最后一个字母（bytewords 校验和失败），丢弃后继续扫。
        let bad = String(good.dropLast()) + (good.last == "A" ? "E" : "A")
        #expect(tracker.receive([bad], at: 0) == nil)
        #expect(tracker.badFrames == 1)
        #expect(tracker.failure == nil)
        var done: UR? = tracker.receive([good], at: 0.1)
        var t = 0.1
        while done == nil, t < 100 {
            good = frames.next()
            t += 0.1
            done = tracker.receive([good], at: t)
        }
        #expect(done == ur)
    }

    @Test func urTypeExtraction() {
        #expect(URTransferTracker.urType(of: "UR:ETH-SIGN-REQUEST/1-3/LPAD") == "eth-sign-request")
        #expect(URTransferTracker.urType(of: "ur:bytes/hdcx") == "bytes")
        #expect(URTransferTracker.urType(of: "UPS/1-2/00/AB") == nil)
    }
}

@Suite struct QRRoundTripTests {
    @Test(arguments: [50, 200, 400])
    func renderThenDecodeURFrame(fragment: Int) throws {
        var frames = URFrames(bytesUR(fragment * 3), maxFragmentLen: fragment)
        let frame = frames.next()
        let symbol = try #require(QRRenderer.symbol(for: frame))
        // 1 像素一个模块太小，放大后再识别。
        let scaled = try #require(Self.upscale(symbol.image, by: 6))
        #expect(QRDecoder.decode(cgImage: scaled) == [frame])
    }

    @Test func uppercaseUsesAlphanumericMode() throws {
        // 字母数字模式 11 bit / 2 字符，字节模式 16 bit / 2 字符：同样长度，大写的版本明显更小。
        var frames = URFrames(bytesUR(600))
        let upper = frames.next()
        let vUpper = try #require(QRRenderer.symbol(for: upper)).version
        let vLower = try #require(QRRenderer.symbol(for: upper.lowercased())).version
        #expect(vUpper < vLower)
    }

    static func upscale(_ image: CGImage, by factor: Int) -> CGImage? {
        let side = image.width * factor
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        ctx?.interpolationQuality = .none
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return ctx?.makeImage()
    }
}
