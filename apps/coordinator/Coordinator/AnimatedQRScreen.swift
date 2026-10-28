import QRTransport
import SwiftUI
import UniPassCore

/// 调试：把一段 bytes 显示成 `ur:bytes` 动态二维码，帧大小、帧率、纠错可调，测上限用。
struct AnimatedQRScreen: View {
    enum Source: String, CaseIterable, Identifiable {
        case testBytes, hex, text
        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .testBytes: "Test data"
            case .hex: "Hex"
            case .text: "Text"
            }
        }
    }

    @State private var source: Source = .testBytes
    @State private var testByteCount = 2000
    @State private var hexInput = ""
    @State private var textInput = ""
    @State private var fragmentLen = URFrames.defaultMaxFragmentLen
    @State private var fps = 8.0
    @State private var correction: QRRenderer.Correction = .low

    private var ur: UR? {
        let message: Data? = switch source {
        case .testBytes: TestPayload.bytes(count: max(1, testByteCount))
        case .hex: Data(hex: hexInput.filter { !$0.isWhitespace })
        case .text: Data(textInput.utf8)
        }
        guard let message, !message.isEmpty else { return nil }
        return try? UR(type: "bytes", value: .bytes(message))
    }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let ur {
                    AnimatedURView(ur: ur, maxFragmentLen: fragmentLen, fps: fps, correction: correction, showsDetails: true).padding()
                } else {
                    Text(source == .hex ? "Not valid hex" : "Nothing to show").foregroundStyle(.red)
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Form {
                Section("Data") {
                    Picker("Source", selection: $source) {
                        ForEach(Source.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    switch source {
                    case .testBytes:
                        Stepper("Length \(testByteCount) B", value: $testByteCount, in: 100...50_000, step: 500)
                    case .hex:
                        TextField("Hex data (0x…)", text: $hexInput, axis: .vertical).lineLimit(3...6)
                    case .text:
                        TextField("Any text", text: $textInput, axis: .vertical).lineLimit(3...6)
                    }
                }
                Section("Playback") {
                    LabeledContent("Part size \(fragmentLen) B") {
                        Slider(value: Binding(get: { Double(fragmentLen) }, set: { fragmentLen = Int($0) }), in: 50...1000, step: 50)
                    }
                    LabeledContent("Frame rate \(Int(fps)) fps") {
                        Slider(value: $fps, in: 1...30, step: 1)
                    }
                    Picker("Error correction", selection: $correction) {
                        ForEach(QRRenderer.Correction.allCases, id: \.self) { Text(verbatim: $0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if let ur {
                    Section("Current settings") {
                        let frames = URFrames(ur, maxFragmentLen: fragmentLen)
                        LabeledContent("CBOR", value: "\(ur.cbor.count) B")
                        LabeledContent("Parts", value: "\(frames.seqLen)")
                        LabeledContent("One loop", value: String(format: "%.1f s", Double(frames.seqLen) / fps))
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 380)
        }
        .navigationTitle("Animated QR")
    }
}
