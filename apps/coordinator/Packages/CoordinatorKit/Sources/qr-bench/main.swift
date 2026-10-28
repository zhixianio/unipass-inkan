import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import QRTransport
import UniPassCore
import UniformTypeIdentifiers

// 帧格式和 App 一致：`ur:bytes` 多帧喷泉码（core 的 UREncoder），大写。
// qr-bench capacity                       单帧容量：每帧字节数 → 字符数、QR 版本、模块数
// qr-bench decode [--frame 1280x720] [--profile typical|harsh]
//                                         模拟拍摄：每帧字节数 × 二维码像素宽度 → 识别率、Vision 耗时
// qr-bench transfer --bytes N --chunk C --fps F --qr-px P [--camera-fps 30] [--trials 5]
//                                         模拟整段传输：屏幕循环播放、摄像头按帧率采样 → 拼完所需时间
// qr-bench sample --chunk C --qr-px P [--profile …] [--noise --contrast --blur --rotation] --out f.png
//                                         保存一张模拟画面，检查模拟器本身
// qr-bench images a.png b.png …            从截图识别二维码、拼回 UR 并按类型解析
// qr-bench gif --bytes N --chunk C --fps F --out file.gif
//                                         生成给手机播放的测试 GIF（和 App 扫码页的测试数据一致）

let args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String, _ fallback: String) -> String {
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return fallback }
    return args[i + 1]
}

func intOption(_ name: String, _ fallback: Int) -> Int { Int(option(name, String(fallback)))! }
func doubleOption(_ name: String, _ fallback: Double) -> Double { Double(option(name, String(fallback)))! }

func correctionOption() -> QRRenderer.Correction {
    QRRenderer.Correction(rawValue: option("ec", "L").uppercased())!
}

func frameSize() -> (Int, Int) {
    let parts = option("frame", "1280x720").split(separator: "x").map { Int($0)! }
    return (parts[0], parts[1])
}

/// 测试数据编成 `ur:bytes` 多帧（和 App 显示的一样，大写）。前 seqLen 帧是原始分片，之后是喷泉码混合帧。
func urFrames(bytes: Int, chunk: Int, loops: Int = 1) -> [String] {
    var frames = URFrames(try! UR(type: "bytes", value: .bytes(TestPayload.bytes(count: bytes))), maxFragmentLen: chunk)
    return (0..<(frames.isSinglePart ? 1 : frames.seqLen * loops)).map { _ in frames.next() }
}

func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: " ", count: n - s.count) + s }

// MARK: - capacity

func runCapacity() {
    print("每帧字节 | 帧字符数 | L: 版本 模块 | M: 版本 模块")
    for chunk in [50, 100, 150, 200, 250, 300, 400, 500, 600, 800, 1000, 1200] {
        let frame = urFrames(bytes: chunk * 3, chunk: chunk)[1]
        let l = QRRenderer.symbol(for: frame, correction: .low)!
        let m = QRRenderer.symbol(for: frame, correction: .medium)!
        print("\(pad("\(chunk)", 8)) | \(pad("\(frame.count)", 8)) | \(pad("v\(l.version)", 4)) \(pad("\(l.modules)", 4)) | \(pad("v\(m.version)", 4)) \(pad("\(m.modules)", 4))")
    }
}

// MARK: - decode

func runDecode() {
    let (w, h) = frameSize()
    let trials = intOption("trials", 20)
    let ec = correctionOption()
    let chunks = [100, 200, 300, 400, 500, 700, 900]
    let widths: [Double] = [160, 220, 300, 400, 520]
    var sim = CaptureSimulator()
    let profile = option("profile", "typical")
    print("画面 \(w)x\(h)，纠错 \(ec.rawValue)，画质 \(profile)，每格 \(trials) 次。格内：识别率 / Vision 平均毫秒 / 每模块像素")
    print(pad("每帧字节\\二维码px", 16) + widths.map { pad("\(Int($0))", 22) }.joined())
    for chunk in chunks {
        let frame = urFrames(bytes: chunk * 2, chunk: chunk)[0]
        let symbol = QRRenderer.symbol(for: frame, correction: ec)!
        var row = pad("\(chunk) (v\(symbol.version))", 16)
        for px in widths {
            var ok = 0
            var visionSeconds: TimeInterval = 0
            for _ in 0..<trials {
                var conditions = CaptureSimulator.Conditions(frameWidth: w, frameHeight: h, qrPixels: px)
                conditions.apply(profile: profile)
                let image = sim.capture(symbol, conditions)!
                let t0 = now()
                let decoded = QRDecoder.decode(cgImage: image)
                visionSeconds += now() - t0
                if decoded.contains(frame) { ok += 1 }
            }
            let perModule = px / Double(symbol.image.width + 6)
            row += pad(String(format: "%3.0f%% %5.1fms %.1fpx", Double(ok) / Double(trials) * 100, visionSeconds / Double(trials) * 1000, perModule), 22)
        }
        print(row)
    }
}

// MARK: - transfer

func runTransfer() {
    let (w, h) = frameSize()
    let bytes = intOption("bytes", 2000)
    let chunk = intOption("chunk", 200)
    let fps = doubleOption("fps", 8)
    let qrPx = doubleOption("qr-px", 300)
    let cameraFPS = doubleOption("camera-fps", 30)
    // 曝光时间内如果屏幕切帧，拍到的是两帧混合。
    let exposure = doubleOption("exposure", 1.0 / 60)
    let trials = intOption("trials", 5)
    let ec = correctionOption()

    // App 里显示的是无限的喷泉码流；这里取 3 轮（原始分片 + 两轮混合帧）循环播放来近似。
    let frames = urFrames(bytes: bytes, chunk: chunk, loops: 3)
    let seqLen = max(1, frames.count / 3)
    let symbols = frames.map { QRRenderer.symbol(for: $0, correction: ec)! }
    var sim = CaptureSimulator()
    var conditions = CaptureSimulator.Conditions(frameWidth: w, frameHeight: h, qrPixels: qrPx)
    conditions.apply(profile: option("profile", "typical"))
    print("\(bytes) 字节 / 每帧 \(chunk) → \(seqLen) 个分片 v\(symbols[0].version)，播放 \(fps) fps，摄像头 \(cameraFPS) fps，二维码 \(Int(qrPx))px")
    print("理想时间（一轮）\(String(format: "%.2f", Double(seqLen) / fps))s")

    var results: [Double] = []
    var hitRates: [Double] = []
    for trial in 0..<trials {
        var tracker = URTransferTracker()
        let phase = Double.random(in: 0..<1) / fps
        var tick = 0
        var hits = 0
        let limit = Int(cameraFPS * Double(frames.count) / fps * 20)
        while tick < limit {
            let t = Double(tick) / cameraFPS + phase
            let a = Int(floor(t * fps))
            let b = Int(floor((t + exposure) * fps))
            let image: CGImage?
            if a == b {
                image = sim.capture(symbols[a % frames.count], conditions)
            } else {
                // 曝光跨过切帧：按时间比例混合两帧。
                let switchAt = Double(b) / fps
                let weight = (switchAt - t) / exposure
                let first = CIImage(cgImage: sim.capture(symbols[a % frames.count], conditions)!)
                let second = CIImage(cgImage: sim.capture(symbols[b % frames.count], conditions)!)
                image = blend(first, second, weightOfFirst: weight)
            }
            let decoded = QRDecoder.decode(cgImage: image!)
            if !decoded.isEmpty { hits += 1 }
            tick += 1
            if tracker.receive(decoded, at: Double(tick) / cameraFPS) != nil { break }
        }
        let seconds = tracker.transferSeconds.map { $0 + 1 / cameraFPS }
        print("第 \(trial + 1) 次：\(seconds.map { String(format: "%.2fs（%.2f 轮）", $0, $0 * fps / Double(seqLen)) } ?? "未完成")，摄像头帧识别率 \(String(format: "%.0f%%", Double(hits) / Double(tick) * 100))")
        if let seconds { results.append(seconds) }
        hitRates.append(Double(hits) / Double(tick))
    }
    if !results.isEmpty {
        let mean = results.reduce(0, +) / Double(results.count)
        print(String(format: "平均 %.2fs，有效吞吐 %.0f B/s，平均识别率 %.0f%%", mean, Double(bytes) / mean, hitRates.reduce(0, +) / Double(hitRates.count) * 100))
    }
}

let blendContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

func blend(_ a: CIImage, _ b: CIImage, weightOfFirst w: Double) -> CGImage? {
    let scaledA = a.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: w, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: w, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: w, w: 0),
    ])
    let scaledB = b.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 1 - w, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1 - w, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 1 - w, w: 0),
    ])
    let sum = scaledA.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: scaledB])
    return blendContext.createCGImage(sum, from: a.extent)
}

// MARK: - gif

func runGIF() {
    let bytes = intOption("bytes", 2000)
    let chunk = intOption("chunk", 200)
    let fps = doubleOption("fps", 8)
    let size = intOption("size", 900)
    let out = URL(fileURLWithPath: option("out", "qr-test.gif"))
    // 原始分片一轮 + 混合帧一轮，GIF 循环播放；漏掉的分片由混合帧补回。
    let frames = urFrames(bytes: bytes, chunk: chunk, loops: 2)
    let symbols = frames.map { QRRenderer.symbol(for: $0, correction: correctionOption())! }

    guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
        fatalError("无法写入 \(out.path)")
    }
    CGImageDestinationSetProperties(dest, [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
    ] as CFDictionary)
    for symbol in symbols {
        let modulePx = max(1, size / (symbol.image.width + 6))
        let side = modulePx * (symbol.image.width + 6)
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.interpolationQuality = .none
        let inset = CGFloat(modulePx * 3)
        ctx.draw(symbol.image, in: CGRect(x: inset, y: inset, width: CGFloat(side) - 2 * inset, height: CGFloat(side) - 2 * inset))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: 1 / fps,
                kCGImagePropertyGIFUnclampedDelayTime: 1 / fps,
            ],
        ] as CFDictionary)
    }
    guard CGImageDestinationFinalize(dest) else { fatalError("GIF 写入失败") }
    print("\(out.path)：\(bytes) 字节 / 每帧 \(chunk) → \(frames.count) 帧（含混合帧）v\(symbols[0].version)，\(fps) fps")
}

// MARK: - sample

/// 保存一张模拟拍摄的画面，用来检查模拟器本身。
func runSample() {
    let (w, h) = frameSize()
    let chunk = intOption("chunk", 200)
    let frame = urFrames(bytes: chunk * 2, chunk: chunk)[0]
    let symbol = QRRenderer.symbol(for: frame, correction: correctionOption())!
    var sim = CaptureSimulator()
    var conditions = CaptureSimulator.Conditions(frameWidth: w, frameHeight: h, qrPixels: doubleOption("qr-px", 300))
    conditions.apply(profile: option("profile", "typical"))
    conditions.rotationDegrees = doubleOption("rotation", conditions.rotationDegrees)
    conditions.blurSigma = doubleOption("blur", conditions.blurSigma)
    conditions.contrast = doubleOption("contrast", conditions.contrast)
    conditions.noiseAmplitude = doubleOption("noise", conditions.noiseAmplitude)
    let image = sim.capture(symbol, conditions)!
    let out = URL(fileURLWithPath: option("out", "sample.png"))
    let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("\(out.path)：识别结果 \(QRDecoder.decode(cgImage: image).map { $0 == frame ? "正确" : "错误" })")
}

// MARK: - images

/// 从截图里识别二维码、拼回 UR，并按类型解析（检查 App 实际显示出来的码）。
func runImages() {
    var tracker = URTransferTracker()
    for (i, path) in args.dropFirst().enumerated() {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { print("读不了 \(path)"); continue }
        let payloads = QRDecoder.decode(cgImage: image)
        print("\(path)：\(payloads.map { String($0.prefix(40)) + "…" })")
        guard let ur = tracker.receive(payloads, at: Double(i)) else { continue }
        print("拼完：\(ur.type)，CBOR \(ur.cbor.count) 字节")
        do {
            switch ur.type {
            case EthSignRequest.urType:
                let req = try EthSignRequest(ur: ur)
                let tx = try SafeTxRequest(signRequest: req)
                print("  eth-sign-request：data-type \(req.dataType)，chain \(req.chainID.map(String.init) ?? "-")，address \(req.address?.checksummed ?? "-")，指纹 \(req.derivationPath.sourceFingerprint.map { String(format: "%08X", $0) } ?? "-")")
                print("  Safe \(tx.safe.checksummed) nonce \(tx.tx.nonce) → \(tx.tx.to.checksummed)，safeTxHash \(tx.safeTxHash.hexString)")
            case SignRequestWithSafe.urType:
                let w = try SignRequestWithSafe(ur: ur)
                let tx = try SafeTxRequest(signRequest: w.request)
                let ic = try SafeAddress.verify(w.registration)
                print("  unipass-sign-request：请求签 \(tx.safe.checksummed) nonce \(tx.tx.nonce)，safeTxHash \(tx.safeTxHash.hexString)")
                print("  登记部分：\(w.registration.safe.checksummed)，\(w.registration.threshold)-of-\(w.registration.owners.count)，CREATE2 核对通过（\(ic.version)），请求指向它：\(w.requestTargetsRegisteredSafe == true)")
            case SafeRegistration.urType:
                let r = try SafeRegistration(ur: ur)
                let ic = try SafeAddress.verify(r)
                print("  unipass-safe：\(r.safe.checksummed)，\(r.threshold)-of-\(r.owners.count)，CREATE2 核对通过（\(ic.version)\(ic.isL2 ? " L2" : "")）")
            case SignerPairing.urType:
                let p = try SignerPairing(ur: ur)
                print("  unipass-pairing：\(p.name)，proxy \(p.signerProxy.checksummed)")
            default:
                break
            }
        } catch {
            print("  解析失败：\(error)")
        }
        return
    }
    print("没拼完：进度 \(String(format: "%.0f%%", tracker.progress * 100))，坏帧 \(tracker.badFrames)，非 UR \(tracker.foreign)")
}

switch args.first {
case "images": runImages()
case "sample": runSample()
case "capacity": runCapacity()
case "decode": runDecode()
case "transfer": runTransfer()
case "gif": runGIF()
default:
    print("用法：qr-bench capacity | decode | transfer | gif（参数见 main.swift 顶部）")
    exit(1)
}
