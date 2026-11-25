import CoreImage
import CoreML
import Foundation
import UIKit

/// LaMa 模型推理。输入 / 输出规格来自对模型文件本身的实测
/// （2026-11-25 下载 model.mlmodel 解析）：
/// - 输入 `image`：800 x 800，RGB 彩色图
/// - 输入 `mask`：800 x 800，灰度图，白 = 要修复，黑 = 保留
/// - 输出 `output`：800 x 800，RGB 彩色图
/// 模型卡要求 computeUnits = .all（转换时验证过的配置）。
final class LaMaEngine {
    static let inputSize = 800

    enum EngineError: LocalizedError {
        case modelNotLoaded
        case pixelBufferFailed
        case outputMissing

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded: return "模型未加载"
            case .pixelBufferFailed: return "图像转像素缓冲失败"
            case .outputMissing: return "模型没有返回修复结果"
            }
        }
    }

    private var model: MLModel?

    var isLoaded: Bool { model != nil }

    /// 加载已编译好的模型。compiledURL 来自 ModelDownloader（首次启动编译后缓存）。
    func load(compiledURL: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all // 模型卡注明的验证配置，不要改成 .cpuAndGPU
        model = try MLModel(contentsOf: compiledURL, configuration: config)
    }

    /// 对 800x800 的裁剪图 + mask 做一次修复，返回 800x800 的修复图。
    func predict(image: CGImage, mask: CGImage) throws -> CGImage {
        guard let model = model else { throw EngineError.modelNotLoaded }
        guard image.width == Self.inputSize, image.height == Self.inputSize,
              mask.width == Self.inputSize, mask.height == Self.inputSize else {
            throw EngineError.pixelBufferFailed
        }
        let imageBuffer = try Self.pixelBuffer(from: image, format: kCVPixelFormatType_32ARGB)
        let maskBuffer = try Self.pixelBuffer(from: mask, format: kCVPixelFormatType_OneComponent8)
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: imageBuffer),
            "mask": MLFeatureValue(pixelBuffer: maskBuffer),
        ])
        let output = try model.prediction(from: provider)
        guard let outBuffer = output.featureValue(for: "output")?.imageBufferValue else {
            throw EngineError.outputMissing
        }
        let ciImage = CIImage(cvPixelBuffer: outBuffer)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let result = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw EngineError.outputMissing
        }
        return result
    }

    /// 把 CGImage 画进指定像素格式的 CVPixelBuffer，供 CoreML 输入用。
    private static func pixelBuffer(from cgImage: CGImage, format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, cgImage.width, cgImage.height,
                                         format, nil, &buffer)
        guard status == kCVReturnSuccess, let pixelBuffer = buffer else {
            throw EngineError.pixelBufferFailed
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw EngineError.pixelBufferFailed
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace: CGColorSpace
        let bitmapInfo: UInt32
        if format == kCVPixelFormatType_OneComponent8 {
            colorSpace = CGColorSpaceCreateDeviceGray()
            bitmapInfo = CGImageAlphaInfo.none.rawValue
        } else {
            colorSpace = CGColorSpaceCreateDeviceRGB()
            bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue
        }
        guard let context = CGContext(data: base, width: cgImage.width, height: cgImage.height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: colorSpace, bitmapInfo: bitmapInfo) else {
            throw EngineError.pixelBufferFailed
        }
        // Core Graphics 原点在左下角，CoreML 图像原点在左上角，翻转 Y。
        context.translateBy(x: 0, y: CGFloat(cgImage.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return pixelBuffer
    }
}
