import AVFoundation
import CoordinatorFlow
import QRTransport
import SwiftUI
import UniPassCore

/// 摄像头 + Vision + core 的 UR 解码。流程页和调试页共用。
@Observable
final class ScanModel {
    enum State: Equatable {
        case idle
        case starting
        case running
        case denied
        case failed(String)
    }

    var state: State = .idle
    var cameras: [CameraScanner.Camera] = []
    var cameraID: String?
    var preset: AVCaptureSession.Preset = .hd1280x720
    var stats = ScanStats()
    var tracker: URTransferTracker
    var result: UR?
    var lastPayload: String?
    /// 收齐后自动关摄像头（流程页）；调试页不关，方便连续测。
    let stopWhenDone: Bool
    @ObservationIgnored var onResult: ((UR) -> Void)?

    init(acceptedTypes: Set<String> = [], stopWhenDone: Bool = true) {
        tracker = URTransferTracker(acceptedTypes: acceptedTypes)
        self.stopWhenDone = stopWhenDone
    }

    @ObservationIgnored private(set) lazy var scanner = CameraScanner(
        onDecode: { [weak self] payloads, time in
            Task { @MainActor in self?.handle(payloads, at: time) }
        },
        onStats: { [weak self] stats in
            Task { @MainActor in self?.stats = stats }
        }
    )

    static let presets: [(String, AVCaptureSession.Preset)] = [
        ("640×480", .vga640x480),
        ("1280×720", .hd1280x720),
        ("1920×1080", .hd1920x1080),
    ]

    func start() async {
        state = .starting
        guard await CameraScanner.requestAccess() else {
            state = .denied
            return
        }
        cameras = CameraScanner.availableCameras()
        if cameraID == nil { cameraID = cameras.first?.id }
        do {
            try await scanner.start(cameraID: cameraID, preset: preset)
            state = .running
        } catch {
            state = .failed(String(describing: error))
        }
    }

    func stop() {
        scanner.stop()
        state = .idle
        stats = ScanStats()
    }

    func restart() async {
        guard state == .running else { return }
        await start()
    }

    func reset() {
        tracker.reset()
        result = nil
        lastPayload = nil
    }

    private func handle(_ payloads: [String], at time: TimeInterval) {
        lastPayload = payloads.last
        guard let ur = tracker.receive(payloads, at: time) else { return }
        result = ur
        if stopWhenDone { stop() }
        onResult?(ur)
    }
}

/// 流程页里嵌的扫码区：预览、开始 / 停止、进度。
struct URScannerView: View {
    @Bindable var model: ScanModel
    var prompt: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.black
                switch model.state {
                case .running, .starting:
                    CameraPreview(session: model.scanner.session)
                case .idle:
                    Text(prompt).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                case .denied:
                    Text("No camera access. Turn it on in System Settings › Privacy & Security › Camera.").foregroundStyle(.secondary).padding()
                case .failed(let message):
                    Text("The camera could not start: \(message)").foregroundStyle(.red).padding()
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: 520)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                if model.state == .running {
                    Button("Stop Scanning") { model.stop() }
                } else {
                    Button("Start Scanning") {
                        model.reset()
                        Task { await model.start() }
                    }
                    .disabled(model.state == .starting)
                }
                if model.state == .running {
                    ProgressView(value: model.tracker.progress).frame(maxWidth: 200)
                    Text(verbatim: String(format: "%.0f%%", model.tracker.progress * 100)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if model.tracker.foreign > 0 {
                Text("Ignored \(model.tracker.foreign) unrelated QR codes").font(.caption).foregroundStyle(.secondary)
            }
            if let failure = model.tracker.failure {
                Text("The code didn't come through completely. Scan it again.").font(.caption).foregroundStyle(.red)
                    .help(Text(verbatim: String(describing: failure)))
            }
        }
    }
}

/// 把一个 UR 显示成二维码：单帧静止，多帧按喷泉码循环换帧。
struct AnimatedURView: View {
    let ur: UR
    var maxFragmentLen = URFrames.defaultMaxFragmentLen
    var fps: Double = 8
    var correction: QRRenderer.Correction = .low
    /// 显示帧数和帧率（只给开发者窗口用）。
    var showsDetails = false

    @State private var image: CGImage?
    @State private var seqLen = 1
    @State private var frameCount = 0

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Color.white
                if let image {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(1, contentMode: .fit)
                        .padding(20)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(minWidth: 280, maxWidth: 520)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            if showsDetails {
                Text(seqLen == 1 ? "Single QR code" : "Animated QR code: \(seqLen) parts, \(Int(fps)) fps")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: TaskKey(ur: ur, maxFragmentLen: maxFragmentLen, fps: fps, correction: correction)) {
            var frames = URFrames(ur, maxFragmentLen: maxFragmentLen)
            seqLen = frames.seqLen
            repeat {
                image = QRRenderer.symbol(for: frames.next(), correction: correction)?.image
                frameCount += 1
                guard !frames.isSinglePart else { return }
                try? await Task.sleep(for: .seconds(1 / fps))
            } while !Task.isCancelled
        }
    }

    private struct TaskKey: Hashable {
        let ur: UR
        let maxFragmentLen: Int
        let fps: Double
        let correction: QRRenderer.Correction
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 地址：每 4 位一组，前 8 位和后 8 位加粗高亮（和签名器一致），中间变淡。永远完整显示。
struct AddressText: View {
    let address: Address
    var font: Font = .system(.body, design: .monospaced)

    var body: some View {
        let groups = PairedSigner.addressGroups(address)
        Text(Self.attributed(groups))
        .font(font)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    static func attributed(_ groups: [String]) -> AttributedString {
        var out = AttributedString("0x ")
        out.foregroundColor = .secondary
        for (i, g) in groups.enumerated() {
            let highlighted = PairedSigner.isHighlightedGroup(i, of: groups.count)
            var part = AttributedString(g + (i < groups.count - 1 ? " " : ""))
            part.inlinePresentationIntent = highlighted ? .stronglyEmphasized : nil
            part.foregroundColor = highlighted ? .primary : .secondary
            out += part
        }
        return out
    }
}

/// 一项检查的结果行。
struct CheckRow: View {
    let title: Text
    let ok: Bool?

    init(_ title: Text, ok: Bool?) {
        self.title = title
        self.ok = ok
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: ok == nil ? "circle.dotted" : ok! ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(ok == nil ? Color.secondary : ok! ? Color.green : Color.red)
            title
        }
    }
}
