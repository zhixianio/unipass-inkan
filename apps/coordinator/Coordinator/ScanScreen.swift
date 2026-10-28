import AVFoundation
import QRTransport
import SwiftUI
import UniPassCore

/// 调试：连续扫任意 UR，看帧率、识别率、拼完用时。
struct ScanScreen: View {
    @State private var model = ScanModel(stopWhenDone: false)

    var body: some View {
        HStack(spacing: 0) {
            preview
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Form {
                controls
                statsSection
                transferSection
            }
            .formStyle(.grouped)
            .frame(width: 380)
        }
        .navigationTitle("Scan Test")
        .onDisappear { model.stop() }
    }

    @ViewBuilder private var preview: some View {
        ZStack {
            Color.black
            switch model.state {
            case .running, .starting:
                CameraPreview(session: model.scanner.session)
            case .idle:
                Text("Click Start to open the camera").foregroundStyle(.secondary)
            case .denied:
                Text("No camera access. Turn it on in System Settings › Privacy & Security › Camera.")
                    .foregroundStyle(.secondary).padding()
            case .failed(let message):
                Text("The camera could not start: \(message)").foregroundStyle(.red).padding()
            }
        }
    }

    @ViewBuilder private var controls: some View {
        Section("Camera") {
            if !model.cameras.isEmpty {
                Picker("Device", selection: $model.cameraID) {
                    ForEach(model.cameras) { Text(verbatim: $0.name).tag(Optional($0.id)) }
                }
                .onChange(of: model.cameraID) { Task { await model.restart() } }
            }
            Picker("Resolution", selection: $model.preset) {
                ForEach(ScanModel.presets, id: \.1) { Text(verbatim: $0.0).tag($0.1) }
            }
            .onChange(of: model.preset) { Task { await model.restart() } }
            HStack {
                if model.state == .running {
                    Button("Stop") { model.stop() }
                } else {
                    Button("Start") { Task { await model.start() } }
                        .disabled(model.state == .starting)
                }
                Button("Reset Progress") { model.reset() }
            }
        }
    }

    @ViewBuilder private var statsSection: some View {
        Section("Live (updated every second)") {
            LabeledContent("Frame", value: model.stats.width == 0 ? "—" : "\(model.stats.width)×\(model.stats.height)")
            LabeledContent("Camera frame rate", value: String(format: "%.1f fps", model.stats.cameraFPS))
            LabeledContent("Vision frame rate", value: String(format: "%.1f fps", model.stats.processedFPS))
            LabeledContent("Vision time per frame", value: String(format: "%.1f ms", model.stats.meanDecodeMs))
            LabeledContent("Frames with a QR code", value: String(format: "%.0f%%", model.stats.hitRate * 100))
        }
    }

    @ViewBuilder private var transferSection: some View {
        Section("UR multi-part transfer") {
            let t = model.tracker
            LabeledContent("Type", value: t.decoder.expectedType ?? model.result?.type ?? "—")
            ProgressView(value: t.progress)
            LabeledContent("Frames received (with repeats)", value: "\(t.acceptedFrames)")
            LabeledContent("Bad frames (dropped)", value: "\(t.badFrames)")
            LabeledContent("Non-UR QR codes", value: "\(t.foreign)")
            if let ur = model.result, let seconds = t.transferSeconds {
                LabeledContent("Done", value: String(format: "%@, %d B CBOR, %.2f s", ur.type, ur.cbor.count, seconds))
                if ur.type == "bytes", case .bytes(let payload) = ur.value {
                    LabeledContent("Content") { Text(payload == TestPayload.bytes(count: payload.count) ? "✔ Matches the test data" : "Not test data (CRC checked)") }
                }
            }
            if let failure = t.failure {
                LabeledContent("Failed", value: String(describing: failure))
            }
            if let last = model.lastPayload {
                HexField(label: "Last frame", value: last)
            }
        }
    }
}
