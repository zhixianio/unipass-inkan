import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Vision

/// Vision 识别二维码，同步调用，供摄像头回调线程和基准测试使用。
public enum QRDecoder {
    public static func decode(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up) -> [String] {
        perform(VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation))
    }

    public static func decode(cgImage: CGImage) -> [String] {
        perform(VNImageRequestHandler(cgImage: cgImage))
    }

    private static func perform(_ handler: VNImageRequestHandler) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }
}
