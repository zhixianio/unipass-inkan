import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// 用 CoreImage 生成二维码。全大写的字母数字内容会自动用字母数字模式编码（实测）。
public enum QRRenderer {
    public enum Correction: String, CaseIterable, Sendable {
        case low = "L", medium = "M", quartile = "Q", high = "H"
    }

    /// 生成的二维码，每个模块 1 像素，四周带 1 模块的留白（CoreImage 自带）。
    /// 显示时放大并关掉插值。
    public struct Symbol: @unchecked Sendable {
        public let image: CGImage
        /// 不含留白的边长（模块数）。
        public var modules: Int { image.width - 2 }
        /// QR 版本 1–40。
        public var version: Int { (modules - 17) / 4 }
    }

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    public static func symbol(for text: String, correction: Correction = .low) -> Symbol? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = correction.rawValue
        guard let output = filter.outputImage,
              let image = context.createCGImage(output, from: output.extent)
        else { return nil }
        return Symbol(image: image)
    }
}
