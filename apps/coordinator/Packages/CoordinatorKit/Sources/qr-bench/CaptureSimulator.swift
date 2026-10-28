import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import QRTransport

/// 粗略模拟"Mac 摄像头拍 iPhone 屏幕上的二维码"：缩放到给定像素宽度、轻微旋转、
/// 失焦模糊、屏幕反光降对比度、传感器噪声。不模拟摩尔纹、运动模糊和自动曝光，
/// 真实数字以 App 扫码页实测为准。
struct CaptureSimulator {
    struct Conditions {
        /// 相机画面尺寸。
        var frameWidth = 1280
        var frameHeight = 720
        /// 二维码（含 4 模块白边）在画面里的像素宽度。
        var qrPixels: Double
        var rotationDegrees = 4.0
        var blurSigma = 0.9
        var contrast = 0.8
        /// 每像素独立的均匀噪声幅度（±）。ISP 降噪后的室内画面大约在 0.02–0.03。
        var noiseAmplitude = 0.03

        /// typical：室内正常光线、手机亮度中等。harsh：反光明显、光线偏暗、轻微失焦。
        mutating func apply(profile: String) {
            switch profile {
            case "typical": break
            case "harsh":
                blurSigma = 1.2
                contrast = 0.65
                noiseAmplitude = 0.04
            default: fatalError("未知 profile \(profile)")
            }
        }
    }

    // 不做色彩管理：噪声、对比度都按 sRGB 编码后的数值算，接近传感器输出；
    // 默认的线性工作空间会把 ±0.08 的噪声放大成整片发白。
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
    private var rng = SystemRandomNumberGenerator()

    mutating func capture(_ symbol: QRRenderer.Symbol, _ c: Conditions) -> CGImage? {
        // 屏幕上的二维码：符号四周再补 3 个模块白边（CoreImage 自带 1 个）。
        let qr = CIImage(cgImage: symbol.image)
        let side = qr.extent.width + 6
        let screen = qr.transformed(by: CGAffineTransform(translationX: 3, y: 3))
            .composited(over: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: side, height: side)))

        let scale = c.qrPixels / side
        let center = CGPoint(x: Double(c.frameWidth) / 2, y: Double(c.frameHeight) / 2)
        let placed = screen
            .samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: -c.qrPixels / 2, y: -c.qrPixels / 2))
            .transformed(by: CGAffineTransform(rotationAngle: c.rotationDegrees * .pi / 180))
            .transformed(by: CGAffineTransform(translationX: center.x, y: center.y))

        let frameRect = CGRect(x: 0, y: 0, width: c.frameWidth, height: c.frameHeight)
        let background = CIImage(color: CIColor(red: 0.22, green: 0.22, blue: 0.24)).cropped(to: frameRect)
        var image = placed.composited(over: background).clampedToExtent()
            .applyingGaussianBlur(sigma: c.blurSigma)
            .cropped(to: frameRect)

        let controls = CIFilter.colorControls()
        controls.inputImage = image
        controls.contrast = Float(c.contrast)
        controls.brightness = 0.05
        controls.saturation = 0
        image = controls.outputImage!

        // 零均值噪声：随机图 ×2A 再减 A。
        let noise = CIFilter.randomGenerator().outputImage!
            .transformed(by: CGAffineTransform(
                translationX: Double.random(in: 0...4096, using: &rng),
                y: Double.random(in: 0...4096, using: &rng)
            ))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 2 * c.noiseAmplitude, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 2 * c.noiseAmplitude, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 2 * c.noiseAmplitude, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: -c.noiseAmplitude, y: -c.noiseAmplitude, z: -c.noiseAmplitude, w: 1),
            ])
            .cropped(to: frameRect)
        image = noise.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: image])

        return context.createCGImage(image, from: frameRect)
    }
}
