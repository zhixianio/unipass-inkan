import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

public enum QRCode {
    /// 用 CoreImage 生成二维码，每个模块放大成 `scale` 像素（最近邻，不糊边）。
    /// UR 用大写（`UR.qrString`）放进二维码，只用 QR 字母数字字符集，码更小。
    public static func image(for text: String, scale: CGFloat = 10, correction: String = "M") -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = correction
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
