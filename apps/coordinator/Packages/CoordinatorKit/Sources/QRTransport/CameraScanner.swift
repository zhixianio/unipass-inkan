@preconcurrency import AVFoundation
import Foundation

/// 每秒汇总一次的扫码统计。
public struct ScanStats: Equatable, Sendable {
    /// 摄像头送来的帧率。
    public var cameraFPS: Double = 0
    /// 实际交给 Vision 的帧率（Vision 跟不上时会丢帧）。
    public var processedFPS: Double = 0
    /// 处理过的帧里识别出至少一个二维码的比例。
    public var hitRate: Double = 0
    /// Vision 单帧平均耗时。
    public var meanDecodeMs: Double = 0
    public var width = 0
    public var height = 0

    public init() {}

    public init(cameraFPS: Double, processedFPS: Double, hitRate: Double, meanDecodeMs: Double, width: Int, height: Int) {
        self.cameraFPS = cameraFPS
        self.processedFPS = processedFPS
        self.hitRate = hitRate
        self.meanDecodeMs = meanDecodeMs
        self.width = width
        self.height = height
    }
}

/// 摄像头 + Vision 连续扫码。回调都在内部的串行队列上，调用方自己切回主线程。
///
/// 每帧同步跑一次 Vision，`alwaysDiscardsLateVideoFrames` 保证 Vision 慢时丢旧帧而不是排队，
/// 所以 `processedFPS` 就是这台机器在这个分辨率下的真实扫码帧率。
public final class CameraScanner: NSObject, @unchecked Sendable {
    public enum ScannerError: Error {
        case noCamera
        case cannotAddInput
        case cannotAddOutput
    }

    public struct Camera: Hashable, Sendable, Identifiable {
        public let id: String
        public let name: String
    }

    public let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "xyz.unipass.coordinator.camera.session")
    private let videoQueue = DispatchQueue(label: "xyz.unipass.coordinator.camera.video")

    /// 每个识别出二维码的帧调用一次：内容、帧时间（秒，单调时钟）。
    private let onDecode: @Sendable ([String], TimeInterval) -> Void
    private let onStats: @Sendable (ScanStats) -> Void

    // 以下只在 videoQueue 上访问。
    private var windowStart: TimeInterval = 0
    private var delivered = 0
    private var processed = 0
    private var hits = 0
    private var decodeSeconds: TimeInterval = 0
    private var lastSize = (0, 0)

    public init(
        onDecode: @escaping @Sendable ([String], TimeInterval) -> Void,
        onStats: @escaping @Sendable (ScanStats) -> Void
    ) {
        self.onDecode = onDecode
        self.onStats = onStats
    }

    /// 只弹一次系统授权框；之后直接返回已有结果。
    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    public static func availableCameras() -> [Camera] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices.map { Camera(id: $0.uniqueID, name: $0.localizedName) }
    }

    public func start(cameraID: String?, preset: AVCaptureSession.Preset) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                do {
                    try configure(cameraID: cameraID, preset: preset)
                    session.startRunning()
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public func stop() {
        sessionQueue.async { [session] in session.stopRunning() }
    }

    private func configure(cameraID: String?, preset: AVCaptureSession.Preset) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)

        let device = cameraID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .video)
        guard let device else { throw ScannerError.noCamera }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw ScannerError.cannotAddInput }
        session.addInput(input)
        session.sessionPreset = session.canSetSessionPreset(preset) ? preset : .high

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        // Vision 直接吃 420 双平面，省一次颜色转换。
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else { throw ScannerError.cannotAddOutput }
        session.addOutput(output)

        // 尽量拉到设备支持的最高帧率（MacBook 内置摄像头一般是 30）。
        if let maxRate = device.activeFormat.videoSupportedFrameRateRanges.map(\.maxFrameRate).max(),
           (try? device.lockForConfiguration()) != nil {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(maxRate.rounded(.down)))
            device.unlockForConfiguration()
        }
    }
}

extension CameraScanner: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if windowStart == 0 { windowStart = now }
        delivered += 1
        lastSize = (CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))

        let started = ProcessInfo.processInfo.systemUptime
        let payloads = QRDecoder.decode(pixelBuffer: pixelBuffer)
        decodeSeconds += ProcessInfo.processInfo.systemUptime - started
        processed += 1
        if !payloads.isEmpty {
            hits += 1
            onDecode(payloads, now)
        }
        flushStats(now: ProcessInfo.processInfo.systemUptime)
    }

    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        delivered += 1
    }

    private func flushStats(now: TimeInterval) {
        let elapsed = now - windowStart
        guard elapsed >= 1 else { return }
        onStats(ScanStats(
            cameraFPS: Double(delivered) / elapsed,
            processedFPS: Double(processed) / elapsed,
            hitRate: processed == 0 ? 0 : Double(hits) / Double(processed),
            meanDecodeMs: processed == 0 ? 0 : decodeSeconds / Double(processed) * 1000,
            width: lastSize.0,
            height: lastSize.1
        ))
        windowStart = now
        delivered = 0
        processed = 0
        hits = 0
        decodeSeconds = 0
    }
}
