import AVFoundation
import SignerKit
import SwiftUI
import UniPassCore

/// 扫码：单帧 UR 直接完成，多帧 UR 按喷泉码累积。格式坏的帧忽略，继续扫。
struct ScanView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var decoder = URDecoder()
    @State private var status = ""
    #if DEBUG
    @State private var pasted = ""
    #endif

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                #if targetEnvironment(simulator)
                ContentUnavailableView("No camera in the simulator", systemImage: "camera.fill")
                #else
                QRScanner { receive($0) }.aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 16))
                #endif
                ProgressView(value: decoder.progress).padding(.horizontal)
                if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.secondary) }
                #if DEBUG
                if DebugTools.enabled {
                    TextField(text: $pasted, axis: .vertical) { Text(verbatim: "Debug: paste a UR") }
                        .font(.caption.monospaced()).textFieldStyle(.roundedBorder).padding(.horizontal)
                    Button { pasted.split(separator: "\n").forEach { receive(String($0)) } } label: { Text(verbatim: "Debug: decode") }
                }
                #endif
                Spacer()
            }
            .padding(.top)
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func receive(_ text: String) {
        guard decoder.result == nil else { return }
        do {
            try decoder.receive(text.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            status = String(localized: "Skipped an unreadable frame.")
        }
        switch decoder.result {
        case .success(let ur)?:
            dismiss()
            model.handleScanned(ur)
        case .failure?:
            status = String(localized: "The code could not be decoded. Ask UniPass Inkan Desktop to show it again.")
            decoder = URDecoder()
        case nil:
            break
        }
    }
}

#if !targetEnvironment(simulator)
/// AVFoundation 的二维码扫描（不涉及网络）。
struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.onCode = onCode
        return c
    }

    func updateUIViewController(_ c: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()

        override func viewDidLoad() {
            super.viewDidLoad()
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
            let s = session
            DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            view.layer.sublayers?.first?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            session.stopRunning()
        }

        /// 代理队列设成了 .main（见 viewDidLoad），所以这里实际就在主线程上。
        nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            let codes = objects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
            MainActor.assumeIsolated {
                for c in codes { onCode?(c) }
            }
        }
    }
}
#endif
